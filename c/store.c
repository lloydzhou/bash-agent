#include "store.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>

/* ============================================================
 * SessionPaths
 * ============================================================ */

void store_session_paths_free(SessionPaths *p) {
    if (!p) return;
    FREE_PTR(p->base_dir);
    FREE_PTR(p->session_dir);
    FREE_PTR(p->conversation);
    FREE_PTR(p->events);
    FREE_PTR(p->stats);
    FREE_PTR(p->summary);
    FREE_PTR(p->plan);
    FREE_PTR(p->plan_draft);
}

char *store_session_project_key(const char *cwd) {
    /* 对齐 bash 版 AWK 算法：
     *   sub(/^\/+/, "", $0)              — 去前导 /
     *   gsub(/\//, "-", $0)              — / → -
     *   gsub(/[^A-Za-z0-9._-]/, "-", $0) — 非字母数字._- → -
     *   gsub(/-+/, "-", $0)              — 压缩连续 -
     *   sub(/^-+/, "", $0)               — 去前导 -
     *   sub(/-+$/, "", $0)               — 去尾部 -
     *   print "-" $0                      — 加 - 前缀
     */
    if (!cwd || !cwd[0]) return util_strdup("-");

    size_t len = strlen(cwd);
    char *key = malloc(len + 3); /* 足够加前缀 - */
    if (!key) return NULL;

    /* 跳过前导 / */
    const char *src = cwd;
    while (*src == '/') src++;

    /* 逐步转换 */
    size_t ki = 0;
    char prev = '\0';
    for (; *src; src++) {
        char c = *src;
        if (c == '/') c = '-';
        else if (!(  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                     (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))
            c = '-';
        /* 压缩连续 - */
        if (c == '-' && prev == '-') continue;
        key[ki++] = c;
        prev = c;
    }
    key[ki] = '\0';

    /* 去尾部 - */
    while (ki > 0 && key[ki - 1] == '-') key[--ki] = '\0';

    /* 加前缀 - */
    char *result = malloc(ki + 2);
    if (!result) { free(key); return NULL; }
    result[0] = '-';
    memcpy(result + 1, key, ki + 1);
    free(key);
    return result;
}

SessionPaths store_session_paths_for(const char *home, const char *cwd, const char *session_id) {
    SessionPaths p;
    memset(&p, 0, sizeof(p));

    char *key = store_session_project_key(cwd);
    StrBuf buf;
    sb_init(&buf);

    /* base_dir = ~/.bash-agent/projects/<key> */
    sb_appendf(&buf, "%s/.bash-agent/projects/%s", home, key);
    p.base_dir = util_strdup(buf.data);

    /* session_dir = base_dir/<session-id> */
    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/%s", p.base_dir, session_id);
    p.session_dir = util_strdup(buf.data);

    /* 各文件路径 */
    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/conversation.jsonl", p.session_dir);
    p.conversation = util_strdup(buf.data);

    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/events.jsonl", p.session_dir);
    p.events = util_strdup(buf.data);

    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/stats.json", p.session_dir);
    p.stats = util_strdup(buf.data);

    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/summary.txt", p.session_dir);
    p.summary = util_strdup(buf.data);

    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/plan.md", p.session_dir);
    p.plan = util_strdup(buf.data);

    sb_truncate(&buf, 0);
    sb_appendf(&buf, "%s/plan.draft", p.session_dir);
    p.plan_draft = util_strdup(buf.data);

    sb_free(&buf);
    free(key);
    return p;
}

/* touch 文件（如果不存在则创建） */
static int touch_file(const char *path) {
    FILE *f = fopen(path, "a");
    if (!f) return -1;
    fclose(f);
    return 0;
}

int store_session_init(const SessionPaths *p, int is_new) {
    if (util_mkdirs(p->base_dir, 0755) != 0) return -1;
    if (util_mkdirs(p->session_dir, 0755) != 0) return -1;
    touch_file(p->conversation);
    touch_file(p->events);
    touch_file(p->summary);
    touch_file(p->plan);
    touch_file(p->plan_draft);

    if (is_new) {
        /* 写入初始 stats.json */
        FILE *f = fopen(p->stats, "w");
        if (!f) return -1;
        fprintf(f, "{\"current_turn_count\":0,\"agent_request_count\":0,"
                   "\"compact_request_count\":0,\"sub_agent_request_count\":0,"
                   "\"total_input_tokens\":0,"
                   "\"total_output_tokens\":0,\"total_cache_read_tokens\":0,"
                   "\"total_cache_creation_tokens\":0,\"current_context_tokens\":0,"
                   "\"last_updated\":\"\"}\n");
        fclose(f);

        /* 写入 session_start 事件（与 bash 版对齐） */
        {
            StrBuf evt;
            sb_init(&evt);
            sb_append(&evt, "{\"type\":\"session_start\",\"session_id\":");
            /* 从 session_dir 路径提取 session_id */
            const char *sid = strrchr(p->session_dir, '/');
            sb_append_json_string(&evt, sid ? sid + 1 : "");
            sb_append_char(&evt, '}');
            store_event_append(p, evt.data);
            sb_free(&evt);
        }
    } else {
        touch_file(p->stats);
    }
    return 0;
}

int store_session_init_sub(const SessionPaths *parent_paths, const SessionPaths *sub_paths, int fork) {
    if (store_session_init(sub_paths, 1) != 0) return -1;
    if (fork) {
        /* 复制父会话文件到子会话 — 对齐 bash 版 store_session_fork:
         * cp conversation.jsonl, summary.txt, plan.md */
        char *parent_conv = util_read_file(parent_paths->conversation);
        if (parent_conv && strlen(parent_conv) > 0) {
            util_write_file(sub_paths->conversation, parent_conv);
        }
        free(parent_conv);
        char *parent_summary = util_read_file(parent_paths->summary);
        if (parent_summary && strlen(parent_summary) > 0) {
            util_write_file(sub_paths->summary, parent_summary);
        }
        free(parent_summary);
        char *parent_plan = util_read_file(parent_paths->plan);
        if (parent_plan && strlen(parent_plan) > 0) {
            util_write_file(sub_paths->plan, parent_plan);
        }
        free(parent_plan);
    }
    return 0;
}

char *session_new_id(void) {
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    unsigned short r = (unsigned short)(rand() % 0xFFFF);
    char buf[64];
    snprintf(buf, sizeof(buf), "%04d%02d%02d-%02d%02d%02d-%04x",
             t->tm_year + 1900, t->tm_mon + 1, t->tm_mday,
             t->tm_hour, t->tm_min, t->tm_sec, r);
    return util_strdup(buf);
}

char *store_session_resolve_continue(const char *home, const char *cwd) {
    char *key = store_session_project_key(cwd);
    StrBuf buf;
    sb_init(&buf);
    sb_appendf(&buf, "%s/.bash-agent/projects/%s", home, key);

    DIR *dir = opendir(buf.data);
    if (!dir) { sb_free(&buf); free(key); return NULL; }

    char *latest_id = NULL;
    long latest_time = 0;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        /* 尝试解析目录名为时间戳: YYYYMMDD-HHMMSS-XXXX */
        struct stat st;
        sb_truncate(&buf, 0);
        sb_appendf(&buf, "%s/.bash-agent/projects/%s/%s", home, key, entry->d_name);
        if (stat(buf.data, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        if (st.st_mtime > latest_time) {
            latest_time = st.st_mtime;
            free(latest_id);
            latest_id = util_strdup(entry->d_name);
        }
    }
    closedir(dir);
    sb_free(&buf);
    free(key);
    return latest_id;
}

/* ============================================================
 * conversation.jsonl 操作
 * ============================================================ */

int store_conv_add_user(const char *path, const char *content) {
    StrBuf buf;
    sb_init(&buf);
    sb_appendf(&buf, "{\"role\":\"user\",\"content\":");
    sb_append_json_string(&buf, content);
    sb_append(&buf, "}");
    int rc = jsonl_append(path, buf.data);
    sb_free(&buf);
    return rc;
}

int store_conv_add_assistant(const char *path, const char *thinking, const char *text,
                       int tool_count, const char **tool_ids,
                       const char **tool_names, const char **tool_inputs) {
    StrBuf buf;
    sb_init(&buf);
    sb_append(&buf, "{\"role\":\"assistant\",\"content\":[");

    /* thinking block */
    sb_append(&buf, "{\"type\":\"thinking\",\"thinking\":");
    sb_append_json_string(&buf, thinking ? thinking : "");
    sb_append(&buf, "}");

    /* text block */
    sb_append(&buf, ",{\"type\":\"text\",\"text\":");
    sb_append_json_string(&buf, text ? text : "");
    sb_append(&buf, "}");

    /* tool_use blocks */
    for (int i = 0; i < tool_count; i++) {
        sb_appendf(&buf, ",{\"type\":\"tool_use\",\"id\":");
        sb_append_json_string(&buf, tool_ids[i]);
        sb_append(&buf, ",\"name\":");
        sb_append_json_string(&buf, tool_names[i]);
        sb_append(&buf, ",\"input\":");
        sb_append(&buf, tool_inputs[i]); /* 已经是 JSON */
        sb_append(&buf, "}");
    }

    sb_append(&buf, "]}");
    int rc = jsonl_append(path, buf.data);
    sb_free(&buf);
    return rc;
}

int store_conv_add_tool_results(const char *path, int count, const char **tool_use_ids,
                          const char **contents) {
    StrBuf buf;
    sb_init(&buf);
    sb_append(&buf, "{\"role\":\"user\",\"content\":[");
    for (int i = 0; i < count; i++) {
        if (i > 0) sb_append(&buf, ",");
        sb_append(&buf, "{\"type\":\"tool_result\",\"tool_use_id\":");
        sb_append_json_string(&buf, tool_use_ids[i]);
        sb_append(&buf, ",\"content\":");
        sb_append_json_string(&buf, contents[i]);
        sb_append(&buf, "}");
    }
    sb_append(&buf, "]}");
    int rc = jsonl_append(path, buf.data);
    sb_free(&buf);
    return rc;
}

int store_conv_line_count(const char *path, char ***out, int *out_count) {
    FILE *f = fopen(path, "r");
    if (!f) { *out = NULL; *out_count = 0; return -1; }

    int cap = 64;
    int count = 0;
    char **lines = malloc(cap * sizeof(char*));
    char linebuf[65536];

    while (fgets(linebuf, sizeof(linebuf), f)) {
        /* 去除尾部换行 */
        size_t len = strlen(linebuf);
        while (len > 0 && (linebuf[len-1] == '\n' || linebuf[len-1] == '\r'))
            linebuf[--len] = '\0';
        if (len == 0) continue;

        if (count >= cap) {
            cap *= 2;
            lines = realloc(lines, cap * sizeof(char*));
        }
        lines[count++] = util_strdup(linebuf);
    }
    fclose(f);
    *out = lines;
    *out_count = count;
    return 0;
}

int store_conv_trim_tail(const char *path, int keep_lines) {
    char **lines = NULL;
    int count = 0;
    if (store_conv_line_count(path, &lines, &count) != 0) return -1;
    if (keep_lines >= count) {
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return 0;
    }

    /* 重写文件，只保留最后 keep_lines 行 */
    FILE *f = fopen(path, "w");
    if (!f) {
        for (int i = 0; i < count; i++) free(lines[i]);
        free(lines);
        return -1;
    }
    int start = count - keep_lines;
    for (int i = start; i < count; i++) {
        fprintf(f, "%s\n", lines[i]);
    }
    fclose(f);
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return 0;
}

int store_conv_user_turn_count(const char *path) {
    char **lines = NULL;
    int count = 0;
    if (store_conv_line_count(path, &lines, &count) != 0) return 0;
    int user_count = 0;
    for (int i = 0; i < count; i++) {
        JsonParse jp = json_parse_root(lines[i]);
        if (jp.error) continue;
        char *role = json_get_string(jp.val, "role");
        if (role && strcmp(role, "user") == 0) {
            JsonVal content = json_get(jp.val, "content");
            if (content.type == JSON_STRING) {
                user_count++;
            }
        }
        free(role);
    }
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return user_count;
}

long store_conv_total_bytes(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    return sz;
}

/* ============================================================
 * stats.json 操作
 * ============================================================ */

char *store_stats_read(const char *path) {
    return util_read_file(path);
}

void store_stats_add_int(JsonVal obj, const char *key, int delta) {
    int cur = store_stats_get_int(obj, key);
    store_stats_set_int(obj, key, cur + delta);
}

void store_stats_set_int(JsonVal obj, const char *key, int value) {
    /* 原地修改 JSON 源字符串中的数字值。
     * 仅在 store_stats_update 的回调中使用。
     * 新数字位数 <= 旧数字位数时直接覆写，多余位用空格填充。
     * 新数字位数 > 旧数字位数时无法原地修改，跳过。 */
    if (!obj.src) return;
    /* 在源文本中找到 "key":<number> 模式 */
    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", key);
    const char *p = strstr(obj.src, search);
    if (!p) return;
    p += strlen(search);
    /* 跳过空白和冒号 */
    while (*p == ' ' || *p == ':') p++;
    /* p 现在指向值的开始 */
    const char *val_start = p;
    /* 找到值的结束（逗号、}或空白） */
    while (*p && *p != ',' && *p != '}' && *p != ' ' && *p != '\n' && *p != '\r') p++;
    int old_len = (int)(p - val_start);
    char new_val[32];
    snprintf(new_val, sizeof(new_val), "%d", value);
    int new_len = (int)strlen(new_val);
    if (new_len > old_len) return; /* 无法原地扩展 */
    memcpy((char*)val_start, new_val, new_len);
    /* 用空格填充多余位置 */
    for (int i = new_len; i < old_len; i++) ((char*)val_start)[i] = ' ';
}

int store_stats_get_int(JsonVal obj, const char *key) {
    return json_get_int(obj, key);
}

/* 简易文件级操作：从 stats 文件中读取整数字段 */
int store_stats_get_file_int(const char *path, const char *key) {
    char *content = store_stats_read(path);
    if (!content) return 0;
    JsonParse jp = json_parse_root(content);
    int val = jp.error ? 0 : json_get_int(jp.val, key);
    free(content);
    return val;
}

/* 简易文件级操作：设置 stats 文件中的整数字段（原地修改 JSON 数字值） */
/* 设置 stats 文件中的整数字段。
 * 由于原地覆盖在值变长时会失败（如 0→13），改用解析→修改→重建策略。
 * 同时更新 last_updated 字段 — 对齐 bash 版 stats.awk _now() */
void store_stats_set_int_file(const char *path, const char *key, int value) {
    char *content = store_stats_read(path);
    if (!content) return;
    JsonParse jp = json_parse_root(content);
    if (!jp.error) {
        /* 先更新 last_updated */
        {
            time_t now = time(NULL);
            struct tm tm_buf;
            gmtime_r(&now, &tm_buf);
            char ts[32];
            strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
            /* 查找并替换 last_updated 值 */
            const char *lu_search = "\"last_updated\":\"";
            char *lu_pos = strstr((char*)content, lu_search);
            if (lu_pos) {
                char *val_start = lu_pos + strlen(lu_search);
                char *val_end = strchr(val_start, '"');
                if (val_end) {
                    size_t old_len = val_end - val_start;
                    size_t new_len = strlen(ts);
                    if (new_len == old_len) {
                        memcpy(val_start, ts, new_len);
                    } else {
                        /* 长度不同，重建 */
                        StrBuf rebuilt;
                        sb_init(&rebuilt);
                        sb_appendn(&rebuilt, content, val_start - content);
                        sb_append(&rebuilt, ts);
                        sb_append(&rebuilt, val_end);
                        util_write_file(path, rebuilt.data);
                        sb_free(&rebuilt);
                        free(content);
                        /* 重新读取以更新 key */
                        content = store_stats_read(path);
                        if (!content) return;
                        jp = json_parse_root(content);
                        if (jp.error) { free(content); return; }
                    }
                }
            }
        }
        /* 再更新目标 key */
        {
            char search[128];
            snprintf(search, sizeof(search), "\"%s\"", key);
            char *p = strstr((char*)jp.val.src, search);
            if (p) {
                p += strlen(search);
                while (*p == ' ' || *p == ':') p++;
                char *vs = p;
                while (*p && *p != ',' && *p != '}' && *p != ' ' && *p != '\n' && *p != '\r') p++;
                int old_len = (int)(p - vs);
                char nv[32];
                snprintf(nv, sizeof(nv), "%d", value);
                int nl = (int)strlen(nv);

                if (nl <= old_len) {
                    /* 原地覆盖，用空格填充多余空间 */
                    memcpy(vs, nv, nl);
                    for (int i = nl; i < old_len; i++) vs[i] = ' ';
                    util_write_file(path, content);
                } else {
                    /* 值变长：切分拼接，重建 JSON 文件 */
                    int prefix_len = (int)(vs - content);
                    int suffix_start = (int)(p - content);
                    StrBuf rebuilt;
                    sb_init(&rebuilt);
                    sb_appendn(&rebuilt, content, prefix_len);
                    sb_append(&rebuilt, nv);
                    sb_append(&rebuilt, content + suffix_start);
                    util_write_file(path, rebuilt.data);
                    sb_free(&rebuilt);
                }
            }
        }
    }
    free(content);
}

/* 通用 stats 更新：读取→修改→写回 */
int store_stats_update(const char *path, stats_update_fn fn, void *ctx) {
    char *content = util_read_file(path);
    if (!content) return -1;

    JsonParse jp = json_parse_root(content);
    if (jp.error) { free(content); return -1; }

    /* 调用回调修改（我们用 StrBuf 重新序列化整个对象） */
    fn(ctx, jp.val);

    /* 重新序列化 */
    StrBuf buf;
    sb_init(&buf);
    sb_append_char(&buf, '{');
    JsonObjectIter it;
    json_obj_iter_init(&it, jp.val);
    int first = 1;
    while (json_obj_iter_next(&it)) {
        if (!first) sb_append(&buf, ",");
        first = 0;
        sb_append_json_string(&buf, it.key);
        sb_append_char(&buf, ':');
        /* 值直接取原始文本 */
        size_t vlen = it.val.end - it.val.start;
        sb_appendn(&buf, jp.val.src + it.val.start, vlen);
    }
    sb_append_char(&buf, '}');
    sb_append_char(&buf, '\n');

    int rc = util_write_file(path, buf.data);
    sb_free(&buf);
    free(content);
    return rc;
}

/* ============================================================
 * events.jsonl 操作
 * ============================================================ */

int store_event_append(const SessionPaths *p, const char *json_str) {
    return jsonl_append(p->events, json_str);
}

int store_event_lines(const SessionPaths *p, char ***out, int *out_count) {
    return store_conv_line_count(p->events, out, out_count);
}

/* ============================================================
 * summary / plan 文件操作
 * ============================================================ */

char *store_summary_get(const SessionPaths *p) {
    char *s = util_read_file(p->summary);
    if (s) {
        size_t len = strlen(s);
        while (len > 0 && (s[len-1] == '\n' || s[len-1] == '\r'))
            s[--len] = '\0';
        if (len == 0) { free(s); return NULL; }
    }
    return s;
}

int store_summary_set(const SessionPaths *p, const char *content) {
    return util_write_file(p->summary, content);
}

char *store_plan_draft_read(const SessionPaths *p) {
    return util_read_file(p->plan_draft);
}

int store_plan_draft_set(const SessionPaths *p, const char *content) {
    return util_write_file(p->plan_draft, content);
}

int store_plan_draft_clear(const SessionPaths *p) {
    return util_write_file(p->plan_draft, "");
}

int store_plan_set(const SessionPaths *p, const char *content) {
    return util_write_file(p->plan, content);
}

int store_plan_clear(const SessionPaths *p) {
    return util_write_file(p->plan, "");
}
