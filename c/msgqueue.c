#include "msgqueue.h"
#include <stdlib.h>
#include <string.h>
#include <errno.h>

int mq_init(MsgQueue *q) {
    memset(q, 0, sizeof(*q));
    q->head = NULL;
    q->tail = NULL;
    q->count = 0;
    q->closed = false;
    if (pthread_mutex_init(&q->mutex, NULL) != 0) return -1;
    if (pthread_cond_init(&q->cond, NULL) != 0) {
        pthread_mutex_destroy(&q->mutex);
        return -1;
    }
    return 0;
}

void mq_close(MsgQueue *q) {
    pthread_mutex_lock(&q->mutex);
    q->closed = true;
    pthread_cond_broadcast(&q->cond);
    pthread_mutex_unlock(&q->mutex);
}

void mq_destroy(MsgQueue *q) {
    /* 释放队列中残留的节点（不释放 data 本身） */
    MQNode *node = q->head;
    while (node) {
        MQNode *next = node->next;
        free(node);
        node = next;
    }
    pthread_mutex_destroy(&q->mutex);
    pthread_cond_destroy(&q->cond);
    memset(q, 0, sizeof(*q));
}

int mq_push(MsgQueue *q, void *data) {
    MQNode *node = malloc(sizeof(MQNode));
    if (!node) return -1;
    node->data = data;
    node->next = NULL;

    pthread_mutex_lock(&q->mutex);
    if (q->closed) {
        pthread_mutex_unlock(&q->mutex);
        free(node);
        return -1;
    }
    if (q->tail) {
        q->tail->next = node;
    } else {
        q->head = node;
    }
    q->tail = node;
    q->count++;
    pthread_cond_signal(&q->cond);
    pthread_mutex_unlock(&q->mutex);
    return 0;
}

int mq_pop(MsgQueue *q, void **data_out) {
    pthread_mutex_lock(&q->mutex);
    while (!q->head && !q->closed) {
        pthread_cond_wait(&q->cond, &q->mutex);
    }
    if (!q->head) {
        /* 队列已关闭且为空 */
        pthread_mutex_unlock(&q->mutex);
        return -1;
    }
    MQNode *node = q->head;
    q->head = node->next;
    if (!q->head) q->tail = NULL;
    q->count--;
    pthread_mutex_unlock(&q->mutex);

    *data_out = node->data;
    free(node);
    return 0;
}

int mq_try_pop(MsgQueue *q, void **data_out) {
    pthread_mutex_lock(&q->mutex);
    if (!q->head) {
        pthread_mutex_unlock(&q->mutex);
        return -1;
    }
    MQNode *node = q->head;
    q->head = node->next;
    if (!q->head) q->tail = NULL;
    q->count--;
    pthread_mutex_unlock(&q->mutex);
    *data_out = node->data;
    free(node);
    return 0;
}

int mq_count(MsgQueue *q) {
    pthread_mutex_lock(&q->mutex);
    int n = q->count;
    pthread_mutex_unlock(&q->mutex);
    return n;
}
