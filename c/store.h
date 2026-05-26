#ifndef STORE_H
#define STORE_H

#include "json.h"
#include "util.h"

/*
 * 会话存储 — session 管理、conversation.jsonl 读写、stats.json 更新
 *
 * 目录结构（与 bash/go/rust 一致）：
 *   ~/.bash-agent/projects/<project-key>/<session-id>/
 *     conversation.jsonl  — 对话历史
 *     events.jsonl        — 事件日志
 *     stats.json          — 统计数据
 *     summary.md          — 上下文摘要
 *     plan.md             — 已确认的计划
 *     plan.draft          — 计划草稿
 */

/* 会话路径集 */
typedef struct {
    char *base_dir;         /* ~/.bash-agent/projects/<key>/ */
    char *session_dir;      /* base_dir/<session-id>/ */
    char *conversation;     /* session_dir/conversation.jsonl */
    char *events;           /* session_dir/events.jsonl */
    char *stats;            /* session_dir/stats.json */
    char *summary;          /* session_dir/summary.md */
    char *plan;             /* session_dir/plan.md */
    char *plan_draft;       /* session_dir/plan.draft */
} SessionPaths;

void store_session_paths_free(SessionPaths *p);

/* 根据 home, cwd, session_id 生成路径集 */
SessionPaths store_session_paths_for(const char *home, const char *cwd, const char *session_id);

/* 确保会话目录和文件存在 */
int store_session_init(const SessionPaths *p, int is_new);

/* 为子 agent 创建新会话（初始化目录） */
int store_session_init_sub(const SessionPaths *parent_paths, const SessionPaths *sub_paths, int fork);

/* 从 cwd 生成 project key（简化为路径替换 / 为 -） */
char *store_session_project_key(const char *cwd);

/* 生成新的 session ID（格式: YYYYMMDD-HHMMSS-XXXX） */
char *session_new_id(void);

/* 查找最近一个会话（用于 --continue） */
char *store_session_resolve_continue(const char *home, const char *cwd);

/* ============================================================
 * conversation.jsonl 操作
 * ============================================================ */

/* 追加 user 消息 */
int store_conv_add_user(const char *path, const char *content);

/* 追加 assistant 消息（含 thinking, text, tool_calls） */
int store_conv_add_assistant(const char *path, const char *thinking, const char *text,
                       /* tool_calls: 数组 of {id, name, input_json}，count 个 */
                       int tool_count, const char **tool_ids,
                       const char **tool_names, const char **tool_inputs);

/* 追加 tool_result 消息 */
int store_conv_add_tool_results(const char *path, int count, const char **tool_use_ids,
                          const char **contents);

/* 读取所有行（JSON 字符串数组，每个元素需 free） */
int store_conv_line_count(const char *path, char ***out, int *out_count);

/* 保留最后 keep_lines 行 */
int store_conv_trim_tail(const char *path, int keep_lines);

/* 统计 user 输入消息数量 */
int store_conv_user_turn_count(const char *path);

/* 计算总字节数 */
long store_conv_total_bytes(const char *path);

/* ============================================================
 * stats.json 操作
 * ============================================================ */

/* 读取 stats（返回 JSON 字符串，需 free） */
char *store_stats_read(const char *path);

/* 更新 stats（读取→调用 callback→写回） */
typedef void (*stats_update_fn)(void *ctx, JsonVal stats);
int store_stats_update(const char *path, stats_update_fn fn, void *ctx);

/* 常用更新操作 */
void store_stats_add_int(JsonVal obj, const char *key, int delta);
void store_stats_set_int(JsonVal obj, const char *key, int value);

/* 简易文件级操作：直接读写 stats 文件中的整数字段 */
int store_stats_get_file_int(const char *path, const char *key);
void store_stats_set_int_file(const char *path, const char *key, int value);

/* 从 stats 中读取整数值 */
int store_stats_get_int(JsonVal obj, const char *key);

/* ============================================================
 * events.jsonl 操作
 * ============================================================ */

/* 追加事件（JSON 字符串） */
int store_event_append(const SessionPaths *p, const char *json_str);

/* 读取所有事件行 */
int store_event_lines(const SessionPaths *p, char ***out, int *out_count);

/* ============================================================
 * summary / plan 文件操作
 * ============================================================ */

char *store_summary_get(const SessionPaths *p);
int store_summary_set(const SessionPaths *p, const char *content);

char *store_plan_draft_read(const SessionPaths *p);
int store_plan_draft_set(const SessionPaths *p, const char *content);
int store_plan_draft_clear(const SessionPaths *p);
int store_plan_set(const SessionPaths *p, const char *content);
int store_plan_clear(const SessionPaths *p);

#endif /* STORE_H */
