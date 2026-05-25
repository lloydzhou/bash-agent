#include "transport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <curl/curl.h>

/* ============================================================
 * libcurl 回调
 * ============================================================ */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} CurlBuffer;

static size_t write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    CurlBuffer *buf = (CurlBuffer *)userdata;
    size_t total = size * nmemb;
    if (buf->len + total + 1 > buf->cap) {
        size_t newcap = buf->cap ? buf->cap * 2 : 4096;
        while (newcap < buf->len + total + 1) newcap *= 2;
        buf->data = realloc(buf->data, newcap);
        buf->cap = newcap;
    }
    memcpy(buf->data + buf->len, ptr, total);
    buf->len += total;
    buf->data[buf->len] = '\0';
    return total;
}

/* 流式回调上下文 */
typedef struct {
    sse_callback_fn callback;
    void *ctx;
    StrBuf line_buf;        /* 累积 SSE 行 */
    char *provider;         /* "claude" 或 "openai" */
    volatile int *cancelled;
} StreamCtx;

static size_t stream_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    StreamCtx *sctx = (StreamCtx *)userdata;

    /* 中断检查：模仿 Rust 版 100ms 轮询 CTRLC_FLAG / Go 版 ctx.Done()。
     * curl 每次收到数据块时调用此回调，如果返回 0 curl 会中止传输。
     * 这不是精确的 100ms 轮询，但对 SSE 流（每 token 一个 data 行）足够快。 */
    if (sctx->cancelled && *(sctx->cancelled)) {
        return 0; /* curl 视为错误，curl_easy_perform 返回 CURLE_WRITE_ERROR */
    }

    size_t total = size * nmemb;

    /* 按行处理 SSE 数据 */
    for (size_t i = 0; i < total; i++) {
        if (sctx->cancelled && *(sctx->cancelled)) {
            return 0; /* 每行之间也检查 */
        }
        if (ptr[i] == '\n') {
            /* 完整一行，处理 — sb_append_char 自动维护 \0 终止 */
            char *line = sctx->line_buf.data;
            /* 去掉 \r */
            size_t llen = strlen(line);
            if (llen > 0 && line[llen-1] == '\r') line[--llen] = '\0';

            if (strncmp(line, "data: ", 6) == 0) {
                const char *data = line + 6;
                sse_parse_event(sctx->provider, data, strlen(data),
                               sctx->callback, sctx->ctx);
            } else if (strncmp(line, "data:", 5) == 0) {
                const char *data = line + 5;
                while (*data == ' ') data++;
                sse_parse_event(sctx->provider, data, strlen(data),
                               sctx->callback, sctx->ctx);
            }
            /* 重置行缓冲 */
            sb_truncate(&sctx->line_buf, 0);
        } else {
            sb_append_char(&sctx->line_buf, ptr[i]);
        }
    }
    return total;
}

/* ============================================================
 * HTTP 请求
 * ============================================================ */

void http_response_free(HttpResponse *r) {
    if (!r) return;
    FREE_PTR(r->body);
}

HttpResponse http_post(const char *url, const char **headers, int header_count,
                       const char *body, size_t body_len) {
    HttpResponse resp;
    memset(&resp, 0, sizeof(resp));

    CURL *curl = curl_easy_init();
    if (!curl) { resp.status_code = 0; resp.body = util_strdup("curl init failed"); return resp; }

    struct curl_slist *hdrs = NULL;
    for (int i = 0; i < header_count; i++) {
        hdrs = curl_slist_append(hdrs, headers[i]);
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);

    CurlBuffer buf = {0};
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);

    CURLcode rc = curl_easy_perform(curl);
    if (rc != CURLE_OK) {
        resp.status_code = 0;
        resp.body = util_strdup(curl_easy_strerror(rc));
    } else {
        long code = 0;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
        resp.status_code = (int)code;
        resp.body = buf.data ? buf.data : util_strdup("");
    }

    curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);
    return resp;
}

/* forward declaration — 定义在 sse_parse_event 之前 */
static void emit_simple_event(sse_callback_fn callback, void *ctx,
                              SseEventType type, const char *content);

int http_post_sse(const char *url, const char **headers, int header_count,
                  const char *body, size_t body_len,
                  const char *provider,
                  sse_callback_fn callback, void *ctx,
                  volatile int *cancelled) {
    CURL *curl = curl_easy_init();
    if (!curl) return -1;

    struct curl_slist *hdrs = NULL;
    for (int i = 0; i < header_count; i++) {
        hdrs = curl_slist_append(hdrs, headers[i]);
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);

    StreamCtx sctx;
    sctx.callback = callback;
    sctx.ctx = ctx;
    sb_init(&sctx.line_buf);
    sctx.cancelled = cancelled;
    sctx.provider = (char *)provider;

    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, stream_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &sctx);

    CURLcode rc = curl_easy_perform(curl);

    long http_code = 0;
    if (rc == CURLE_OK) {
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    }

    /* 处理非 SSE 响应：如果 line_buf 中有残留 JSON，作为完整响应解析 */
    if (rc == CURLE_OK && sctx.line_buf.data && sctx.line_buf.len > 0) {
        char *residual = sctx.line_buf.data;
        /* 去掉前导空白 */
        while (*residual == ' ' || *residual == '\t' || *residual == '\r' || *residual == '\n') residual++;
        if (*residual == '{') {
            /* 非 SSE 的完整 JSON 响应 — 按格式解析 */
            size_t pos = 0;
            JsonParse jp = json_parse(residual, &pos);
            if (!jp.error) {
                char *err_msg = json_get_string(jp.val, "error");
                if (err_msg) {
                    emit_simple_event(callback, ctx, SSE_ERROR, err_msg);
                    free(err_msg);
                } else if (strcmp(provider, "claude") == 0) {
                    /* Claude 非流式响应 */
                    JsonVal content = json_get(jp.val, "content");
                    if (content.type == JSON_ARRAY) {
                        int clen = json_array_len(content);
                        for (int i = 0; i < clen; i++) {
                            JsonVal block = json_array_get(content, i);
                            char *btype = json_get_string(block, "type");
                            if (btype && strcmp(btype, "text") == 0) {
                                char *txt = json_get_string(block, "text");
                                if (txt) { emit_simple_event(callback, ctx, SSE_TEXT, txt); free(txt); }
                            } else if (btype && strcmp(btype, "thinking") == 0) {
                                char *txt = json_get_string(block, "thinking");
                                if (txt) { emit_simple_event(callback, ctx, SSE_THINKING, txt); free(txt); }
                            } else if (btype && strcmp(btype, "tool_use") == 0) {
                                char *id = json_get_string(block, "id");
                                char *name = json_get_string(block, "name");
                                SseEvent evt;
                                memset(&evt, 0, sizeof(evt));
                                evt.type = SSE_TOOL_CALL;
                                evt.tool_id = id;
                                evt.tool_name = name;
                                evt.tool_input = "{}"; /* 非 SSE 模式简化处理 */
                                callback(ctx, &evt);
                                free(id); free(name);
                            }
                            free(btype);
                        }
                    }
                    /* stop_reason */
                    char *stop_reason = json_get_string(jp.val, "stop_reason");
                    if (stop_reason) {
                        emit_simple_event(callback, ctx, SSE_STOP, stop_reason);
                        free(stop_reason);
                    }
                    /* usage */
                    JsonVal usage = json_get(jp.val, "usage");
                    if (usage.type != JSON_NULL) {
                        SseEvent evt;
                        memset(&evt, 0, sizeof(evt));
                        evt.type = SSE_USAGE;
                        evt.in_tokens = json_get_int(usage, "input_tokens");
                        evt.out_tokens = json_get_int(usage, "output_tokens");
                        evt.cache_read_tokens = json_get_int(usage, "cache_read_input_tokens");
                        evt.cache_creation_tokens = json_get_int(usage, "cache_creation_input_tokens");
                        callback(ctx, &evt);
                    }
                } else {
                    /* OpenAI 非流式响应 */
                    JsonVal choices = json_get(jp.val, "choices");
                    if (choices.type == JSON_ARRAY) {
                        JsonVal choice = json_array_get(choices, 0);
                        JsonVal msg = json_get(choice, "message");
                        char *content = json_get_string(msg, "content");
                        if (content) {
                            emit_simple_event(callback, ctx, SSE_TEXT, content);
                            free(content);
                        }
                        char *finish = json_get_string(choice, "finish_reason");
                        if (finish) {
                            emit_simple_event(callback, ctx, SSE_STOP, finish);
                            free(finish);
                        }
                    }
                    JsonVal usage = json_get(jp.val, "usage");
                    if (usage.type != JSON_NULL) {
                        SseEvent evt;
                        memset(&evt, 0, sizeof(evt));
                        evt.type = SSE_USAGE;
                        evt.in_tokens = json_get_int(usage, "prompt_tokens");
                        evt.out_tokens = json_get_int(usage, "completion_tokens");
                        callback(ctx, &evt);
                    }
                }
            }
        }
    }

    sb_free(&sctx.line_buf);
    curl_slist_free_all(hdrs);
    curl_easy_cleanup(curl);

    /* 如果是被 cancelled 中断的，发送 STOP interrupted 让 agent_loop 正常结束 */
    if (rc == CURLE_WRITE_ERROR && cancelled && *cancelled) {
        emit_simple_event(callback, ctx, SSE_STOP, "interrupted");
        return 0;  /* 不是错误——是被中断的正常退出 */
    }

    if (rc != CURLE_OK) return -1;
    if (http_code >= 400) return (int)http_code;  /* HTTP 错误码作为负返回值的替代 */
    return 0;
}

/* ============================================================
 * SSE 事件解析
 * ============================================================ */

static void emit_simple_event(sse_callback_fn callback, void *ctx,
                              SseEventType type, const char *content) {
    SseEvent evt;
    memset(&evt, 0, sizeof(evt));
    evt.type = type;
    evt.content = (char *)content;  /* 临时，不 free */
    callback(ctx, &evt);
}

/* 在回调中复制字符串的工具函数 */
/* 保留备用 */
#if 0
static char *dup_and_free(char *s) {
    return util_strdup(s);
}
#endif

int sse_parse_event(const char *provider, const char *data, size_t data_len,
                    sse_callback_fn callback, void *ctx) {
    if (data_len == 0) return 0;
    if (strcmp(data, "[DONE]") == 0) {
        emit_simple_event(callback, ctx, SSE_STOP, "end_turn");
        return 0;
    }

    /* 解析 JSON */
    size_t pos = 0;
    JsonParse jp = json_parse(data, &pos);
    if (jp.error) return 0;

    if (strcmp(provider, "claude") == 0) {
        /* Claude SSE 格式 */
        char *type = json_get_string(jp.val, "type");
        if (!type) return 0;

        if (strcmp(type, "content_block_delta") == 0) {
            int idx = json_get_int(jp.val, "index");
            JsonVal delta = json_get(jp.val, "delta");
            char *dtype = json_get_string(delta, "type");
            if (dtype && strcmp(dtype, "text_delta") == 0) {
                char *text = json_get_string(delta, "text");
                if (text) { emit_simple_event(callback, ctx, SSE_TEXT, text); free(text); }
            } else if (dtype && strcmp(dtype, "thinking_delta") == 0) {
                char *text = json_get_string(delta, "thinking");
                if (text) { emit_simple_event(callback, ctx, SSE_THINKING, text); free(text); }
            } else if (dtype && strcmp(dtype, "input_json_delta") == 0) {
                /* 工具调用 input 增量 */
                char *partial = json_get_string(delta, "partial_json");
                if (partial) {
                    SseEvent evt;
                    memset(&evt, 0, sizeof(evt));
                    evt.type = SSE_TOOL_INPUT_DELTA;
                    evt.content = partial;
                    evt.tool_id = NULL; /* index 用于匹配 */
                    callback(ctx, &evt);
                    free(partial);
                }
            }
            (void)idx;
            free(dtype);
        } else if (strcmp(type, "content_block_start") == 0) {
            int idx = json_get_int(jp.val, "index");
            JsonVal cb = json_get(jp.val, "content_block");
            char *cb_type = json_get_string(cb, "type");
            if (cb_type && strcmp(cb_type, "tool_use") == 0) {
                char *id = json_get_string(cb, "id");
                char *name = json_get_string(cb, "name");
                SseEvent evt;
                memset(&evt, 0, sizeof(evt));
                evt.type = SSE_TOOL_CALL_START;
                evt.tool_id = id;
                evt.tool_name = name;
                callback(ctx, &evt);
                /* 回调中已复制，这里释放 */
                free(id);
                free(name);
            }
            (void)idx;
            free(cb_type);
        } else if (strcmp(type, "content_block_stop") == 0) {
            /* 工具调用完成 — 由累积器在收到 stop 后统一处理 */
        } else if (strcmp(type, "message_delta") == 0) {
            JsonVal delta = json_get(jp.val, "delta");
            char *stop_reason = json_get_string(delta, "stop_reason");
            if (stop_reason) {
                emit_simple_event(callback, ctx, SSE_STOP, stop_reason);
                free(stop_reason);
            }
            JsonVal usage = json_get(jp.val, "usage");
            if (usage.type != JSON_NULL) {
                SseEvent evt;
                memset(&evt, 0, sizeof(evt));
                evt.type = SSE_USAGE;
                evt.out_tokens = json_get_int(usage, "output_tokens");
                /* input/cache_* 字段仅在 message_start 未提供时取（与 Rust 版对齐）
                 * OpenAI 路径无 message_start，通过 transport 合成 message_delta */
                int it = json_get_int(usage, "input_tokens");
                int cr = json_get_int(usage, "cache_read_input_tokens");
                int cc = json_get_int(usage, "cache_creation_input_tokens");
                if (it > 0) evt.in_tokens = it;
                if (cr > 0) evt.cache_read_tokens = cr;
                if (cc > 0) evt.cache_creation_tokens = cc;
                callback(ctx, &evt);
            }
        } else if (strcmp(type, "message_start") == 0) {
            JsonVal msg = json_get(jp.val, "message");
            JsonVal usage = json_get(msg, "usage");
            if (usage.type != JSON_NULL) {
                SseEvent evt;
                memset(&evt, 0, sizeof(evt));
                evt.type = SSE_USAGE;
                evt.in_tokens = json_get_int(usage, "input_tokens");
                evt.cache_read_tokens = json_get_int(usage, "cache_read_input_tokens");
                evt.cache_creation_tokens = json_get_int(usage, "cache_creation_input_tokens");
                callback(ctx, &evt);
            }
        } else if (strcmp(type, "error") == 0) {
            char *msg = json_get_string(jp.val, "error");
            if (!msg) msg = json_get_string(jp.val, "message");
            emit_simple_event(callback, ctx, SSE_ERROR, msg ? msg : "unknown error");
            free(msg);
        }
        free(type);
    } else {
        /* OpenAI SSE 格式 */
        char *obj_type = json_get_string(jp.val, "object");
        if (!obj_type) return 0;

        if (strcmp(obj_type, "chat.completion.chunk") == 0) {
            JsonVal choices = json_get(jp.val, "choices");
            if (choices.type == JSON_ARRAY) {
                JsonVal choice = json_array_get(choices, 0);
                JsonVal delta = json_get(choice, "delta");
                char *content = json_get_string(delta, "content");
                if (content) {
                    emit_simple_event(callback, ctx, SSE_TEXT, content);
                    free(content);
                }
                char *finish = json_get_string(choice, "finish_reason");
                if (finish) {
                    if (strcmp(finish, "tool_calls") == 0) {
                        emit_simple_event(callback, ctx, SSE_STOP, "tool_use");
                    } else {
                        emit_simple_event(callback, ctx, SSE_STOP, finish);
                    }
                    free(finish);
                }
            }
            JsonVal usage = json_get(jp.val, "usage");
            if (usage.type != JSON_NULL) {
                SseEvent evt;
                memset(&evt, 0, sizeof(evt));
                evt.type = SSE_USAGE;
                evt.in_tokens = json_get_int(usage, "prompt_tokens");
                evt.out_tokens = json_get_int(usage, "completion_tokens");
                callback(ctx, &evt);
            }
        }
        free(obj_type);
    }
    return 0;
}

/* ============================================================
 * SSE 累积器
 * ============================================================ */

void sse_accum_init(SseAccumulator *acc) {
    memset(acc, 0, sizeof(*acc));
    sb_init(&acc->text);
    sb_init(&acc->thinking);
    acc->tool_cap = 8;
    acc->tools = calloc(acc->tool_cap, sizeof(ToolCallAccum));
    acc->tool_count = 0;
    acc->current_block_index = -1;
}

void sse_accum_free(SseAccumulator *acc) {
    sb_free(&acc->text);
    sb_free(&acc->thinking);
    for (int i = 0; i < acc->tool_count; i++) {
        FREE_PTR(acc->tools[i].id);
        FREE_PTR(acc->tools[i].name);
        sb_free(&acc->tools[i].input_json);
    }
    free(acc->tools);
    FREE_PTR(acc->current_block_type);
    FREE_PTR(acc->current_tool_id);
    FREE_PTR(acc->current_tool_name);
    FREE_PTR(acc->stop_reason);
    FREE_PTR(acc->error);
}

void sse_accum_callback(void *ctx, const SseEvent *evt) {
    SseAccumulator *acc = (SseAccumulator *)ctx;

    switch (evt->type) {
    case SSE_TEXT:
        sb_append(&acc->text, evt->content);
        break;

    case SSE_THINKING:
        sb_append(&acc->thinking, evt->content);
        break;

    case SSE_TOOL_CALL_START: {
        /* 新工具调用开始 */
        if (acc->tool_count >= acc->tool_cap) {
            acc->tool_cap *= 2;
            acc->tools = realloc(acc->tools, acc->tool_cap * sizeof(ToolCallAccum));
        }
        ToolCallAccum *tc = &acc->tools[acc->tool_count];
        memset(tc, 0, sizeof(*tc));
        tc->id = util_strdup(evt->tool_id);
        tc->name = util_strdup(evt->tool_name);
        sb_init(&tc->input_json);
        acc->tool_count++;
        break;
    }

    case SSE_TOOL_INPUT_DELTA: {
        /* 追加到当前最后一个工具调用的 input_json */
        if (acc->tool_count > 0 && evt->content) {
            sb_append(&acc->tools[acc->tool_count - 1].input_json, evt->content);
        }
        break;
    }

    case SSE_TOOL_CALL: {
        /* 完整的工具调用（非增量模式，如 OpenAI） */
        if (acc->tool_count >= acc->tool_cap) {
            acc->tool_cap *= 2;
            acc->tools = realloc(acc->tools, acc->tool_cap * sizeof(ToolCallAccum));
        }
        ToolCallAccum *tc = &acc->tools[acc->tool_count];
        memset(tc, 0, sizeof(*tc));
        tc->id = util_strdup(evt->tool_id ? evt->tool_id : "");
        tc->name = util_strdup(evt->tool_name ? evt->tool_name : "");
        sb_init(&tc->input_json);
        sb_append(&tc->input_json, evt->tool_input ? evt->tool_input : "{}");
        acc->tool_count++;
        break;
    }

    case SSE_USAGE:
        if (evt->in_tokens > 0) acc->in_tokens = evt->in_tokens;
        if (evt->out_tokens > 0) acc->out_tokens = evt->out_tokens;
        if (evt->cache_read_tokens > 0) acc->cache_read_tokens = evt->cache_read_tokens;
        if (evt->cache_creation_tokens > 0) acc->cache_creation_tokens = evt->cache_creation_tokens;
        break;

    case SSE_STOP:
        acc->stopped = 1;
        if (evt->content) {
            FREE_PTR(acc->stop_reason);
            acc->stop_reason = util_strdup(evt->content);
        }
        break;

    case SSE_ERROR:
        FREE_PTR(acc->error);
        acc->error = util_strdup(evt->content ? evt->content : "unknown error");
        break;

    case SSE_RETRY:
        /* 清空当前累积 */
        sb_truncate(&acc->text, 0);
        sb_truncate(&acc->thinking, 0);
        for (int i = 0; i < acc->tool_count; i++) {
            FREE_PTR(acc->tools[i].id);
            FREE_PTR(acc->tools[i].name);
            sb_free(&acc->tools[i].input_json);
        }
        acc->tool_count = 0;
        acc->stopped = 0;
        FREE_PTR(acc->stop_reason);
        break;
    }
}

/* ============================================================
 * 请求体构建
 * ============================================================ */

char *build_claude_request(const char *model, const char *system_prompt,
                           const char *tools_json,
                           char **conv_lines, int conv_line_count,
                           int max_tokens, const char *thinking, const char *effort) {
    StrBuf buf;
    sb_init(&buf);

    sb_append(&buf, "{\"model\":");
    sb_append_json_string(&buf, model);
    sb_append(&buf, ",\"max_tokens\":");
    sb_appendf(&buf, "%d", max_tokens);
    sb_append(&buf, ",\"stream\":true");

    /* system prompt — 与 bash/Go/Rust 一致用字符串格式，触发 API prompt caching */
    if (system_prompt && system_prompt[0]) {
        sb_append(&buf, ",\"system\":");
        sb_append_json_string(&buf, system_prompt);
    }

    /* thinking — 对齐 bash 版: {"type":"adaptive"} + {"output_config":{"effort":"high"}} */
    if (thinking && strcmp(thinking, "disabled") != 0) {
        sb_append(&buf, ",\"thinking\":{\"type\":");
        sb_append_json_string(&buf, thinking);
        sb_append(&buf, "}");
        sb_append(&buf, ",\"output_config\":{\"effort\":");
        sb_append_json_string(&buf, effort ? effort : "high");
        sb_append(&buf, "}");
    }

    /* tools */
    if (tools_json) {
        sb_append(&buf, ",\"tools\":");
        sb_append(&buf, tools_json);
    }

    /* messages */
    sb_append(&buf, ",\"messages\":[");
    for (int i = 0; i < conv_line_count; i++) {
        if (i > 0) sb_append(&buf, ",");
        sb_append(&buf, conv_lines[i]);
    }
    sb_append(&buf, "]}");

    char *result = buf.data;
    /* 不要 sb_free，因为我们返回 buf.data */
    return result;
}

char *convert_to_openai(const char *claude_body) {
    /* 简化的 Claude → OpenAI 转换 */
    /* 对于完整的转换需要解析并重组 JSON，这里先返回原样 */
    return util_strdup(claude_body);
}
