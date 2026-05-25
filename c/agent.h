#ifndef AGENT_H
#define AGENT_H

#include "store.h"
#include "transport.h"
#include "tools.h"
#include "msgqueue.h"
#include "protocol.h"
#include "json.h"
#include "util.h"

/*
 * Agent — 核心逻辑层
 *
 * 包含 Agent 结构体、agent_loop、prompt 构建、compact、SubAgent 处理。
 */

typedef struct {
    /* 配置 */
    char *provider;         /* "claude" 或 "openai" */
    char *model;
    char *api_key;
    char *base_url;
    char *api_url;
    int max_tokens;
    int max_turns;
    int max_context_tokens;
    int tool_timeout_secs;
    int tool_result_max_bytes;
    int output_format;      /* 0=human, 1=stream-json */
    int verbose;
    int interactive;
    char *thinking;
    char *effort;

    /* Skills */
    char **skill_names;
    int skill_count;

    /* 路径 */
    char *cwd;
    char *home;
    char *session_id;
    SessionPaths paths;

    /* 统计 */
    int last_context_tokens;
    int last_input_tokens;
    int last_output_tokens;
    int last_cache_read_tokens;
    int last_cache_creation_tokens;
    int active_sub_count;

    /* 消息队列 */
    MsgQueue *input_queue;  /* 外部传入，agent_loop 从中读取 */
    MsgQueue *display_queue;/* 外部传入，agent_loop 向其写入 */

    /* 中断标志 */
    volatile int interrupted;

    /* 待处理的 fork 子 agent（在 tool_result 写入后执行复制） */
    void **pending_fork_args;  /* SubAgentArgs* 数组 */
    int pending_fork_count;
    int pending_fork_cap;
} Agent;

/* 创建 Agent（解析配置，初始化会话） */
Agent *agent_create(const char *provider, const char *model,
                    const char *api_key, const char *base_url,
                    const char *cwd, const char *home,
                    const char *session_id, int interactive,
                    char **skill_names, int skill_count,
                    MsgQueue *input_queue, MsgQueue *display_queue);

/* 销毁 Agent */
void agent_destroy(Agent *agent);

/* 主循环（从 input_queue 取消息，驱动 LLM 调用） */
int agent_main_loop(Agent *agent);

/* 单次 agent loop：用户输入 → LLM → 工具调用 → 循环 */
int agent_loop(Agent *agent, const char *user_input, const char *turn_kind);

/* SubAgent 处理：在子线程中执行独立 agent_loop */
char *agent_handle_sub_agent(Agent *agent, const char *prompt,
                             const char *description, int fork);

/* 处理 SubAgent 结果 */
int agent_handle_sub_agent_result(Agent *agent, const char *session_id,
                                   const char *status, const char *thinking,
                                   const char *text,
                                   int in_tokens, int out_tokens,
                                   int cache_read, int cache_creation);

/* 构建 system prompt */
char *agent_build_prompt(Agent *agent);

/* 上下文压缩 */
int agent_compact_context(Agent *agent, const char *trigger);

/* 从 events.jsonl 重放最近 N 轮事件到 display_queue */
void agent_replay_events(Agent *agent, int max_turns);

/* 更新终端标题 */
void agent_update_title(Agent *agent);

#endif /* AGENT_H */
