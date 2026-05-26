#ifndef MSGQUEUE_H
#define MSGQUEUE_H

#include <pthread.h>
#include <stdbool.h>

/*
 * 线程安全消息队列 — pthread mutex + condvar 实现
 *
 * 用于 input_queue 和 display_queue。
 * 队列存储的是 void* 指针，具体类型由使用者定义（InputMessage / DisplayMessage）。
 * 消息的内存所有权转移给队列，取出后由消费者负责释放。
 */

typedef struct MQNode {
    void *data;
    struct MQNode *next;
} MQNode;

typedef struct {
    MQNode *head;           /* 队列头部（出队端） */
    MQNode *tail;           /* 队列尾部（入队端） */
    int count;              /* 当前队列中的消息数 */
    bool closed;            /* 队列是否已关闭 */
    pthread_mutex_t mutex;
    pthread_cond_t cond;    /* 非空通知 */
} MsgQueue;

/* 初始化队列 */
int mq_init(MsgQueue *q);

/* 关闭队列（唤醒所有等待者） */
void mq_close(MsgQueue *q);

/* 销毁队列（释放内部资源，不释放消息本身） */
void mq_destroy(MsgQueue *q);

/*
 * 入队 — data 的所有权转移给队列
 * 返回 0 成功，-1 队列已关闭
 */
int mq_push(MsgQueue *q, void *data);

/*
 * 出队 — 调用者获得 data 的所有权，需要自行 free
 * 如果队列为空，阻塞等待。
 * 返回 0 成功，-1 队列已关闭且为空
 */
int mq_pop(MsgQueue *q, void **data_out);

/* 当前队列长度 */
int mq_count(MsgQueue *q);

#endif /* MSGQUEUE_H */
