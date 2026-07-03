#ifndef AGENT_H
#define AGENT_H

#include "store.h"
#include "transport.h"
#include "tools.h"
#include "msgqueue.h"
#include "protocol.h"
#include "json.h"
#include "util.h"

/* DP Compact 配置结构体 */
typedef struct {
    int baseline_e;
    int e_fixed;
    double L_fixed;
    double V;
    double p_input;
    double p_cache;
    double p_out;
    double S;
    double min_keep_ratio;
    double r;
    double beta;
    double quality_penalty;
    int max_context;
} DPConfig;

/* 初始化 DP 配置（从环境变量读取，默认值对齐 bash 版） */
DPConfig dp_config_init(int max_context_tokens);

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

    /* DP Compact 配置 */
    DPConfig dp_cfg;

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
    int active_task_count;

    /* 消息队列 */
    MsgQueue *input_queue;      /* 外部传入，agent_loop 从中读取 */
    MsgQueue *display_queue;    /* 外部传入，agent_loop 向其写入 */
    MsgQueue *sub_result_queue; /* SubAgent 结果队列（对齐 bash NOTIFY_FIFO） */

    /* 中断标志 */
    volatile int interrupted;

    /* 运行标志 — 1 表示 agent 正在处理（agent_loop 执行中），
     * 0 表示空闲等待输入。
     * readline 线程在 Ctrl+C 时检查此标志来决定是否中断 agent。 */
    volatile int running;

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
/* agent_loop wrapper：结束后恢复 idle 标题 */
int agent_run_loop(Agent *agent, const char *user_input, const char *turn_kind);

/* SubAgent 处理：在子线程中执行独立 agent_loop */
char *agent_handle_sub_agent(Agent *agent, const char *prompt,
                             const char *description, int fork);

/* 处理 SubAgent 结果 */
int agent_handle_sub_agent_result(Agent *agent, const char *session_id,
                                   const char *status, const char *thinking,
                                   const char *text,
                                   int in_tokens, int out_tokens,
                                   int cache_read, int cache_creation,
                                   int request_count);

/* 构建 system prompt */
char *agent_build_prompt(Agent *agent);

/* 上下文压缩 */
int agent_compact_context(Agent *agent, const char *trigger);

/* 从 events.jsonl 重放最近 N 轮事件到 display_queue */
int agent_replay_events(Agent *agent, int max_turns);

/* 更新终端标题 */
void agent_update_title(Agent *agent);
void agent_update_title_status(Agent *agent, const char *status);

/* ============================================================
 * 图片占位符支持
 * ============================================================ */

/* 展开输入中的 [Image #N] 占位符，调用描述 API 后替换输入指针 */
/* 图像处理 */
char *agent_image_describe(char **paths, int count);
void agent_image_expand_placeholders(Agent *agent, char **input);
void agent_image_clipboard_paste(const char *session_dir, char **out, size_t *outlen);

#endif /* AGENT_H */
