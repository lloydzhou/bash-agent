#ifndef TRANSPORT_H
#define TRANSPORT_H

#include "util.h"
#include "json.h"

/*
 * 传输层 — HTTP 请求（libcurl）、SSE 流式解析
 *
 * 支持 Claude (Anthropic) 和 OpenAI 两种协议。
 * SSE 解析是同步阻塞的，在一个独立线程中运行。
 */

/* SSE 事件回调 */
typedef enum {
    SSE_TEXT,               /* 文本增量 */
    SSE_THINKING,           /* 思考增量 */
    SSE_TOOL_CALL_START,    /* 工具调用开始（id + name 已知） */
    SSE_TOOL_INPUT_DELTA,   /* 工具调用 input_json 增量 */
    SSE_TOOL_CALL,          /* 工具调用完成（完整，无增量） */
    SSE_USAGE,              /* token 用量 */
    SSE_STOP,               /* 停止 */
    SSE_ERROR,              /* 错误 */
    SSE_RETRY,              /* 重试（清空当前累积） */
} SseEventType;

typedef struct {
    SseEventType type;
    char *content;           /* TEXT/THINKING/STOP/ERROR: 文本内容 */
    char *tool_id;           /* TOOL_CALL: 工具调用 ID */
    char *tool_name;         /* TOOL_CALL: 工具名 */
    char *tool_input;        /* TOOL_CALL: 工具参数 JSON */
    int in_tokens;           /* USAGE: 输入 token */
    int out_tokens;          /* USAGE: 输出 token */
    int cache_read_tokens;   /* USAGE: 缓存读取 token */
    int cache_creation_tokens; /* USAGE: 缓存创建 token */
} SseEvent;

typedef void (*sse_callback_fn)(void *ctx, const SseEvent *evt);

/* HTTP 响应（非流式） */
typedef struct {
    int status_code;
    char *body;
} HttpResponse;

/* 释放 HTTP 响应 */
void http_response_free(HttpResponse *r);

/* 同步 POST 请求，返回整个响应 */
HttpResponse http_post(const char *url, const char **headers, int header_count,
                       const char *body, size_t body_len);

/* 流式 POST 请求，通过回调传递 SSE 事件 */
int http_post_sse(const char *url, const char **headers, int header_count,
                  const char *body, size_t body_len,
                  const char *provider,
                  sse_callback_fn callback, void *ctx,
                  volatile int *cancelled);

/* 解析 SSE 事件行（从 HTTP 响应体的 "data: ..." 行解析） */
int sse_parse_event(const char *provider, const char *data, size_t data_len,
                    sse_callback_fn callback, void *ctx);

/* ============================================================
 * SSE 累积器 — 用于 agent_loop 中收集流式事件
 * ============================================================ */

/* 累积的工具调用 */
typedef struct {
    char *id;
    char *name;
    StrBuf input_json;     /* 累积 input_json_delta */
} ToolCallAccum;

typedef struct {
    /* 累积的文本 */
    StrBuf text;
    StrBuf thinking;

    /* 累积的工具调用列表 */
    ToolCallAccum *tools;
    int tool_count;
    int tool_cap;

    /* 当前正在累积的 content_block 索引（-1 表示无） */
    int current_block_index;
    char *current_block_type;  /* "text", "thinking", "tool_use" */
    char *current_tool_id;     /* content_block_start 时的 tool id */
    char *current_tool_name;   /* content_block_start 时的 tool name */

    /* 统计 */
    int in_tokens;
    int out_tokens;
    int cache_read_tokens;
    int cache_creation_tokens;

    /* 停止原因 */
    char *stop_reason;

    /* 错误 */
    char *error;

    /* 状态标记 */
    int stopped;            /* 收到 stop 事件 */
} SseAccumulator;

/* 初始化/释放累积器 */
void sse_accum_init(SseAccumulator *acc);
void sse_accum_free(SseAccumulator *acc);

/* SSE 回调 — 累积事件到 SseAccumulator */
void sse_accum_callback(void *ctx, const SseEvent *evt);

/* 构建请求体 */
char *build_claude_request(const char *model, const char *system_prompt,
                           const char *tools_json,
                           char **conv_lines, int conv_line_count,
                           int max_tokens, const char *thinking, const char *effort);

/* 将 Claude 请求体转换为 OpenAI 格式 */
char *convert_to_openai(const char *claude_body);

/* 将 Claude 请求体转换为 Responses API 格式 */
char *convert_to_responses(const char *claude_body);

#endif /* TRANSPORT_H */
