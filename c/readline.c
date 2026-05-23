#include "readline.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

static void *readline_thread_fn(void *arg) {
    ReadlineConfig *cfg = (ReadlineConfig *)arg;
    char linebuf[65536];

    while (1) {
        if (cfg->interactive) {
            fprintf(stderr, "\x1b[32m> \x1b[0m");
            fflush(stderr);
        }

        if (!fgets(linebuf, sizeof(linebuf), stdin)) {
            /* EOF (Ctrl+D) */
            break;
        }

        /* 去除尾部换行 */
        util_rtrim(linebuf);

        /* 空行跳过 */
        if (linebuf[0] == '\0') continue;

        /* exit / quit */
        if (strcmp(linebuf, "exit") == 0 || strcmp(linebuf, "quit") == 0) {
            break;
        }

        /* 构造 InputMessage 并推送到队列 */
        InputMessage *msg = malloc(sizeof(InputMessage));
        if (!msg) break;
        memset(msg, 0, sizeof(*msg));
        msg->type = MSG_USER_INPUT;
        msg->data.user_input.text = util_strdup(linebuf);

        if (mq_push(cfg->input_queue, msg) != 0) {
            input_message_free(msg);
            free(msg);
            break; /* 队列已关闭 */
        }
    }

    return NULL;
}

int readline_thread_start(pthread_t *thread, const ReadlineConfig *cfg) {
    ReadlineConfig *heap_cfg = malloc(sizeof(ReadlineConfig));
    if (!heap_cfg) return -1;
    *heap_cfg = *cfg;
    return pthread_create(thread, NULL, readline_thread_fn, heap_cfg);
}
