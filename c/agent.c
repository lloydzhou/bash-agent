#include "agent.h"
#include "display.h"
#include "tools_embed.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>
#include <signal.h>
#include <sys/utsname.h>
#include <dirent.h>
#include <sys/stat.h>
#include <time.h>
#include <curl/curl.h>

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

/* 图像粘贴回调的路劲 — 从 cagent.c 设置，由 linenoise readline 线程调用 */

/* ============================================================
 * 前向声明
 * ============================================================ */

typedef struct {
    char *cmd;
    char *task_id;
    char *output_file;
    int timeout_secs;
    MsgQueue *sub_result_queue;
} AsyncBashArgs;

static const char *store_session_get_dir_str(Agent *agent);
static void *async_bash_thread_fn(void *arg);

/* ============================================================
 * 图片占位符支持
 * ============================================================ */

static char *agent_tool_display_summary(const char *name, JsonVal input, const char *input_json) {
    char *field = NULL;
    if (strcmp(name, "Read") == 0 || strcmp(name, "Write") == 0 || strcmp(name, "Edit") == 0) {
        field = json_get_string(input, "path");
    } else if (strcmp(name, "Glob") == 0 || strcmp(name, "Grep") == 0) {
        field = json_get_string(input, "pattern");
    } else if (strcmp(name, "Bash") == 0) {
        field = json_get_string(input, "command");
    } else if (strcmp(name, "Skill") == 0) {
        field = json_get_string(input, "name");
    } else if (strcmp(name, "SubAgent") == 0) {
        field = json_get_string(input, "description");
    } else if (strcmp(name, "WebSearch") == 0) {
        field = json_get_string(input, "query");
    } else if (strcmp(name, "WebFetch") == 0 || strcmp(name, "WebReader") == 0) {
        field = json_get_string(input, "url");
    } else if (strcmp(name, "TodoWrite") == 0) {
        JsonVal todos_arr = json_get(input, "todos");
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
    if (field && strcmp(name, "Bash") == 0) {
        /* 替换换行为空格，截断过长命令，对齐 bash 版行为 */
        char *p;
        while ((p = strchr(field, '\n')) != NULL) *p = ' ';
        size_t flen = strlen(field);
        if (flen > 80) {
            int slen = (int)util_utf8_truncate_len(field, 77);
            char *trunc = malloc(slen + 4);
            memcpy(trunc, field, slen);
            strcpy(trunc + slen, "...");
            free(field);
            field = trunc;
        }
    }
    if (field) return field;

    if (input_json && input_json[0]) {
        size_t len = strlen(input_json);
        if (len > 80) {
            char *summary = malloc(84);
            memcpy(summary, input_json, 80);
            strcpy(summary + 80, "...");
            return summary;
        }
        return util_strdup(input_json);
    }
    return util_strdup("");
}

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
        /* STOP 的 display 推送统一由 agent_loop 处理，避免重复 */
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
        sb_init(&tc->input_json);
        tc->id = util_strdup(evt->tool_id);
        tc->name = util_strdup(evt->tool_name);
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
    MsgQueue *sub_result_queue;
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
    a->sub_result_queue = malloc(sizeof(MsgQueue));
    mq_init(a->sub_result_queue);
    a->max_tokens = 16384;
    a->max_turns = 1000;
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

    /* DP Compact 配置（启动时初始化一次） */
    a->dp_cfg = dp_config_init(a->max_context_tokens);

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

    int is_new = 1;
    struct stat st;
    if (stat(a->paths.events, &st) == 0 && st.st_size > 0) is_new = 0;

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
    if (agent->sub_result_queue) {
        mq_destroy(agent->sub_result_queue);
        free(agent->sub_result_queue);
    }
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

static void display_tool_result_set_tool(DisplayMessage *msg, const ToolCallAccum *tc) {
    if (!msg || !tc) return;
    free(msg->tool_id);
    free(msg->tool_name);
    msg->tool_id = util_strdup(tc->id ? tc->id : "");
    msg->tool_name = util_strdup(tc->name ? tc->name : "");
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
        sb_append(&buf, ",\"status\":");
        sb_append_json_string(&buf, (msg->tool_exit_code == 0) ? "ok" : "failed");
        sb_appendf(&buf, ",\"input_tokens\":%d,\"output_tokens\":%d",
                   msg->in_tokens, msg->out_tokens);
        sb_append(&buf, ",\"thinking\":");
        sb_append_json_string(&buf, msg->tool_name ? msg->tool_name : "");
        sb_append(&buf, ",\"text\":");
        sb_append_json_string(&buf, msg->content ? msg->content : "");
        sb_append_char(&buf, '}');
        break;
    case DISPLAY_ASYNC_TASK_RESULT:
        sb_append(&buf, "{\"type\":\"async_task_result\",\"task_id\":");
        sb_append_json_string(&buf, msg->session_id ? msg->session_id : "");
        sb_appendf(&buf, ",\"exit_code\":%d", msg->tool_exit_code);
        sb_append(&buf, ",\"output\":");
        sb_append_json_string(&buf, msg->content ? msg->content : "");
        sb_append_char(&buf, '}');
        break;
    case DISPLAY_IMAGE_DESCRIBE:
        sb_append(&buf, "{\"type\":\"image_describe\",\"images\":\"");
        sb_append(&buf, msg->tool_name ? msg->tool_name : "");
        sb_append(&buf, "\",\"content\":");
        sb_append_json_string(&buf, msg->content ? msg->content : "");
        sb_append_char(&buf, '}');
        break;
    default:
        sb_free(&buf);
        return NULL;
    }

    return buf.data;
}

/* 推送 display 队列 + 写入 events.jsonl。msg 所有权转移给 display 线程。 */
static void push_display_event(const SessionPaths *paths, MsgQueue *dq, DisplayMessage *msg) {
    if (!msg) return;
    /* 写入 events.jsonl */
    char *evt = display_msg_to_event(msg);
    if (evt) {
        store_event_append(paths, evt);
        free(evt);
    }
    /* 推送 display 队列（stream-json 模式由 display 线程输出事件，否则交互式渲染） */
    if (dq && !store_event_stream_json_enabled()) {
        mq_push(dq, msg);
    } else {
        display_message_free(msg);
        free(msg);
    }
}

/* 仅推送 display 队列（不写事件）。msg 所有权转移给 display 线程。 */
static void display_only_push(MsgQueue *dq, DisplayMessage *msg) {
    if (!msg) return;
    if (dq && !store_event_stream_json_enabled()) {
        mq_push(dq, msg);
    } else {
        display_message_free(msg);
        free(msg);
    }
}

/* ============================================================
 * agent_replay_events — 从 events.jsonl 重放最近 N 轮事件
 *
 * 对应 bash 版：store_event_recent_turn_lines 10 | event_replay.awk | display_stream
 * 核心逻辑：累积 per-token 的 text/thinking 事件为完整块，然后推送 DisplayMessage。
 * ============================================================ */

/* 最近 N 轮事件的起始文件偏移。只记录 user_input 偏移，避免启动 replay 全量读 events.jsonl。 */
static long find_recent_turn_start_offset(const SessionPaths *paths, int max_turns) {
    FILE *f = fopen(paths->events, "r");
    if (!f) return -1;

    if (max_turns <= 0) max_turns = 10;
    long *offsets = calloc((size_t)max_turns, sizeof(long));
    if (!offsets) {
        fclose(f);
        return -1;
    }

    char *line = NULL;
    size_t cap = 0;
    int seen = 0;
    for (;;) {
        long pos = ftell(f);
        ssize_t n = getline(&line, &cap, f);
        if (n < 0) break;
        if (strstr(line, "\"type\":\"user_input\"")) {
            offsets[seen % max_turns] = pos;
            seen++;
        }
    }

    long start = 0;
    if (seen > 0) {
        start = (seen >= max_turns) ? offsets[seen % max_turns] : offsets[0];
    }

    free(line);
    free(offsets);
    fclose(f);
    return start;
}

int agent_replay_events(Agent *agent, int max_turns) {
    long start = find_recent_turn_start_offset(&agent->paths, max_turns);
    int replayed = 0;
    if (start < 0) return 0;

    FILE *f = fopen(agent->paths.events, "r");
    if (!f) return 0;
    if (fseek(f, start, SEEK_SET) != 0) {
        fclose(f);
        return 0;
    }

    char *line = NULL;
    size_t line_cap = 0;
    while (getline(&line, &line_cap, f) >= 0) {
        size_t line_len = strlen(line);
        while (line_len > 0 && (line[line_len - 1] == '\n' || line[line_len - 1] == '\r')) {
            line[--line_len] = '\0';
        }
        if (line_len == 0) continue;

        JsonParse jp = json_parse_root(line);
        if (jp.error) continue;

        char *type = json_get_string(jp.val, "type");
        if (!type) continue;

        if (strcmp(type, "user_input") == 0) {
            char *content = json_get_string(jp.val, "content");
            if (content && content[0]) {
                util_truncate_str(content, 80);
                char *nl = strchr(content, '\n');
                if (nl) *nl = '\0';

                StrBuf user_display;
                sb_init(&user_display);
                sb_appendf(&user_display, "\n\x1b[32m> %s\x1b[0m\n", content);
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(user_display.data);
                push_display(agent->display_queue, dm);
                replayed = 1;
                sb_free(&user_display);
            }
            free(content);
        } else if (strcmp(type, "text") == 0) {
            char *content = json_get_string(jp.val, "content");
            if (content && *content) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_text(content);
                push_display(agent->display_queue, dm);
                replayed = 1;
            }
            free(content);
        } else if (strcmp(type, "thinking") == 0) {
            char *content = json_get_string(jp.val, "content");
            if (content && *content) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_thinking(content);
                push_display(agent->display_queue, dm);
                replayed = 1;
            }
            free(content);
        } else if (strcmp(type, "tool_call") == 0) {
            char *name = json_get_string(jp.val, "name");
            char *id = json_get_string(jp.val, "id");
            JsonVal input_val = json_get(jp.val, "input");
            char *input_str = NULL;
            char *summary = NULL;
            if (input_val.type != JSON_NULL) {
                input_str = json_as_string(input_val);
                summary = agent_tool_display_summary(name ? name : "", input_val, input_str);
            }
            if (!input_str) input_str = util_strdup("{}");
            if (!summary) summary = util_strdup("");

            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_tool_call(id ? id : "", name ? name : "", summary);
            free(dm->tool_input);
            dm->tool_input = util_strdup(input_str);
            push_display(agent->display_queue, dm);
            replayed = 1;
            free(input_str);
            free(summary);
            free(name);
            free(id);
        } else if (strcmp(type, "tool_result") == 0) {
            char *content = json_get_string(jp.val, "content");
            if (content) util_truncate_str(content, 200);
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_tool_result(content ? content : "", 0);
            dm->tool_id = json_get_string(jp.val, "tool_use_id");
            dm->tool_name = json_get_string(jp.val, "name");
            push_display(agent->display_queue, dm);
            replayed = 1;
            free(content);
        } else if (strcmp(type, "sub_agent_result") == 0) {
            char *sid = json_get_string(jp.val, "session_id");
            char *status = json_get_string(jp.val, "status");
            char *thinking = json_get_string(jp.val, "thinking");
            char *text = json_get_string(jp.val, "text");
            int in_tok = json_get_int(jp.val, "input_tokens");
            int out_tok = json_get_int(jp.val, "output_tokens");
            if (thinking) thinking[util_utf8_truncate_len(thinking, 120)] = '\0';
            if (text) util_truncate_str(text, 200);
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_sub_agent_result(sid ? sid : "", status ? status : "ok",
                                               thinking, text ? text : "", in_tok, out_tok);
            push_display(agent->display_queue, dm);
            replayed = 1;
            free(sid);
            free(status);
            free(thinking);
            free(text);
        } else if (strcmp(type, "image_describe") == 0) {
            char *images = json_get_string(jp.val, "images");
            char *desc = json_get_string(jp.val, "content");
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_image_describe(images ? images : "", desc ? desc : "");
            push_display(agent->display_queue, dm);
            replayed = 1;
            free(images);
            free(desc);
        } else if (strcmp(type, "error") == 0) {
            char *message = json_get_string(jp.val, "message");
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_error(message ? message : "unknown");
            push_display(agent->display_queue, dm);
            replayed = 1;
            free(message);
        }

        free(type);
    }

    free(line);
    fclose(f);
    return replayed;
}

/* ============================================================
 * agent_run_loop — agent_loop wrapper: 结束后恢复 idle 标题
 * 对齐 bash 版 agent_run_loop
 * ============================================================ */

/* drain SubAgent 结果：display + conversation 注入，返回消费条数（对齐 bash agent_drain_notify_buf） */
static int agent_drain_sub_results(Agent *agent) {
    int drained = 0;
    while (1) {
        void *sub_data = NULL;
        if (mq_try_pop(agent->sub_result_queue, &sub_data) != 0) break;
        InputMessage *sub_msg = (InputMessage *)sub_data;
        if (sub_msg && sub_msg->type == MSG_AGENT_RESULT) {
            agent_handle_sub_agent_result(agent,
                sub_msg->data.agent_result.session_id,
                sub_msg->data.agent_result.status,
                sub_msg->data.agent_result.thinking,
                sub_msg->data.agent_result.text,
                sub_msg->data.agent_result.in_tokens,
                sub_msg->data.agent_result.out_tokens,
                sub_msg->data.agent_result.cache_read_tokens,
                sub_msg->data.agent_result.cache_creation_tokens,
                sub_msg->data.agent_result.request_count);
            StrBuf ctx;
            sb_init(&ctx);
            sb_appendf(&ctx, "[sub-agent %s] %s (in=%d, out=%d)\nThinking: %s\nText: %s",
                       sub_msg->data.agent_result.session_id,
                       sub_msg->data.agent_result.status,
                       sub_msg->data.agent_result.in_tokens,
                       sub_msg->data.agent_result.out_tokens,
                       sub_msg->data.agent_result.thinking ? sub_msg->data.agent_result.thinking : "",
                       sub_msg->data.agent_result.text ? sub_msg->data.agent_result.text : "");
            store_conv_add_user(agent->paths.conversation, ctx.data);
            sb_free(&ctx);
            drained++;
        } else if (sub_msg && sub_msg->type == MSG_ASYNC_TASK_RESULT) {
            /* 记录事件 */
            store_event_append(&agent->paths, "");
            StrBuf evt;
            sb_init(&evt);
            sb_appendf(&evt, "{\"type\":\"async_task_result\",\"task_id\":\"%s\",\"exit_code\":%d,\"output\":",
                       sub_msg->data.async_task_result.task_id, sub_msg->data.async_task_result.exit_code);
            sb_append_json_string(&evt, sub_msg->data.async_task_result.output ? sub_msg->data.async_task_result.output : "");
            sb_append(&evt, "}");
            store_event_append(&agent->paths, evt.data);
            sb_free(&evt);
            /* 递减计数器 */
            if (agent->active_sub_count > 0) agent->active_sub_count--;
            /* display */
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_async_task_result(
                sub_msg->data.async_task_result.task_id,
                sub_msg->data.async_task_result.exit_code,
                sub_msg->data.async_task_result.output ? sub_msg->data.async_task_result.output : "");
            push_display_event(&agent->paths, agent->display_queue, dm);
            /* conversation 注入 */
            StrBuf ctx;
            sb_init(&ctx);
            sb_appendf(&ctx, "[async-task %s] exit_code=%d\nOutput: %s",
                       sub_msg->data.async_task_result.task_id,
                       sub_msg->data.async_task_result.exit_code,
                       sub_msg->data.async_task_result.output ? sub_msg->data.async_task_result.output : "");
            store_conv_add_user(agent->paths.conversation, ctx.data);
            sb_free(&ctx);
            drained++;
        }
        input_message_free(sub_msg);
        free(sub_msg);
    }
    return drained;
}

int agent_run_loop(Agent *agent, const char *user_input, const char *turn_kind) {
    int rc = agent_loop(agent, user_input, turn_kind);
    agent_update_title_status(agent, "idle");
    return rc;
}

/* ============================================================
 * agent_loop — 单次 LLM 对话循环
 * ============================================================ */

int agent_loop(Agent *agent, const char *user_input, const char *turn_kind) {
    if (!user_input || !user_input[0]) return 0;

    /* 记录 user_input 事件 — 仅当 turn_kind 为 "user_input" 时记录
     * （与 bash 版对齐：sub_agent_result turn 不记录 user_input 事件） */
    if (turn_kind == NULL || strcmp(turn_kind, "user_input") == 0) {
        StrBuf evt;
        sb_init(&evt);
        sb_append(&evt, "{\"type\":\"user_input\",\"content\":");
        sb_append_json_string(&evt, user_input);
        sb_append_char(&evt, '}');
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    /* 展开图片占位符：events 记录原始文本，conversation/LLM 使用展开后的长文本 */
    char *expanded_input = NULL;
    if ((turn_kind == NULL || strcmp(turn_kind, "user_input") == 0) && strstr(user_input, "[Image #") != NULL) {
        /* 收集所有 [Image #N] 占位符和对应路径 */
        StrBuf images, expanded;
        sb_init(&images);
        sb_init(&expanded);
        sb_append(&expanded, user_input);

        const char *pattern = "[Image #";
        const char *rest = user_input;
        int first_img = 1;
        char **paths = NULL;
        int path_count = 0;
        int path_cap = 16;
        paths = calloc((size_t)path_cap, sizeof(char*));

        while ((rest = strstr(rest, pattern)) != NULL) {
            const char *end = strchr(rest, ']');
            if (!end) break;
            if (!first_img) sb_append_char(&images, ' ');
            first_img = 0;
            sb_appendn(&images, rest, (size_t)(end - rest + 1));

            /* 提取数字并检查文件 */
            int n = 0;
            const char *num = rest + strlen(pattern);
            while (*num >= '0' && *num <= '9') {
                n = n * 10 + (*num - '0');
                num++;
            }
            char imgpath[1024];
            snprintf(imgpath, sizeof(imgpath), "%s/%d.png", store_session_image_dir(&agent->paths), n);
            FILE *f = fopen(imgpath, "r");
            if (f) {
                fclose(f);
                if (path_count >= path_cap) {
                    path_cap *= 2;
                    paths = realloc(paths, (size_t)path_cap * sizeof(char*));
                }
                paths[path_count++] = util_strdup(imgpath);
            }
            rest = end + 1;
        }

        /* 调用 describe 获取描述 */
        char *desc = agent_image_describe(paths, path_count);

        /* 记录 image_describe 事件 */
        if (images.len > 0) {
            StrBuf evt;
            sb_init(&evt);
            sb_append(&evt, "{\"type\":\"image_describe\",\"images\":\"");
            sb_append(&evt, images.data);
            sb_append(&evt, "\",\"content\":");
            sb_append_json_string(&evt, desc ? desc : "");
            sb_append_char(&evt, '}');
            store_event_append(&agent->paths, evt.data);
            sb_free(&evt);

            /* 推送 IMAGE_DESCRIBE 到 display queue */
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_image_describe(images.data, desc);
            push_display(agent->display_queue, dm);
        }

        /* 拼接 expanded_input */
        sb_append(&expanded, "\n\n<attached-images>\n");
        sb_append(&expanded, desc ? desc : "");
        sb_append(&expanded, "\n</attached-images>");

        /* 清理 */
        for (int i = 0; i < path_count; i++) free(paths[i]);
        free(paths);
        free(desc);
        sb_free(&images);
        expanded_input = expanded.data;
        user_input = expanded_input;
    }

    /* 重置中断标志 */
    agent->interrupted = 0;

    /* 添加 user 消息到 conversation */
    store_conv_add_user(agent->paths.conversation, user_input);

    /* 递增 turn 计数 — 对齐 bash 版 store_stats_update current_turn_count=+1 */
    store_stats_set_int_file(agent->paths.stats, "current_turn_count",
        store_stats_get_file_int(agent->paths.stats, "current_turn_count") + 1);
    /* 对齐 bash 版: store_stats_update 末尾调 display_term_title */
    agent_update_title(agent);

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

        /* drain SubAgent 结果（对齐 bash agent_drain_notify_buf） */
        agent_drain_sub_results(agent);

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

        /* tools.json 编译时嵌入 */
        const char *tools_json = embedded_tools_json;

        /* 构建请求体 */
        char *claude_body = build_claude_request(agent->model, system_prompt,
                                                 tools_json, lines, line_count,
                                                 agent->max_tokens,
                                                 agent->thinking, agent->effort);
        char *body = claude_body;
        if (strcmp(agent->provider, "openai") == 0) {
            body = convert_to_openai(claude_body);
            free(claude_body);
        }
        if (agent->verbose && body) {
            int body_len = (int)strlen(body);
            int preview_len = body_len > 200 ? 200 : body_len;
            fprintf(stderr, "[verbose] Request body (%dKB): %.*s%s\n",
                    body_len / 1024, preview_len, body, body_len > 200 ? "..." : "");
        }

        /* 构建 HTTP headers */
        const char *headers[8];
        char auth_header[512];
        int hdr_count = 0;
        headers[hdr_count++] = "Content-Type: application/json";
        headers[hdr_count++] = "User-Agent: claude-cli/1.0.33 (max, cli)";

        if (strcmp(agent->provider, "claude") == 0) {
            headers[hdr_count++] = "x-app: cli";
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
        /* tools_json 是嵌入常量，不需要 free */
        for (int i = 0; i < line_count; i++) free(lines[i]);
        free(lines);

        if (sse_rc != 0) {
            /* Ctrl+C 中断：输出 STOP interrupted 而不是 ERROR */
            if (agent->interrupted) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_stop("interrupted");
                push_display_event(&agent->paths, agent->display_queue, dm);
                sse_accum_free(accum);
                return 0;
            }
            /* 对齐 bash 版 END 块：总是发出 STOP + ERROR */
            DisplayMessage *dm_err = malloc(sizeof(DisplayMessage));
            *dm_err = display_msg_error(accum->error ? accum->error : "HTTP request failed");
            push_display_event(&agent->paths, agent->display_queue, dm_err);
            DisplayMessage *dm_stop = malloc(sizeof(DisplayMessage));
            *dm_stop = display_msg_stop("error");
            push_display_event(&agent->paths, agent->display_queue, dm_stop);
            sse_accum_free(accum);
            return -1;
        }

        if (accum->error) {
            DisplayMessage *dm_err = malloc(sizeof(DisplayMessage));
            *dm_err = display_msg_error(accum->error);
            push_display_event(&agent->paths, agent->display_queue, dm_err);
            DisplayMessage *dm_stop = malloc(sizeof(DisplayMessage));
            *dm_stop = display_msg_stop("error");
            push_display_event(&agent->paths, agent->display_queue, dm_stop);
            sse_accum_free(accum);
            return -1;
        }

        /* text/thinking 已在 stream_display_callback 中实时推送，此处不再批量推送 */

        /* ---- 显示工具调用 ---- */
        for (int i = 0; i < accum->tool_count; i++) {
            ToolCallAccum *tc = &accum->tools[i];
            char *summary = NULL;
            if (tc->input_json.len > 0) {
                JsonParse jp2 = json_parse_root(tc->input_json.data);
                if (!jp2.error) {
                    summary = agent_tool_display_summary(tc->name, jp2.val, tc->input_json.data);
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

        /* 更新 stats.json — 对齐 bash 版 agent_record_usage:
         * store_stats_update agent_request_count=+1 total_input_tokens=+N ... */
        if (accum->in_tokens > 0 || accum->out_tokens > 0) {
            store_stats_set_int_file(agent->paths.stats, "agent_request_count",
                store_stats_get_file_int(agent->paths.stats, "agent_request_count") + 1);
            store_stats_set_int_file(agent->paths.stats, "total_input_tokens",
                store_stats_get_file_int(agent->paths.stats, "total_input_tokens") + accum->in_tokens);
            store_stats_set_int_file(agent->paths.stats, "total_output_tokens",
                store_stats_get_file_int(agent->paths.stats, "total_output_tokens") + accum->out_tokens);
            store_stats_set_int_file(agent->paths.stats, "total_cache_read_tokens",
                store_stats_get_file_int(agent->paths.stats, "total_cache_read_tokens") + accum->cache_read_tokens);
            store_stats_set_int_file(agent->paths.stats, "total_cache_creation_tokens",
                store_stats_get_file_int(agent->paths.stats, "total_cache_creation_tokens") + accum->cache_creation_tokens);
            /* 对齐 bash 版: store_stats_update current_context_tokens=${_ctx_tokens} */
            if (agent->last_context_tokens > 0) {
                store_stats_set_int_file(agent->paths.stats, "current_context_tokens",
                    agent->last_context_tokens);
            }
            /* 对齐 bash 版 store_stats_update 末尾的 display_term_title */
            agent_update_title(agent);
        }

        /* ---- 执行工具调用 ---- */
        const char **result_ids = NULL;
        const char **result_contents = NULL;
        if (accum->tool_count > 0 && accum->stop_reason &&
            (strcmp(accum->stop_reason, "tool_use") == 0 ||
             strcmp(accum->stop_reason, "tool_calls") == 0)) {

            result_ids = malloc(accum->tool_count * sizeof(char*));
            result_contents = malloc(accum->tool_count * sizeof(char*));

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
                } else if (strcmp(tc->name, "Bash") == 0) {
                    /* Bash async=true 特殊处理：后台执行，立即返回 task_id */
                    JsonParse jp = json_parse_root(tc->input_json.data);
                    int is_async = 0;
                    char *cmd = NULL;
                    if (!jp.error) {
                        is_async = json_get_bool(jp.val, "async", false) ? 1 : 0;
                        cmd = json_get_string(jp.val, "command");
                    }
                    if (is_async && cmd && cmd[0]) {
                        /* 生成 task_id */
                        char task_id[64];
                        snprintf(task_id, sizeof(task_id), "async_%ld_%d", (long)time(NULL), getpid() & 0xFFFF);
                        /* 输出文件 */
                        char output_file[1024];
                        snprintf(output_file, sizeof(output_file), "%s/%s/%s.log",
                                 store_session_get_dir_str(agent), agent->session_id, task_id);
                        /* 递增计数器 */
                        agent->active_sub_count++;
                        /* 后台线程 */
                        AsyncBashArgs *args = calloc(1, sizeof(AsyncBashArgs));
                        args->cmd = util_strdup(cmd);
                        args->task_id = util_strdup(task_id);
                        args->output_file = util_strdup(output_file);
                        args->timeout_secs = agent->tool_timeout_secs;
                        args->sub_result_queue = agent->sub_result_queue;
                        pthread_t thread;
                        pthread_create(&thread, NULL, async_bash_thread_fn, args);
                        pthread_detach(thread);
                        /* 立即返回 */
                        StrBuf result;
                        sb_init(&result);
                        sb_appendf(&result, "Async task started: task_id=%s", task_id);
                        tr.output = result.data;
                        tr.exit_code = 0;
                    } else {
                        free(cmd);
                        tr = tool_dispatch(tc->name, tc->input_json.data,
                                          agent->cwd, agent->home,
                                          agent->tool_timeout_secs,
                                          agent->tool_result_max_bytes,
                                          &agent->paths);
                    }
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
                    /* 从 input_json 获取 path / offset / limit */
                    char *fpath = NULL, *foffset = NULL, *flimit = NULL;
                    JsonParse jp2 = json_parse_root(tc->input_json.data);
                    if (!jp2.error) {
                        fpath = json_get_string(jp2.val, "path");
                        foffset = json_as_string(json_get(jp2.val, "offset"));
                        flimit = json_as_string(json_get(jp2.val, "limit"));
                    }

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
                            /* nl = 换行符个数；最后一行无换行符结尾则补1 */
                            if (fbytes > 0) {
                                fseek(fp, -1, SEEK_END);
                                int last = fgetc(fp);
                                flines = nl + (last != '\n' ? 1 : 0);
                            } else {
                                flines = 0;
                            }
                            fclose(fp);
                        }
                        sb_appendf(&summary, "%s(%s) [%ld lines, %ld bytes",
                                   tc->name, fpath, flines, fbytes);
                        if ((foffset && *foffset) || (flimit && *flimit)) {
                            sb_appendf(&summary, ", offset=%s, limit=%s",
                                       foffset ? foffset : "1",
                                       flimit ? flimit : "0");
                        }
                        sb_append(&summary, "]");
                    } else {
                        sb_appendf(&summary, "%s()", tc->name);
                    }
                    free(fpath);
                    free(foffset);
                    free(flimit);

                    /* display 只显示 summary 行 */
                    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                    *dm = display_msg_tool_result(summary.data, tr.exit_code);
                    display_tool_result_set_tool(dm, tc);
                    push_display_event(&agent->paths, agent->display_queue, dm);

                    free(summary.data);
                } else {
                    /* 显示工具结果 */
                    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                    *dm = display_msg_tool_result(tr.output ? tr.output : "(empty)", tr.exit_code);
                    display_tool_result_set_tool(dm, tc);
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

            }
            /* PlanClear / PlanConfirm 触发 compact（在 tool_result 写入之后）
             * 对齐 bash 版: PlanConfirm→先 compact 再 mv draft→plan; PlanClear→compact+clear */
            for (int i = 0; i < accum->tool_count; i++) {
                if (strcmp(accum->tools[i].name, "PlanConfirm") == 0) {
                    agent_compact_context(agent, "plan_confirm");
                    /* compact 后执行 mv draft→plan（对齐 bash 版 tool_plan_confirm 顺序） */
                    {
                        char *draft = store_plan_draft_read(&agent->paths);
                        if (draft && draft[0]) {
                            store_plan_set(&agent->paths, draft);
                            store_plan_draft_clear(&agent->paths);
                        }
                        free(draft);
                    }
                    break;
                } else if (strcmp(accum->tools[i].name, "PlanClear") == 0) {
                    agent_compact_context(agent, "plan_clear");
                    break;
                }
            }

        }

        /* ---- 保存 assistant / tool_results 到 conversation ---- */
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

        if (result_ids && result_contents) {
            store_conv_add_tool_results(agent->paths.conversation, accum->tool_count,
                                  result_ids, result_contents);
            for (int i = 0; i < accum->tool_count; i++) free((void *)result_contents[i]);
            free(result_ids);
            free(result_contents);
        }

        /* ---- 致命 stop reason: error/max_tokens/length → 立即退出 ---- */
        /* 对齐 bash 版: return 1，max_tokens/length 时额外发 ERROR */
        if (accum->stop_reason) {
            if (strcmp(accum->stop_reason, "error") == 0) {
                sse_accum_free(accum);
                return -1;
            }
            if (strcmp(accum->stop_reason, "max_tokens") == 0 ||
                strcmp(accum->stop_reason, "length") == 0) {
                DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                *dm = display_msg_error("Response truncated (max_tokens reached)");
                push_display_event(&agent->paths, agent->display_queue, dm);
                sse_accum_free(accum);
                return -1;
            }
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

        if (!should_continue) {
            /* end_turn 后尝试 drain（对齐 bash agent_drain_notify_buf && continue） */
            if (agent_drain_sub_results(agent) > 0 && !agent->interrupted) continue;
            break;
        }
        if (agent->interrupted) break;
    }

    /* 对齐 bash 版: turn >= MAX_TURNS 时发 ERROR */
    if (turn >= agent->max_turns) {
        DisplayMessage *dm = malloc(sizeof(DisplayMessage));
        char errbuf[128];
        snprintf(errbuf, sizeof(errbuf), "Max turns (%d) reached", agent->max_turns);
        *dm = display_msg_error(errbuf);
        push_display_event(&agent->paths, agent->display_queue, dm);
    }

    /* agent_loop 结束：恢复 idle 标题 + 清除 progress indicator */

    free(expanded_input);
    return 0;
}

/* ============================================================
 * agent_main_loop — 从 input_queue 取消息驱动循环
 * ============================================================ */

/* ============================================================
 * 图像处理 — placeholder 展开 + GLM 描述 + Ctrl+V 粘贴
 * ============================================================ */

/* HTTP POST 辅助类型 — 用于图像描述请求 */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} ImageWebBuf;

static size_t image_web_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    ImageWebBuf *buf = (ImageWebBuf *)userdata;
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

/* base64 编码文件内容，返回 malloc'd 字符串 */
static char *file_to_base64(const char *path) {
    /* 使用 OpenSSL BIO 或 popen base64 */
    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "base64 < '%s' 2>/dev/null", path);
    FILE *fp = popen(cmd, "r");
    if (!fp) return NULL;

    StrBuf out;
    sb_init(&out);
    char buf[4096];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf) - 1, fp)) > 0) {
        buf[n] = '\0';
        sb_append(&out, buf);
    }
    int rc = pclose(fp);
    if (rc != 0 || out.len == 0) {
        sb_free(&out);
        return NULL;
    }
    /* 去掉尾部换行 */
    while (out.len > 0 && (out.data[out.len - 1] == '\n' || out.data[out.len - 1] == '\r'))
        out.len--;
    out.data[out.len] = '\0';
    return out.data;
}

char *agent_image_describe(char **paths, int count) {
    if (!paths || count <= 0) return NULL;

    const char *api_key = getenv("DESCRIBE_API_KEY");
    if (!api_key || !api_key[0]) return NULL;

    const char *model = getenv("DESCRIBE_MODEL");
    if (!model || !model[0]) model = "glm-4v-flash";

    const char *base_url = getenv("DESCRIBE_BASE_URL");
    if (!base_url || !base_url[0]) base_url = "https://open.bigmodel.cn/api/paas/v4";

    /* 构建 URL */
    char url[1024];
    snprintf(url, sizeof(url), "%s/chat/completions", base_url);

    /* 构建请求体 */
    StrBuf body;
    sb_init(&body);

    sb_appendf(&body, "{\"model\":");
    sb_append_json_string(&body, model);
    sb_append(&body, ",\"messages\":[{\"role\":\"user\",\"content\":[");
    sb_append(&body, "{\"type\":\"text\",\"text\":");
    sb_append_json_string(&body,
        "Output all visible text from each image, separated by a blank line between images. "
        "Transcribe every character including special symbols (arrows, prompts, dots, slashes). "
        "Preserve exact spacing and line breaks. "
        "Pay attention to date formats (month names, numbers). "
        "Do not summarize or describe - just output the raw text exactly as shown. "
        "If an image has no text, briefly describe what you see.");
    sb_append(&body, "}");

    for (int i = 0; i < count; i++) {
        char *b64 = file_to_base64(paths[i]);
        if (!b64) continue;
        sb_append(&body, ",{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,");
        sb_append(&body, b64);
        sb_append(&body, "\"}}");
        free(b64);
    }

    sb_append(&body, "]}]}");

    /* 构建 headers */
    char auth_header[512];
    snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", api_key);
    const char *headers[] = {
        "Content-Type: application/json",
        auth_header
    };
    int hdr_count = 2;

    /* 发送 POST 请求 */
    CURL *curl = curl_easy_init();
    if (!curl) {
        sb_free(&body);
        return NULL;
    }

    ImageWebBuf wb = {NULL, 0, 0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.data);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)body.len);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, image_web_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &wb);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 120L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);

    struct curl_slist *slist = NULL;
    for (int i = 0; i < hdr_count; i++) {
        slist = curl_slist_append(slist, headers[i]);
    }
    if (slist) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, slist);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(slist);
    curl_easy_cleanup(curl);
    sb_free(&body);

    if (res != CURLE_OK) {
        free(wb.data);
        return NULL;
    }

    if (!wb.data || wb.len == 0) {
        free(wb.data);
        return NULL;
    }

    /* 解析 JSON 响应: choices[0].message.content */
    JsonParse jp = json_parse_root(wb.data);
    if (jp.error) {
        free(wb.data);
        return NULL;
    }

    JsonVal choices = json_get(jp.val, "choices");
    if (choices.type != JSON_ARRAY || json_array_len(choices) <= 0) {
        free(wb.data);
        return NULL;
    }

    JsonVal first = json_array_get(choices, 0);
    JsonVal msg = json_get(first, "message");
    char *content = json_get_string(msg, "content");

    free(wb.data);
    return content; /* caller must free */
}

void agent_image_expand_placeholders(Agent *agent, char **input) {
    if (!input || !*input || !(*input)[0]) return;

    /* 扫描 [Image #N] 模式 */
    const char *pattern = "[Image #";
    int max_images = 256;
    char **image_paths = calloc((size_t)max_images, sizeof(char*));
    int img_count = 0;

    const char *p = *input;
    while ((p = strstr(p, pattern)) != NULL && img_count < max_images) {
        p += strlen(pattern);
        /* 提取数字 */
        int n = 0;
        while (*p >= '0' && *p <= '9') {
            n = n * 10 + (*p - '0');
            p++;
        }
        /* 必须后跟 ] */
        if (*p != ']') continue;
        p++; /* 跳过 ] */

        /* 检查文件是否存在 */
        const char *imgdir = store_session_image_dir(&agent->paths);
        char imgpath[1024];
        snprintf(imgpath, sizeof(imgpath), "%s/%d.png", imgdir, n);
        FILE *f = fopen(imgpath, "r");
        if (f) {
            fclose(f);
            image_paths[img_count] = util_strdup(imgpath);
            img_count++;
        }
    }

    if (img_count == 0) {
        free(image_paths);
        /* 无图片也追加空标签，与其他版本一致 */
        StrBuf result;
        sb_init(&result);
        sb_append(&result, *input);
        sb_append(&result, "\n\n<attached-images>\n\n</attached-images>");
        free(*input);
        *input = result.data;
        return;
    }

    /* 调用 GLM API 描述图像 */
    char *desc = agent_image_describe(image_paths, img_count);

    /* 清理路径 */
    for (int i = 0; i < img_count; i++) free(image_paths[i]);
    free(image_paths);

    if (!desc) {
        /* describe 返回空（无 API key 或调用失败），仍追加空标签 */
        StrBuf result;
        sb_init(&result);
        sb_append(&result, *input);
        sb_append(&result, "\n\n<attached-images>\n\n</attached-images>");
        free(*input);
        *input = result.data;
        return;
    }

    /* 构建结果: input + \n\n<attached-images>\n...\n</attached-images> */
    StrBuf result;
    sb_init(&result);
    sb_append(&result, *input);
    sb_append(&result, "\n\n<attached-images>\n");
    sb_append(&result, desc);
    sb_append(&result, "\n</attached-images>");
    free(desc);

    /* 替换 input 指针指向新分配的字符串 */
    free(*input);
    *input = result.data;
}

void agent_image_clipboard_paste(const char *session_dir, char **out, size_t *outlen) {
    *out = NULL;
    *outlen = 0;

    if (!session_dir || !session_dir[0]) return;

    /* 构建 images 目录路径 */
    char imgdir[1024];
    snprintf(imgdir, sizeof(imgdir), "%s/images", session_dir);

    /* 计算下一个图片编号 */
    int next_n = 1;
    for (;;) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/%d.png", imgdir, next_n);
        FILE *f = fopen(path, "r");
        if (f) {
            fclose(f);
            next_n++;
        } else {
            break;
        }
    }

    /* 尝试从剪贴板获取图片 (macOS) */
    char save_path[1024];
    snprintf(save_path, sizeof(save_path), "%s/%d.png", imgdir, next_n);

    /* 创建保存目录 */
    util_mkdirs(imgdir, 0755);

    int saved = 0;

    /* macOS: osascript 获取 PNG */
    {
        char tmp_path[1024];
        snprintf(tmp_path, sizeof(tmp_path), "%s/clipimg_%d.png", imgdir, next_n);
        char cmd[2048];
        snprintf(cmd, sizeof(cmd),
            "osascript -e 'set theImage to the clipboard as «class PNGf»' "
            "-e \"set theFile to open for access POSIX file \\\"%s\\\" with write permission\" "
            "-e 'write theImage to theFile' "
            "-e 'close access theFile' >/dev/null 2>&1"
            " && mv '%s' '%s' 2>/dev/null",
            tmp_path, tmp_path, save_path);
        int rc = system(cmd);
        if (rc == 0) {
            struct stat st;
            if (stat(save_path, &st) == 0 && st.st_size > 0) {
                saved = 1;
            }
        }
    }

    if (!saved) {
        /* Linux: 尝试 wl-paste 或 xclip */
        const char *paste_cmds[] = {
            "wl-paste --type image/png > '%s' 2>/dev/null",
            "xclip -selection clipboard -t image/png -o > '%s' 2>/dev/null",
            NULL
        };
        for (int ci = 0; paste_cmds[ci]; ci++) {
            char paste_cmd[2048];
            snprintf(paste_cmd, sizeof(paste_cmd), paste_cmds[ci], save_path);
            int paste_rc = system(paste_cmd);
            if (paste_rc == 0) {
                struct stat st;
                if (stat(save_path, &st) == 0 && st.st_size > 0) {
                    saved = 1;
                    break;
                }
            }
        }
    }

    if (!saved) return;

    /* 格式化输出: [Image #N] */
    char result[64];
    int rlen = snprintf(result, sizeof(result), "[Image #%d]", next_n);
    *out = malloc((size_t)rlen + 1);
    if (*out) {
        memcpy(*out, result, (size_t)rlen + 1);
        *outlen = (size_t)rlen;
    }
}

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
                   * 残留到 agent_loop 开始时导致立即中断。 */
                  agent->interrupted = 0;
                  /* 标记 agent 正在运行，readline 线程的 Ctrl+C 可中断 */
                  agent->running = 1;

                  agent_run_loop(agent, msg->data.user_input.text, "user_input");

                  agent->running = 0;

                /* 如果有活跃的 sub-agent，继续处理它们的结果，
                 * 直到所有 sub-agent 完成才 signal done。
                 * 这避免 readline 线程在 sub-agent 结果到达前显示提示符，
                 * 导致输出与提示符交错混乱。
                 * 模仿 bash 版 agent_run_loop 的单线程行为：
                 * bash 版是同步的，agent_loop 处理 sub-agent 结果后
                 * 才显示下一轮提示符。 */
                while (agent->active_sub_count > 0) {
                    void *sub_data = NULL;
                    if (mq_pop(agent->sub_result_queue, &sub_data) != 0) break;
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
                            sub_msg->data.agent_result.cache_creation_tokens,
                            sub_msg->data.agent_result.request_count);

                        StrBuf ctx;
                        sb_init(&ctx);
                        sb_appendf(&ctx, "[sub-agent %s] %s (in=%d, out=%d)\nThinking: %s\nText: %s",
                                   sub_msg->data.agent_result.session_id,
                                   sub_msg->data.agent_result.status,
                                   sub_msg->data.agent_result.in_tokens,
                                   sub_msg->data.agent_result.out_tokens,
                                   sub_msg->data.agent_result.thinking ? sub_msg->data.agent_result.thinking : "",
                                   sub_msg->data.agent_result.text ? sub_msg->data.agent_result.text : "");
                        agent_run_loop(agent, ctx.data, "sub_agent_result");
                        sb_free(&ctx);
                    } else if (sub_msg->type == MSG_ASYNC_TASK_RESULT) {
                        /* 记录事件 + display + conversation 注入 */
                        StrBuf evt;
                        sb_init(&evt);
                        sb_appendf(&evt, "{\"type\":\"async_task_result\",\"task_id\":\"%s\",\"exit_code\":%d,\"output\":",
                                   sub_msg->data.async_task_result.task_id, sub_msg->data.async_task_result.exit_code);
                        sb_append_json_string(&evt, sub_msg->data.async_task_result.output ? sub_msg->data.async_task_result.output : "");
                        sb_append(&evt, "}");
                        store_event_append(&agent->paths, evt.data);
                        sb_free(&evt);
                        if (agent->active_sub_count > 0) agent->active_sub_count--;
                        DisplayMessage *dm = malloc(sizeof(DisplayMessage));
                        *dm = display_msg_async_task_result(
                            sub_msg->data.async_task_result.task_id,
                            sub_msg->data.async_task_result.exit_code,
                            sub_msg->data.async_task_result.output ? sub_msg->data.async_task_result.output : "");
                        push_display_event(&agent->paths, agent->display_queue, dm);
                        StrBuf ctx;
                        sb_init(&ctx);
                        sb_appendf(&ctx, "[async-task %s] exit_code=%d\nOutput: %s",
                                   sub_msg->data.async_task_result.task_id,
                                   sub_msg->data.async_task_result.exit_code,
                                   sub_msg->data.async_task_result.output ? sub_msg->data.async_task_result.output : "");
                        agent_run_loop(agent, ctx.data, "async_task_result");
                        sb_free(&ctx);
                    }
                    input_message_free(sub_msg);
                    free(sub_msg);
                }

                /* 所有轮次完成：等待 display 队列写完 */
                if (agent->interactive) {
                    display_flush(agent->display_queue);
                }
                break;
            }
            default:
                break;
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

/* store_session_get_dir 辅助：返回 session 目录字符串 */
static const char *store_session_get_dir_str(Agent *agent) {
    static char buf[1024];
    /* 复用 Bash 版的逻辑：project_dir/session_id */
    const char *home = agent->home;
    const char *cwd = agent->cwd;
    char project_key[512];
    /* 简化：直接用 cwd 的转义路径作为 key（与 store.c 的逻辑一致） */
    snprintf(project_key, sizeof(project_key), "%s", cwd);
    /* 替换 / 为 _ */
    for (char *p = project_key; *p; p++) if (*p == '/') *p = '_';
    snprintf(buf, sizeof(buf), "%s/.bash-agent/projects/%s/%s", home, project_key, agent->session_id);
    return buf;
}

/* Async Bash 后台线程：执行命令，输出写入文件，完成后 push 到 sub_result_queue */
static void *async_bash_thread_fn(void *arg) {
    AsyncBashArgs *args = (AsyncBashArgs *)arg;

    /* 执行命令，输出写入文件 */
    char cmd_buf[8192];
    if (args->timeout_secs > 0) {
        snprintf(cmd_buf, sizeof(cmd_buf), "timeout %d bash -lc '%s' > '%s' 2>&1",
                 args->timeout_secs, args->cmd, args->output_file);
    } else {
        snprintf(cmd_buf, sizeof(cmd_buf), "bash -lc '%s' > '%s' 2>&1",
                 args->cmd, args->output_file);
    }
    /* 简化：直接用 system()，通过 $? 获取退出码 */
    int rc = system(cmd_buf);
    int exit_code = WEXITSTATUS(rc);

    /* 读取输出（截断到 8192 字节） */
    char *output = NULL;
    FILE *f = fopen(args->output_file, "r");
    if (f) {
        fseek(f, 0, SEEK_END);
        long fsize = ftell(f);
        if (fsize > 8192) {
            fseek(f, fsize - 8192, SEEK_SET);
        } else {
            fseek(f, 0, SEEK_SET);
        }
        output = malloc(8193);
        size_t n = fread(output, 1, 8192, f);
        output[n] = '\0';
        fclose(f);
        /* 删除临时文件 */
        remove(args->output_file);
    }

    /* 构造 MSG_ASYNC_TASK_RESULT 并 push 到 sub_result_queue */
    InputMessage *msg = calloc(1, sizeof(InputMessage));
    msg->type = MSG_ASYNC_TASK_RESULT;
    msg->data.async_task_result.task_id = util_strdup(args->task_id);
    msg->data.async_task_result.exit_code = exit_code;
    msg->data.async_task_result.output = output ? output : util_strdup("");

    mq_push(args->sub_result_queue, msg);

    /* 清理 */
    free(args->cmd);
    free(args->task_id);
    free(args->output_file);
    free(args);

    return NULL;
}

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
        mq_push(args->sub_result_queue, msg);
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
    int rc = agent_loop(sub, args->prompt, "user_input");

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
    msg->data.agent_result.request_count = store_stats_get_file_int(sub->paths.stats, "agent_request_count");
    mq_push(args->sub_result_queue, msg);

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
    if (asprintf(&sub_session_id, "sub_%s", raw_id) < 0) {
        free(raw_id);
        return util_strdup("Error: failed to allocate session id");
    }
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

    /* 显示启动通知（事件已手动写入，只推显示队列不重复写事件） */
    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
    *dm = display_msg_sub_agent_start(sub_session_id, description);
    if (!store_event_stream_json_enabled()) {
        mq_push(agent->display_queue, dm);
    } else {
        display_message_free(dm);
        free(dm);
    }

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
    args->sub_result_queue = agent->sub_result_queue;

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
                                   int cache_read, int cache_creation,
                                   int request_count) {
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

    /* 记录 sub_agent_result 事件 — 供 replay 和 stream-json 复现 */
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

    /* 记录 sub_agent_end 事件 — 带 timestamp */
    {
        time_t now = time(NULL);
        struct tm tm_buf;
        gmtime_r(&now, &tm_buf);
        char ts[32];
        strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", &tm_buf);

        StrBuf evt;
        sb_init(&evt);
        sb_appendf(&evt, "{\"type\":\"sub_agent_end\",\"session_id\":");
        sb_append_json_string(&evt, session_id);
        sb_appendf(&evt, ",\"timestamp\":\"%s\"", ts);
        sb_appendf(&evt, ",\"status\":");
        sb_append_json_string(&evt, status);
        sb_append(&evt, "}");
        store_event_append(&agent->paths, evt.data);
        sb_free(&evt);
    }

    /* 更新统计 */
    store_stats_set_int_file(agent->paths.stats, "total_input_tokens",
        store_stats_get_file_int(agent->paths.stats, "total_input_tokens") + in_tokens);
    store_stats_set_int_file(agent->paths.stats, "total_output_tokens",
        store_stats_get_file_int(agent->paths.stats, "total_output_tokens") + out_tokens);
    store_stats_set_int_file(agent->paths.stats, "total_cache_read_tokens",
        store_stats_get_file_int(agent->paths.stats, "total_cache_read_tokens") + cache_read);
    store_stats_set_int_file(agent->paths.stats, "total_cache_creation_tokens",
        store_stats_get_file_int(agent->paths.stats, "total_cache_creation_tokens") + cache_creation);
    store_stats_set_int_file(agent->paths.stats, "sub_agent_request_count",
        store_stats_get_file_int(agent->paths.stats, "sub_agent_request_count") + 1);
    store_stats_set_int_file(agent->paths.stats, "agent_request_count",
        store_stats_get_file_int(agent->paths.stats, "agent_request_count") + request_count);
    agent_update_title(agent);

    /* 递减活跃子 agent 计数 */
    agent->active_sub_count--;

    /* 显示结果（推 display 队列） */
    DisplayMessage *dm = malloc(sizeof(DisplayMessage));
    *dm = display_msg_sub_agent_result(session_id, status, thinking,
                                       text, in_tokens, out_tokens);
    if (!store_event_stream_json_enabled()) {
        mq_push(agent->display_queue, dm);
    } else {
        display_message_free(dm);
        free(dm);
    }

    return 0;
}

/* ============================================================
 * system prompt 构建 — 辅助函数
 * ============================================================ */

/* 追加 XML section：<tag>\ncontent\n</tag> 或 <tag name="name">\ncontent\n</tag> */
static void prompt_append_attr_escaped(StrBuf *buf, const char *src) {
    if (!src) return;
    for (; *src; src++) {
        unsigned char c = (unsigned char)*src;
        switch (c) {
            case '"':  sb_append(buf, "\\\""); break;
            case '\\': sb_append(buf, "\\\\"); break;
            case '\b': sb_append(buf, "\\b"); break;
            case '\f': sb_append(buf, "\\f"); break;
            case '\n': sb_append(buf, "\\n"); break;
            case '\r': sb_append(buf, "\\r"); break;
            case '\t': sb_append(buf, "\\t"); break;
            default:
                if (c < 0x20) sb_appendf(buf, "\\u%04x", c);
                else sb_append_char(buf, c);
                break;
        }
    }
}

static void prompt_append_section(StrBuf *buf, const char *tag,
                                   const char *content, const char *name) {
    if (!content || !content[0]) return;
    size_t content_len = strlen(content);
    while (content_len > 0 &&
           (content[content_len - 1] == '\n' || content[content_len - 1] == '\r')) {
        content_len--;
    }
    if (content_len == 0) return;
    if (name && name[0]) {
        sb_appendf(buf, "<%s name=\"", tag);
        prompt_append_attr_escaped(buf, name);
        sb_append(buf, "\">\n");
        sb_appendn(buf, content, content_len);
        sb_appendf(buf, "\n</%s>\n", tag);
    } else {
        sb_appendf(buf, "<%s>\n", tag);
        sb_appendn(buf, content, content_len);
        sb_appendf(buf, "\n</%s>\n", tag);
    }
}

/* 检测 locale：LC_ALL → LC_MESSAGES → LANG → "en_US"，去掉 .xxx 后缀 */
static const char *detect_locale(void) {
    const char *loc = util_env("LC_ALL", NULL);
    if (!loc || !loc[0]) loc = util_env("LC_MESSAGES", NULL);
    if (!loc || !loc[0]) loc = util_env("LANG", NULL);
    if (!loc || !loc[0]) loc = "en_US";
    /* 去掉 .xxx 后缀（静态缓冲区，需调用者立即使用） */
    static __thread char buf[128];
    strncpy(buf, loc, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    char *dot = strchr(buf, '.');
    if (dot) *dot = '\0';
    return buf;
}

/* 在 dir 下查找指令文件，返回路径（需 free） */
static char *find_instruction_file(const char *dir) {
    const char *candidates[] = {
        "AGENTS.md", "AGENT.md", "CLAUDE.md", ".claude/CLAUDE.md", NULL
    };
    for (int i = 0; candidates[i]; i++) {
        char *path = util_path_join(dir, candidates[i]);
        FILE *f = fopen(path, "r");
        if (f) {
            fclose(f);
            return path;
        }
        free(path);
    }
    return NULL;
}

/* 从 SKILL.md 内容中提取摘要：优先 description: 行，否则取第一个非空非标题非---行 */
static void extract_skill_summary(const char *md, StrBuf *out) {
    const char *p = md;
    char line[1024];
    int found = 0;
    char fallback[1024] = "";

    while (*p) {
        /* 读取一行 */
        int li = 0;
        while (*p && *p != '\n' && li < (int)sizeof(line) - 1) {
            line[li++] = *p++;
        }
        line[li] = '\0';
        if (*p == '\n') p++;

        /* trim */
        char *s = line;
        while (*s == ' ' || *s == '\t') s++;
        char *e = s + strlen(s);
        while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) e--;
        *e = '\0';
        if (*s == '\0') continue;

        /* description: 行 */
        if (strncmp(s, "description:", 12) == 0) {
            char *val = s + 12;
            while (*val == ' ' || *val == '\t') val++;
            /* 去掉引号 */
            size_t vl = strlen(val);
            if (vl >= 2 && ((val[0] == '"' && val[vl-1] == '"') ||
                            (val[0] == '\'' && val[vl-1] == '\''))) {
                val++;
                vl -= 2;
            }
            sb_appendn(out, val, vl);
            found = 1;
            return;
        }
        /* fallback：非标题、非---、非``` */
        if (!found && fallback[0] == '\0' && s[0] != '#' &&
            !(s[0] == '-' && s[1] == '-' && s[2] == '-' && s[3] == '\0') &&
            !(s[0] == '`' && s[1] == '`' && s[2] == '`')) {
            strncpy(fallback, s, sizeof(fallback) - 1);
            fallback[sizeof(fallback) - 1] = '\0';
        }
    }
    if (!found && fallback[0]) {
        sb_append(out, fallback);
    }
}

/* 扫描 skill 目录列表（去重），构建 skill-index */
static void build_skill_index(StrBuf *index, const char *cwd, const char *home) {
    /* 搜索路径 */
    char *dirs[4];
    int dcount = 0;
    {
        char *p = util_path_join(cwd, ".claude/skills");
        dirs[dcount++] = p;
        p = util_path_join(cwd, "skills");
        dirs[dcount++] = p;
        if (home && home[0]) {
            p = util_path_join(home, ".claude/skills");
            dirs[dcount++] = p;
        }
        dirs[dcount] = NULL;
    }

    /* 去重 seen 列表 */
    char *seen[256];
    int seen_count = 0;

    for (int d = 0; d < dcount; d++) {
        DIR *dir = opendir(dirs[d]);
        if (!dir) continue;
        struct dirent *ent;
        while ((ent = readdir(dir)) != NULL) {
            if (ent->d_name[0] == '.') continue;
            /* 检查是否已 seen */
            int dup = 0;
            for (int s = 0; s < seen_count; s++) {
                if (strcmp(seen[s], ent->d_name) == 0) { dup = 1; break; }
            }
            if (dup) continue;

            /* 检查 SKILL.md 是否存在 */
            char *md_path = util_path_join(dirs[d], ent->d_name);
            char *skill_md = util_path_join(md_path, "SKILL.md");
            free(md_path);
            char *md_content = util_read_file(skill_md);
            free(skill_md);
            if (!md_content || !md_content[0]) { free(md_content); continue; }

            /* 记录 seen */
            if (seen_count < 256) seen[seen_count++] = util_strdup(ent->d_name);

            /* 提取摘要 */
            StrBuf summary;
            sb_init(&summary);
            extract_skill_summary(md_content, &summary);
            free(md_content);

            sb_appendf(index, "- %s", ent->d_name);
            if (summary.len > 0) sb_appendf(index, ": %s", summary.data);
            sb_append_char(index, '\n');
            sb_free(&summary);
        }
        closedir(dir);
    }
    /* 清理 */
    for (int d = 0; d < dcount; d++) free(dirs[d]);
    for (int s = 0; s < seen_count; s++) free(seen[s]);
}

/* 加载 skill 内容，替换 ${BASH_AGENT_SKILL_DIR}，返回需 free 的字符串 */
static char *load_skill_content(const char *skill_name, const char *cwd, const char *home, char **out_skill_dir) {
    /* 搜索路径 */
    char *dirs[4];
    int dcount = 0;
    {
        char *p = util_path_join(cwd, ".claude/skills");
        dirs[dcount++] = p;
        p = util_path_join(cwd, "skills");
        dirs[dcount++] = p;
        if (home && home[0]) {
            p = util_path_join(home, ".claude/skills");
            dirs[dcount++] = p;
        }
        dirs[dcount] = NULL;
    }

    for (int d = 0; d < dcount; d++) {
        char *skill_dir_path = util_path_join(dirs[d], skill_name);
        char *md_path = util_path_join(skill_dir_path, "SKILL.md");
        char *content = util_read_file(md_path);
        free(md_path);
        if (content) {
            /* 替换 ${BASH_AGENT_SKILL_DIR} */
            const char *placeholder = strstr(content, "${BASH_AGENT_SKILL_DIR}");
            if (placeholder) {
                StrBuf replaced;
                sb_init(&replaced);
                size_t prefix_len = placeholder - content;
                sb_appendn(&replaced, content, prefix_len);
                sb_append(&replaced, skill_dir_path);
                sb_append(&replaced, placeholder + strlen("${BASH_AGENT_SKILL_DIR}"));
                free(content);
                content = replaced.data;
            }
            /* 格式: Base directory: <dir>\n\n<content> */
            StrBuf full;
            sb_init(&full);
            sb_appendf(&full, "Base directory: %s\n\n%s", skill_dir_path, content);
            free(content);
            if (out_skill_dir) *out_skill_dir = skill_dir_path;
            else free(skill_dir_path);
            for (int i = 0; i < dcount; i++) free(dirs[i]);
            return full.data;
        }
        free(skill_dir_path);
    }
    for (int i = 0; i < dcount; i++) free(dirs[i]);
    return NULL;
}

/* ============================================================
 * system prompt 构建 — 主函数
 * ============================================================ */

char *agent_build_prompt(Agent *agent) {
    StrBuf buf;
    sb_init(&buf);

    const char *locale = detect_locale();
    int is_zh = (locale[0] == 'z' && locale[1] == 'h');

    /* 1. agent-identity */
    {
        const char *identity = "You are bash-agent, a lightweight coding agent that works in a terminal.";
        if (is_zh) identity = "你是 bash-agent，一个在终端中运行的轻量级编码智能体。";
        prompt_append_section(&buf, "agent-identity", identity, NULL);
    }

    /* 2. environment */
    {
        StrBuf env;
        sb_init(&env);
        sb_appendf(&env, "lang: %s\n", locale);
        sb_appendf(&env, "pwd: %s\n", agent->cwd);
        sb_appendf(&env, "home: %s\n", agent->home);
        /* platform via uname */
        {
            struct utsname uts;
            if (uname(&uts) == 0) {
                sb_appendf(&env, "platform: %s\n", uts.sysname);
            } else {
                sb_append(&env, "platform: unknown\n");
            }
        }
        sb_appendf(&env, "shell: %s", util_env("SHELL", "/bin/zsh"));
        prompt_append_section(&buf, "environment", env.data, NULL);
        sb_free(&env);
    }

    /* 3. rules */
    {
        const char *rules = "- Be concise and concrete. No pleasantries, no explanations unless asked. Raw results only.\n"
                            "- Prefer safe, exact edits.\n"
                            "- Report failures clearly.";
        prompt_append_section(&buf, "rules", rules, NULL);
    }

    /* 4. using-your-tools */
    {
        const char *tool_guidance =
            "- Use Read for a single file. If you need multiple files, call Read multiple times.\n"
            "- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n"
            "- Use Glob and Grep for one pattern at a time.\n"
            "- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n"
            "- Use multiple tool calls in one response when they are independent.\n"
            "- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n"
            "- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n"
            "- For skills, first check the skill-index section, then use Skill(name) for the matching skill.\n"
            "- Bash supports async=true for long-running commands (builds, tests, servers). The command starts in background, returns immediately with task_id and pid. When finished, the result arrives asynchronously as: [async-task <id>] exit_code=<code>\\nOutput: <output>. Results are delivered via the same notify mechanism as SubAgent.\n"
            "- SubAgent launches a background agent session. Results are injected back into your conversation when complete. Use for parallelizable or independent sub-tasks. See sub-agent-guidance section for context inheritance rules.";
        prompt_append_section(&buf, "using-your-tools", tool_guidance, NULL);
    }

    /* 5. sub-agent-guidance */
    {
        const char *sag =
            "- **When to use**: delegating independent sub-tasks that do NOT need your current conversation context — e.g. investigating a separate file, running a focused search, testing a hypothesis in isolation.\n"
            "- **When NOT to use**: tasks that depend on your working context, conversation history, or intermediate state. The child agent starts with a blank slate.\n"
            "- **Fork mode**: pass `fork=true` to inherit parent session context (conversation history, plan, skills). Use when the child needs your working context.\n"
            "- **Prompt design**: write a complete, self-contained prompt. Include all file paths, function names, error messages, and constraints the child needs. Assume zero shared context.\n"
            "- **Result handling**: when the child completes, its result is injected as a user message: `[sub-agent <id>] <status> (in=<n>, out=<n>)\nThinking: ...\nText: ...`. You then get another LLM turn to interpret and act on it.\n"
            "- **Parallelism**: multiple SubAgent calls in one turn run concurrently. Use this to parallelize independent investigations. **IMPORTANT**: results return asynchronously as each sub-agent finishes — they do NOT return together. When you receive a result for one sub-agent, the others are still running. Simply wait for all results to arrive before acting. Do NOT re-launch a sub-agent just because another one finished first — match results by session_id.\n"
            "- **Failure**: if the child fails (status=failed), the result text may be partial or empty. Handle gracefully — do not retry automatically.";
        prompt_append_section(&buf, "sub-agent-guidance", sag, NULL);
    }

    /* 6. todo-guidance */
    {
        const char *todo =
            "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n"
            "- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n"
            "- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n"
            "- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n"
            "- Keep the checklist short, concrete, and actionable.\n"
            "- Prefer exactly one in_progress item when work is actively underway.\n"
            "- Mark items completed immediately after finishing them, and remove stale items that no longer matter.";
        prompt_append_section(&buf, "todo-guidance", todo, NULL);
    }

    /* 7. plan-lifecycle-guidance */
    {
        StrBuf plg;
        sb_init(&plg);
        sb_append(&plg, "- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n");
        sb_appendf(&plg, "- **Files**: PLAN_DRAFT_FILE: %s | PLAN_FILE: %s\n",
                   agent->paths.plan_draft ? agent->paths.plan_draft : "<not set>",
                   agent->paths.plan ? agent->paths.plan : "<not set>");
        sb_append(&plg, "- **Why draft first?** Writing to PLAN_FILE immediately invalidates the system prompt cache. Use PLAN_DRAFT_FILE for all drafting iterations to avoid this cost.\n");
        sb_append(&plg, "- **Drafting phase** (PLAN_DRAFT_FILE non-empty → you are drafting):\n"
                        "  Every user reply MUST be classified as exactly ONE of:\n"
                        "  ① REVISE (any feedback/question/change) → Edit PLAN_DRAFT_FILE → ask confirmation → stay in drafting\n"
                        "  ② CONFIRM (explicit ok/go/confirmed) → call PlanConfirm IMMEDIATELY (before any other action) → TodoWrite checklist → execute\n"
                        "  ③ CANCEL (explicit cancel/forget it) → Bash `: > PLAN_DRAFT_FILE` → exit to idle\n"
                        "  ⚠ On CONFIRM you MUST call PlanConfirm first — no edits, no tool calls before it.\n");
        sb_append(&plg, "- **Execution phase**: after PlanConfirm → TodoWrite checklist → execute tasks → PlanClear when all done\n"
                        "- **Plan vs Todo**: PLAN_FILE=locked plan (only via PlanConfirm), PLAN_DRAFT_FILE=draft (edit freely), TodoWrite=progress tracker. Do NOT mix.");
        prompt_append_section(&buf, "plan-lifecycle-guidance", plg.data, NULL);
        sb_free(&plg);
    }

    /* 8. instruction-files */
    {
        StrBuf ifiles;
        sb_init(&ifiles);
        /* 全局: $HOME/.bash-agent/ */
        {
            StrBuf global_dir;
            sb_init(&global_dir);
            sb_appendf(&global_dir, "%s/.bash-agent", agent->home);
            char *gf = find_instruction_file(global_dir.data);
            sb_free(&global_dir);
            if (gf) {
                char *gc = util_read_file(gf);
                free(gf);
                if (gc && gc[0]) {
                    prompt_append_section(&ifiles, "instruction-file", gc, "global");
                }
                free(gc);
            }
        }
        /* 项目: $CWD/ */
        {
            char *pf = find_instruction_file(agent->cwd);
            if (pf) {
                char *pc = util_read_file(pf);
                free(pf);
                if (pc && pc[0]) {
                    prompt_append_section(&ifiles, "instruction-file", pc, "project");
                }
                free(pc);
            }
        }
        /* bash 版去掉尾部 \n */
        if (ifiles.len > 0 && ifiles.data[ifiles.len - 1] == '\n') {
            sb_truncate(&ifiles, ifiles.len - 1);
        }
        prompt_append_section(&buf, "instruction-files", ifiles.data, NULL);
        sb_free(&ifiles);
    }

    /* 9. skill-index */
    {
        StrBuf si;
        sb_init(&si);
        build_skill_index(&si, agent->cwd, agent->home);
        /* bash 版去掉尾部 \n */
        if (si.len > 0 && si.data[si.len - 1] == '\n') {
            sb_truncate(&si, si.len - 1);
        }
        prompt_append_section(&buf, "skill-index", si.data, NULL);
        sb_free(&si);
    }

    /* 10. selected-skills */
    {
        StrBuf skills;
        sb_init(&skills);
        for (int i = 0; i < agent->skill_count; i++) {
            const char *skill_name = agent->skill_names[i];
            char *skill_dir = NULL;
            char *content = load_skill_content(skill_name, agent->cwd, agent->home, &skill_dir);
            if (content) {
                prompt_append_section(&skills, "skill", content, skill_name);
                free(skill_dir);
                free(content);
            }
        }
        /* bash 版去掉尾部 \n */
        if (skills.len > 0 && skills.data[skills.len - 1] == '\n') {
            sb_truncate(&skills, skills.len - 1);
        }
        prompt_append_section(&buf, "selected-skills", skills.data, NULL);
        sb_free(&skills);
    }

    /* 11. current-plan */
    {
        char *plan = util_read_file(agent->paths.plan);
        if (plan && plan[0]) {
            /* bash 版 name 属性 = plan 文件路径 */
            prompt_append_section(&buf, "current-plan", plan, agent->paths.plan);
        }
        free(plan);
    }

    /* 12. context-snapshot */
    {
        char *summary = store_summary_get(&agent->paths);
        if (summary && summary[0]) {
            prompt_append_section(&buf, "context-snapshot", summary, NULL);
        }
        free(summary);
    }

    /* 13. output-language */
    {
        StrBuf ol;
        sb_init(&ol);
        if (is_zh) {
            sb_append(&ol, "再次强调：必须使用中文进行所有输出，包括你的思考过程（Chain of Thought/推理/thinking）！严禁在思考或回答中出现任何英文内容！");
        } else {
            sb_appendf(&ol, "MUST use \"%s\" for all output, including your Chain of Thought/reasoning/thinking! Never mix languages! Code, commands, and file content remain as-is.", locale);
        }
        prompt_append_section(&buf, "output-language", ol.data, NULL);
        sb_free(&ol);
    }

    /* 去掉末尾 \n（bash 版 printf '%s' "${output%$'\\n'}"） */
    if (buf.len > 0 && buf.data[buf.len - 1] == '\n') {
        buf.data[buf.len - 1] = '\0';
        buf.len--;
    }

    return buf.data;
}

/* ── 辅助：从环境变量读取 double，fallback 默认值 ── */
static double dp_env_d(const char *name, double def) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    char *end;
    double d = strtod(v, &end);
    return (*end == '\0') ? d : def;
}

static int dp_env_i(const char *name, int def) {
    const char *v = getenv(name);
    if (!v || !*v) return def;
    return atoi(v);
}

/* ── DP Compact 配置初始化 ── */
DPConfig dp_config_init(int max_context_tokens) {
    DPConfig c = {0};
    c.baseline_e       = dp_env_i("DP_BASELINE_E", 8);
    c.e_fixed          = dp_env_i("DP_E_FIXED", 0);
    c.L_fixed          = dp_env_d("DP_L", 0.0);
    c.V                = dp_env_d("DP_V", 5000.0);
    c.p_input          = dp_env_d("DP_P_INPUT", 3.0);
    c.p_cache          = dp_env_d("DP_P_CACHE", 0.30);
    c.p_out            = dp_env_d("DP_P_OUT", 15.0);
    c.S                = dp_env_d("DP_S", 500.0);
    c.min_keep_ratio   = dp_env_d("DP_MIN_KEEP_RATIO", 0.25);
    c.r                = dp_env_d("DP_R", 0.8);
    c.beta             = dp_env_d("DP_BETA", 0.03);
    c.quality_penalty  = dp_env_d("DP_QUALITY_PENALTY", 0.2);
    c.max_context      = (max_context_tokens > 0) ? max_context_tokens : 200000;
    return c;
}

static int compact_is_real_user_line(const char *line) {
    JsonParse jp = json_parse_root(line);
    if (!jp.error) {
        char *role = json_get_string(jp.val, "role");
        char *content = NULL;
        int ok = 0;
        if (role && strcmp(role, "user") == 0) {
            content = json_get_string(jp.val, "content");
            ok = (content != NULL);
        }
        free(content);
        free(role);
        return ok;
    }
    return (strstr(line, "\"role\":\"user\"") != NULL &&
            strstr(line, "\"content\":[") == NULL) ? 1 : 0;
}

/*
 * DP 最优 compact 决策 — 移植自 compact_dp.awk
 *
 * 计算 5 项 benefit：
 *   ① savings   — 后续 LLM 调用的缓存节省
 *   ② cache_miss — 首次压缩请求的缓存失效成本
 *   ③ compact_cost — 压缩请求本身的费用
 *   ④ info_loss — 信息丢失的惩罚
 *   ⑤ quality_savings — 压缩后的质量改善收益
 *
 * 返回：保留行数（对齐到 user 消息边界），0 表示不压缩
 */
static int compact_dp_decision(char **lines, int n, const DPConfig *cfg,
                               int turn_count, int total_requests,
                               int total_compact, int total_input) {
    if (n == 0) return 0;

    /* 每行 token 大小: (字节数+3)/4 + 1 */
    int *sizes = (int *)malloc((size_t)n * sizeof(int));
    int *is_user = (int *)calloc((size_t)n, sizeof(int));
    if (!sizes || !is_user) { free(sizes); free(is_user); return 0; }

    int total_tokens = 0;
    for (int i = 0; i < n; i++) {
        sizes[i] = (int)((strlen(lines[i]) + 3) / 4) + 1;
        total_tokens += sizes[i];
        /* 标记 user 消息（非 tool_result） */
        is_user[i] = compact_is_real_user_line(lines[i]);
    }

    /* ── 参数（来自 cfg，对齐 bash 版）── */
    int baseline_e    = cfg->baseline_e;
    int e_fixed       = cfg->e_fixed;
    double L_fixed    = cfg->L_fixed;
    double V          = cfg->V;
    double p_input    = cfg->p_input;
    double p_cache    = cfg->p_cache;
    double p_out      = cfg->p_out;
    double S          = cfg->S;
    double min_keep_ratio = cfg->min_keep_ratio;
    double r          = cfg->r;
    double beta       = cfg->beta;
    double quality_penalty = cfg->quality_penalty;
    int max_ctx       = cfg->max_context;

    /* ── E: expected remaining user-input rounds ── */
    double E;
    if (e_fixed > 0) {
        E = (double)e_fixed;
    } else if (baseline_e > 0) {
        int remaining = baseline_e - turn_count;
        int floor_val = (baseline_e > 1) ? baseline_e / 2 : 2;
        E = (remaining > floor_val) ? (double)remaining : (double)floor_val;
    } else {
        E = 2.0;
    }

    /* ── L: avg LLM calls per user input ── */
    double L;
    if (L_fixed > 0.0) {
        L = L_fixed;
    } else if (turn_count > 0 && total_requests > 0) {
        L = (double)total_requests / (double)turn_count;
    } else {
        L = 5.0;
    }
    if (L < 1.0) L = 1.0;

    /* ── avg: avg input tokens per LLM request ── */
    double avg;
    if (total_requests > 0 && total_input > 0) {
        avg = (double)total_input / (double)total_requests;
    } else {
        avg = 4000.0;
    }

    /* R = total expected remaining LLM calls */
    double R = E * L;

    /* summary instruction length */
    double l_instr = 70.0;

    /* cumulative retention */
    int c = total_compact;
    double r_t = 1.0;
    for (int i = 0; i <= c; i++) r_t *= r;
    if (r_t < 0.37) r_t = 0.37;

    /* N_remain: expected remaining input tokens */
    double N_remain = R * avg;

    /* ④ Info loss (constant across all k) */
    double info_loss = beta * (1.0 - r_t) * N_remain * p_input / 1e6;

    /* min_keep floor */
    int min_keep = (int)((double)n * min_keep_ratio + 0.5);
    if (min_keep < 3) min_keep = 3;
    if (min_keep > n) min_keep = n;

    /* max_keep ceiling = 1 - min_keep_ratio.
     * Rationale: if k > 75% of NR, less than 25% is dropped — too little to
     * justify the cost of an LLM summary call.  This also prevents pathological
     * cases where turn-alignment would expand a small best_k backward past many
     * tool_result lines, inflating the actual keep ratio far above min_keep
     * (e.g. DP picks 25% but turn-alignment pushes it to 80%+), resulting in a
     * compact that barely trims anything while still consuming a full LLM call. */
    int max_keep = (int)((double)n * (1.0 - min_keep_ratio) + 0.5);
    if (max_keep > n) max_keep = n;
    /* When min_keep_ratio > 0.5, the ceiling drops below the floor and the
     * for-loop can never execute.  The user set a high min_keep to be
     * conservative — not to disable compression entirely — so fall back to
     * no ceiling and let DP search up to n. */
    if (max_keep < min_keep) max_keep = n;

    /* H_min: minimum tokens to drop — must be several × summary output cost (S)
     * Dropping less than H_min means compact costs more than it saves.
     * 20×S: with S=500, requires dropping ≥10k tokens to justify a compact call.
     * At R≈20 remaining calls, 10k drop saves $0.06 vs $0.04 cost — clear margin. */
    int h_min = (int)(20.0 * S);

    /* ── DP 遍历所有 k ── */
    int best_k = 0;
    double best_benefit = -1e18;

    for (int k = min_keep; k <= max_keep; k++) {
        /* K = tokens in last k lines */
        int K = 0;
        for (int i = n - k; i < n; i++) K += sizes[i];
        int H = total_tokens - K;
        if (H <= 0) continue;

        /* ① Savings */
        double savings = (R - 1.0) * p_cache * (double)H / 1e6;
        /* ② Cache miss */
        double cache_miss = (S + (double)K) * (p_input - p_cache) / 1e6;
        /* ③ Compact cost */
        double compact_cost = (p_cache * V + p_input * ((double)H + l_instr) + p_out * S) / 1e6;
        /* ⑤ Quality savings — only when context is large enough */
        double quality_savings = 0.0;
        if (total_tokens > max_ctx * 0.30) {
            double v_plus_T = V + (double)total_tokens;
            double v_plus_K = V + (double)K;
            quality_savings = quality_penalty * p_input *
                (v_plus_T * v_plus_T - v_plus_K * v_plus_K) /
                ((double)max_ctx * 1e6);
        }

        double benefit = savings - cache_miss - compact_cost - info_loss + quality_savings;
        if (benefit > best_benefit) {
            best_benefit = benefit;
            best_k = k;
        }
    }

    int result = 0;
    if (best_benefit > 0.0) {
        /* Align to user-message (turn) boundary — must cut at user turn */
        int adj = best_k;
        int cut = n - adj;
        while (cut > 0 && !is_user[cut]) {
            cut--;
        }
        adj = n - cut;
        if (adj < 1) adj = 1;

        /* Post-alignment guards — alignment result must satisfy both:
         *   1. adj <= max_keep (alignment must not exceed ceiling)
         *   2. H_actual >= h_min  (tokens dropped must justify summary cost)
         * Cannot fall back to best_k — it is not on a user-message boundary. */
        int abort = 0;
        if (adj > max_keep) abort = 1;
        if (!abort) {
            int k_tokens = 0;
            for (int i = n - adj; i < n; i++) k_tokens += sizes[i];
            int h_actual = total_tokens - k_tokens;
            if (h_actual < h_min) abort = 1;
        }
        if (!abort) result = adj;
        /* else result stays 0 → no compact */
    }

    free(sizes);
    free(is_user);
    return result;
}

static int compact_turn_keep(char **lines, int line_count, double ratio) {
    if (line_count <= 0) return 0;

    int *user_idx = calloc((size_t)line_count, sizeof(int));
    if (!user_idx) return 0;
    int user_count = 0;
    for (int i = 0; i < line_count; i++) {
        if (compact_is_real_user_line(lines[i])) user_idx[user_count++] = i;
    }
    if (user_count == 0) {
        free(user_idx);
        return 0;
    }

    int keep_turns = (int)((double)user_count * ratio + 0.5);
    if (keep_turns < 1) keep_turns = 1;
    int start_turn = user_count - keep_turns;
    if (start_turn < 0) start_turn = 0;
    int cut_line = user_idx[start_turn];
    int keep = line_count - cut_line;
    free(user_idx);
    return keep;
}

/* ============================================================
 * 上下文压缩
 * ============================================================ */

int agent_compact_context(Agent *agent, const char *trigger) {
    /* 判断是否需要压缩 */
    int need_compact = 0;

    if (strcmp(trigger, "plan_clear") == 0 || strcmp(trigger, "plan_confirm") == 0) {
        need_compact = 1;
    } else {
        /* auto 模式：读取 stats，然后调用 DP 决策 */
        int turn_count = 0, total_requests = 0;
        int total_compact = 0, total_input = 0;

        char *stats_content = store_stats_read(agent->paths.stats);
        if (stats_content) {
            JsonParse jp = json_parse_root(stats_content);
            if (!jp.error) {
                turn_count     = json_get_int(jp.val, "current_turn_count");
                total_requests = json_get_int(jp.val, "agent_request_count");
                total_compact  = json_get_int(jp.val, "compact_request_count");
                total_input    = json_get_int(jp.val, "total_input_tokens");
            }
            free(stats_content);
        }

        /* 快速前置检查：太短的对话不需要 DP */
        char **quick_lines = NULL;
        int quick_count = 0;
        if (store_conv_line_count(agent->paths.conversation, &quick_lines, &quick_count) != 0)
            return 0;

        if (quick_count <= 4) {
            for (int i = 0; i < quick_count; i++) free(quick_lines[i]);
            free(quick_lines);
            return 0;
        }

        /* DP 决策 */
        int dp_keep = compact_dp_decision(quick_lines, quick_count, &agent->dp_cfg,
                                           turn_count, total_requests,
                                           total_compact, total_input);
        for (int i = 0; i < quick_count; i++) free(quick_lines[i]);
        free(quick_lines);

        if (dp_keep > 0) {
            need_compact = 1;
        } else {
            /* DP 不建议压缩，但 context_tokens 接近上限时仍然压缩 */
            char *stats2 = store_stats_read(agent->paths.stats);
            if (stats2) {
                JsonParse jp2 = json_parse_root(stats2);
                if (!jp2.error) {
                    int ct = json_get_int(jp2.val, "current_context_tokens");
                    if (ct > 0 && ct > agent->max_context_tokens * 90 / 100)
                        need_compact = 1;
                }
                free(stats2);
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

    /* 使用 DP 决策确定保留行数 */
    int turn_count = 0, total_requests = 0;
    int total_compact = 0, total_input = 0;

    char *stats2 = store_stats_read(agent->paths.stats);
    if (stats2) {
        JsonParse jp2 = json_parse_root(stats2);
        if (!jp2.error) {
            turn_count     = json_get_int(jp2.val, "current_turn_count");
            total_requests = json_get_int(jp2.val, "agent_request_count");
            total_compact  = json_get_int(jp2.val, "compact_request_count");
            total_input    = json_get_int(jp2.val, "total_input_tokens");
        }
        free(stats2);
    }

    int keep = compact_dp_decision(lines, line_count, &agent->dp_cfg,
                                    turn_count, total_requests,
                                    total_compact, total_input);
    /* DP 返回 0（不值得）或 >= line_count（全保留）→ fallback */
    if (keep <= 0 || keep >= line_count) {
        /* plan_clear / plan_confirm 强制按 user turn 比例截断 */
        if (strcmp(trigger, "plan_clear") == 0 || strcmp(trigger, "plan_confirm") == 0) {
            keep = compact_turn_keep(lines, line_count, agent->dp_cfg.min_keep_ratio);
        } else {
            /* auto 模式：检查 context_tokens 是否接近上限 */
            int ct = 0;
            char *stats3 = store_stats_read(agent->paths.stats);
            if (stats3) {
                JsonParse jp3 = json_parse_root(stats3);
                if (!jp3.error) ct = json_get_int(jp3.val, "current_context_tokens");
                free(stats3);
            }
            if (ct > 0 && ct > agent->max_context_tokens * 90 / 100) {
                keep = compact_turn_keep(lines, line_count, agent->dp_cfg.min_keep_ratio);
            } else {
                for (int i = 0; i < line_count; i++) free(lines[i]);
                free(lines);
                return 0;
            }
        }
    }
    if (keep <= 0) keep = compact_turn_keep(lines, line_count, agent->dp_cfg.min_keep_ratio);
    /* 对齐 bash 版: plan_clear/plan_confirm 绕过 keep >= line_count 守卫 */
    if (keep >= line_count &&
        strcmp(trigger, "plan_clear") != 0 &&
        strcmp(trigger, "plan_confirm") != 0) {
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

    /* 调用 LLM 做 summary — Cache-Aligned: 复用 build_claude_request 保持前缀一致
     * 对齐 bash 版: llm_summary_call → llm_call（含 system prompt + tools）
     * 对齐 Rust 版: run_summary_call → build_claude_request（含 system prompt + tools）
     * system prompt 和 tools 虽然本次调用用不到，但必须包含以命中 KV cache */
    const char *summary_instruction =
        "The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. "
        "Do NOT think. Just output the summary directly as plain text. "
        "Summarize the key information from the messages above into a concise context summary. "
        "Update the existing summary snapshot using the messages above. "
        "Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:\nReflections:";

    /* 构造 conv_lines: 丢弃的消息行 + summary 指令行 */
    StrBuf instr_line;
    sb_init(&instr_line);
    sb_append(&instr_line, "{\"role\":\"user\",\"content\":");
    sb_append_json_string(&instr_line, summary_instruction);
    sb_append(&instr_line, "}");

    int summary_line_count = drop + 1;
    char **summary_lines = malloc(sizeof(char*) * summary_line_count);
    for (int i = 0; i < drop; i++) summary_lines[i] = lines[i];
    summary_lines[drop] = instr_line.data;

    /* 构建 system prompt（与正常 agent 请求一致） */
    char *system_prompt = agent_build_prompt(agent);

    /* 复用 build_claude_request，与正常 agent 请求保持前缀一致 */
    char *summary_body = build_claude_request(
        agent->model, system_prompt, embedded_tools_json,
        summary_lines, summary_line_count,
        agent->max_tokens, "disabled", agent->effort);
    free(system_prompt);
    free(instr_line.data);
    free(summary_lines);

    if (strcmp(agent->provider, "openai") == 0) {
        char *openai_body = convert_to_openai(summary_body);
        free(summary_body);
        summary_body = openai_body;
    }
    /* 发送 summary 请求 */
    const char *headers[8];
    char auth_header[512];
    int hdr_count = 0;
    headers[hdr_count++] = "Content-Type: application/json";
    headers[hdr_count++] = "User-Agent: claude-cli/1.0.33 (max, cli)";
    if (strcmp(agent->provider, "claude") == 0) {
        headers[hdr_count++] = "x-app: cli";
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

    /* 对齐 bash 版 llm_summary_call: text 为空时报错退出，不 trim 不写 usage
     * bash: [[ -n "$text" ]] || util_die "Failed to generate context summary..." */
    if (rc != 0 || accum.text.len == 0) {
        fprintf(stderr, "[compact] Failed to generate summary: rc=%d text_len=%zu stop=%s error=%s\n",
                rc, accum.text.len,
                accum.stop_reason ? accum.stop_reason : "none",
                accum.error ? accum.error : "none");
        sse_accum_free(&accum);
        free(summary_body);
        sb_free(&dropped);
        for (int i = 0; i < line_count; i++) free(lines[i]);
        free(lines);
        return -1;
    }

    /* 保存 summary */
    store_summary_set(&agent->paths, accum.text.data);

    /* 保存 compact 的 token 消耗（sse_accum_free 前提取） */
    int compact_in = accum.in_tokens, compact_out = accum.out_tokens;
    int compact_cr = accum.cache_read_tokens, compact_cc = accum.cache_creation_tokens;
    sse_accum_free(&accum);
    free(summary_body);
    sb_free(&dropped);

    /* 截断 conversation（对齐 Go 版: keepLines < totalLines 才 trim） */
    if (keep < line_count) {
        store_conv_trim_tail(agent->paths.conversation, keep);
    }

    /* 更新 stats + 写入 usage 事件（对齐 Go 版: tokens > 0 才写）
     * 注意：不再重置 current_turn_count — 它应始终保持 session 累计计数 */
    if (compact_in > 0 || compact_out > 0 || compact_cr > 0 || compact_cc > 0) {
        store_stats_set_int_file(agent->paths.stats, "compact_request_count",
            store_stats_get_file_int(agent->paths.stats, "compact_request_count") + 1);
        /* 累加 compact 的 token 消耗（对齐 bash 版 agent_record_usage） */
        store_stats_set_int_file(agent->paths.stats, "total_input_tokens",
            store_stats_get_file_int(agent->paths.stats, "total_input_tokens") + compact_in);
        store_stats_set_int_file(agent->paths.stats, "total_output_tokens",
            store_stats_get_file_int(agent->paths.stats, "total_output_tokens") + compact_out);
        store_stats_set_int_file(agent->paths.stats, "total_cache_read_tokens",
            store_stats_get_file_int(agent->paths.stats, "total_cache_read_tokens") + compact_cr);
        store_stats_set_int_file(agent->paths.stats, "total_cache_creation_tokens",
            store_stats_get_file_int(agent->paths.stats, "total_cache_creation_tokens") + compact_cc);
        /* 写入 usage 事件（kind=compact），对齐 bash 版 agent_record_usage */
        {
            StrBuf evt;
            sb_init(&evt);
            sb_appendf(&evt, "{\"type\":\"usage\",\"input_tokens\":%d,\"output_tokens\":%d",
                       compact_in, compact_out);
            sb_appendf(&evt, ",\"cache_read_input_tokens\":%d,\"cache_creation_input_tokens\":%d",
                       compact_cr, compact_cc);
            sb_append(&evt, ",\"kind\":\"compact\"}");
            store_event_append(&agent->paths, evt.data);
            sb_free(&evt);
        }
    }
    /* 对齐 bash 版: store_stats_update 末尾调 display_term_title */
    agent_update_title(agent);

    /* 推送 CONTEXT_UPDATE 到 display */
    if (agent->display_queue) {
        DisplayMessage *dm = malloc(sizeof(DisplayMessage));
        *dm = display_msg_context_update(trigger);
        push_display_event(&agent->paths, agent->display_queue, dm);
    }

    for (int i = 0; i < line_count; i++) free(lines[i]);
    free(lines);

    return 0;
}

/* ============================================================
 * 终端标题更新
 * ============================================================ */

static void format_int_commas(int n, char *out, size_t out_size) {
    char raw[32];
    snprintf(raw, sizeof(raw), "%d", n);
    size_t len = strlen(raw);
    size_t commas = (len > 0) ? (len - 1) / 3 : 0;
    size_t need = len + commas + 1;
    if (out_size < need) {
        snprintf(out, out_size, "%d", n);
        return;
    }

    out[need - 1] = '\0';
    int ri = (int)len - 1;
    int oi = (int)need - 2;
    int group = 0;
    while (ri >= 0) {
        if (group == 3) {
            out[oi--] = ',';
            group = 0;
        }
        out[oi--] = raw[ri--];
        group++;
    }
}

static void format_ll_commas(long long n, char *out, size_t out_size) {
    char raw[32];
    snprintf(raw, sizeof(raw), "%lld", n);
    size_t len = strlen(raw);
    size_t commas = (len > 0) ? (len - 1) / 3 : 0;
    size_t need = len + commas + 1;
    if (out_size < need) {
        snprintf(out, out_size, "%lld", n);
        return;
    }

    out[need - 1] = '\0';
    int ri = (int)len - 1;
    int oi = (int)need - 2;
    int group = 0;
    while (ri >= 0) {
        if (group == 3) {
            out[oi--] = ',';
            group = 0;
        }
        out[oi--] = raw[ri--];
        group++;
    }
}

void agent_update_title(Agent *agent) {
    agent_update_title_status(agent, NULL);
}

void agent_update_title_status(Agent *agent, const char *status) {
    if (!agent->interactive) return;
    char *stats_content = store_stats_read(agent->paths.stats);
    if (!stats_content) return;
    JsonParse jp = json_parse_root(stats_content);
    if (jp.error) { free(stats_content); return; }

    int tc = json_get_int(jp.val, "current_turn_count");
    int ar = json_get_int(jp.val, "agent_request_count");
    long long ll_ai = json_get_ll(jp.val, "total_input_tokens");
    int ao = json_get_int(jp.val, "total_output_tokens");
    long long ll_cr = json_get_ll(jp.val, "total_cache_read_tokens");
    int ct = json_get_int(jp.val, "current_context_tokens");

    /* 对齐 bash 版 term_title.awk: model T:turn R:req I:in+cr(pct) O:out C:ctx */
    long long total_i = ll_ai + ll_cr;
    int pct = (total_i > 0) ? (int)(ll_cr * 100 / total_i) : 0;

    char tc_s[32], ar_s[32], total_i_s[32], ao_s[32], ct_s[32];
    format_int_commas(tc, tc_s, sizeof(tc_s));
    format_int_commas(ar, ar_s, sizeof(ar_s));
    format_ll_commas(total_i, total_i_s, sizeof(total_i_s));
    format_int_commas(ao, ao_s, sizeof(ao_s));
    format_int_commas(ct, ct_s, sizeof(ct_s));

    const char *prefix = (status && strcmp(status, "idle") == 0) ? "" : "\xe2\x8f\xb3 ";
    int progress = (status && strcmp(status, "idle") == 0) ? 0 : 3;
    fprintf(stderr, "\x1b]0;%s%s T:%s R:%s I:%s(%d%%) O:%s C:%s\x07\x1b]9;4;%d\x07",
            prefix, agent->model, tc_s, ar_s, total_i_s, pct, ao_s, ct_s, progress);
    fflush(stderr);

    free(stats_content);
}
