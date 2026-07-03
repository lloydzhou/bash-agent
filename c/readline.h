#ifndef READLINE_H
#define READLINE_H

#include "msgqueue.h"
#include "protocol.h"

/*
 * 输入层 — readline 线程（stdin → input_queue）
 *
 * 从 stdin 读取用户输入，封装为 InputMessage 发送到 input_queue。
 * 交互模式下显示提示符 "> "，支持 Ctrl+C（重新提示）和 Ctrl+D（退出）。
 */

/* readline 线程配置 */
typedef struct {
    MsgQueue *input_queue;  /* 写入目标 */
    int interactive;        /* 是否交互模式 */
    const char *home;       /* 用户主目录（用于 history 文件路径） */
} ReadlineConfig;

/* 启动 readline 线程，返回 pthread_t */
int readline_thread_start(pthread_t *thread, const ReadlineConfig *cfg);

/* 设置 agent 的 interrupted 和 running 指针
 * interrupted: Ctrl+C 时设为 1，让 agent_loop 中断 HTTP 请求
 * running: agent_loop 执行中为 1，readline 据此判断 Ctrl+C 是否应中断 */
void readline_set_agent_interrupted(volatile int *interrupted, const volatile int *running);

/* 设置 inject callback 使用的队列指针（Ctrl+O 中间介入）
 * sub_queue: 写入 USER_NOTIFY pending
 * input_queue: 写入 MSG_NOTIFY_PENDING 唤醒主循环 */
void readline_set_inject_queues(MsgQueue *sub_queue, MsgQueue *input_queue);

/* Ctrl+O inject callback — 供 linenoise 调用 */
int inject_callback(char *buf, size_t len);

#endif /* READLINE_H */
