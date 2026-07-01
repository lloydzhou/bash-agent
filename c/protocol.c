#include "protocol.h"
#include "util.h"
#include <stdlib.h>
#include <string.h>

/* ============================================================
 * InputMessage 释放
 * ============================================================ */

void input_message_free(InputMessage *msg) {
    if (!msg) return;
    switch (msg->type) {
        case MSG_USER_INPUT:
            FREE_PTR(msg->data.user_input.text);
            break;
        case MSG_AGENT_RESULT:
            FREE_PTR(msg->data.agent_result.session_id);
            FREE_PTR(msg->data.agent_result.status);
            FREE_PTR(msg->data.agent_result.thinking);
            FREE_PTR(msg->data.agent_result.text);
            break;
        case MSG_ASYNC_TASK_RESULT:
            FREE_PTR(msg->data.async_task_result.task_id);
            FREE_PTR(msg->data.async_task_result.output);
            break;
    }
}

/* ============================================================
 * DisplayMessage 构造函数
 * ============================================================ */

DisplayMessage display_msg_text(const char *content) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_TEXT;
    m.content = util_strdup(content);
    return m;
}

DisplayMessage display_msg_thinking(const char *content) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_THINKING;
    m.content = util_strdup(content);
    return m;
}

DisplayMessage display_msg_tool_call(const char *id, const char *name, const char *input) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_TOOL_CALL;
    m.content = util_strdup(input); /* content 用于显示摘要 */
    m.tool_id = util_strdup(id);
    m.tool_name = util_strdup(name);
    m.tool_input = util_strdup(input);
    return m;
}

DisplayMessage display_msg_tool_result(const char *content, int exit_code) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_TOOL_RESULT;
    m.content = util_strdup(content);
    m.tool_exit_code = exit_code;
    return m;
}

DisplayMessage display_msg_usage(int in_tok, int out_tok, int cache_read, int cache_creation) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_USAGE;
    m.in_tokens = in_tok;
    m.out_tokens = out_tok;
    m.cache_read_tokens = cache_read;
    m.cache_creation_tokens = cache_creation;
    return m;
}

DisplayMessage display_msg_stop(const char *reason) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_STOP;
    m.content = util_strdup(reason);
    return m;
}

DisplayMessage display_msg_error(const char *content) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_ERROR;
    m.content = util_strdup(content);
    return m;
}

DisplayMessage display_msg_sub_agent_start(const char *session_id, const char *desc) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_SUB_AGENT_START;
    m.session_id = util_strdup(session_id);
    m.content = util_strdup(desc);
    return m;
}

DisplayMessage display_msg_sub_agent_result(const char *session_id, const char *status,
                                             const char *thinking, const char *text,
                                             int in_tokens, int out_tokens) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_SUB_AGENT_RESULT;
    m.session_id = util_strdup(session_id);
    m.content = util_strdup(text ? text : "");
    m.tool_exit_code = (strcmp(status, "ok") == 0) ? 0 : 1;
    m.in_tokens = in_tokens;
    m.out_tokens = out_tokens;
    /* 把 thinking 存入 tool_name 字段复用（避免改结构体） */
    m.tool_name = util_strdup(thinking ? thinking : "");
    return m;
}

DisplayMessage display_msg_async_task_result(const char *task_id, int exit_code,
                                             const char *output) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_ASYNC_TASK_RESULT;
    m.session_id = util_strdup(task_id);
    m.tool_exit_code = exit_code;
    m.content = util_strdup(output ? output : "");
    return m;
}

DisplayMessage display_msg_context_update(const char *trigger) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_CONTEXT_UPDATE;
    /* 复用 tool_name 字段存 trigger（避免改结构体） */
    m.tool_name = util_strdup(trigger ? trigger : "auto");
    return m;
}

DisplayMessage display_msg_image_describe(const char *images, const char *description) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_IMAGE_DESCRIBE;
    m.tool_name = util_strdup(images ? images : "");  /* 复用 tool_name 存 images 占位符 */
    m.content = util_strdup(description ? description : "");
    return m;
}

/* ============================================================
 * DisplayMessage 释放
 * ============================================================ */

void display_message_free(DisplayMessage *msg) {
    if (!msg) return;
    FREE_PTR(msg->content);
    FREE_PTR(msg->tool_name);
    FREE_PTR(msg->tool_id);
    FREE_PTR(msg->tool_input);
    FREE_PTR(msg->session_id);
}
