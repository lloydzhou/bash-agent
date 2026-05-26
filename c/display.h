#ifndef DISPLAY_H
#define DISPLAY_H

#include "msgqueue.h"
#include "protocol.h"

/*
 * 显示层 — display 线程 + 渲染逻辑
 *
 * 从 display_queue 取消息，渲染到 stdout。
 * 支持 human 和 stream-json 两种输出格式。
 */

typedef enum {
    OUTPUT_HUMAN,
    OUTPUT_STREAM_JSON,
} OutputFormat;

/* display 线程的配置 */
typedef struct {
    MsgQueue *queue;        /* display_queue */
    OutputFormat format;
    int interactive;        /* 是否交互模式 */
} DisplayConfig;

/* 启动 display 线程，返回 pthread_t */
int display_thread_start(pthread_t *thread, const DisplayConfig *cfg);

/* 请求 display 线程停止 */
void display_thread_stop(MsgQueue *queue);

/* 等待 display 线程处理完当前已入队的所有消息 */
int display_flush(MsgQueue *queue);

#endif /* DISPLAY_H */
