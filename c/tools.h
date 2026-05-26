#ifndef TOOLS_H
#define TOOLS_H

#include "json.h"
#include "util.h"

/*
 * 工具层 — 工具调度器 + 各工具实现
 */

/* 工具执行结果 */
typedef struct {
    char *output;           /* 工具输出（需要 free） */
    int exit_code;          /* 退出码，0=成功 */
} ToolResult;

void tool_result_free(ToolResult *r);

/* 截断过长的工具结果 */
char *tool_format_result(const char *output, int max_bytes);

#include "store.h"

/* 工具调度：根据名称和参数执行工具，返回结果 */
ToolResult tool_dispatch(const char *name, const char *input_json,
                         const char *cwd, const char *home,
                         int timeout_secs, int max_bytes,
                         const SessionPaths *paths);

/* 工具调用摘要（用于显示） */
char *tool_call_summary(const char *name, JsonVal input);

#endif /* TOOLS_H */
