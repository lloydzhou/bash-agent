#include "transport.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <unistd.h>
#include <curl/curl.h>

/* ============================================================
 * libcurl 回调
 * ============================================================ */

typedef struct {
    char *data;
    size_t len;
    size_t cap;
} CurlBuffer;

typedef struct {
    int index;
    char *id;
    char *name;
    StrBuf arguments;
} OpenAIToolAccum;

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
    char *event;            /* Responses SSE 事件名 */
    char *provider;         /* "claude"、"openai" 或 "responses" */
    volatile int *cancelled;
    OpenAIToolAccum *openai_tools;
    int openai_tool_count;
    int openai_tool_cap;
    int responses_saw_text;
    int responses_terminal;
    int responses_input_tokens;
    int responses_output_tokens;
    int responses_cache_read_tokens;
    char **responses_item_ids;
    int *responses_item_indexes;
    int responses_item_count;
    int responses_item_cap;
} StreamCtx;

static void emit_simple_event(sse_callback_fn callback, void *ctx,
                              SseEventType type, const char *content);
static void fill_openai_usage_event(SseEvent *evt, JsonVal usage);

static void streamctx_free_openai_tools(StreamCtx *sctx) {
    for (int i = 0; i < sctx->responses_item_count; i++) FREE_PTR(sctx->responses_item_ids[i]);
    FREE_PTR(sctx->responses_item_ids);
    FREE_PTR(sctx->responses_item_indexes);
    sctx->responses_item_count = 0;
    sctx->responses_item_cap = 0;
    for (int i = 0; i < sctx->openai_tool_count; i++) {
        FREE_PTR(sctx->openai_tools[i].id);
        FREE_PTR(sctx->openai_tools[i].name);
        sb_free(&sctx->openai_tools[i].arguments);
    }
    FREE_PTR(sctx->openai_tools);
    sctx->openai_tool_count = 0;
    sctx->openai_tool_cap = 0;
}

static void streamctx_reset_openai_tool(OpenAIToolAccum *tool) {
    FREE_PTR(tool->id);
    FREE_PTR(tool->name);
    sb_free(&tool->arguments);
    memset(tool, 0, sizeof(*tool));
}

static OpenAIToolAccum *streamctx_ensure_openai_tool(StreamCtx *sctx, int idx) {
    for (int i = 0; i < sctx->openai_tool_count; i++) {
        if (sctx->openai_tools[i].index == idx) return &sctx->openai_tools[i];
    }
    if (sctx->openai_tool_count >= sctx->openai_tool_cap) {
        int old_cap = sctx->openai_tool_cap;
        sctx->openai_tool_cap = sctx->openai_tool_cap ? sctx->openai_tool_cap * 2 : 4;
        sctx->openai_tools = realloc(sctx->openai_tools,
            (size_t)sctx->openai_tool_cap * sizeof(*sctx->openai_tools));
        memset(sctx->openai_tools + old_cap, 0,
            (size_t)(sctx->openai_tool_cap - old_cap) * sizeof(*sctx->openai_tools));
    }
    OpenAIToolAccum *tool = &sctx->openai_tools[sctx->openai_tool_count++];
    tool->index = idx;
    sb_init(&tool->arguments);
    return tool;
}

static void streamctx_emit_openai_tool_calls(StreamCtx *sctx) {
    for (int i = 0; i < sctx->openai_tool_count; i++) {
        OpenAIToolAccum *tool = &sctx->openai_tools[i];
        if (tool->arguments.len == 0) continue;
        SseEvent evt;
        memset(&evt, 0, sizeof(evt));
        evt.type = SSE_TOOL_CALL;
        evt.tool_id = tool->id ? tool->id : "";
        evt.tool_name = tool->name ? tool->name : "";
        evt.tool_input = tool->arguments.data ? tool->arguments.data : "{}";
        sctx->callback(sctx->ctx, &evt);
        streamctx_reset_openai_tool(tool);
    }
    sctx->openai_tool_count = 0;
}

static void parse_openai_sse_event(StreamCtx *sctx, const char *data, size_t data_len) {
    if (data_len == 0) return;
    if (strcmp(data, "[DONE]") == 0) return;

    size_t pos = 0;
    JsonParse jp = json_parse(data, &pos);
    if (jp.error) return;

    char *obj_type = json_get_string(jp.val, "object");
    if (!obj_type || strcmp(obj_type, "chat.completion.chunk") != 0) {
        FREE_PTR(obj_type);
        return;
    }
    FREE_PTR(obj_type);

    JsonVal choices = json_get(jp.val, "choices");
    if (choices.type == JSON_ARRAY) {
        JsonVal choice = json_array_get(choices, 0);
        JsonVal delta = json_get(choice, "delta");
        char *content = json_get_string(delta, "content");
        if (content) {
            emit_simple_event(sctx->callback, sctx->ctx, SSE_TEXT, content);
            FREE_PTR(content);
        }
        char *reasoning = json_get_string(delta, "reasoning_content");
        if (!reasoning) reasoning = json_get_string(delta, "reasoning");
        if (reasoning) {
            emit_simple_event(sctx->callback, sctx->ctx, SSE_THINKING, reasoning);
            FREE_PTR(reasoning);
        }
        JsonVal tool_calls = json_get(delta, "tool_calls");
        if (tool_calls.type == JSON_ARRAY) {
            int tc_len = json_array_len(tool_calls);
            for (int i = 0; i < tc_len; i++) {
                JsonVal tc = json_array_get(tool_calls, i);
                int idx = json_get_int(tc, "index");
                JsonVal fn = json_get(tc, "function");
                OpenAIToolAccum *tool = streamctx_ensure_openai_tool(sctx, idx);
                char *id = json_get_string(tc, "id");
                char *name = json_get_string(fn, "name");
                char *arguments = json_get_string(fn, "arguments");
                /* 非标准 OpenAI 兼容 API（如 sensenova）在后续 chunk 中
                 * 发送空字符串 "" 而非省略字段，必须用 [0] 检查避免覆盖 */
                if (id && id[0]) {
                    FREE_PTR(tool->id);
                    tool->id = id;
                } else {
                    FREE_PTR(id);
                }
                if (name && name[0]) {
                    FREE_PTR(tool->name);
                    tool->name = name;
                } else {
                    FREE_PTR(name);
                }
                if (arguments) {
                    sb_append(&tool->arguments, arguments);
                    FREE_PTR(arguments);
                }
            }
        }
        char *finish = json_get_string(choice, "finish_reason");
        /* 非标准 API 可能用空字符串 "" 代替 null（如 sensenova），
         * 空字符串不应触发 STOP */
        if (finish && finish[0]) {
            if (strcmp(finish, "tool_calls") == 0) {
                streamctx_emit_openai_tool_calls(sctx);
                emit_simple_event(sctx->callback, sctx->ctx, SSE_STOP, "tool_use");
            } else if (strcmp(finish, "stop") == 0) {
                emit_simple_event(sctx->callback, sctx->ctx, SSE_STOP, "end_turn");
            } else if (strcmp(finish, "length") == 0) {
                emit_simple_event(sctx->callback, sctx->ctx, SSE_STOP, "max_tokens");
            } else {
                emit_simple_event(sctx->callback, sctx->ctx, SSE_STOP, finish);
            }
            FREE_PTR(finish);
        }
    }

    JsonVal usage = json_get(jp.val, "usage");
    if (usage.type != JSON_NULL) {
        SseEvent evt;
        memset(&evt, 0, sizeof(evt));
        evt.type = SSE_USAGE;
        fill_openai_usage_event(&evt, usage);
        sctx->callback(sctx->ctx, &evt);
    }
}



static int responses_tool_index(StreamCtx *sctx, JsonVal root, JsonVal item) {
    char *item_id = json_get_string(root, "item_id");
    if (!item_id && item.type != JSON_NULL) item_id = json_get_string(item, "id");
    JsonVal output_index = json_get(root, "output_index");
    int idx = output_index.type == JSON_NUMBER ? json_get_int(root, "output_index") : -1;
    if (idx < 0 && item_id) {
        for (int i = 0; i < sctx->responses_item_count; i++) {
            if (strcmp(sctx->responses_item_ids[i], item_id) == 0) { idx = sctx->responses_item_indexes[i]; break; }
        }
    }
    if (idx >= 0 && item_id) {
        int found = 0;
        for (int i = 0; i < sctx->responses_item_count; i++) if (strcmp(sctx->responses_item_ids[i], item_id) == 0) { found = 1; break; }
        if (!found) {
            if (sctx->responses_item_count >= sctx->responses_item_cap) {
                sctx->responses_item_cap = sctx->responses_item_cap ? sctx->responses_item_cap * 2 : 4;
                sctx->responses_item_ids = realloc(sctx->responses_item_ids, (size_t)sctx->responses_item_cap * sizeof(char *));
                sctx->responses_item_indexes = realloc(sctx->responses_item_indexes, (size_t)sctx->responses_item_cap * sizeof(int));
            }
            int pos = sctx->responses_item_count++;
            sctx->responses_item_ids[pos] = util_strdup(item_id);
            sctx->responses_item_indexes[pos] = idx;
        }
    }
    FREE_PTR(item_id);
    return idx;
}

static void responses_record_usage(StreamCtx *sctx, JsonVal response) {
    JsonVal usage = json_get(response, "usage");
    if (usage.type == JSON_NULL) usage = response;
    sctx->responses_output_tokens = json_get_int(usage, "output_tokens");
    JsonVal input_details = json_get(usage, "input_tokens_details");
    int nested_cached = input_details.type == JSON_NULL ? 0 : json_get_int(input_details, "cached_tokens");
    sctx->responses_cache_read_tokens = nested_cached > 0
        ? nested_cached
        : json_get_int(usage, "cached_tokens");
    sctx->responses_input_tokens = json_get_int(usage, "input_tokens") - sctx->responses_cache_read_tokens;
    if (sctx->responses_input_tokens < 0) sctx->responses_input_tokens = 0;
}

static void responses_emit_usage(StreamCtx *sctx) {
    SseEvent evt;
    memset(&evt, 0, sizeof(evt));
    evt.type = SSE_USAGE;
    evt.in_tokens = sctx->responses_input_tokens;
    evt.out_tokens = sctx->responses_output_tokens;
    evt.cache_read_tokens = sctx->responses_cache_read_tokens;
    sctx->callback(sctx->ctx, &evt);
}

static void parse_responses_sse_event(StreamCtx *sctx, const char *event, const char *data, size_t data_len) {
    if (data_len == 0) return;
    size_t pos = 0;
    JsonParse jp = json_parse(data, &pos);
    if (jp.error) return;
    JsonVal root = jp.val;
    if (strcmp(event, "response.reasoning_text.delta") == 0) {
        char *delta = json_get_string(root, "delta");
        if (delta && delta[0]) emit_simple_event(sctx->callback, sctx->ctx, SSE_THINKING, delta);
        FREE_PTR(delta);
    } else if (strcmp(event, "response.output_text.delta") == 0) {
        char *delta = json_get_string(root, "delta");
        if (delta) {
            char *text = delta;
            if (!sctx->responses_saw_text) while (*text == '\n' || *text == '\r') text++;
            if (*text) { sctx->responses_saw_text = 1; emit_simple_event(sctx->callback, sctx->ctx, SSE_TEXT, text); }
        }
        FREE_PTR(delta);
    } else if (strcmp(event, "response.output_item.added") == 0 || strcmp(event, "response.output_item.done") == 0) {
        JsonVal item = json_get(root, "item");
        char *type = json_get_string(item, "type");
        if (type && strcmp(type, "function_call") == 0) {
            int idx = responses_tool_index(sctx, root, item);
            if (idx < 0) { FREE_PTR(type); return; }
            OpenAIToolAccum *tool = streamctx_ensure_openai_tool(sctx, idx);
            char *id = json_get_string(item, "call_id");
            char *name = json_get_string(item, "name");
            char *args = json_get_string(item, "arguments");
            if (id && id[0]) { FREE_PTR(tool->id); tool->id = id; } else FREE_PTR(id);
            if (name && name[0]) { FREE_PTR(tool->name); tool->name = name; } else FREE_PTR(name);
            if (args && args[0]) { sb_truncate(&tool->arguments, 0); sb_append(&tool->arguments, args); }
            FREE_PTR(args);
        }
        FREE_PTR(type);
    } else if (strcmp(event, "response.function_call_arguments.delta") == 0) {
        int idx = responses_tool_index(sctx, root, json_get(root, "item"));
        if (idx < 0) return;
        OpenAIToolAccum *tool = streamctx_ensure_openai_tool(sctx, idx);
        char *delta = json_get_string(root, "delta");
        if (delta) { sb_append(&tool->arguments, delta); FREE_PTR(delta); }
    } else if (strcmp(event, "response.completed") == 0) {
        JsonVal response = json_get(root, "response");
        if (response.type == JSON_NULL) response = root;
        responses_record_usage(sctx, response);
        int has_tools = sctx->openai_tool_count > 0;
        streamctx_emit_openai_tool_calls(sctx);
        responses_emit_usage(sctx);
        emit_simple_event(sctx->callback, sctx->ctx, SSE_STOP, has_tools ? "tool_use" : "end_turn");
        sctx->responses_terminal = 1;
    } else if (strcmp(event, "response.failed") == 0 || strcmp(event, "response.incomplete") == 0 || strcmp(event, "error") == 0) {
        JsonVal response = json_get(root, "response");
        if (response.type == JSON_NULL) response = root;
        responses_record_usage(sctx, response);
        JsonVal error = json_get(response, "error");
        char *message = json_get_string(error, "message");
        if (!message) message = json_get_string(response, "message");
        if (!message) message = json_get_string(response, "reason");
        if (!message) message = util_strdup(strcmp(event, "response.incomplete") == 0 ? "Response incomplete" : (strcmp(event, "error") == 0 ? "Stream error" : "Response failed"));
        emit_simple_event(sctx->callback, sctx->ctx, SSE_ERROR, message);
        FREE_PTR(message);
        responses_emit_usage(sctx);
        emit_simple_event(sctx->callback, sctx->ctx, SSE_STOP, "error");
        sctx->responses_terminal = 1;
    }
}

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

            if (strncmp(line, "event: ", 7) == 0 && strcmp(sctx->provider, "responses") == 0) {
                FREE_PTR(sctx->event);
                sctx->event = util_strdup(line + 7);
            } else if (strncmp(line, "data: ", 6) == 0) {
                const char *data = line + 6;
                if (strcmp(sctx->provider, "openai") == 0) parse_openai_sse_event(sctx, data, strlen(data));
                else if (strcmp(sctx->provider, "responses") == 0) parse_responses_sse_event(sctx, sctx->event ? sctx->event : "", data, strlen(data));
                else sse_parse_event(sctx->provider, data, strlen(data), sctx->callback, sctx->ctx);
            } else if (strncmp(line, "data:", 5) == 0) {
                const char *data = line + 5;
                while (*data == ' ') data++;
                if (strcmp(sctx->provider, "openai") == 0) parse_openai_sse_event(sctx, data, strlen(data));
                else if (strcmp(sctx->provider, "responses") == 0) parse_responses_sse_event(sctx, sctx->event ? sctx->event : "", data, strlen(data));
                else sse_parse_event(sctx->provider, data, strlen(data), sctx->callback, sctx->ctx);
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
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);

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

static int openai_cached_tokens(JsonVal usage) {
    int cached = json_get_int(usage, "cached_tokens");
    if (cached > 0) return cached;
    JsonVal details = json_get(usage, "prompt_tokens_details");
    if (details.type != JSON_NULL) cached = json_get_int(details, "cached_tokens");
    return cached;
}

static void fill_openai_usage_event(SseEvent *evt, JsonVal usage) {
    int prompt = json_get_int(usage, "prompt_tokens");
    int cached = openai_cached_tokens(usage);
    evt->out_tokens = json_get_int(usage, "completion_tokens");
    evt->cache_read_tokens = cached;
    if (prompt > 0) {
        evt->in_tokens = prompt - cached;
        if (evt->in_tokens < 0) evt->in_tokens = 0;
    }
}

/* 处理非 SSE 响应：如果 line_buf 中有残留 JSON，作为完整响应解析 */
static void process_residual_json(StreamCtx *sctx, const char *provider,
                                  sse_callback_fn callback, void *ctx) {
    if (!sctx->line_buf.data || sctx->line_buf.len == 0) return;
    char *residual = sctx->line_buf.data;
    while (*residual == ' ' || *residual == '\t' || *residual == '\r' || *residual == '\n') residual++;
    if (*residual != '{') return;

    size_t pos = 0;
    JsonParse jp = json_parse(residual, &pos);
    if (jp.error) return;

    char *err_msg = json_get_string(jp.val, "error");
    if (err_msg) {
        emit_simple_event(callback, ctx, SSE_ERROR, err_msg);
        free(err_msg);
    } else if (strcmp(provider, "claude") == 0) {
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
                    evt.tool_input = "{}";
                    callback(ctx, &evt);
                    free(id); free(name);
                }
                free(btype);
            }
        }
        char *stop_reason = json_get_string(jp.val, "stop_reason");
        if (stop_reason) {
            emit_simple_event(callback, ctx, SSE_STOP, stop_reason);
            free(stop_reason);
        }
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
        JsonVal choices = json_get(jp.val, "choices");
        if (choices.type == JSON_ARRAY) {
            JsonVal choice = json_array_get(choices, 0);
            JsonVal msg = json_get(choice, "message");
            char *content = json_get_string(msg, "content");
            if (content) {
                emit_simple_event(callback, ctx, SSE_TEXT, content);
                free(content);
            }
            char *reasoning = json_get_string(msg, "reasoning_content");
            if (!reasoning) reasoning = json_get_string(msg, "reasoning");
            if (reasoning) {
                emit_simple_event(callback, ctx, SSE_THINKING, reasoning);
                free(reasoning);
            }
            JsonVal tool_calls = json_get(msg, "tool_calls");
            if (tool_calls.type == JSON_ARRAY) {
                int tc_len = json_array_len(tool_calls);
                for (int i = 0; i < tc_len; i++) {
                    JsonVal tc = json_array_get(tool_calls, i);
                    JsonVal fn = json_get(tc, "function");
                    char *id = json_get_string(tc, "id");
                    char *name = json_get_string(fn, "name");
                    char *arguments = json_get_string(fn, "arguments");
                    SseEvent evt;
                    memset(&evt, 0, sizeof(evt));
                    evt.type = SSE_TOOL_CALL;
                    evt.tool_id = id;
                    evt.tool_name = name;
                    evt.tool_input = arguments ? arguments : (char *)"{}";
                    callback(ctx, &evt);
                    free(id);
                    free(name);
                    free(arguments);
                }
            }
            char *finish = json_get_string(choice, "finish_reason");
            if (finish) {
                if (strcmp(finish, "tool_calls") == 0) emit_simple_event(callback, ctx, SSE_STOP, "tool_use");
                else if (strcmp(finish, "stop") == 0) emit_simple_event(callback, ctx, SSE_STOP, "end_turn");
                else emit_simple_event(callback, ctx, SSE_STOP, finish);
                free(finish);
            }
        }
        JsonVal usage = json_get(jp.val, "usage");
        if (usage.type != JSON_NULL) {
            SseEvent evt;
            memset(&evt, 0, sizeof(evt));
            evt.type = SSE_USAGE;
            fill_openai_usage_event(&evt, usage);
            callback(ctx, &evt);
        }
    }
}

int http_post_sse(const char *url, const char **headers, int header_count,
                  const char *body, size_t body_len,
                  const char *provider,
                  sse_callback_fn callback, void *ctx,
                  volatile int *cancelled) {
    /* 对齐 Bash curl --retry 2 --retry-delay 1 --retry-max-time 20
     * 和 Rust StreamClient: 最多重试 2 次，延迟 1s，总窗口 20s */
    const int max_retries = 2;
    const long retry_max_time_ms = 20000;

    struct timespec start_ts;
    clock_gettime(CLOCK_MONOTONIC, &start_ts);

    struct curl_slist *hdrs = NULL;
    for (int i = 0; i < header_count; i++) {
        hdrs = curl_slist_append(hdrs, headers[i]);
    }

    CURLcode rc = CURLE_OK;
    long http_code = 0;

    for (int attempt = 0; attempt <= max_retries; attempt++) {
        CURL *curl = curl_easy_init();
        if (!curl) { curl_slist_free_all(hdrs); return -1; }

        StreamCtx sctx;
        memset(&sctx, 0, sizeof(sctx));
        sctx.callback = callback;
        sctx.ctx = ctx;
        sb_init(&sctx.line_buf);
        sctx.cancelled = cancelled;
        sctx.provider = (char *)provider;

        curl_easy_setopt(curl, CURLOPT_URL, url);
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, hdrs);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
        curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body_len);
        curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);
        curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 5L);
        curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, stream_cb);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &sctx);

        rc = curl_easy_perform(curl);

        http_code = 0;
        if (rc == CURLE_OK) {
            curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
        }

        /* 判断是否需要重试 */
        int should_retry = 0;
        if (rc != CURLE_OK) {
            if (!(rc == CURLE_WRITE_ERROR && cancelled && *cancelled))
                should_retry = 1;
        } else if (http_code >= 500) {
            should_retry = 1;
        }

        if (!should_retry) {
            /* 成功或不可重试错误 → 处理残留 JSON */
            if (rc == CURLE_OK) {
                process_residual_json(&sctx, provider, callback, ctx);
            }
            sb_free(&sctx.line_buf);
            FREE_PTR(sctx.event);
            streamctx_free_openai_tools(&sctx);
            curl_easy_cleanup(curl);
            curl_slist_free_all(hdrs);

            if (rc == CURLE_WRITE_ERROR && cancelled && *cancelled) {
                emit_simple_event(callback, ctx, SSE_STOP, "interrupted");
                return 0;
            }
            if (rc != CURLE_OK) return -1;
            if (http_code >= 400) return (int)http_code;
            if (strcmp(provider, "responses") == 0 && !sctx.responses_terminal) {
                emit_simple_event(callback, ctx, SSE_ERROR, "Stream interrupted (no response.completed received)");
                emit_simple_event(callback, ctx, SSE_STOP, "error");
            }
            return 0;
        }

        /* 需要重试 → 清理本次尝试的状态 */
        sb_free(&sctx.line_buf);
        FREE_PTR(sctx.event);
        streamctx_free_openai_tools(&sctx);
        curl_easy_cleanup(curl);

        /* cancelled 不重试 */
        if (rc == CURLE_WRITE_ERROR && cancelled && *cancelled) {
            emit_simple_event(callback, ctx, SSE_STOP, "interrupted");
            curl_slist_free_all(hdrs);
            return 0;
        }

        /* 检查重试限制 */
        struct timespec now_ts;
        clock_gettime(CLOCK_MONOTONIC, &now_ts);
        long elapsed_ms = (now_ts.tv_sec - start_ts.tv_sec) * 1000L +
                          (now_ts.tv_nsec - start_ts.tv_nsec) / 1000000L;
        if (attempt >= max_retries || elapsed_ms >= retry_max_time_ms) {
            /* 重试耗尽 */
            curl_slist_free_all(hdrs);
            if (rc != CURLE_OK) return -1;
            if (http_code >= 400) return (int)http_code;
            return 0;
        }

        /* 发送 SSE_RETRY 重置累积器（对齐 bash awk RETRY 事件） */
        {
            SseEvent retry_evt;
            memset(&retry_evt, 0, sizeof(retry_evt));
            retry_evt.type = SSE_RETRY;
            callback(ctx, &retry_evt);
        }

        sleep(1);
    }

    /* 不应到达 */
    curl_slist_free_all(hdrs);
    return -1;
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
        if (strcmp(provider, "claude") == 0) emit_simple_event(callback, ctx, SSE_STOP, "end_turn");
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
            free(dtype);
        } else if (strcmp(type, "content_block_start") == 0) {
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
                char *reasoning = json_get_string(delta, "reasoning_content");
                if (!reasoning) reasoning = json_get_string(delta, "reasoning");
                if (reasoning) {
                    emit_simple_event(callback, ctx, SSE_THINKING, reasoning);
                    free(reasoning);
                }
                JsonVal tool_calls = json_get(delta, "tool_calls");
                if (tool_calls.type == JSON_ARRAY) {
                            int tc_len = json_array_len(tool_calls);
                            for (int i = 0; i < tc_len; i++) {
                                JsonVal tc = json_array_get(tool_calls, i);
                                JsonVal fn = json_get(tc, "function");
                                char *id = json_get_string(tc, "id");
                                char *name = json_get_string(fn, "name");
                        char *arguments = json_get_string(fn, "arguments");
                        if (id || name) {
                            SseEvent evt;
                            memset(&evt, 0, sizeof(evt));
                            evt.type = SSE_TOOL_CALL_START;
                            evt.tool_id = id;
                            evt.tool_name = name;
                            callback(ctx, &evt);
                        }
                        if (arguments) {
                            SseEvent evt;
                            memset(&evt, 0, sizeof(evt));
                            evt.type = SSE_TOOL_INPUT_DELTA;
                            evt.content = arguments;
                            callback(ctx, &evt);
                        }
                        free(id);
                        free(name);
                        free(arguments);
                    }
                }
                char *finish = json_get_string(choice, "finish_reason");
                if (finish) {
                    if (strcmp(finish, "tool_calls") == 0) {
                        emit_simple_event(callback, ctx, SSE_STOP, "tool_use");
                    } else if (strcmp(finish, "stop") == 0) {
                        emit_simple_event(callback, ctx, SSE_STOP, "end_turn");
                    } else if (strcmp(finish, "length") == 0) {
                        emit_simple_event(callback, ctx, SSE_STOP, "max_tokens");
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
                fill_openai_usage_event(&evt, usage);
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
        if (acc->tool_count >= acc->tool_cap) {
            acc->tool_cap *= 2;
            acc->tools = realloc(acc->tools, acc->tool_cap * sizeof(ToolCallAccum));
        }
        ToolCallAccum *tc = &acc->tools[acc->tool_count];
        memset(tc, 0, sizeof(*tc));
        sb_init(&tc->input_json);
        tc->id = util_strdup(evt->tool_id);
        tc->name = util_strdup(evt->tool_name);
        acc->tool_count++;
        break;
    }

    case SSE_TOOL_INPUT_DELTA: {
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
        /* 清空当前累积（对齐 stream_display_callback） */
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
        acc->in_tokens = 0;
        acc->out_tokens = 0;
        acc->cache_read_tokens = 0;
        acc->cache_creation_tokens = 0;
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

    /* 字段顺序对齐 Go/Rust 的 map 字母序：
     * max_tokens → messages → model → output_config → stream → system → thinking → tools */
    sb_append(&buf, "{\"max_tokens\":");
    sb_appendf(&buf, "%d", max_tokens);

    /* messages */
    sb_append(&buf, ",\"messages\":[");
    for (int i = 0; i < conv_line_count; i++) {
        if (i > 0) sb_append(&buf, ",");
        sb_append(&buf, conv_lines[i]);
    }
    sb_append(&buf, "]");

    /* model */
    sb_append(&buf, ",\"model\":");
    sb_append_json_string(&buf, model);

    /* output_config (仅 thinking != disabled) */
    if (thinking && strcmp(thinking, "disabled") != 0) {
        sb_append(&buf, ",\"output_config\":{\"effort\":");
        sb_append_json_string(&buf, effort ? effort : "high");
        sb_append(&buf, "}");
    }

    /* stream */
    sb_append(&buf, ",\"stream\":true");

    /* system prompt */
    if (system_prompt && system_prompt[0]) {
        sb_append(&buf, ",\"system\":");
        sb_append_json_string(&buf, system_prompt);
    }

    /* thinking (仅 thinking != disabled) */
    if (thinking && strcmp(thinking, "disabled") != 0) {
        sb_append(&buf, ",\"thinking\":{\"type\":");
        sb_append_json_string(&buf, thinking);
        sb_append(&buf, "}");
    }

    /* tools */
    if (tools_json) {
        sb_append(&buf, ",\"tools\":");
        sb_append(&buf, tools_json);
    }

    sb_append(&buf, "}");

    char *result = buf.data;
    /* 不要 sb_free，因为我们返回 buf.data */
    return result;
}

static void sb_append_json_val(StrBuf *sb, JsonVal v) {
    if (v.type == JSON_NULL || !v.src) {
        sb_append(sb, "null");
        return;
    }
    sb_appendn(sb, v.src + v.start, v.end - v.start);
}

static void openai_convert_tools(StrBuf *out, JsonVal tools_val) {
    if (tools_val.type != JSON_ARRAY) {
        sb_append(out, "[]");
        return;
    }
    sb_append_char(out, '[');
    int n = json_array_len(tools_val);
    for (int i = 0; i < n; i++) {
        JsonVal td = json_array_get(tools_val, i);
        if (i > 0) sb_append_char(out, ',');
        char *type = json_get_string(td, "type");
        if (type && strcmp(type, "function") == 0) {
            sb_append_json_val(out, td);
            FREE_PTR(type);
            continue;
        }
        FREE_PTR(type);
        char *name = json_get_string(td, "name");
        char *desc = json_get_string(td, "description");
        JsonVal params = json_get(td, "input_schema");
        if (params.type == JSON_NULL) params = json_get(td, "parameters");
        sb_append(out, "{\"type\":\"function\",\"function\":{\"name\":");
        sb_append_json_string(out, name ? name : "");
        sb_append(out, ",\"description\":");
        sb_append_json_string(out, desc ? desc : "");
        sb_append(out, ",\"parameters\":");
        if (params.type == JSON_NULL) sb_append(out, "{}");
        else sb_append_json_val(out, params);
        sb_append(out, "}}");
        FREE_PTR(name);
        FREE_PTR(desc);
    }
    sb_append_char(out, ']');
}

static void openai_convert_assistant_message(StrBuf *out, JsonVal content_val) {
    StrBuf text, reasoning, tool_calls;
    sb_init(&text);
    sb_init(&reasoning);
    sb_init(&tool_calls);

    int n = json_array_len(content_val);
    for (int i = 0; i < n; i++) {
        JsonVal block = json_array_get(content_val, i);
        char *btype = json_get_string(block, "type");
        if (!btype) continue;
        if (strcmp(btype, "thinking") == 0) {
            char *t = json_get_string(block, "thinking");
            if (t) { sb_append(&reasoning, t); FREE_PTR(t); }
        } else if (strcmp(btype, "text") == 0) {
            char *t = json_get_string(block, "text");
            if (t) { sb_append(&text, t); FREE_PTR(t); }
        } else if (strcmp(btype, "tool_use") == 0) {
            char *id = json_get_string(block, "id");
            char *name = json_get_string(block, "name");
            JsonVal input = json_get(block, "input");
            if (tool_calls.len > 0) sb_append_char(&tool_calls, ',');
            sb_append(&tool_calls, "{\"id\":");
            sb_append_json_string(&tool_calls, id ? id : "");
            sb_append(&tool_calls, ",\"type\":\"function\",\"function\":{\"name\":");
            sb_append_json_string(&tool_calls, name ? name : "");
            sb_append(&tool_calls, ",\"arguments\":");
            if (input.type == JSON_NULL) sb_append_json_string(&tool_calls, "{}");
            else {
                StrBuf arg;
                sb_init(&arg);
                sb_append_json_val(&arg, input);
                sb_append_json_string(&tool_calls, arg.data ? arg.data : "{}");
                sb_free(&arg);
            }
            sb_append(&tool_calls, "}}");
            FREE_PTR(id);
            FREE_PTR(name);
        }
        FREE_PTR(btype);
    }

    sb_append(out, "{\"role\":\"assistant\",\"reasoning_content\":");
    sb_append_json_string(out, reasoning.data ? reasoning.data : "");
    sb_append(out, ",\"content\":");
    sb_append_json_string(out, text.data ? text.data : "");
    if (tool_calls.len > 0) {
        sb_append(out, ",\"tool_calls\":[");
        sb_append(out, tool_calls.data);
        sb_append_char(out, ']');
    }
    sb_append_char(out, '}');

    sb_free(&text);
    sb_free(&reasoning);
    sb_free(&tool_calls);
}

static int openai_convert_tool_results(StrBuf *out, JsonVal content_val) {
    int written = 0;
    int n = json_array_len(content_val);
    for (int i = 0; i < n; i++) {
        JsonVal block = json_array_get(content_val, i);
        char *btype = json_get_string(block, "type");
        if (!btype || strcmp(btype, "tool_result") != 0) {
            FREE_PTR(btype);
            continue;
        }
        char *tool_use_id = json_get_string(block, "tool_use_id");
        char *content = json_get_string(block, "content");
        if (written > 0) sb_append_char(out, ',');
        sb_append(out, "{\"role\":\"tool\",\"tool_call_id\":");
        sb_append_json_string(out, tool_use_id ? tool_use_id : "");
        sb_append(out, ",\"content\":");
        sb_append_json_string(out, content ? content : "");
        sb_append_char(out, '}');
        written++;
        FREE_PTR(tool_use_id);
        FREE_PTR(content);
        FREE_PTR(btype);
    }
    return written;
}

static void openai_convert_messages(StrBuf *out, JsonVal messages_val) {
    sb_append_char(out, '[');
    int wrote = 0;
    int n = json_array_len(messages_val);
    for (int i = 0; i < n; i++) {
        JsonVal msg = json_array_get(messages_val, i);
        char *role = json_get_string(msg, "role");
        JsonVal content = json_get(msg, "content");
        if (role && strcmp(role, "assistant") == 0 && content.type == JSON_ARRAY) {
            if (wrote > 0) sb_append_char(out, ',');
            openai_convert_assistant_message(out, content);
            wrote++;
        } else if (role && strcmp(role, "user") == 0 && content.type == JSON_ARRAY) {
            int before = wrote;
            if (wrote > 0 && json_array_len(content) > 0) {
                /* openai_convert_tool_results handles commas after the first item */
            }
            if (wrote > 0) {
                StrBuf tmp;
                sb_init(&tmp);
                int tool_written = openai_convert_tool_results(&tmp, content);
                if (tool_written > 0) {
                    sb_append_char(out, ',');
                    sb_append(out, tmp.data);
                    wrote += tool_written;
                } else {
                    if (wrote > 0) sb_append_char(out, ',');
                    sb_append_json_val(out, msg);
                    wrote++;
                }
                sb_free(&tmp);
            } else {
                int tool_written = openai_convert_tool_results(out, content);
                if (tool_written > 0) wrote += tool_written;
                else {
                    sb_append_json_val(out, msg);
                    wrote++;
                }
            }
            (void)before;
        } else {
            if (wrote > 0) sb_append_char(out, ',');
            sb_append_json_val(out, msg);
            wrote++;
        }
        FREE_PTR(role);
    }
    sb_append_char(out, ']');
}

char *convert_to_openai(const char *claude_body) {
    JsonParse jp = json_parse_root(claude_body);
    if (jp.error) return util_strdup(claude_body);

    char *model = json_get_string(jp.val, "model");
    int max_tokens = json_get_int(jp.val, "max_tokens");
    JsonVal system_val = json_get(jp.val, "system");
    JsonVal thinking_val = json_get(jp.val, "thinking");
    JsonVal output_config_val = json_get(jp.val, "output_config");
    JsonVal messages_val = json_get(jp.val, "messages");
    JsonVal tools_val = json_get(jp.val, "tools");

    StrBuf messages, tools, result;
    sb_init(&messages);
    sb_init(&tools);
    sb_init(&result);

    openai_convert_messages(&messages, messages_val);
    if (tools_val.type == JSON_ARRAY && json_array_len(tools_val) > 0) {
        openai_convert_tools(&tools, tools_val);
    }

    sb_append(&result, "{\"model\":");
    sb_append_json_string(&result, model ? model : "");
    sb_append(&result, ",\"max_tokens\":");
    sb_appendf(&result, "%d", max_tokens);
    sb_append(&result, ",\"stream\":true");

    if (system_val.type != JSON_NULL) {
        char *sys = json_as_string(system_val);
        if (sys && sys[0]) {
            StrBuf with_system;
            sb_init(&with_system);
            sb_append(&with_system, "[{\"role\":\"system\",\"content\":");
            sb_append_json_string(&with_system, sys);
            sb_append_char(&with_system, '}');
            if (messages.len > 2) {
                sb_append_char(&with_system, ',');
                sb_appendn(&with_system, messages.data + 1, messages.len - 2);
            }
            sb_append_char(&with_system, ']');
            sb_free(&messages);
            messages = with_system;
        }
        FREE_PTR(sys);
    }

    char *thinking_type = json_get_string(thinking_val, "type");
    if (thinking_type &&
        (strcmp(thinking_type, "adaptive") == 0 || strcmp(thinking_type, "enabled") == 0)) {
        sb_append(&result, ",\"thinking\":{\"type\":\"enabled\"}");
        char *effort = json_get_string(output_config_val, "effort");
        sb_append(&result, ",\"reasoning_effort\":");
        sb_append_json_string(&result, (effort && effort[0]) ? effort : "high");
        FREE_PTR(effort);
    }
    FREE_PTR(thinking_type);

    if (tools.len > 0 && strcmp(tools.data, "[]") != 0) {
        sb_append(&result, ",\"tools\":");
        sb_append(&result, tools.data);
    }

    sb_append(&result, ",\"messages\":");
    sb_append(&result, messages.data ? messages.data : "[]");
    sb_append_char(&result, '}');

    FREE_PTR(model);
    sb_free(&messages);
    sb_free(&tools);
    return result.data;
}


static void responses_convert_tools(StrBuf *out, JsonVal tools_val) {
    sb_append_char(out, '[');
    int wrote = 0;
    int n = json_array_len(tools_val);
    for (int i = 0; i < n; i++) {
        JsonVal tool = json_array_get(tools_val, i);
        char *name = json_get_string(tool, "name");
        if (!name || !name[0]) { FREE_PTR(name); continue; }
        char *desc = json_get_string(tool, "description");
        JsonVal parameters = json_get(tool, "input_schema");
        if (parameters.type == JSON_NULL) parameters = json_get(tool, "parameters");
        if (wrote++) sb_append_char(out, ',');
        sb_append(out, "{\"type\":\"function\",\"name\":");
        sb_append_json_string(out, name);
        sb_append(out, ",\"description\":");
        sb_append_json_string(out, desc ? desc : "");
        sb_append(out, ",\"parameters\":");
        if (parameters.type == JSON_NULL) sb_append(out, "{}"); else sb_append_json_val(out, parameters);
        sb_append_char(out, '}');
        FREE_PTR(name); FREE_PTR(desc);
    }
    sb_append_char(out, ']');
}

static void responses_convert_messages(StrBuf *out, JsonVal messages_val) {
    sb_append_char(out, '[');
    int wrote = 0;
    int n = json_array_len(messages_val);
    for (int i = 0; i < n; i++) {
        JsonVal msg = json_array_get(messages_val, i);
        char *role = json_get_string(msg, "role");
        JsonVal content = json_get(msg, "content");
        if (role && strcmp(role, "assistant") == 0 && content.type == JSON_ARRAY) {
            StrBuf text; sb_init(&text);
            int blocks = json_array_len(content);
            for (int j = 0; j < blocks; j++) {
                JsonVal block = json_array_get(content, j);
                char *type = json_get_string(block, "type");
                if (type && strcmp(type, "text") == 0) {
                    char *value = json_get_string(block, "text");
                    if (value) { sb_append(&text, value); FREE_PTR(value); }
                } else if (type && strcmp(type, "tool_use") == 0) {
                    char *id = json_get_string(block, "id");
                    char *name = json_get_string(block, "name");
                    JsonVal input = json_get(block, "input");
                    if (wrote++) sb_append_char(out, ',');
                    sb_append(out, "{\"type\":\"function_call\",\"call_id\":"); sb_append_json_string(out, id ? id : "");
                    sb_append(out, ",\"name\":"); sb_append_json_string(out, name ? name : "");
                    sb_append(out, ",\"arguments\":");
                    StrBuf args; sb_init(&args); if (input.type == JSON_NULL) sb_append(&args, "{}"); else sb_append_json_val(&args, input);
                    sb_append_json_string(out, args.data ? args.data : "{}"); sb_free(&args); sb_append_char(out, '}');
                    FREE_PTR(id); FREE_PTR(name);
                }
                FREE_PTR(type);
            }
            if (text.len > 0) { if (wrote++) sb_append_char(out, ','); sb_append(out, "{\"role\":\"assistant\",\"content\":"); sb_append_json_string(out, text.data); sb_append_char(out, '}'); }
            sb_free(&text);
        } else if (role && strcmp(role, "user") == 0 && content.type == JSON_ARRAY) {
            int blocks = json_array_len(content);
            for (int j = 0; j < blocks; j++) {
                JsonVal block = json_array_get(content, j);
                char *type = json_get_string(block, "type");
                if (type && strcmp(type, "tool_result") == 0) {
                    char *id = json_get_string(block, "tool_use_id"); char *value = json_get_string(block, "content");
                    if (wrote++) sb_append_char(out, ','); sb_append(out, "{\"type\":\"function_call_output\",\"call_id\":"); sb_append_json_string(out, id ? id : ""); sb_append(out, ",\"output\":"); sb_append_json_string(out, value ? value : ""); sb_append_char(out, '}');
                    FREE_PTR(id); FREE_PTR(value);
                } else if (type && strcmp(type, "text") == 0) {
                    char *value = json_get_string(block, "text"); if (wrote++) sb_append_char(out, ','); sb_append(out, "{\"role\":\"user\",\"content\":"); sb_append_json_string(out, value ? value : ""); sb_append_char(out, '}'); FREE_PTR(value);
                }
                FREE_PTR(type);
            }
        } else { if (wrote++) sb_append_char(out, ','); sb_append_json_val(out, msg); }
        FREE_PTR(role);
    }
    sb_append_char(out, ']');
}

char *convert_to_responses(const char *claude_body) {
    JsonParse jp = json_parse_root(claude_body);
    if (jp.error) return util_strdup(claude_body);
    char *model = json_get_string(jp.val, "model");
    int max_tokens = json_get_int(jp.val, "max_tokens");
    JsonVal system = json_get(jp.val, "system");
    JsonVal thinking = json_get(jp.val, "thinking");
    JsonVal output = json_get(jp.val, "output_config");
    JsonVal messages = json_get(jp.val, "messages");
    JsonVal tools_val = json_get(jp.val, "tools");
    StrBuf input, tools, result; sb_init(&input); sb_init(&tools); sb_init(&result);
    responses_convert_messages(&input, messages);
    if (tools_val.type == JSON_ARRAY && json_array_len(tools_val)) responses_convert_tools(&tools, tools_val);
    sb_append(&result, "{\"model\":"); sb_append_json_string(&result, model ? model : "");
    sb_append(&result, ",\"input\":"); sb_append(&result, input.data ? input.data : "[]");
    sb_appendf(&result, ",\"max_output_tokens\":%d,\"stream\":true", max_tokens);
    if (system.type != JSON_NULL) { char *value = json_as_string(system); if (value && value[0]) { sb_append(&result, ",\"instructions\":"); sb_append_json_string(&result, value); } FREE_PTR(value); }
    char *thinking_type = json_get_string(thinking, "type");
    if (thinking_type && (!strcmp(thinking_type, "adaptive") || !strcmp(thinking_type, "enabled"))) { char *effort = json_get_string(output, "effort"); sb_append(&result, ",\"reasoning\":{\"effort\":"); sb_append_json_string(&result, effort && effort[0] ? effort : "high"); sb_append_char(&result, '}'); FREE_PTR(effort); }
    FREE_PTR(thinking_type);
    if (tools.len && strcmp(tools.data, "[]")) { sb_append(&result, ",\"tools\":"); sb_append(&result, tools.data); }
    sb_append_char(&result, '}');
    FREE_PTR(model); sb_free(&input); sb_free(&tools);
    return result.data;
}
