#include "display.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

/* display 线程的显示状态 */
typedef struct {
    char last_char[8];      /* 最后一个字符（UTF-8 安全） */
    int prev_was_thinking;
} DisplayState;

static void ds_init(DisplayState *ds) {
    memset(ds, 0, sizeof(*ds));
    ds->last_char[0] = '\n';
    ds->last_char[1] = '\0';
    ds->prev_was_thinking = 0;
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
    }
}

/* 渲染一条 display 消息 */
static void render_message(FILE *out, DisplayState *ds, OutputFormat format,
                            int interactive, DisplayMessage *msg) {
    if (format == OUTPUT_STREAM_JSON) {
        /* stream-json 模式：直接输出 JSON */
        StrBuf buf;
        sb_init(&buf);
        const char *type_name = "";
        switch (msg->type) {
            case DISPLAY_TEXT: type_name = "text"; break;
            case DISPLAY_THINKING: type_name = "thinking"; break;
            case DISPLAY_TOOL_CALL: type_name = "tool_call"; break;
            case DISPLAY_TOOL_RESULT: type_name = "tool_result"; break;
            case DISPLAY_USAGE: type_name = "usage"; break;
            case DISPLAY_STOP: type_name = "stop"; break;
            case DISPLAY_ERROR: type_name = "error"; break;
            case DISPLAY_SUB_AGENT_START: type_name = "sub_agent_start"; break;
            case DISPLAY_SUB_AGENT_RESULT: type_name = "sub_agent_result"; break;
            case DISPLAY_CONTEXT_UPDATE: type_name = "context_update"; break;
        }
        sb_append_char(&buf, '{');
        sb_append(&buf, "\"type\":");
        sb_append_json_string(&buf, type_name);
        if (msg->content) {
            sb_append(&buf, ",\"text\":");
            sb_append_json_string(&buf, msg->content);
        }
        if (msg->type == DISPLAY_USAGE) {
            sb_appendf(&buf, ",\"input_tokens\":%d,\"output_tokens\":%d,"
                       "\"cache_read_input_tokens\":%d,\"cache_creation_input_tokens\":%d",
                       msg->in_tokens, msg->out_tokens,
                       msg->cache_read_tokens, msg->cache_creation_tokens);
        }
        if (msg->type == DISPLAY_CONTEXT_UPDATE) {
            sb_append(&buf, ",\"kind\":\"compact\",\"trigger\":");
            sb_append_json_string(&buf, msg->tool_name ? msg->tool_name : "auto");
        }
        if (msg->type == DISPLAY_TOOL_CALL) {
            if (msg->tool_name) {
                sb_append(&buf, ",\"name\":");
                sb_append_json_string(&buf, msg->tool_name);
            }
            if (msg->tool_id) {
                sb_append(&buf, ",\"id\":");
                sb_append_json_string(&buf, msg->tool_id);
            }
            if (msg->tool_input) {
                sb_append(&buf, ",\"input\":");
                sb_append_json_string(&buf, msg->tool_input);
            }
        }
        if (msg->type == DISPLAY_TOOL_RESULT && msg->content) {
            sb_append(&buf, ",\"content\":");
            sb_append_json_string(&buf, msg->content);
        }
        if (msg->type == DISPLAY_STOP && msg->content) {
            sb_append(&buf, ",\"reason\":");
            sb_append_json_string(&buf, msg->content);
        }
        sb_append_char(&buf, '}');
        fprintf(out, "%s\n", buf.data);
        fflush(out);
        sb_free(&buf);
        return;
    }

    /* human 模式 */
    switch (msg->type) {
        case DISPLAY_THINKING:
            if (msg->content) {
                fprintf(out, "\x1b[90m%s\x1b[0m", msg->content);
                fflush(out);
                ds_update_last_char(ds, msg->content);
            }
            ds->prev_was_thinking = 1;
            break;

        case DISPLAY_TEXT:
            if (msg->content) {
                if (ds->prev_was_thinking && ds->last_char[0] != '\n') {
                    fputc('\n', out);
                    ds->last_char[0] = '\n';
                }
                write_human(out, msg->content);
                ds_update_last_char(ds, msg->content);
            }
            ds->prev_was_thinking = 0;
            break;

        case DISPLAY_TOOL_CALL: {
            ensure_newline(ds, out);
            const char *name = msg->tool_name ? msg->tool_name : "unknown";
            const char *summary = msg->content ? msg->content : "";
            fprintf(out, "\x1b[33m[tool] %s(%s)\x1b[0m\n", name, summary);
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
                }
                ds->prev_was_thinking = 0;
                fprintf(out, "%s\n", msg->content);
                fflush(out);
                ds->last_char[0] = '\n';
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

        case DISPLAY_SUB_AGENT_RESULT: {
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
            break;
        }
    }
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
