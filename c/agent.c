#include "agent.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <signal.h>

/* ============================================================
 * 流式 SSE 回调 — 同时累积到 accum 并实时推送到 display queue
 *
 * 架构与 Go 版 streamCallback 一致：
 *   text/thinking  → 累积 accum + 立即 push display
 *   tool_call 等   → 仅累积 accum（需要完整数据）
 * ============================================================ */

/* 前置声明 */
static void push_display(MsgQueue *dq, DisplayMessage *msg);
static void push_display_event(const SessionPaths *paths, MsgQueue *dq, DisplayMessage *msg);

typedef struct {
    SseAccumulator accum;
    MsgQueue *display_queue;
    const SessionPaths *paths;      /* 用于记录事件到 events.jsonl */
} StreamDisplayCtx;

static void stream_display_callback(void *ctx, const SseEvent *evt) {
    StreamDisplayCtx *sctx = (StreamDisplayCtx *)ctx;

    switch (evt->type) {
    case SSE_TEXT:
        /* 累积 */
        sb_append(&sctx->accum.text, evt->content);
        /* 实时推送 display + 记录事件 */
        {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_text(evt->content);
            push_display_event(sctx->paths, sctx->display_queue, dm);
        }
        break;

    case SSE_THINKING:
        /* 累积 */
        sb_append(&sctx->accum.thinking, evt->content);
        /* 实时推送 display + 记录事件 */
        {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_thinking(evt->content);
            push_display_event(sctx->paths, sctx->display_queue, dm);
        }
        break;

    case SSE_STOP:
        sctx->accum.stopped = 1;
        if (evt->content) {
            if (sctx->accum.stop_reason) free(sctx->accum.stop_reason);
            sctx->accum.stop_reason = util_strdup(evt->content);
        }
        /* 推送 stop 到 display + 记录事件 */
        {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_stop(evt->content ? evt->content : "end_turn");
            push_display_event(sctx->paths, sctx->display_queue, dm);
        }
        break;

    case SSE_ERROR:
        if (sctx->accum.error) free(sctx->accum.error);
        sctx->accum.error = util_strdup(evt->content ? evt->content : "unknown error");
        {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_error(sctx->accum.error);
            push_display_event(sctx->paths, sctx->display_queue, dm);
        }
        break;

    case SSE_USAGE:
        if (evt->in_tokens > 0) sctx->accum.in_tokens = evt->in_tokens;
        if (evt->out_tokens > 0) sctx->accum.out_tokens = evt->out_tokens;
        if (evt->cache_read_tokens > 0) sctx->accum.cache_read_tokens = evt->cache_read_tokens;
        if (evt->cache_creation_tokens > 0) sctx->accum.cache_creation_tokens = evt->cache_creation_tokens;
        break;

    case SSE_TOOL_CALL_START: {
        SseAccumulator *acc = &sctx->accum;
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
        SseAccumulator *acc = &sctx->accum;
        if (acc->tool_count > 0 && evt->content) {
            sb_append(&acc->tools[acc->tool_count - 1].input_json, evt->content);
        }
        break;
    }

    case SSE_TOOL_CALL: {
        SseAccumulator *acc = &sctx->accum;
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

    case SSE_RETRY:
        sb_truncate(&sctx->accum.text, 0);
        sb_truncate(&sctx->accum.thinking, 0);
        for (int i = 0; i < sctx->accum.tool_count; i++) {
            free(sctx->accum.tools[i].id);
            free(sctx->accum.tools[i].name);
            sb_free(&sctx->accum.tools[i].input_json);
        }
        sctx->accum.tool_count = 0;
        sctx->accum.stopped = 0;
        if (sctx->accum.stop_reason) { free(sctx->accum.stop_reason); sctx->accum.stop_reason = NULL; }
        if (sctx->accum.error) { free(sctx->accum.error); sctx->accum.error = NULL; }
        sctx->accum.in_tokens = 0;
        sctx->accum.out_tokens = 0;
        sctx->accum.cache_read_tokens = 0;
        sctx->accum.cache_creation_tokens = 0;
        break;
    }
}

/* ============================================================
 * SubAgent 线程参数（前置声明，agent_loop 中需要引用）
 * ============================================================ */
typedef struct {
    Agent *parent;
    char *prompt;
    char *description;
    int fork_mode;
    char *sub_session_id;
    MsgQueue *input_queue;
} SubAgentArgs;

/* ============================================================
 * Agent 创建/销毁
 * ============================================================ */

Agent *agent_create(const char *provider, const char *model,
                    const char *api_key, const char *base_url,
                    const char *cwd, const char *home,
                    const char *session_id, int interactive,
                    char **skill_names, int skill_count,
                    MsgQueue *input_queue, MsgQueue *display_queue) {
    Agent *a = calloc(1, sizeof(Agent));
    if (!a) return NULL;

    a->provider = util_strdup(provider);
    a->model = util_strdup(model);
    a->api_key = util_strdup(api_key);
    a->base_url = util_strdup(base_url);
    a->cwd = util_strdup(cwd);
    a->home = util_strdup(home);
    a->interactive = interactive;
    a->input_queue = input_queue;
    a->display_queue = display_queue;
    a->max_tokens = 4096;
    a->max_turns = 40;
    a->max_context_tokens = 200000;
    a->tool_timeout_secs = 600;
    a->tool_result_max_bytes = 100000;
    {
        const char *env_max = getenv("TOOL_RESULT_MAX_BYTES");
        if (env_max && *env_max) a->tool_result_max_bytes = atoi(env_max);
        if (a->tool_result_max_bytes <= 0) a->tool_result_max_bytes = 100000;
    }
    a->thinking = util_strdup(util_env("THINKING", "adaptive"));
    a->effort = util_strdup(util_env("EFFORT", "high"));

    /* Skills */
    a->skill_count = skill_count;
    if (skill_count > 0) {
        a->skill_names = malloc(skill_count * sizeof(char*));
        for (int i = 0; i < skill_count; i++) {
            a->skill_names[i] = util_strdup(skill_names[i]);
        }
    } else {
        a->skill_names = NULL;
    }

    /* 构建 API URL */
    StrBuf url_buf;
    sb_init(&url_buf);
    if (strcmp(provider, "claude") == 0) {
        const char *base = (base_url && base_url[0]) ? base_url : "https://api.anthropic.com/v1";
        sb_appendf(&url_buf, "%s/messages", base);
    } else {
        const char *base = (base_url && base_url[0]) ? base_url : "https://api.openai.com/v1";
        sb_appendf(&url_buf, "%s/chat/completions", base);
    }
    a->api_url = url_buf.data;

    /* 初始化会话 */
    char *sid = util_strdup(session_id);
    if (!sid || !sid[0]) {
        FREE_PTR(sid);
        sid = util_new_session_id();
    }
    a->session_id = util_strdup(sid);
    a->paths = store_session_paths_for(home, cwd, sid);
    free(sid);

    /* 判断是否新会话 */
    int is_new = 1;
    FILE *f = fopen(a->paths.conversation, "r");
    if (f) { is_new = 0; fclose(f); }

    store_session_init(&a->paths, is_new);

    /* 初始化 pending fork（暂未使用） */
    a->pending_fork_cap = 0;
    a->pending_fork_args = NULL;
    a->pending_fork_count = 0;

    return a;
}

void agent_destroy(Agent *agent) {
    if (!agent) return;
    FREE_PTR(agent->provider);
    FREE_PTR(agent->model);
    FREE_PTR(agent->api_key);
    FREE_PTR(agent->base_url);
    FREE_PTR(agent->api_url);
    FREE_PTR(agent->cwd);
    FREE_PTR(agent->home);
    FREE_PTR(agent->session_id);
    FREE_PTR(agent->thinking);
    FREE_PTR(agent->effort);
    if (agent->skill_names) {
        for (int i = 0; i < agent->skill_count; i++) FREE_PTR(agent->skill_names[i]);
        free(agent->skill_names);
    }
    store_session_paths_free(&agent->paths);
    free(agent);
}

/* ============================================================
 * 推送 display 消息的辅助函数
 * ============================================================ */

static void push_display(MsgQueue *dq, DisplayMessage *msg) {
    if (dq && msg) {
        mq_push(dq, msg);
    }
}

/* 将 DisplayMessage 转为事件 JSON 字符串（用于 events.jsonl） */
static char *display_msg_to_event(DisplayMessage *msg) {
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
        if (msg->tool_input) {
            /* tool_input 已是 JSON 字符串，直接输出 */
            sb_append(&buf, msg->tool_input);
        } else {
            sb_append(&buf, "{}");
        }
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
        sb_appendf(&buf,
            "{\"type\":\"usage\",\"input_tokens\":%d,\"output_tokens\":%d,"
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
        sb_append_char(&buf, '}');
        break;
    default:
        sb_free(&buf);
        return NULL;
    }

    return buf.data;
}

/* 推送 display 消息并同步记录事件 */
static void push_display_event(const SessionPaths *paths, MsgQueue *dq, DisplayMessage *msg) {
    if (!msg) return;
    /* 先记录事件（读取 msg 字段），再推送（交出 msg 所有权给 display 线程）。
     * 顺序很重要：mq_push 后 display 线程可能异步 free(msg)，
     * 此时再读取 msg->content 等字段就是 use-after-free。 */
    if (paths) {
        char *evt = display_msg_to_event(msg);
        if (evt) {
            store_event_append(paths, evt);
            free(evt);
        }
    }
    if (dq) mq_push(dq, msg);
}

/* ============================================================
 * agent_replay_events — 从 events.jsonl 重放最近 N 轮事件
 *
 * 对应 bash 版：store_event_recent_turn_lines 10 | event_replay.awk | display_stream
 * 核心逻辑：累积 per-token 的 text/thinking 事件为完整块，然后推送 DisplayMessage。
 * ============================================================ */

/* 最近 N 轮事件的起始行号 */
static int find_recent_turn_start(const SessionPaths *paths, int max_turns) {
    char **lines = NULL;
    int count = 0;
    if (store_event_lines(paths, &lines, &count) != 0 || count == 0) return -1;

    int user_input_count = 0;
    int start_line = -1;
    for (int i = count - 1; i >= 0; i--) {
        if (strstr(lines[i], "\"type\":\"user_input\"")) {
            user_input_count++;
            start_line = i;
            if (user_input_count >= max_turns) break;
        }
    }

    /* 释放 */
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);

    return start_line;
}

void agent_replay_events(Agent *agent, int max_turns) {
    char **lines = NULL;
    int count = 0;
    if (store_event_lines(&agent->paths, &lines, &count) != 0 || count == 0) return;

    int start = find_recent_turn_start(&agent->paths, max_turns);
    if (start < 0) {
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return;
    }

    /* 累积缓冲 */
    StrBuf acc_text, acc_thinking;
    sb_init(&acc_text);
    sb_init(&acc_thinking);

    for (int i = start; i < count; i++) {
        const char *line = lines[i];
        JsonParse jp = json_parse_root(line);
        if (jp.error) {  continue; }

        char *type = json_get_string(jp.val, "type");
        if (!type) {  continue; }

        if (strcmp(type, "user_input") == 0) {
            /* flush 累积 */
            if (acc_thinking.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(acc_thinking.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_thinking, 0);
            }
            if (acc_text.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(acc_text.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_text, 0);
            }
            /* 显示 user_input（与 Rust 版 display_replay_event USER_MESSAGE 对齐） */
            char *content = json_get_string(jp.val, "content");
            if (content && content[0]) {
                /* 截断到 77 字符（加 "..." 共 80） */
                size_t clen = strlen(content);
                if (clen > 80) {
                    content[77] = '.';
                    content[78] = '.';
                    content[79] = '.';
                    content[80] = '\0';
                }
                /* 取第一行 */
                char *nl = strchr(content, '\n');
                if (nl) *nl = '\0';

                StrBuf user_display;
                sb_init(&user_display);
                sb_appendf(&user_display, "\n\x1b[32m> %s\x1b[0m\n", content);
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(user_display.data);
                push_display(agent->display_queue, dm);
                sb_free(&user_display);
            }
            free(content);
        }
        else if (strcmp(type, "text") == 0) {
            /* flush thinking */
            if (acc_thinking.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(acc_thinking.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_thinking, 0);
            }
            char *content = json_get_string(jp.val, "content");
            if (content && *content) sb_append(&acc_text, content);
            free(content);
        }
        else if (strcmp(type, "thinking") == 0) {
            /* flush text */
            if (acc_text.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(acc_text.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_text, 0);
            }
            char *content = json_get_string(jp.val, "content");
            if (content && *content) sb_append(&acc_thinking, content);
            free(content);
        }
        else if (strcmp(type, "tool_call") == 0) {
            /* flush 累积 */
            if (acc_thinking.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(acc_thinking.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_thinking, 0);
            }
            if (acc_text.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(acc_text.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_text, 0);
            }
            char *name = json_get_string(jp.val, "name");
            char *id = json_get_string(jp.val, "id");
            /* 从 input 提取摘要（截断） */
            char summary[84] = "";
            JsonVal input_val = json_get(jp.val, "input");
            if (input_val.type != JSON_NULL) {
                char *input_str = json_as_string(input_val);
                if (input_str) {
                    size_t slen = strlen(input_str);
                    if (slen > 80) {
                        memcpy(summary, input_str, 80);
                        strcpy(summary + 80, "...");
                    } else {
                        memcpy(summary, input_str, slen);
                        summary[slen] = '\0';
                    }
                    free(input_str);
                }
            }
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_tool_call(id ? id : "", name ? name : "", summary);
            push_display(agent->display_queue, dm);
            free(name); free(id);
        }
        else if (strcmp(type, "tool_result") == 0) {
            /* flush 累积 */
            if (acc_thinking.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(acc_thinking.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_thinking, 0);
            }
            if (acc_text.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(acc_text.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_text, 0);
            }
            char *content = json_get_string(jp.val, "content");
            /* 截断到 200 字符（与 bash 版 event_replay.awk 对齐） */
            if (content) {
                size_t len = strlen(content);
                if (len > 200) {
                    content[200] = '.';
                    content[201] = '.';
                    content[202] = '.';
                    content[203] = '\0';
                }
            }
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_tool_result(content ? content : "", 0);
            push_display(agent->display_queue, dm);
            free(content);
        }
        else if (strcmp(type, "sub_agent_result") == 0) {
            /* flush 累积 */
            if (acc_thinking.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(acc_thinking.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_thinking, 0);
            }
            if (acc_text.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(acc_text.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_text, 0);
            }
            char *sid = json_get_string(jp.val, "session_id");
            char *status = json_get_string(jp.val, "status");
            char *text = json_get_string(jp.val, "text");
            /* 截断 text */
            if (text) {
                size_t len = strlen(text);
                if (len > 200) {
                    text[200] = '.';
                    text[201] = '.';
                    text[202] = '.';
                    text[203] = '\0';
                }
            }
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_sub_agent_result(sid ? sid : "", status ? status : "ok", text ? text : "");
            push_display(agent->display_queue, dm);
            free(sid); free(status); free(text);
        }
        else if (strcmp(type, "error") == 0) {
            /* flush 累积 */
            if (acc_thinking.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(acc_thinking.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_thinking, 0);
            }
            if (acc_text.len > 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(acc_text.data);
                push_display(agent->display_queue, dm);
                sb_truncate(&acc_text, 0);
            }
            char *message = json_get_string(jp.val, "message");
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_error(message ? message : "unknown");
            push_display(agent->display_queue, dm);
            free(message);
        }
        /* stop, usage, session_start, retry, sub_agent_start, sub_agent_end 等跳过 */

        free(type);
        
    }

    /* flush 最后的累积 */
    if (acc_thinking.len > 0) {
        DisplayMessage *dm = malloc(sizeof(DisplayMessage));
        *dm = display_msg_thinking(acc_thinking.data);
        push_display(agent->display_queue, dm);
    }
    if (acc_text.len > 0) {
        DisplayMessage *dm = malloc(sizeof(DisplayMessage));
        *dm = display_msg_text(acc_text.data);
        push_display(agent->display_queue, dm);
    }

    sb_free(&acc_text);
    sb_free(&acc_thinking);
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
}

/* ============================================================
 * agent_loop — 单次 LLM 对话循环
 * ============================================================ */

int agent_loop(Agent *agent, const char *user_input) {
    if (!user_input || !user_input[0]) return 0;

    /* 记录 user_input 事件（与 bash 版对齐） */
    {
        StrBuf evt;
        sb_init(&evt);
        sb_append(&evt, "{\"type\":\"user_input\",\"content\":");
        sb_append_json_string(&evt, user_input);
        sb_append_char(&evt, '}');
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    /* 重置中断标志 */
    agent->interrupted = 0;

    /* 添加 user 消息到 conversation */
    store_conv_add_user(agent->paths.conversation, user_input);

    /* 递增 turn 计数 */
    char *stats_content = store_stats_read(agent->paths.stats);
    if (stats_content) {
        JsonParse jp = json_parse_root(stats_content);
        if (!jp.error) {
            /* 简单地修改 JSON 字符串中的 current_turn_count */
            /* 由于我们的 JSON 解析器是零拷贝的，这里用文件重写方式 */
        }
        free(stats_content);
    }

    /* 记录事件：新 session 时记录 session_start */
    {
        int event_count = 0;
        char **store_event_lines = NULL;
        store_conv_line_count(agent->paths.events, &store_event_lines, &event_count);
        for (int ei = 0; ei < event_count; ei++) free(store_event_lines[ei]);
        free(store_event_lines);

        if (event_count == 0) {
            StrBuf ss_buf;
            sb_init(&ss_buf);
            sb_appendf(&ss_buf, "{\"type\":\"session_start\",\"session_id\":");
            sb_append_json_string(&ss_buf, agent->session_id ? agent->session_id : "");
            sb_append(&ss_buf, "}");
            store_event_append(&agent->paths, ss_buf.data);
            sb_free(&ss_buf);
        }
    }

    int turn = 0;
    while (turn < agent->max_turns) {
        turn++;
        agent->interrupted = 0;

        /* compact */
        agent_compact_context(agent, "auto");

        /* 读取 conversation */
        char **lines = NULL;
        int line_count = 0;
        if (store_conv_line_count(agent->paths.conversation, &lines, &line_count) != 0) {
            return -1;
        }

        /* 构建 system prompt */
        char *system_prompt = agent_build_prompt(agent);
        if (!system_prompt) {
            for (int i = 0; i < line_count; i++) free(lines[i]);
            free(lines);
            return -1;
        }

        /* 读取 tools.json */
        char *tools_json = util_read_file("c/tools.json");
        if (!tools_json) tools_json = util_strdup("[]");

        /* 构建请求体 */
        char *body = build_claude_request(agent->model, system_prompt,
                                          tools_json, lines, line_count,
                                          agent->max_tokens,
                                          agent->thinking, agent->effort);

        /* 构建 HTTP headers */
        const char *headers[8];
        char auth_header[512];
        int hdr_count = 0;
        headers[hdr_count++] = "Content-Type: application/json";
        headers[hdr_count++] = "User-Agent: claude-cli/1.0.33 (max, cli)";

        if (strcmp(agent->provider, "claude") == 0) {
            snprintf(auth_header, sizeof(auth_header), "x-api-key: %s", agent->api_key);
            headers[hdr_count++] = auth_header;
            headers[hdr_count++] = "anthropic-version: 2023-06-01";
        } else {
            snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", agent->api_key);
            headers[hdr_count++] = auth_header;
        }

        /* ---- SSE 流式请求 ---- */
        /* 准备流式上下文（累积 + 实时 display） */
        StreamDisplayCtx sctx;
        sse_accum_init(&sctx.accum);
        sctx.display_queue = agent->display_queue;
        sctx.paths = &agent->paths;

        int sse_rc = http_post_sse(agent->api_url, headers, hdr_count,
                                   body, strlen(body),
                                   agent->provider,
                                   stream_display_callback, &sctx,
                                   &agent->interrupted);

        /* 回收引用 — accum 已嵌入 sctx 中 */
        SseAccumulator *accum = &sctx.accum;

        free(body);
        free(system_prompt);
        free(tools_json);
        for (int i = 0; i < line_count; i++) free(lines[i]);
        free(lines);

        if (sse_rc != 0) {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_error(accum->error ? accum->error : "HTTP request failed");
            push_display_event(&agent->paths, agent->display_queue, dm);
            sse_accum_free(accum);
            return -1;
        }

        if (accum->error) {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_error(accum->error);
            push_display_event(&agent->paths, agent->display_queue, dm);
            sse_accum_free(accum);
            return -1;
        }

        /* text/thinking 已在 stream_display_callback 中实时推送，此处不再批量推送 */

        /* ---- 显示工具调用 ---- */
        for (int i = 0; i < accum->tool_count; i++) {
            ToolCallAccum *tc = &accum->tools[i];
            /* 从 input_json 提取摘要 */
            char *summary = NULL;
            if (tc->input_json.len > 0) {
                JsonParse jp2 = json_parse_root(tc->input_json.data);
                if (!jp2.error) {
                    char *field = NULL;
                    if (strcmp(tc->name, "Read") == 0 || strcmp(tc->name, "Write") == 0 || strcmp(tc->name, "Edit") == 0) {
                        field = json_get_string(jp2.val, "path");
                    } else if (strcmp(tc->name, "Glob") == 0 || strcmp(tc->name, "Grep") == 0) {
                        field = json_get_string(jp2.val, "pattern");
                    } else if (strcmp(tc->name, "Bash") == 0) {
                        field = json_get_string(jp2.val, "command");
                    } else if (strcmp(tc->name, "Skill") == 0) {
                        field = json_get_string(jp2.val, "name");
                    } else if (strcmp(tc->name, "TodoWrite") == 0) {
                        /* 计算 completed/total */
                        JsonVal todos_arr = json_get(jp2.val, "todos");
                        if (todos_arr.type == JSON_ARRAY) {
                            int total = json_array_len(todos_arr);
                            int comp = 0;
                            for (int ti = 0; ti < total; ti++) {
                                JsonVal ti_item = json_array_get(todos_arr, ti);
                                char *ti_status = json_get_string(ti_item, "status");
                                if (ti_status && strcmp(ti_status, "completed") == 0) comp++;
                                free(ti_status);
                            }
                            char buf[32];
                            snprintf(buf, sizeof(buf), "%d/%d", comp, total);
                            field = util_strdup(buf);
                        }
                    }
                    if (field) {
                        summary = field;
                    } else {
                        /* 使用整个 input_json（截断） */
                        if (tc->input_json.len > 80) {
                            summary = malloc(84);
                            memcpy(summary, tc->input_json.data, 80);
                            strcpy(summary + 80, "...");
                        } else {
                            summary = util_strdup(tc->input_json.data);
                        }
                    }
                }
            }
            if (!summary) summary = util_strdup("");

            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_tool_call(tc->id, tc->name, summary);
            /* 覆盖 tool_input 为完整 JSON（用于事件记录） */
            free(dm->tool_input);
            dm->tool_input = util_strdup(tc->input_json.data);
            push_display_event(&agent->paths, agent->display_queue, dm);
            free(summary);
        }

        /* ---- 更新 token 统计 ---- */
        agent->last_input_tokens = accum->in_tokens;
        agent->last_output_tokens = accum->out_tokens;
        agent->last_cache_read_tokens = accum->cache_read_tokens;
        agent->last_cache_creation_tokens = accum->cache_creation_tokens;
        agent->last_context_tokens = accum->in_tokens + accum->out_tokens +
            accum->cache_read_tokens + accum->cache_creation_tokens;

        if (accum->in_tokens > 0 || accum->out_tokens > 0) {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_usage(accum->in_tokens, accum->out_tokens,
                                    accum->cache_read_tokens, accum->cache_creation_tokens);
            push_display_event(&agent->paths, agent->display_queue, dm);
        }

        /* ---- 保存 assistant 消息到 conversation ---- */
        const char **tc_ids = NULL, **tc_names = NULL, **tc_inputs = NULL;
        if (accum->tool_count > 0) {
            tc_ids = malloc(accum->tool_count * sizeof(char*));
            tc_names = malloc(accum->tool_count * sizeof(char*));
            tc_inputs = malloc(accum->tool_count * sizeof(char*));
            for (int i = 0; i < accum->tool_count; i++) {
                tc_ids[i] = accum->tools[i].id;
                tc_names[i] = accum->tools[i].name;
                tc_inputs[i] = accum->tools[i].input_json.data;
            }
        }
        store_conv_add_assistant(agent->paths.conversation,
                          accum->thinking.data, accum->text.data,
                          accum->tool_count, tc_ids, tc_names, tc_inputs);
        free(tc_ids);
        free(tc_names);
        free(tc_inputs);

        /* ---- 执行工具调用 ---- */
        if (accum->tool_count > 0 && accum->stop_reason &&
            (strcmp(accum->stop_reason, "tool_use") == 0 ||
             strcmp(accum->stop_reason, "tool_calls") == 0)) {

            const char **result_ids = malloc(accum->tool_count * sizeof(char*));
            const char **result_contents = malloc(accum->tool_count * sizeof(char*));

            for (int i = 0; i < accum->tool_count; i++) {
                ToolCallAccum *tc = &accum->tools[i];
                ToolResult tr;

                /* SubAgent 特殊处理 */
                if (strcmp(tc->name, "SubAgent") == 0) {
                    JsonParse jp = json_parse_root(tc->input_json.data);
                    char *prompt = NULL, *description = NULL;
                    int fork_mode = 0;
                    if (!jp.error) {
                        prompt = json_get_string(jp.val, "prompt");
                        description = json_get_string(jp.val, "description");
                        fork_mode = json_get_bool(jp.val, "fork", false) ? 1 : 0;
                    }
                    char *result = agent_handle_sub_agent(agent,
                                        prompt ? prompt : "",
                                        description ? description : "",
                                        fork_mode);
                    tr.output = result;
                    tr.exit_code = 0;
                    free(prompt); free(description);
                } else {
                    tr = tool_dispatch(tc->name, tc->input_json.data,
                                      agent->cwd, agent->home,
                                      agent->tool_timeout_secs,
                                      agent->tool_result_max_bytes,
                                      &agent->paths);
                }

                /* 截断结果 */
                if (tr.output) {
                    char *formatted = tool_format_result(tr.output, agent->tool_result_max_bytes);
                    free(tr.output);
                    tr.output = formatted;
                }

                /* 为 Read/Write 工具添加 file summary 前缀 */
                if (strcmp(tc->name, "Read") == 0 || strcmp(tc->name, "Write") == 0) {
                    /* 从 input_json 获取 path */
                    char *fpath = NULL;
                    JsonParse jp2 = json_parse_root(tc->input_json.data);
                    if (!jp2.error) fpath = json_get_string(jp2.val, "path");

                    StrBuf summary;
                    sb_init(&summary);
                    if (fpath && *fpath) {
                        /* 获取文件大小和行数 */
                        long fbytes = 0, flines = 0;
                        FILE *fp = fopen(fpath, "r");
                        if (fp) {
                            fseek(fp, 0, SEEK_END);
                            fbytes = ftell(fp);
                            fseek(fp, 0, SEEK_SET);
                            int ch, nl = 0;
                            while ((ch = fgetc(fp)) != EOF) {
                                if (ch == '\n') nl++;
                            }
                            flines = nl;
                            fclose(fp);
                        }
                        sb_appendf(&summary, "%s(%s) [%ld lines, %ld bytes]",
                                   tc->name, fpath, flines, fbytes);
                    } else {
                        sb_appendf(&summary, "%s()", tc->name);
                    }
                    free(fpath);

                    /* display 只显示 summary 行 */
                    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                    *dm = display_msg_tool_result(summary.data, tr.exit_code);
                    push_display_event(&agent->paths, agent->display_queue, dm);

                    /* conversation 保存 file_summary + "\n" + 工具结果 */
                    StrBuf conv_result;
                    sb_init(&conv_result);
                    sb_append(&conv_result, summary.data);
                    sb_append(&conv_result, "\n");
                    if (tr.output) sb_append(&conv_result, tr.output);
                    free(tr.output);
                    tr.output = conv_result.data;

                    free(summary.data);
                } else {
                    /* 显示工具结果 */
                    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                    *dm = display_msg_tool_result(tr.output ? tr.output : "(empty)", tr.exit_code);
                    push_display_event(&agent->paths, agent->display_queue, dm);
                }

                result_ids[i] = tc->id;

                /* Edit 工具只保存第一行到 conversation */
                if (strcmp(tc->name, "Edit") == 0 && tr.output) {
                    const char *nl = strchr(tr.output, '\n');
                    if (nl) {
                        size_t first_len = nl - tr.output;
                        char *first_line = malloc(first_len + 1);
                        memcpy(first_line, tr.output, first_len);
                        first_line[first_len] = '\0';
                        result_contents[i] = first_line;
                        free(tr.output);
                        tr.output = NULL;
                    } else {
                        result_contents[i] = tr.output;
                    }
                } else {
                    /* result_contents 必须是 malloc'd 指针，因为后面会 free */
                    result_contents[i] = tr.output ? tr.output : util_strdup("");
                }

                /* PlanClear / PlanConfirm 触发 compact */
                if (strcmp(tc->name, "PlanClear") == 0 || strcmp(tc->name, "PlanConfirm") == 0) {
                    agent_compact_context(agent, "store_plan_clear");
                }
            }

            /* 保存 tool_results */
            store_conv_add_tool_results(agent->paths.conversation, accum->tool_count,
                                  result_ids, result_contents);

            /* 释放 tool result 输出 */
            for (int i = 0; i < accum->tool_count; i++) {
                free((void*)result_contents[i]);
            }
            free(result_ids);
            free(result_contents);
        }

        /* ---- 显示 stop ---- */
        if (accum->stop_reason) {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_stop(accum->stop_reason);
            push_display_event(&agent->paths, agent->display_queue, dm);
        }

        /* ---- 判断是否继续循环 ---- */
        int should_continue = (accum->stop_reason != NULL) &&
            (strcmp(accum->stop_reason, "tool_use") == 0 ||
             strcmp(accum->stop_reason, "tool_calls") == 0);

        sse_accum_free(accum);

        if (!should_continue) break;
        if (agent->interrupted) break;
    }

    return 0;
}

/* ============================================================
 * agent_main_loop — 从 input_queue 取消息驱动循环
 * ============================================================ */

int agent_main_loop(Agent *agent) {
    while (1) {
        void *data = NULL;
        if (mq_pop(agent->input_queue, &data) != 0) break; /* 队列关闭 */

        InputMessage *msg = (InputMessage *)data;
        if (!msg) continue;

        switch (msg->type) {
            case MSG_USER_INPUT: {
                /* 重置 interrupted 标志。
                 * 防止等待输入时的 Ctrl+C（设了 agent->interrupted=1）
                 * 残留到 agent_loop 开始时导致立即中断。
                 * 模仿 Rust 版 agent_loop_stream 入口的 CTRLC_FLAG.swap(false) 模式。 */
                agent->interrupted = 0;

                agent_loop(agent, msg->data.user_input.text);

                /* 如果有活跃的 sub-agent，继续处理它们的结果，
                 * 直到所有 sub-agent 完成才 signal done。
                 * 这避免 readline 线程在 sub-agent 结果到达前显示提示符，
                 * 导致输出与提示符交错混乱。
                 * 模仿 bash 版 agent_run_loop 的单线程行为：
                 * bash 版是同步的，agent_loop 处理 sub-agent 结果后
                 * 才显示下一轮提示符。 */
                while (agent->active_sub_count > 0) {
                    void *sub_data = NULL;
                    if (mq_pop(agent->input_queue, &sub_data) != 0) break;
                    InputMessage *sub_msg = (InputMessage *)sub_data;
                    if (!sub_msg) continue;

                    if (sub_msg->type == MSG_AGENT_RESULT) {
                        agent_handle_sub_agent_result(agent,
                            sub_msg->data.agent_result.session_id,
                            sub_msg->data.agent_result.status,
                            sub_msg->data.agent_result.thinking,
                            sub_msg->data.agent_result.text,
                            sub_msg->data.agent_result.in_tokens,
                            sub_msg->data.agent_result.out_tokens,
                            sub_msg->data.agent_result.cache_read_tokens,
                            sub_msg->data.agent_result.cache_creation_tokens);

                        StrBuf ctx;
                        sb_init(&ctx);
                        sb_appendf(&ctx, "[sub-agent %s] %s (in=%d, out=%d)\nThinking: %s\nText: %s",
                                   sub_msg->data.agent_result.session_id,
                                   sub_msg->data.agent_result.status,
                                   sub_msg->data.agent_result.in_tokens,
                                   sub_msg->data.agent_result.out_tokens,
                                   sub_msg->data.agent_result.thinking ? sub_msg->data.agent_result.thinking : "",
                                   sub_msg->data.agent_result.text ? sub_msg->data.agent_result.text : "");
                        agent_loop(agent, ctx.data);
                        sb_free(&ctx);
                    } else {
                        /* 非预期消息（如另一个 USER_INPUT），放回队列 */
                        /* 简单处理：也执行它 */
                        /* 这里不会发生，因为 readline 线程在等 done */
                        agent_loop(agent, sub_msg->data.user_input.text);
                    }
                    input_message_free(sub_msg);
                    free(sub_msg);
                }

                /* 所有轮次完成：signal done（通知 readline 线程继续读下一行） */
                if (msg->data.user_input.done_mutex) {
                    pthread_mutex_lock(msg->data.user_input.done_mutex);
                    *(msg->data.user_input.done_flag) = 1;
                    pthread_cond_signal(msg->data.user_input.done_cond);
                    pthread_mutex_unlock(msg->data.user_input.done_mutex);
                }
                break;
            }
            case MSG_AGENT_RESULT: {
                /* SubAgent 结果处理（非交互模式下直接到达此处） */
                agent_handle_sub_agent_result(agent,
                    msg->data.agent_result.session_id,
                    msg->data.agent_result.status,
                    msg->data.agent_result.thinking,
                    msg->data.agent_result.text,
                    msg->data.agent_result.in_tokens,
                    msg->data.agent_result.out_tokens,
                    msg->data.agent_result.cache_read_tokens,
                    msg->data.agent_result.cache_creation_tokens);

                /* 将结果注入 conversation 并触发 agent loop */
                StrBuf ctx;
                sb_init(&ctx);
                sb_appendf(&ctx, "[sub-agent %s] %s (in=%d, out=%d)\nThinking: %s\nText: %s",
                           msg->data.agent_result.session_id,
                           msg->data.agent_result.status,
                           msg->data.agent_result.in_tokens,
                           msg->data.agent_result.out_tokens,
                           msg->data.agent_result.thinking ? msg->data.agent_result.thinking : "",
                           msg->data.agent_result.text ? msg->data.agent_result.text : "");
                agent_loop(agent, ctx.data);
                sb_free(&ctx);
                break;
            }
        }

        input_message_free(msg);
        free(msg);

        /* 非交互模式且无活跃子 agent 时退出 */
        if (!agent->interactive && agent->active_sub_count <= 0) break;
    }
    return 0;
}

/* ============================================================
 * SubAgent 处理
 * ============================================================ */

static void *sub_agent_thread_fn(void *arg) {
    SubAgentArgs *args = (SubAgentArgs *)arg;

    /* 创建子 Agent */
    Agent *sub = agent_create(args->parent->provider,
                              args->parent->model,
                              args->parent->api_key,
                              args->parent->base_url,
                              args->parent->cwd,
                              args->parent->home,
                              args->sub_session_id,
                              0, /* 非交互 */
                              NULL, 0, /* 无 skills */
                              NULL, NULL); /* 不需要消息队列 */

    if (!sub) {
        /* 发送失败结果 */
        InputMessage *msg = calloc(1, sizeof(InputMessage));
        msg->type = MSG_AGENT_RESULT;
        msg->data.agent_result.session_id = util_strdup(args->sub_session_id);
        msg->data.agent_result.status = util_strdup("failed");
        msg->data.agent_result.text = util_strdup("Failed to create sub-agent");
        mq_push(args->input_queue, msg);
        goto cleanup;
    }

    /* fork 模式：复制父会话（不含 tool_result，因为主线程还未写入） */
    if (args->fork_mode) {
        SessionPaths sub_paths = store_session_paths_for(args->parent->home,
                                                    args->parent->cwd,
                                                    args->sub_session_id);
        store_session_init_sub(&args->parent->paths, &sub_paths, 1);
        store_session_paths_free(&sub_paths);
    }

    /* 重定向 stdout/stderr 到 /dev/null */
    /* (在子线程中不做这个，因为工具执行用的是 popen) */

    /* 执行 agent_loop */
    int rc = agent_loop(sub, args->prompt);

    /* 提取结果：取最后一条 assistant 消息 */
    char **lines = NULL;
    int line_count = 0;
    store_conv_line_count(sub->paths.conversation, &lines, &line_count);

    char *result_thinking = NULL;
    char *result_text = NULL;

    for (int i = line_count - 1; i >= 0; i--) {
        JsonParse jp = json_parse_root(lines[i]);
        if (jp.error) continue;
        char *role = json_get_string(jp.val, "role");
        if (role && strcmp(role, "assistant") == 0) {
            JsonVal content = json_get(jp.val, "content");
            if (content.type == JSON_ARRAY) {
                int clen = json_array_len(content);
                for (int j = 0; j < clen; j++) {
                    JsonVal block = json_array_get(content, j);
                    char *btype = json_get_string(block, "type");
                    if (btype) {
                        if (strcmp(btype, "thinking") == 0 && !result_thinking) {
                            result_thinking = json_get_string(block, "thinking");
                        } else if (strcmp(btype, "text") == 0 && !result_text) {
                            result_text = json_get_string(block, "text");
                        }
                        free(btype);
                    }
                }
            }
            free(role);
            break;
        }
        free(role);
    }

    for (int i = 0; i < line_count; i++) free(lines[i]);
    free(lines);

    /* 发送结果 */
    InputMessage *msg = calloc(1, sizeof(InputMessage));
    msg->type = MSG_AGENT_RESULT;
    msg->data.agent_result.session_id = util_strdup(args->sub_session_id);
    msg->data.agent_result.status = util_strdup(rc == 0 ? "ok" : "failed");
    msg->data.agent_result.thinking = result_thinking;
    msg->data.agent_result.text = result_text ? result_text : util_strdup("");
    msg->data.agent_result.in_tokens = sub->last_input_tokens;
    msg->data.agent_result.out_tokens = sub->last_output_tokens;
    msg->data.agent_result.cache_read_tokens = sub->last_cache_read_tokens;
    msg->data.agent_result.cache_creation_tokens = sub->last_cache_creation_tokens;
    mq_push(args->input_queue, msg);

    agent_destroy(sub);

cleanup:
    FREE_PTR(args->prompt);
    FREE_PTR(args->description);
    FREE_PTR(args->sub_session_id);
    free(args);
    return NULL;
}

char *agent_handle_sub_agent(Agent *agent, const char *prompt,
                             const char *description, int fork) {
    if (!prompt || !prompt[0]) return util_strdup("Error: no prompt provided");

    char *raw_id = util_new_session_id();
    char *sub_session_id;
    asprintf(&sub_session_id, "sub_%s", raw_id);
    free(raw_id);

    /* 记录 sub_agent_start 事件 */
    {
        StrBuf evt;
        sb_init(&evt);
        sb_appendf(&evt, "{\"type\":\"sub_agent_start\",\"session_id\":");
        sb_append_json_string(&evt, sub_session_id);
        sb_appendf(&evt, ",\"prompt\":");
        sb_append_json_string(&evt, prompt);
        sb_appendf(&evt, ",\"description\":");
        sb_append_json_string(&evt, description ? description : "");
        sb_appendf(&evt, ",\"fork\":%s}", fork ? "true" : "false");
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    /* 显示启动通知 */
    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
    *dm = display_msg_sub_agent_start(sub_session_id, description);
    push_display_event(&agent->paths, agent->display_queue, dm);

    /* 增加活跃子 agent 计数 */
    agent->active_sub_count++;

    /* fork 模式：在主线程中立即复制父会话（确保在 tool_result 写入之前） */
    if (fork) {
        SessionPaths sub_paths = store_session_paths_for(agent->home,
                                                    agent->cwd,
                                                    sub_session_id);
        store_session_init_sub(&agent->paths, &sub_paths, 1);
        store_session_paths_free(&sub_paths);
    }

    /* 启动子线程 */
    SubAgentArgs *args = calloc(1, sizeof(SubAgentArgs));
    args->parent = agent;
    args->prompt = util_strdup(prompt);
    args->description = util_strdup(description);
    args->fork_mode = 0;  /* fork 已在主线程完成 */
    args->sub_session_id = util_strdup(sub_session_id);
    args->input_queue = agent->input_queue;

    pthread_t thread;
    pthread_create(&thread, NULL, sub_agent_thread_fn, args);
    pthread_detach(thread);

    StrBuf result;
    sb_init(&result);
    sb_appendf(&result, "Sub-agent started: session_id=%s", sub_session_id);
    free(sub_session_id);
    return result.data;
}

int agent_handle_sub_agent_result(Agent *agent, const char *session_id,
                                   const char *status, const char *thinking,
                                   const char *text,
                                   int in_tokens, int out_tokens,
                                   int cache_read, int cache_creation) {
    agent->active_sub_count--;

    /* 显示结果 */
    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
    *dm = display_msg_sub_agent_result(session_id, status, text);
    push_display_event(&agent->paths, agent->display_queue, dm);

    /* 记录 usage 事件（kind=sub_agent, sub_session_id） */
    {
        StrBuf evt;
        sb_init(&evt);
        sb_appendf(&evt, "{\"type\":\"usage\",\"input_tokens\":%d,\"output_tokens\":%d", in_tokens, out_tokens);
        sb_appendf(&evt, ",\"cache_read_input_tokens\":%d,\"cache_creation_input_tokens\":%d", cache_read, cache_creation);
        sb_appendf(&evt, ",\"kind\":\"sub_agent\",\"sub_session_id\":");
        sb_append_json_string(&evt, session_id);
        sb_append(&evt, "}");
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    /* 更新统计 — TODO: 复用 bash 的 store_stats_update 模式 */
    /* bash: store_stats_update total_input_tokens=+$_in total_output_tokens=+$_out ... */

    /* 记录 sub_agent_result 事件 */
    {
        StrBuf evt;
        sb_init(&evt);
        sb_appendf(&evt, "{\"type\":\"sub_agent_result\",\"session_id\":");
        sb_append_json_string(&evt, session_id);
        sb_appendf(&evt, ",\"status\":");
        sb_append_json_string(&evt, status);
        sb_appendf(&evt, ",\"input_tokens\":%d,\"output_tokens\":%d", in_tokens, out_tokens);
        sb_appendf(&evt, ",\"thinking\":");
        sb_append_json_string(&evt, thinking ? thinking : "");
        sb_appendf(&evt, ",\"text\":");
        sb_append_json_string(&evt, text ? text : "");
        sb_append(&evt, "}");
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    /* 记录 sub_agent_end 事件 */
    {
        StrBuf evt;
        sb_init(&evt);
        sb_appendf(&evt, "{\"type\":\"sub_agent_end\",\"session_id\":");
        sb_append_json_string(&evt, session_id);
        sb_appendf(&evt, ",\"status\":");
        sb_append_json_string(&evt, status);
        sb_append(&evt, "}");
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    return 0;
}

/* ============================================================
 * system prompt 构建
 * ============================================================ */

char *agent_build_prompt(Agent *agent) {
    StrBuf buf;
    sb_init(&buf);

    /* 简化版 system prompt — 与 bash/go/rust 对齐需要完整移植 agent_build_prompt */
    sb_append(&buf, "You are bash-agent, a lightweight coding agent that works in a terminal.\n");
    sb_appendf(&buf, "pwd: %s\n", agent->cwd);
    sb_appendf(&buf, "home: %s\n", agent->home);
    sb_append(&buf, "platform: Darwin\n");
    sb_appendf(&buf, "shell: %s\n", util_env("SHELL", "/bin/zsh"));
    sb_append(&buf, "\n- Be concise and concrete. No pleasantries, no explanations unless asked.\n");
    sb_append(&buf, "- Prefer safe, exact edits.\n");
    sb_append(&buf, "- Report failures clearly.\n");

    /* ---- Instruction files ---- */
    /* 搜索路径与 bash 版本一致：
       全局: $HOME/.bash-agent/{AGENTS.md,AGENT.md,CLAUDE.md,.claude/CLAUDE.md}
       项目: $CWD/{AGENTS.md,AGENT.md,CLAUDE.md,.claude/CLAUDE.md} */
    {
        const char *global_candidates[] = {
            "/AGENTS.md", "/AGENT.md", "/CLAUDE.md", "/.claude/CLAUDE.md", NULL
        };
        /* 全局指令 */
        for (int c = 0; global_candidates[c]; c++) {
            StrBuf path;
            sb_init(&path);
            sb_appendf(&path, "%s/.bash-agent%s", agent->home, global_candidates[c]);
            char *content = util_read_file(path.data);
            sb_free(&path);
            if (content && content[0]) {
                sb_appendf(&buf, "\n<instruction-file name=\"global\">\n%s\n</instruction-file>\n", content);
                free(content);
                break;
            }
            free(content);
        }
        /* 项目指令 */
        for (int c = 0; global_candidates[c]; c++) {
            StrBuf path;
            sb_init(&path);
            sb_appendf(&path, "%s%s", agent->cwd, global_candidates[c]);
            char *content = util_read_file(path.data);
            sb_free(&path);
            if (content && content[0]) {
                sb_appendf(&buf, "\n<instruction-file name=\"project\">\n%s\n</instruction-file>\n", content);
                free(content);
                break;
            }
            free(content);
        }
    }

    /* ---- Skills ---- */
    /* Skill index */
    {
        /* 扫描 .claude/skills/ 和 skills/ 目录 */
        StrBuf skill_index;
        sb_init(&skill_index);

        const char *skill_dirs[] = {
            ".claude/skills",
            "skills",
            NULL
        };
        for (int d = 0; skill_dirs[d]; d++) {
            StrBuf list_cmd;
            sb_init(&list_cmd);
            sb_appendf(&list_cmd, "ls -1 '%s' 2>/dev/null", skill_dirs[d]);
            FILE *pipe = popen(list_cmd.data, "r");
            if (pipe) {
                char linebuf[256];
                while (fgets(linebuf, sizeof(linebuf), pipe)) {
                    /* trim newline */
                    size_t len = strlen(linebuf);
                    if (len > 0 && linebuf[len-1] == '\n') linebuf[--len] = '\0';
                    /* 读取 SKILL.md 的第一段作为摘要 */
                    StrBuf skill_path;
                    sb_init(&skill_path);
                    sb_appendf(&skill_path, "%s/%s/SKILL.md", skill_dirs[d], linebuf);
                    char *md = util_read_file(skill_path.data);
                    sb_free(&skill_path);
                    if (md && md[0]) {
                        /* 提取第一行标题和后续内容作为摘要 */
                        char *nl = strchr(md, '\n');
                        /* 跳过标题行，取第一段非空文本 */
                        char *desc = nl ? nl + 1 : md;
                        while (*desc == '\n' || *desc == '\r') desc++;
                        char *end = strstr(desc, "\n\n");
                        if (end) *end = '\0';
                        sb_appendf(&skill_index, "- %s: %s\n", linebuf, desc);
                    }
                    free(md);
                }
                pclose(pipe);
            }
            sb_free(&list_cmd);
        }

        if (skill_index.len > 0) {
            sb_append(&buf, "\n<skill-index>\n");
            sb_append(&buf, skill_index.data);
            sb_append(&buf, "</skill-index>\n");
        }
        sb_free(&skill_index);
    }

    /* 注入选定的 skills */
    for (int i = 0; i < agent->skill_count; i++) {
        const char *skill_name = agent->skill_names[i];
        /* 搜索路径: .claude/skills/NAME/SKILL.md, skills/NAME/SKILL.md, ~/.claude/skills/NAME/SKILL.md */
        const char *search_paths[] = {
            ".claude/skills",
            "skills",
            NULL
        };
        char *skill_content = NULL;
        for (int d = 0; search_paths[d]; d++) {
            StrBuf sp;
            sb_init(&sp);
            sb_appendf(&sp, "%s/%s/SKILL.md", search_paths[d], skill_name);
            skill_content = util_read_file(sp.data);
            sb_free(&sp);
            if (skill_content) break;
        }
        if (!skill_content) {
            /* 尝试 home 目录 */
            StrBuf sp;
            sb_init(&sp);
            sb_appendf(&sp, "%s/.claude/skills/%s/SKILL.md", agent->home, skill_name);
            skill_content = util_read_file(sp.data);
            sb_free(&sp);
        }
        if (skill_content && skill_content[0]) {
            /* 替换 ${BASH_AGENT_SKILL_DIR} 占位符 */
            StrBuf skill_dir;
            sb_init(&skill_dir);
            /* 找到 skill 所在目录 */
            for (int d = 0; search_paths[d]; d++) {
                StrBuf sp;
                sb_init(&sp);
                sb_appendf(&sp, "%s/%s/SKILL.md", search_paths[d], skill_name);
                FILE *f = fopen(sp.data, "r");
                sb_free(&sp);
                if (f) { fclose(f); sb_appendf(&skill_dir, "%s/%s", search_paths[d], skill_name); break; }
            }
            if (skill_dir.len == 0) {
                sb_appendf(&skill_dir, "%s/.claude/skills/%s", agent->home, skill_name);
            }

            /* 简单替换 ${BASH_AGENT_SKILL_DIR}/helper.sh 为实际路径 */
            char *placeholder = strstr(skill_content, "${BASH_AGENT_SKILL_DIR}");
            if (placeholder) {
                StrBuf replaced;
                sb_init(&replaced);
                size_t prefix_len = placeholder - skill_content;
                sb_appendn(&replaced, skill_content, prefix_len);
                sb_append(&replaced, skill_dir.data);
                sb_append(&replaced, placeholder + strlen("${BASH_AGENT_SKILL_DIR}"));
                free(skill_content);
                skill_content = replaced.data;
            }

            sb_appendf(&buf, "\n<skill name=\"%s\" path=\"%s\">\n%s\n</skill>\n",
                       skill_name, skill_dir.data, skill_content);
            sb_free(&skill_dir);
        }
        free(skill_content);
    }

    /* 读取 summary */
    char *summary = store_summary_get(&agent->paths);
    if (summary) {
        sb_appendf(&buf, "\n<context-snapshot>\n%s\n</context-snapshot>\n", summary);
        free(summary);
    }

    /* 读取 plan */
    char *plan = util_read_file(agent->paths.plan);
    if (plan && plan[0]) {
        sb_appendf(&buf, "\n<current-plan>\n%s\n</current-plan>\n", plan);
    }
    free(plan);

    /* Plan lifecycle guidance */
    sb_append(&buf, "\n<plan-lifecycle-guidance>\n"
        "- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n"
        "- **Execution phase**: after PlanConfirm → TodoWrite checklist → execute tasks → PlanClear when all done\n"
        "- **Plan vs Todo**: PLAN_FILE=locked plan (only via PlanConfirm), TodoWrite=progress tracker. Do NOT mix.\n"
        "</plan-lifecycle-guidance>\n");

    /* Todo guidance（硬编码） */
    sb_append(&buf, "\n<todo-guidance>\n"
        "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n"
        "- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n"
        "- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n"
        "- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n"
        "- Keep the checklist short, concrete, and actionable.\n"
        "- Prefer exactly one in_progress item when work is actively underway.\n"
        "- Mark items completed immediately after finishing them, and remove stale items that no longer matter.\n"
        "</todo-guidance>\n");

    return buf.data;
}

/* ============================================================
 * 上下文压缩
 * ============================================================ */

int agent_compact_context(Agent *agent, const char *trigger) {
    /* 判断是否需要压缩 */
    int need_compact = 0;

    if (strcmp(trigger, "store_plan_clear") == 0 || strcmp(trigger, "plan_confirm") == 0) {
        need_compact = 1;
    } else {
        /* auto 模式：检查 context tokens */
        /* 从 stats.json 中读取 current_context_tokens */
        int ctx_tokens = agent->last_context_tokens;
        if (ctx_tokens <= 0) {
            char *stats_content = store_stats_read(agent->paths.stats);
            if (stats_content) {
                JsonParse jp = json_parse_root(stats_content);
                if (!jp.error) {
                    ctx_tokens = json_get_int(jp.val, "current_context_tokens");
                }
                free(stats_content);
            }
        }
        if (ctx_tokens > 0 &&
            ctx_tokens >= agent->max_context_tokens * 90 / 100) {
            need_compact = 1;
        }
        /* 也检查 conversation 行数 */
        if (!need_compact) {
            char **lines = NULL;
            int line_count = 0;
            if (store_conv_line_count(agent->paths.conversation, &lines, &line_count) == 0) {
                if (line_count > 100) need_compact = 1;
                for (int i = 0; i < line_count; i++) free(lines[i]);
                free(lines);
            }
        }
    }

    if (!need_compact) return 0;

    /* 读取 conversation */
    char **lines = NULL;
    int line_count = 0;
    if (store_conv_line_count(agent->paths.conversation, &lines, &line_count) != 0) return -1;
    if (line_count <= 4) {
        for (int i = 0; i < line_count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    /* 计算保留行数（保留最后 20% 或至少 4 行） */
    int keep = line_count * 20 / 100;
    if (keep < 4) keep = 4;
    if (keep >= line_count) {
        for (int i = 0; i < line_count; i++) free(lines[i]);
        free(lines);
        return 0;
    }
    int drop = line_count - keep;

    /* 构造丢弃的消息内容用于 summary */
    StrBuf dropped;
    sb_init(&dropped);
    for (int i = 0; i < drop; i++) {
        sb_append(&dropped, lines[i]);
        sb_append_char(&dropped, '\n');
    }

    /* 调用 LLM 做 summary */
    const char *summary_instruction =
        "The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. "
        "Do NOT think. Just output the summary directly as plain text. "
        "Summarize the key information from the messages above into a concise context summary. "
        "Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:\nReflections:";

    /* 构造 summary 请求体 */
    /* messages 数组包含丢弃的消息 + summary 指令 */
    StrBuf req_body;
    sb_init(&req_body);
    sb_append(&req_body, "{\"model\":");
    sb_append_json_string(&req_body, agent->model);
    sb_append(&req_body, ",\"max_tokens\":1024,\"messages\":[");
    for (int i = 0; i < drop; i++) {
        if (i > 0) sb_append(&req_body, ",");
        sb_append(&req_body, lines[i]);
    }
    sb_append(&req_body, ",{\"role\":\"user\",\"content\":");
    sb_append_json_string(&req_body, summary_instruction);
    sb_append(&req_body, "}]}");

    char *summary_body = req_body.data;

    /* 发送 summary 请求 */
    const char *headers[8];
    char auth_header[512];
    int hdr_count = 0;
    headers[hdr_count++] = "Content-Type: application/json";
    headers[hdr_count++] = "User-Agent: claude-cli/1.0.33 (max, cli)";
    if (strcmp(agent->provider, "claude") == 0) {
        snprintf(auth_header, sizeof(auth_header), "x-api-key: %s", agent->api_key);
        headers[hdr_count++] = auth_header;
        headers[hdr_count++] = "anthropic-version: 2023-06-01";
    } else {
        snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", agent->api_key);
        headers[hdr_count++] = auth_header;
    }

    SseAccumulator accum;
    sse_accum_init(&accum);
    int rc = http_post_sse(agent->api_url, headers, hdr_count,
                           summary_body, strlen(summary_body),
                           agent->provider,
                           sse_accum_callback, &accum,
                           &agent->interrupted);

    if (rc == 0 && accum.text.len > 0) {
        /* 保存 summary */
        store_summary_set(&agent->paths, accum.text.data);
    }
    sse_accum_free(&accum);
    free(summary_body);
    sb_free(&dropped);

    /* 截断 conversation */
    store_conv_trim_tail(agent->paths.conversation, keep);

    for (int i = 0; i < line_count; i++) free(lines[i]);
    free(lines);

    return 0;
}

/* ============================================================
 * 终端标题更新
 * ============================================================ */

void agent_update_title(Agent *agent) {
    if (!agent->interactive) return;
    char *stats_content = store_stats_read(agent->paths.stats);
    if (!stats_content) return;
    JsonParse jp = json_parse_root(stats_content);
    if (jp.error) { free(stats_content); return; }

    int tc = json_get_int(jp.val, "current_turn_count");
    int ar = json_get_int(jp.val, "agent_request_count");
    int ai = json_get_int(jp.val, "total_input_tokens");
    int ao = json_get_int(jp.val, "total_output_tokens");

    fprintf(stderr, "\x1b]0;%s T:%d R:%d I:%d O:%d\x07",
            agent->model, tc, ar, ai, ao);
    fflush(stderr);

    free(stats_content);
}
