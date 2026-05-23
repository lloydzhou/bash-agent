#ifndef READLINE_H
#define READLINE_H

#include "msgqueue.h"
#include "protocol.h"

/*
 * 输入层 — readline 线程（stdin → input_queue）
 *
 * 从 stdin 读取用户输入，封装为 InputMessage 发送到 input_queue。
 * 交互模式下显示提示符 "> "。
 */

/* readline 线程配置 */
typedef struct {
    MsgQueue *input_queue;  /* 写入目标 */
    int interactive;        /* 是否交互模式 */
} ReadlineConfig;

/* 启动 readline 线程，返回 pthread_t */
int readline_thread_start(pthread_t *thread, const ReadlineConfig *cfg);

#endif /* READLINE_H */
