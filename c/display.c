#include "display.h"
#include "readline.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <wchar.h>
#include <locale.h>
#include <sys/ioctl.h>

/* display 线程的显示状态 */
typedef struct {
    char last_char[8];      /* 最后一个字符（UTF-8 安全） */
    int prev_was_thinking;
    int output_col;         /* assistant 尾行显示列（ANSI=0，按 wcwidth 计算） */
} DisplayState;

static void ds_init(DisplayState *ds) {
    memset(ds, 0, sizeof(*ds));
    ds->last_char[0] = '\n';
    ds->last_char[1] = '\0';
    ds->prev_was_thinking = 0;
}

static void ds_update_output_col(DisplayState *ds, const char *text) {
    if (!text || !*text) return;
    static int locale_inited = 0;
    if (!locale_inited) {
        setlocale(LC_CTYPE, "");
        locale_inited = 1;
    }
    int esc = 0;
    for (const unsigned char *p = (const unsigned char *)text; *p; ) {
        unsigned char c = *p;
        if (esc) {
            if (c >= 0x40 && c <= 0x7e) esc = 0;
            p++;
            continue;
        }
        if (c == 0x1b && p[1] == '[') {
            esc = 1;
            p += 2;
            continue;
        }
        if (c == '\r') {
            ds->output_col = 0;
            p++;
            continue;
        }
        if (c == '\n') {
            ds->output_col = 0;
            p++;
            continue;
        }
        if (c < 0x80) {
            ds->output_col++;
            p++;
        } else {
            wchar_t wc = 0;
            int len = 1;
            if (c < 0xE0) len = 2;
            else if (c < 0xF0) len = 3;
            else len = 4;
            int w = mbtowc(&wc, (const char *)p, len);
            if (w > 0) {
                int cw = wcwidth(wc);
                ds->output_col += (cw > 0) ? cw : 0;
                p += w;
            } else {
                ds->output_col += 2;
                p += len;
            }
        }
    }
}

static int ds_physical_output_col(DisplayState *ds) {
    struct winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) != 0 || ws.ws_col <= 0 || ds->output_col <= 0) {
        return ds->output_col;
    }
    return ((ds->output_col - 1) % ws.ws_col) + 1;
}

static void ds_update_last_char(DisplayState *ds, const char *text) {
    if (!text || !*text) return;
    /* 找到最后一个 UTF-8 字符 */
    const char *p = text;
    const char *last = p;
    while (*p) {
        last = p;
        /* 跳过一个 UTF-8 字符 */
        unsigned char c = (unsigned char)*p;
        if (c < 0x80) p++;
        else if (c < 0xE0) p += 2;
        else if (c < 0xF0) p += 3;
        else p += 4;
    }
    size_t len = p - last;
    if (len > 0 && len < 8) {
        memcpy(ds->last_char, last, len);
        ds->last_char[len] = '\0';
    }
}

#if 0
static int ends_with_newline(const char *s) {
    size_t len = strlen(s);
    return len > 0 && s[len - 1] == '\n';
}
#endif

static void write_human(FILE *out, const char *text) {
    fputs(text, out);
    fflush(out);
}

static void ensure_newline(DisplayState *ds, FILE *out) {
    if (ds->last_char[0] != '\n') {
        fputc('\n', out);
        ds->last_char[0] = '\n';
        ds->last_char[1] = '\0';
        ds->output_col = 0;
    }
}

static void signal_flush(DisplayMessage *msg) {
    if (!msg->flush_mutex || !msg->flush_cond || !msg->flush_done) return;
    pthread_mutex_lock(msg->flush_mutex);
    *msg->flush_done = 1;
    pthread_cond_signal(msg->flush_cond);
    pthread_mutex_unlock(msg->flush_mutex);
}

/* 渲染一条 display 消息 */
static void render_message(FILE *out, DisplayState *ds, OutputFormat format,
                            int interactive, DisplayMessage *msg) {
    if (format == OUTPUT_STREAM_JSON) {
        /* stream-json 模式：对齐 bash 版 util_msg_to_stream 的事件形状 */
        StrBuf buf;
        sb_init(&buf);
        switch (msg->type) {
        case DISPLAY_TEXT:
            sb_append(&buf, "{\"type\":\"text\",\"content\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_THINKING:
            sb_append(&buf, "{\"type\":\"thinking\",\"content\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_TOOL_CALL:
            sb_append(&buf, "{\"type\":\"tool_call\",\"name\":");
            sb_append_json_string(&buf, msg->tool_name ? msg->tool_name : "");
            sb_append(&buf, ",\"id\":");
            sb_append_json_string(&buf, msg->tool_id ? msg->tool_id : "");
            sb_append(&buf, ",\"input\":");
            sb_append(&buf, (msg->tool_input && msg->tool_input[0]) ? msg->tool_input : "{}");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_TOOL_RESULT:
            sb_append(&buf, "{\"type\":\"tool_result\",\"tool_use_id\":");
            sb_append_json_string(&buf, msg->tool_id ? msg->tool_id : "");
            sb_append(&buf, ",\"name\":");
            sb_append_json_string(&buf, msg->tool_name ? msg->tool_name : "");
            sb_append(&buf, ",\"content\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_USAGE:
            sb_appendf(&buf, "{\"type\":\"usage\",\"input_tokens\":%d,\"output_tokens\":%d,"
                       "\"cache_read_input_tokens\":%d,\"cache_creation_input_tokens\":%d,"
                       "\"kind\":\"agent\"}",
                       msg->in_tokens, msg->out_tokens,
                       msg->cache_read_tokens, msg->cache_creation_tokens);
            break;
        case DISPLAY_STOP:
            sb_append(&buf, "{\"type\":\"stop\",\"reason\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_ERROR:
            sb_append(&buf, "{\"type\":\"error\",\"message\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_SUB_AGENT_START:
            sb_append(&buf, "{\"type\":\"sub_agent_start\",\"session_id\":");
            sb_append_json_string(&buf, msg->session_id ? msg->session_id : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_SUB_AGENT_RESULT:
            sb_append(&buf, "{\"type\":\"sub_agent_result\",\"session_id\":");
            sb_append_json_string(&buf, msg->session_id ? msg->session_id : "");
            sb_append(&buf, ",\"status\":");
            sb_append_json_string(&buf, msg->tool_exit_code == 0 ? "ok" : "failed");
            sb_appendf(&buf, ",\"input_tokens\":%d,\"output_tokens\":%d",
                       msg->in_tokens, msg->out_tokens);
            sb_append(&buf, ",\"thinking\":");
            sb_append_json_string(&buf, msg->tool_name ? msg->tool_name : "");
            sb_append(&buf, ",\"text\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_CONTEXT_UPDATE:
            sb_append(&buf, "{\"type\":\"context_update\",\"kind\":\"compact\",\"trigger\":");
            sb_append_json_string(&buf, msg->tool_name ? msg->tool_name : "auto");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_IMAGE_DESCRIBE:
            sb_append(&buf, "{\"type\":\"image_describe\",\"images\":\"");
            sb_append(&buf, msg->tool_name ? msg->tool_name : "");
            sb_append(&buf, "\",\"content\":");
            sb_append_json_string(&buf, msg->content ? msg->content : "");
            sb_append_char(&buf, '}');
            break;
        case DISPLAY_FLUSH:
            signal_flush(msg);
            sb_free(&buf);
            return;
        }
        fprintf(out, "%s\n", buf.data);
        fflush(out);
        sb_free(&buf);
        return;
    }

    /* human 模式 */
    /* Hide linenoise prompt before writing to stdout; keep readline lock held
     * until after Show so EditFeed cannot mutate terminal state concurrently. */
    if (interactive) readline_display_begin();

    switch (msg->type) {
        case DISPLAY_THINKING:
            /* bash 版在每个消息显示前检查 last_char=='\n' 并执行 \r\033[K */
            if (interactive && ds->last_char[0] == '\n') {
                fprintf(out, "\r\033[K");
                ds->last_char[0] = '\0';
                ds->output_col = 0;
            }
            if (msg->content) {
                fprintf(out, "\x1b[90m%s\x1b[0m", msg->content);
                fflush(out);
                ds_update_output_col(ds, msg->content);
                ds_update_last_char(ds, msg->content);
            }
            ds->prev_was_thinking = 1;
            break;

        case DISPLAY_TEXT:
            /* bash 版在每个消息显示前检查 last_char=='\n' 并执行 \r\033[K */
            if (interactive && ds->last_char[0] == '\n') {
                fprintf(out, "\r\033[K");
                ds->last_char[0] = '\0';
                ds->output_col = 0;
            }
            if (msg->content) {
                /* Insert newline when transitioning from thinking to text */
                if (ds->prev_was_thinking && ds->last_char[0] != '\n') {
                    fputc('\n', out);
                    ds->last_char[0] = '\n';
                    ds->output_col = 0;
                }
                write_human(out, msg->content);
                ds_update_output_col(ds, msg->content);
                ds_update_last_char(ds, msg->content);
            }
            ds->prev_was_thinking = 0;
            break;

        case DISPLAY_TOOL_CALL: {
            ensure_newline(ds, out);
            const char *summary = msg->content ? msg->content : "";
            fprintf(out, "\x1b[33m[tool] %s\x1b[0m\n", summary);
            fflush(out);
            ds->last_char[0] = '\n';
            ds->prev_was_thinking = 0;
            break;
        }

        case DISPLAY_TOOL_RESULT:
            if (msg->content && msg->content[0]) {
                if (ds->prev_was_thinking && ds->last_char[0] != '\n') {
                    fputc('\n', out);
                    ds->last_char[0] = '\n';
                    ds->output_col = 0;
                }
                ds->prev_was_thinking = 0;
                const char *tr_name = msg->tool_name ? msg->tool_name : "";
                if (strcmp(tr_name, "Edit") == 0) {
                    /* Edit: 全文 + 换行 */
                    fprintf(out, "%s\n", msg->content);
                } else if (strcmp(tr_name, "Read") == 0 || strcmp(tr_name, "Write") == 0) {
                    /* Read/Write: 只显示第一行摘要 + 换行 */
                    const char *nl = strchr(msg->content, '\n');
                    if (nl) {
                        fprintf(out, "%.*s\n", (int)(nl - msg->content), msg->content);
                    } else {
                        fprintf(out, "%s\n", msg->content);
                    }
                } else {
                    /* 其他工具：全文 + 换行 */
                    fprintf(out, "%s\n", msg->content);
                }
                fflush(out);
                ds->last_char[0] = '\n';
                ds->output_col = 0;
            }
            break;

        case DISPLAY_USAGE:
            /* human 模式不显示 usage */
            break;

        case DISPLAY_STOP:
            ensure_newline(ds, out);
            if (msg->content && strcmp(msg->content, "interrupted") == 0) {
                fprintf(out, "\x1b[36mInterrupted.\x1b[0m\n");
                fflush(out);
                ds->last_char[0] = '\n';
            }
            break;

        case DISPLAY_ERROR:
            ensure_newline(ds, out);
            fprintf(stderr, "\x1b[31mError: %s\x1b[0m\n",
                    msg->content ? msg->content : "unknown");
            fflush(stderr);
            ds->last_char[0] = '\n';
            break;

        case DISPLAY_SUB_AGENT_START:
            /* bash 版不单独展示 start，靠 tool_result 显示。
             * C 版也一样，不额外输出。 */
            break;

        case DISPLAY_CONTEXT_UPDATE:
            ensure_newline(ds, out);
            fprintf(out, "\x1b[36mContext compacted (%s).\x1b[0m\n",
                    msg->tool_name ? msg->tool_name : "auto");
            fflush(out);
            ds->last_char[0] = '\n';
            break;

        case DISPLAY_IMAGE_DESCRIBE: {
            ensure_newline(ds, out);
            const char *images = msg->tool_name ? msg->tool_name : "";
            const char *desc = msg->content ? msg->content : "";
            if (desc[0]) {
                fprintf(out, "\x1b[36m📸 %s: %s\x1b[0m\n", images, desc);
            }
            fflush(out);
            ds->last_char[0] = '\n';
            break;
        }

        case DISPLAY_SUB_AGENT_RESULT: {
            /* 清空当前行，避免子 agent 残留的输出内容导致排版混乱
             * bash 版同样有 \r\033[K 保护 */
            if (interactive && ds->last_char[0] == '\n') {
                fprintf(out, "\r\033[K");
            }
            ensure_newline(ds, out);
            if (msg->tool_exit_code == 0) {
                fprintf(out, "\x1b[35m[sub-agent %s] completed (in=%d, out=%d)\x1b[0m\n",
                        msg->session_id ? msg->session_id : "?",
                        msg->in_tokens, msg->out_tokens);
            } else {
                fprintf(out, "\x1b[31m[sub-agent %s] failed\x1b[0m\n",
                        msg->session_id ? msg->session_id : "?");
            }
            /* thinking — 灰色，截断 120 字节（UTF-8 安全） */
            if (msg->tool_name && msg->tool_name[0]) {
                int tlen = (int)util_utf8_truncate_len(msg->tool_name, 120);
                fprintf(out, "\x1b[90m%.*s%s\x1b[0m\n",
                        tlen, msg->tool_name,
                        strlen(msg->tool_name) > 120 ? "…" : "");
            }
            /* text — 截断 120 字节（UTF-8 安全） */
            if (msg->content && msg->content[0]) {
                int clen = (int)util_utf8_truncate_len(msg->content, 120);
                fprintf(out, "%.*s%s\n",
                        clen, msg->content,
                        strlen(msg->content) > 120 ? "…" : "");
            }
            fflush(out);
            ds->last_char[0] = '\n';
            ds->prev_was_thinking = 0;
            break;
        }

        case DISPLAY_FLUSH:
            signal_flush(msg);
            break;
    }

    /* Show linenoise prompt after writing to stdout and release lock */
    if (interactive) readline_display_end(ds_physical_output_col(ds), ds->last_char[0] == '\n');
}

/* display 线程主函数 */
static void *display_thread_fn(void *arg) {
    DisplayConfig *cfg = (DisplayConfig *)arg;
    DisplayState ds;
    ds_init(&ds);
    FILE *out = stdout;

    while (1) {
        void *data = NULL;
        if (mq_pop(cfg->queue, &data) != 0) break; /* 队列关闭 */
        DisplayMessage *msg = (DisplayMessage *)data;
        if (!msg) continue;

        render_message(out, &ds, cfg->format, cfg->interactive, msg);
        display_message_free(msg);
        free(msg);
    }

    return NULL;
}

int display_thread_start(pthread_t *thread, const DisplayConfig *cfg) {
    DisplayConfig *heap_cfg = malloc(sizeof(DisplayConfig));
    if (!heap_cfg) return -1;
    *heap_cfg = *cfg;
    return pthread_create(thread, NULL, display_thread_fn, heap_cfg);
}

void display_thread_stop(MsgQueue *queue) {
    mq_close(queue);
}

int display_flush(MsgQueue *queue) {
    if (!queue) return -1;

    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int done = 0;
    if (pthread_mutex_init(&mutex, NULL) != 0) return -1;
    if (pthread_cond_init(&cond, NULL) != 0) {
        pthread_mutex_destroy(&mutex);
        return -1;
    }

    DisplayMessage *msg = calloc(1, sizeof(DisplayMessage));
    if (!msg) {
        pthread_cond_destroy(&cond);
        pthread_mutex_destroy(&mutex);
        return -1;
    }
    msg->type = DISPLAY_FLUSH;
    msg->flush_mutex = &mutex;
    msg->flush_cond = &cond;
    msg->flush_done = &done;

    pthread_mutex_lock(&mutex);
    if (mq_push(queue, msg) != 0) {
        pthread_mutex_unlock(&mutex);
        free(msg);
        pthread_cond_destroy(&cond);
        pthread_mutex_destroy(&mutex);
        return -1;
    }
    while (!done) {
        pthread_cond_wait(&cond, &mutex);
    }
    pthread_mutex_unlock(&mutex);

    pthread_cond_destroy(&cond);
    pthread_mutex_destroy(&mutex);
    return 0;
}
