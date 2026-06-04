#include "readline.h"
#include "linenoise.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <sys/stat.h>
#include <termios.h>

/* ============================================================
 * Ctrl+C / 中断状态
 *
 * 交互模式（linenoise raw mode）：
 *   - ISIG 被禁用，Ctrl+C 产生 0x03 字节而非 SIGINT
 *   - linenoise 捕获后返回 NULL + errno=EAGAIN
 *   - 此时通过 g_agent_interrupted 设置 agent 的中断标志
 *
 * 非交互模式（fgets）：
 *   - ISIG 开启，Ctrl+C 产生 SIGINT
 *   - sigint_handler 设置 g_sigint_received，readline 循环检测后退出
 * ============================================================ */

static volatile sig_atomic_t g_sigint_received = 0;

/* agent 的 interrupted 和 running 指针 — 在 readline_thread_start 之前设置 */
static volatile int *g_agent_interrupted = NULL;
static const volatile int *g_agent_running = NULL;

void readline_set_agent_interrupted(volatile int *interrupted, const volatile int *running) {
    g_agent_interrupted = interrupted;
    g_agent_running = running;
}

static void sigint_handler(int sig) {
    (void)sig;
    g_sigint_received = 1;
    /* 非交互模式下，直接设置 agent interrupted 标志 */
    if (g_agent_interrupted) {
        *(g_agent_interrupted) = 1;
    }
}

/* ============================================================
 * 全局 linenoiseState 共享 — display worker 用它做 Hide/Show
 * ============================================================ */

static pthread_mutex_t g_display_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct linenoiseState *g_current_ls = NULL;
static int g_ls_active = 0; /* 1=linenoise 在编辑中 */
static int g_prompt_detached = 0;  /* 上一轮输出没以 \n 结尾，prompt 被 push 到下一行 */
static int g_output_col = 0;       /* 上一轮输出结束时的光标列位置 */

/* ============================================================
 * display worker 调用：开始一轮输出
 *
 * 流程：锁 mutex → Hide prompt → 如果 detached 则回退光标到 output_col → 开 OPOST
 * 对应 Go 版 Readline.AcquireOutputLock
 * ============================================================ */
void readline_display_begin(void) {
    pthread_mutex_lock(&g_display_mutex);
    if (g_ls_active && g_current_ls) {
        /* Hide prompt */
        linenoiseHide(g_current_ls);

        /* 如果上一轮输出没以 \n 结尾（prompt detached），光标回退到上一行的 output_col */
        if (g_prompt_detached) {
            fputs("\x1b[1A\r", stdout);
            if (g_output_col > 0) {
                fprintf(stdout, "\x1b[%dC", g_output_col);
            }
            fflush(stdout);
            g_prompt_detached = 0;
        }

        /* 暂时恢复 OPOST，让 display 的 \n 自动 CR+LF */
        struct termios tios;
        if (tcgetattr(STDIN_FILENO, &tios) == 0) {
            tios.c_oflag |= OPOST;
            tcsetattr(STDIN_FILENO, TCSADRAIN, &tios);
        }
    }
}

/* ============================================================
 * display worker 调用：结束一轮输出
 *
 * 流程：flush → 关 OPOST（恢复 raw mode）→ 如果没以 \n 结尾则 push prompt → 记录 output_col → Show → 解锁
 * 对应 Go 版 AcquireOutputLock 返回的 unlock 函数
 * ============================================================ */
void readline_display_end(int output_col, int output_at_newline) {
    if (g_ls_active && g_current_ls) {
        /* 先 flush 所有 display 输出（在 OPOST 下 \n 已被正确转换） */
        fflush(stdout);

        /* 恢复 linenoise raw mode（关闭 OPOST），避免 Show 的输出被 OPOST 干扰 */
        struct termios tios;
        if (tcgetattr(STDIN_FILENO, &tios) == 0) {
            tios.c_oflag &= ~OPOST;
            tcsetattr(STDIN_FILENO, TCSADRAIN, &tios);
        }

        /* 如果输出没以 \n 结尾，push prompt 到下一行 */
        if (!output_at_newline) {
            fputs("\r\n", stdout);
            fflush(stdout);
            g_prompt_detached = 1;
        } else {
            g_prompt_detached = 0;
        }

        /* 记录本次输出的光标列位置，供下一轮 begin 回退用 */
        g_output_col = output_col;

        /* Show prompt */
        linenoiseShow(g_current_ls);
    }
    pthread_mutex_unlock(&g_display_mutex);
}

/* display worker 调用：Hide 当前 prompt（兼容旧调用点） */
void readline_display_hide(void) {
    pthread_mutex_lock(&g_display_mutex);
    if (g_ls_active && g_current_ls) {
        linenoiseHide(g_current_ls);
    }
    pthread_mutex_unlock(&g_display_mutex);
}

/* display worker 调用：Show 当前 prompt */
void readline_display_show(void) {
    pthread_mutex_lock(&g_display_mutex);
    if (g_ls_active && g_current_ls) {
        linenoiseShow(g_current_ls);
    }
    pthread_mutex_unlock(&g_display_mutex);
}

/* ============================================================
 * History 文件路径构建
 *
 * 与 Bash/Rust/Go 版一致：~/.bash-agent/history
 * 使用 linenoise 内置的 linenoiseHistoryLoad/Save 管理。
 * ============================================================ */

#define MAX_LINE 65536

static char *build_history_path(const char *home) {
    StrBuf path;
    sb_init(&path);
    sb_appendf(&path, "%s/.bash-agent/history", home ? home : "/");
    return path.data; /* 调用者负责 free */
}

/* ============================================================
 * readline 线程
 *
 * 使用 linenoise 非阻塞 API（linenoiseEditStart/Feed/Stop）：
 *   - linenoise 管理 raw mode、UTF-8 编辑、history 导航
 *   - SIGINT handler 设置 g_sigint_received 标志
 *   - Ctrl+C 时 linenoiseEditFeed 返回 NULL + errno=EAGAIN
 *   - Ctrl+D 时返回 NULL + errno=ENOENT
 *   - Enter 时返回堆分配的字符串
 *
 * 输出到 stderr（不污染 stdout 管道）。
 * 不再使用 done 同步 — readline 线程立即进入下一轮 EditStart。
 * display worker 通过共享 linenoiseState + Hide/Show 保护输出。
 * ============================================================ */

static void *readline_thread_fn(void *arg) {
    ReadlineConfig *cfg = (ReadlineConfig *)arg;
    char linebuf[MAX_LINE];

    if (cfg->interactive) {
        /* 构建 history 路径，确保目录存在 */
        char *hist_path = build_history_path(cfg->home);
        {
            char *last_slash = strrchr(hist_path, '/');
            if (last_slash) {
                *last_slash = '\0';
                mkdir(hist_path, 0755);
                *last_slash = '/';
            }
        }
        linenoiseSetMultiLine(1);
        linenoiseHistorySetMaxLen(4096);
        linenoiseHistoryLoad(hist_path);

        /* 安装 SIGINT handler */
        struct sigaction sa, old_sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = sigint_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        sigaction(SIGINT, &sa, &old_sa);

        while (1) {
            /* 重置 SIGINT 标志 */
            g_sigint_received = 0;

            /* 使用 linenoise 非阻塞 API
             * 传入 STDERR_FILENO 作为输出 fd，避免提示符污染 stdout */
            struct linenoiseState ls;
            if (linenoiseEditStart(&ls, STDIN_FILENO, STDERR_FILENO,
                                   linebuf, sizeof(linebuf),
                                   "\x1b[32m> \x1b[0m") == -1) {
                break;
            }

            /* 注册到全局共享状态，让 display worker 可以 Hide/Show */
            pthread_mutex_lock(&g_display_mutex);
            g_current_ls = &ls;
            g_ls_active = 1;
            pthread_mutex_unlock(&g_display_mutex);

            /* 循环读取输入 */
            char *result;
            while ((result = linenoiseEditFeed(&ls)) == linenoiseEditMore) {
                /* linenoiseEditFeed 内部 read() 会被 SIGINT 打断
                 * 但 linenoise 自己处理 Ctrl+C（返回 NULL + EAGAIN）
                 * 这里只是继续等待 */
            }

            /* 清除全局共享状态 */
            pthread_mutex_lock(&g_display_mutex);
            g_current_ls = NULL;
            g_ls_active = 0;
            pthread_mutex_unlock(&g_display_mutex);

            linenoiseEditStop(&ls);

              if (result == NULL) {
                  if (errno == EAGAIN) {
                      /* Ctrl+C — linenoise 已显示 ^C 并换行
                       * 如果 agent 正在运行（agent_loop 执行中），
                       * 设置 interrupted 标志让它中断当前 HTTP 请求 */
                      if (g_agent_running && *g_agent_running && g_agent_interrupted) {
                          *(g_agent_interrupted) = 1;
                      }
                      continue;
                  }
                /* Ctrl+D 或 I/O 错误 — 退出 */
                fprintf(stderr, "\n");
                break;
            }

            /* result 是堆分配的字符串，linenoiseEditStop 不释放 buf，
             * 但 result 指向的是 ls.buf（linebuf），不是 malloc 的。
             * 实际上 linenoiseEditFeed 在 Enter 时返回 strdup(buf)。*/
            strncpy(linebuf, result, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
            linenoiseFree(result);

            /* 去除尾部空白 */
            util_rtrim(linebuf);

            /* 空行跳过 */
            if (linebuf[0] == '\0') continue;

            /* exit / quit */
            if (strcmp(linebuf, "exit") == 0 || strcmp(linebuf, "quit") == 0) {
                break;
            }

            /* 添加到 history */
            linenoiseHistoryAdd(linebuf);
            linenoiseHistorySave(hist_path);

            /* 构造 InputMessage 并推送到队列。
             * 不再使用 done 同步机制 — readline 线程立即进入下一轮 EditStart。
             * display worker 通过 Hide/Show 保护输出。 */
            InputMessage *msg = malloc(sizeof(InputMessage));
            if (!msg) break;
            memset(msg, 0, sizeof(*msg));
            msg->type = MSG_USER_INPUT;
            msg->data.user_input.text = util_strdup(linebuf);

            if (mq_push(cfg->input_queue, msg) != 0) {
                input_message_free(msg);
                free(msg);
                break; /* 队列已关闭 */
            }

            /* 不再等 done — 立即进入下一轮循环 */
        }

        /* 恢复原始 SIGINT handler */
        sigaction(SIGINT, &old_sa, NULL);
        g_agent_interrupted = NULL;

        free(hist_path);
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
