#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <pthread.h>

/*
 * 消息协议定义 — 线程间通信的消息类型
 *
 * 三条队列：
 *   input_queue   — readline 线程和 SubAgent 线程写入，agent_loop 读取
 *   display_queue — agent_loop 写入，display 线程读取
 */

/* ============================================================
 * input_queue 的消息类型
 * ============================================================ */

typedef enum {
    MSG_USER_INPUT,       /* 用户从 stdin 输入 */
    MSG_AGENT_RESULT,     /* SubAgent 完成后发送结果 */
    MSG_ASYNC_TASK_RESULT,/* 异步 Bash 任务完成 */
    MSG_USER_NOTIFY,      /* 用户 Ctrl+O 中间介入（走 sub_result_queue） */
    MSG_NOTIFY_PENDING,   /* 唤醒主循环消费 pending notify */
} InputMsgType;

typedef struct {
    InputMsgType type;
    union {
        struct {
            char *text;   /* 用户输入的文本，需要调用者 free */
        } user_input;
        struct {
            char *session_id;
            char *status;           /* "ok" 或 "failed" */
            char *thinking;         /* 可能为 NULL */
            char *text;             /* 可能为 NULL */
            int in_tokens;
            int out_tokens;
            int cache_read_tokens;
            int cache_creation_tokens;
            int request_count;
        } agent_result;
        struct {
            char *task_id;
            int exit_code;
            char *output;           /* 可能为 NULL */
        } async_task_result;
        struct {
            char *text;             /* 用户 Ctrl+O 介入的文本 */
        } user_notify;
    } data;
} InputMessage;

/* 释放 InputMessage 内部动态分配的内存 */
void input_message_free(InputMessage *msg);

/* ============================================================
 * display_queue 的消息类型
 * ============================================================ */

typedef enum {
    DISPLAY_TEXT,                /* 文本内容（assistant 回复） */
    DISPLAY_THINKING,            /* 思考内容 */
    DISPLAY_TOOL_CALL,           /* 工具调用开始 */
    DISPLAY_TOOL_RESULT,         /* 工具执行结果 */
    DISPLAY_USAGE,               /* token 用量统计 */
    DISPLAY_STOP,                /* 停止原因 */
    DISPLAY_ERROR,               /* 错误信息 */
    DISPLAY_SUB_AGENT_RESULT,    /* SubAgent 结果摘要 */
    DISPLAY_SUB_AGENT_START,     /* SubAgent 启动通知 */
    DISPLAY_ASYNC_TASK_RESULT,   /* 异步 Bash 任务结果 */
    DISPLAY_CONTEXT_UPDATE,      /* 上下文压缩通知 */
    DISPLAY_FLUSH,               /* display 队列同步屏障 */
    DISPLAY_USER_NOTIFY,         /* 用户 Ctrl+O 介入输入 */
} DisplayMsgType;

typedef struct {
    DisplayMsgType type;
    /* 通用内容字段（所有类型都可能有，需要 free） */
    char *content;
    /* 工具调用专用 */
    char *tool_name;
    char *tool_id;
    char *tool_input;
    /* 工具结果专用 */
    int tool_exit_code;         /* Bash 命令退出码，0 表示成功 */
    /* 用量统计 */
    int in_tokens;
    int out_tokens;
    int cache_read_tokens;
    int cache_creation_tokens;
    /* SubAgent 专用 */
    char *session_id;
    /* DISPLAY_FLUSH 专用：display 线程处理到该消息后 signal */
    pthread_mutex_t *flush_mutex;
    pthread_cond_t *flush_cond;
    int *flush_done;
} DisplayMessage;

/* 创建各种类型的 DisplayMessage */
DisplayMessage display_msg_text(const char *content);
DisplayMessage display_msg_thinking(const char *content);
DisplayMessage display_msg_tool_call(const char *id, const char *name, const char *input);
DisplayMessage display_msg_tool_result(const char *content, int exit_code);
DisplayMessage display_msg_usage(int in_tok, int out_tok, int cache_read, int cache_creation);
DisplayMessage display_msg_stop(const char *reason);
DisplayMessage display_msg_error(const char *content);
DisplayMessage display_msg_sub_agent_start(const char *session_id, const char *desc);
DisplayMessage display_msg_sub_agent_result(const char *session_id, const char *status,
                                             const char *thinking, const char *text,
                                             int in_tokens, int out_tokens);
DisplayMessage display_msg_async_task_result(const char *task_id, int exit_code,
                                             const char *output);
DisplayMessage display_msg_context_update(const char *trigger);
DisplayMessage display_msg_user_notify(const char *text);

/* 释放 DisplayMessage 内部动态分配的内存 */
void display_message_free(DisplayMessage *msg);

#endif /* PROTOCOL_H */
