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

DisplayMessage display_msg_sub_agent_result(const char *session_id, const char *status, const char *summary) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_SUB_AGENT_RESULT;
    m.session_id = util_strdup(session_id);
    m.content = util_strdup(summary);
    m.tool_exit_code = (strcmp(status, "ok") == 0) ? 0 : 1;
    return m;
}

DisplayMessage display_msg_context_update(int dropped, int kept) {
    DisplayMessage m;
    memset(&m, 0, sizeof(m));
    m.type = DISPLAY_CONTEXT_UPDATE;
    /* in_tokens 复用为 dropped，out_tokens 复用为 kept */
    m.in_tokens = dropped;
    m.out_tokens = kept;
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
