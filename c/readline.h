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

/* 检查并消费 SIGINT 标志 */
int readline_sigint_consumed(void);

/* 设置 agent 的 interrupted 指针（SIGINT handler 中同时设置） */
void readline_set_agent_interrupted(volatile int *flag);

/* display worker 调用：Hide/Show 当前 linenoise prompt */
void readline_display_hide(void);
void readline_display_show(void);

#endif /* READLINE_H */
