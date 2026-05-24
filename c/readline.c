#include "readline.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <termios.h>
#include <sys/stat.h>

/* ============================================================
 * 全局 SIGINT 状态
 *
 * 模仿 Rust 版的 CTRLC_FLAG 设计：
 * - 全局标志由 SIGINT handler 设置
 * - readline 线程用它区分 Ctrl+C（重新提示）和 Ctrl+D（退出）
 * - agent_loop 的 SSE 层检查它来中断 HTTP 请求
 * ============================================================ */

static volatile sig_atomic_t g_sigint_received = 0;

/* agent 的 interrupted 指针 — 在 readline_thread_start 之前由 cagent.c 设置 */
static volatile int *g_agent_interrupted = NULL;

int readline_sigint_consumed(void) {
    if (g_sigint_received) {
        g_sigint_received = 0;
        return 1;
    }
    return 0;
}

void readline_set_agent_interrupted(volatile int *flag) {
    g_agent_interrupted = flag;
}

static void sigint_handler(int sig) {
    (void)sig;
    g_sigint_received = 1;
    /* 同时设置 agent 的 interrupted 标志，让 http_post_sse 中的 curl 被中断 */
    if (g_agent_interrupted) {
        *(g_agent_interrupted) = 1;
    }
}

/* ============================================================
 * History 管理
 *
 * 与 Bash/Rust/Go 版一致：~/.bash-agent/history，每行一条。
 * ============================================================ */

#define MAX_HISTORY 4096
#define MAX_LINE 65536

typedef struct {
    char **entries;      /* 历史条目数组 */
    int count;           /* 条目数量 */
    int cap;             /* 数组容量 */
    char *filepath;      /* history 文件路径 */
} History;

static void history_init(History *h, const char *home) {
    memset(h, 0, sizeof(*h));
    h->cap = 256;
    h->entries = malloc(h->cap * sizeof(char*));
    h->count = 0;
    /* 构建路径：home/.bash-agent/history */
    StrBuf path;
    sb_init(&path);
    sb_appendf(&path, "%s/.bash-agent/history", home ? home : "/");
    h->filepath = path.data;
}

static void history_load(History *h) {
    FILE *f = fopen(h->filepath, "r");
    if (!f) return;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) {
        /* trim */
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r'))
            line[--len] = '\0';
        if (len == 0 || line[0] == '#') continue;
        /* 去重：跳过与最后一条相同的 */
        if (h->count > 0 && strcmp(h->entries[h->count - 1], line) == 0)
            continue;
        if (h->count >= h->cap) {
            h->cap *= 2;
            h->entries = realloc(h->entries, h->cap * sizeof(char*));
        }
        h->entries[h->count++] = util_strdup(line);
    }
    fclose(f);
}

static void history_add(History *h, const char *line) {
    if (!line || !line[0]) return;
    /* 去重：跳过与最后一条相同的 */
    if (h->count > 0 && strcmp(h->entries[h->count - 1], line) == 0)
        return;
    if (h->count >= MAX_HISTORY) {
        /* 移除最旧的 */
        free(h->entries[0]);
        memmove(h->entries, h->entries + 1, (h->count - 1) * sizeof(char*));
        h->count--;
    }
    if (h->count >= h->cap) {
        h->cap *= 2;
        h->entries = realloc(h->entries, h->cap * sizeof(char*));
    }
    h->entries[h->count++] = util_strdup(line);
    /* 追加写入文件 */
    FILE *f = fopen(h->filepath, "a");
    if (f) {
        fprintf(f, "%s\n", line);
        fclose(f);
    }
}

static void history_free(History *h) {
    for (int i = 0; i < h->count; i++) free(h->entries[i]);
    free(h->entries);
    free(h->filepath);
}

/* ============================================================
 * Raw mode 终端控制
 *
 * 在 readline 期间关闭 ICANON + ECHO，手动处理字符输入/回显。
 * 退出 readline 恢复原始设置，确保 agent 执行期间 Ctrl+C 正常
 * 产生 SIGINT（ISIG 保持开启）。
 * ============================================================ */

static int g_termios_saved = 0;
static struct termios g_termios_orig;

/* 进入 raw mode（ICANON off, ECHO off, ISIG on） */
static void term_raw_enter(void) {
    if (!g_termios_saved) {
        tcgetattr(STDIN_FILENO, &g_termios_orig);
        g_termios_saved = 1;
    }
    struct termios raw = g_termios_orig;
    raw.c_lflag &= ~(ICANON | ECHO);  /* 关闭规范模式和回显 */
    /* ISIG 保持开启，但 Ctrl+C 在 raw mode 下由内核转为 SIGINT，
     * 我们需要关闭 ISIG 来自己处理 0x03 */
    raw.c_lflag &= ~ISIG;
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &raw);
}

/* 恢复原始终端设置 */
static void term_raw_leave(void) {
    if (g_termios_saved) {
        tcsetattr(STDIN_FILENO, TCSANOW, &g_termios_orig);
    }
}

/* ============================================================
 * 交互式行读取 — raw mode，手动处理字符输入
 *
 * 支持：
 *   - 普通字符回显（UTF-8 安全）
 *   - Backspace/Delete 删除字符
 *   - Ctrl+C 清空输入行，显示 ^C，换行继续
 *   - Ctrl+D 空行退出，非空行删光标后字符
 *   - Ctrl+A 跳行首，Ctrl+E 跳行尾
 *   - Ctrl+U 清空整行
 *   - 上/下箭头 history 导航
 *   - 左/右箭头光标移动
 * ============================================================ */

/* 计算 buf[0..len) 的显示列数（UTF-8 安全）
 * ASCII = 1 列, CJK/emoji 等 >= 3 字节的 = 2 列, 其余 UTF-8 = 1 列 */
static int display_width(const char *buf, size_t len) {
    int cols = 0;
    size_t i = 0;
    while (i < len) {
        unsigned char c = (unsigned char)buf[i];
        if (c < 0x80) {
            cols++; i++;
        } else if (c < 0xC0) {
            i++; /* 续字节，不应出现 */
        } else {
            /* 计算字节数 */
            size_t clen = 2;
            if (c >= 0xF0) clen = 4;
            else if (c >= 0xE0) clen = 3;
            /* CJK 等宽字符（3+ 字节 UTF-8）占 2 列 */
            cols += (clen >= 3) ? 2 : 1;
            i += clen;
        }
    }
    return cols;
}

/* 返回值：1=有输入，0=EOF/退出，-1=Ctrl+C（重新提示） */
static int read_line_raw(char *buf, size_t bufsize, History *hist) {
    size_t pos = 0;       /* 当前行长度 */
    size_t cursor = 0;    /* 光标位置（0..pos） */
    int hist_pos = hist->count;  /* history 游标（count 表示不在历史中） */

    while (1) {
        unsigned char c;
        ssize_t n = read(STDIN_FILENO, &c, 1);
        if (n < 0) {
            if (errno == EINTR) {
                /* ISIG off 不会到这里，但防御性处理 */
                continue;
            }
            return 0; /* 其他错误视为 EOF */
        }
        if (n == 0) return 0;

        /* Ctrl+C */
        if (c == 0x03) {
            /* 清除当前行，显示 ^C 并换行 */
            if (cursor > 0) {
                int cols = display_width(buf, cursor);
                fprintf(stderr, "\x1b[%dD", cols);  /* 移到行首 */
                fprintf(stderr, "\x1b[K");          /* 清到行尾 */
            }
            fprintf(stderr, "^C\n");
            fflush(stderr);
            return -1;
        }

        /* Ctrl+D */
        if (c == 0x04) {
            if (pos == 0) {
                return 0; /* 空行退出 */
            }
            /* 非空行：删除光标后字符（暂时不实现复杂光标操作，等同忽略） */
            continue;
        }

        /* Ctrl+U 清空行 */
        if (c == 0x15) {
            if (pos > 0) {
                int cols = display_width(buf, cursor);
                fprintf(stderr, "\x1b[%dD", cols);
                fprintf(stderr, "\x1b[K");
                fflush(stderr);
                pos = 0;
                cursor = 0;
            }
            continue;
        }

        /* Ctrl+A 跳行首 */
        if (c == 0x01) {
            if (cursor > 0) {
                int cols = display_width(buf, cursor);
                fprintf(stderr, "\x1b[%dD", cols);
                fflush(stderr);
                cursor = 0;
            }
            continue;
        }

        /* Ctrl+E 跳行尾 */
        if (c == 0x05) {
            if (cursor < pos) {
                int cols = display_width(buf + cursor, pos - cursor);
                fprintf(stderr, "\x1b[%dC", cols);
                fflush(stderr);
                cursor = pos;
            }
            continue;
        }

        /* Backspace (0x08 或 0x7F) */
        if (c == 0x08 || c == 0x7F) {
            if (cursor > 0) {
                /* 删除光标前一个字符（UTF-8 安全：回退到上一个字符首字节） */
                size_t del_bytes = 1;
                /* UTF-8 续字节是 10xxxxxx (0x80..0xBF)，首字节不是 */
                while (cursor - del_bytes > 0 &&
                       (unsigned char)buf[cursor - del_bytes - 1] >= 0x80 &&
                       (unsigned char)buf[cursor - del_bytes - 1] <= 0xBF) {
                    del_bytes++;
                }
                /* 现在 cursor-del_bytes 是前一个字符的首字节位置 */
                if (cursor < del_bytes) del_bytes = cursor;
                size_t char_start = cursor - del_bytes;
                /* 计算显示列数（大多数 CJK = 2 列，其余 = 1 列） */
                int display_cols = 1;
                if (del_bytes >= 3) display_cols = 2; /* CJK 等宽字符占 2 列 */
                memmove(buf + char_start, buf + cursor, pos - cursor);
                pos -= del_bytes;
                cursor = char_start;
                buf[pos] = '\0';
                /* 重绘 */
                int after_cols = display_width(buf + cursor, pos - cursor);
                fprintf(stderr, "\x1b[%dD", display_cols); /* 回退显示列数 */
                fwrite(buf + cursor, 1, pos - cursor, stderr);
                for (int dc = 0; dc < display_cols; dc++) fputc(' ', stderr);
                fprintf(stderr, "\x1b[%dD", display_cols + after_cols);
                fflush(stderr);
            }
            continue;
        }

        /* ESC 序列（箭头键等） */
        if (c == 0x1b) {
            unsigned char seq[2];
            ssize_t n1 = read(STDIN_FILENO, &seq[0], 1);
            if (n1 <= 0) continue;
            if (seq[0] == '[') {
                ssize_t n2 = read(STDIN_FILENO, &seq[1], 1);
                if (n2 <= 0) continue;
                if (seq[1] == 'A') {
                    /* 上箭头：history 上移 */
                    if (hist_pos > 0) {
                        /* 清除当前行 */
                        fprintf(stderr, "\r\x1b[K");
                        hist_pos--;
                        const char *entry = hist->entries[hist_pos];
                        size_t elen = strlen(entry);
                        if (elen >= bufsize) elen = bufsize - 1;
                        memcpy(buf, entry, elen);
                        buf[elen] = '\0';
                        pos = elen;
                        cursor = elen;
                        fprintf(stderr, "\x1b[32m> \x1b[0m%s", buf);
                        fflush(stderr);
                    }
                } else if (seq[1] == 'B') {
                    /* 下箭头：history 下移 */
                    fprintf(stderr, "\r\x1b[K");
                    if (hist_pos < hist->count - 1) {
                        hist_pos++;
                        const char *entry = hist->entries[hist_pos];
                        size_t elen = strlen(entry);
                        if (elen >= bufsize) elen = bufsize - 1;
                        memcpy(buf, entry, elen);
                        buf[elen] = '\0';
                        pos = elen;
                        cursor = elen;
                    } else {
                        hist_pos = hist->count;
                        buf[0] = '\0';
                        pos = 0;
                        cursor = 0;
                    }
                    fprintf(stderr, "\x1b[32m> \x1b[0m%s", buf);
                    fflush(stderr);
                } else if (seq[1] == 'C') {
                    /* 右箭头（UTF-8 安全：跳过一个完整字符） */
                    if (cursor < pos) {
                        size_t skip = 1;
                        while (cursor + skip < pos &&
                               (unsigned char)buf[cursor + skip] >= 0x80 &&
                               (unsigned char)buf[cursor + skip] <= 0xBF) {
                            skip++;
                        }
                        int display_cols = 1;
                        if (skip >= 3) display_cols = 2;
                        cursor += skip;
                        fprintf(stderr, "\x1b[%dC", display_cols);
                        fflush(stderr);
                    }
                } else if (seq[1] == 'D') {
                    /* 左箭头（UTF-8 安全：回退到上一个字符首字节） */
                    if (cursor > 0) {
                        size_t skip = 1;
                        while (cursor - skip > 0 &&
                               (unsigned char)buf[cursor - skip - 1] >= 0x80 &&
                               (unsigned char)buf[cursor - skip - 1] <= 0xBF) {
                            skip++;
                        }
                        int display_cols = 1;
                        if (skip >= 3) display_cols = 2;
                        cursor -= skip;
                        fprintf(stderr, "\x1b[%dD", display_cols);
                        fflush(stderr);
                    }
                } else if (seq[1] == '3') {
                    /* Delete: ESC[3~ */
                    unsigned char tilde;
                    ssize_t n3 = read(STDIN_FILENO, &tilde, 1);
                    if (n3 > 0 && tilde == '~') {
                        if (cursor < pos) {
                            /* UTF-8 安全：跳过光标后的完整字符 */
                            size_t del_bytes = 1;
                            while (cursor + del_bytes < pos &&
                                   (unsigned char)buf[cursor + del_bytes] >= 0x80 &&
                                   (unsigned char)buf[cursor + del_bytes] <= 0xBF) {
                                del_bytes++;
                            }
                            int display_cols = 1;
                            if (del_bytes >= 3) display_cols = 2;
                            memmove(buf + cursor, buf + cursor + del_bytes, pos - cursor - del_bytes);
                            pos -= del_bytes;
                            buf[pos] = '\0';
                            int after_cols = display_width(buf + cursor, pos - cursor);
                            fwrite(buf + cursor, 1, pos - cursor, stderr);
                            for (int dc = 0; dc < display_cols; dc++) fputc(' ', stderr);
                            fprintf(stderr, "\x1b[%dD", display_cols + after_cols);
                            fflush(stderr);
                        }
                    }
                }
            }
            continue;
        }

        /* 回车 */
        if (c == 0x0d || c == 0x0a) {
            buf[pos] = '\0';
            fprintf(stderr, "\n");
            fflush(stderr);
            return 1;
        }

        /* 普通字符（可打印 ASCII 或 UTF-8 高字节） */
        if (c >= 0x20 && c < 0x7f) {
            if (pos < bufsize - 1) {
                /* 插入到 cursor 位置 */
                memmove(buf + cursor + 1, buf + cursor, pos - cursor);
                buf[cursor] = c;
                pos++;
                cursor++;
                buf[pos] = '\0';
                /* 重绘光标后的内容 */
                fwrite(buf + cursor - 1, 1, pos - cursor + 1, stderr);
                /* 回退到正确光标位置 */
                if (cursor < pos) {
                    int back_cols = display_width(buf + cursor, pos - cursor);
                    fprintf(stderr, "\x1b[%dD", back_cols);
                }
                fflush(stderr);
            }
            continue;
        }

        /* UTF-8 多字节序列首字节 */
        if (c >= 0xc0) {
            /* 计算该 UTF-8 字符的字节数 */
            int utf8_len = 1;
            if (c >= 0xf0) utf8_len = 4;
            else if (c >= 0xe0) utf8_len = 3;
            else if (c >= 0xc0) utf8_len = 2;

            if (pos + utf8_len < bufsize) {
                /* 读后续字节 */
                char utf8_buf[4];
                utf8_buf[0] = c;
                for (int u = 1; u < utf8_len; u++) {
                    ssize_t un = read(STDIN_FILENO, &utf8_buf[u], 1);
                    if (un <= 0) break;
                }
                /* 插入到 cursor 位置 */
                memmove(buf + cursor + utf8_len, buf + cursor, pos - cursor);
                memcpy(buf + cursor, utf8_buf, utf8_len);
                pos += utf8_len;
                cursor += utf8_len;
                buf[pos] = '\0';
                /* 重绘 */
                fwrite(buf + cursor - utf8_len, 1, pos - cursor + utf8_len, stderr);
                if (cursor < pos) {
                    int back_cols = display_width(buf + cursor, pos - cursor);
                    fprintf(stderr, "\x1b[%dD", back_cols);
                }
                fflush(stderr);
            }
            continue;
        }

        /* 其他控制字符忽略 */
    }
}

/* ============================================================
 * readline 线程
 * ============================================================ */

static void *readline_thread_fn(void *arg) {
    ReadlineConfig *cfg = (ReadlineConfig *)arg;
    char linebuf[MAX_LINE];

    if (cfg->interactive) {
        /* 初始化 history */
        History hist;
        history_init(&hist, cfg->home);
        /* 确保目录存在 */
        {
            StrBuf cmd;
            sb_init(&cmd);
            sb_appendf(&cmd, "mkdir -p '%s'", hist.filepath);
            /* 取目录部分 */
            char *last_slash = strrchr(hist.filepath, '/');
            if (last_slash) {
                *last_slash = '\0';
                mkdir(hist.filepath, 0755);
                *last_slash = '/';
            }
            sb_free(&cmd);
        }
        history_load(&hist);

        /* 安装 SIGINT handler */
        struct sigaction sa, old_sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = sigint_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0; /* 不用 SA_RESTART，让 read() 被 SIGINT 打断返回 EINTR */
        sigaction(SIGINT, &sa, &old_sa);

        while (1) {
            /* 重置 SIGINT 标志 */
            g_sigint_received = 0;

            /* 进入 raw mode */
            term_raw_enter();

            fprintf(stderr, "\x1b[32m> \x1b[0m");
            fflush(stderr);

            int rc = read_line_raw(linebuf, sizeof(linebuf), &hist);

            /* 恢复终端设置 */
            term_raw_leave();

            if (rc < 0) {
                /* Ctrl+C — 已在 read_line_raw 中显示 ^C，继续循环 */
                continue;
            }
            if (rc == 0) {
                /* EOF — Ctrl+D */
                break;
            }

            /* 去除尾部空白 */
            util_rtrim(linebuf);

            /* 空行跳过 */
            if (linebuf[0] == '\0') continue;

            /* exit / quit */
            if (strcmp(linebuf, "exit") == 0 || strcmp(linebuf, "quit") == 0) {
                break;
            }

            /* 添加到 history */
            history_add(&hist, linebuf);

            /* 构造 InputMessage 并推送到队列。
             * 使用 done 同步机制（模仿 Rust 版 done channel）：
             * readline 线程发送消息后阻塞等待 agent_main_loop 处理完成。
             * 这确保 agent 运行期间不会显示提示符或读取下一行。 */
            pthread_mutex_t done_mutex;
            pthread_cond_t done_cond;
            int done_flag = 0;
            pthread_mutex_init(&done_mutex, NULL);
            pthread_cond_init(&done_cond, NULL);

            InputMessage *msg = malloc(sizeof(InputMessage));
            if (!msg) { pthread_mutex_destroy(&done_mutex); pthread_cond_destroy(&done_cond); break; }
            memset(msg, 0, sizeof(*msg));
            msg->type = MSG_USER_INPUT;
            msg->data.user_input.text = util_strdup(linebuf);
            msg->data.user_input.done_mutex = &done_mutex;
            msg->data.user_input.done_cond = &done_cond;
            msg->data.user_input.done_flag = &done_flag;

            if (mq_push(cfg->input_queue, msg) != 0) {
                input_message_free(msg);
                free(msg);
                pthread_mutex_destroy(&done_mutex);
                pthread_cond_destroy(&done_cond);
                break; /* 队列已关闭 */
            }

            /* 等待 agent_main_loop 处理完成 */
            pthread_mutex_lock(&done_mutex);
            while (!done_flag) {
                pthread_cond_wait(&done_cond, &done_mutex);
            }
            pthread_mutex_unlock(&done_mutex);

            pthread_mutex_destroy(&done_mutex);
            pthread_cond_destroy(&done_cond);
        }

        /* 恢复原始 SIGINT handler */
        sigaction(SIGINT, &old_sa, NULL);
        g_agent_interrupted = NULL;

        history_free(&hist);
    } else {
        /* 非交互模式：简单行读取（用 fgets，不需要处理信号） */
        while (1) {
            if (!fgets(linebuf, sizeof(linebuf), stdin)) {
                break;
            }
            util_rtrim(linebuf);
            if (linebuf[0] == '\0') continue;

            InputMessage *msg = malloc(sizeof(InputMessage));
            if (!msg) break;
            memset(msg, 0, sizeof(*msg));
            msg->type = MSG_USER_INPUT;
            msg->data.user_input.text = util_strdup(linebuf);

            if (mq_push(cfg->input_queue, msg) != 0) {
                input_message_free(msg);
                free(msg);
                break;
            }
        }
    }

    /* 退出时关闭 input_queue（让 agent_main_loop 的 mq_pop 不再阻塞） */
    mq_close(cfg->input_queue);

    free(cfg);
    return NULL;
}

int readline_thread_start(pthread_t *thread, const ReadlineConfig *cfg) {
    ReadlineConfig *heap_cfg = malloc(sizeof(ReadlineConfig));
    if (!heap_cfg) return -1;
    *heap_cfg = *cfg;
    return pthread_create(thread, NULL, readline_thread_fn, heap_cfg);
}
