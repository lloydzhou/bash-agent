#include "store.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
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

const char *store_session_image_dir(const SessionPaths *paths) {
    static __thread char buf[1024];
    snprintf(buf, sizeof(buf), "%s/images", paths->session_dir);
    return buf;
}

int store_session_init(const SessionPaths *p, int is_new) {
    if (util_mkdirs(p->base_dir, 0755) != 0) return -1;
    if (util_mkdirs(p->session_dir, 0755) != 0) return -1;
    mkdir(store_session_image_dir(p), 0755);
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

    /* 创建 images 目录 */
    {
        char imgdir[1024];
        snprintf(imgdir, sizeof(imgdir), "%s/images", p->session_dir);
        util_mkdirs(imgdir, 0755);
    }

    return 0;
}

int store_session_fork(const SessionPaths *parent, const SessionPaths *child) {
    util_mkdirs(child->session_dir, 0755);
    char *parent_conv = util_read_file(parent->conversation);
    if (parent_conv && strlen(parent_conv) > 0) util_write_file(child->conversation, parent_conv);
    free(parent_conv);
    char *parent_summary = util_read_file(parent->summary);
    if (parent_summary && strlen(parent_summary) > 0) util_write_file(child->summary, parent_summary);
    free(parent_summary);
    char *parent_plan = util_read_file(parent->plan);
    if (parent_plan && strlen(parent_plan) > 0) util_write_file(child->plan, parent_plan);
    free(parent_plan);
    return 0;
}

int store_session_init_sub(const SessionPaths *parent_paths, const SessionPaths *sub_paths, int fork) {
    if (fork) {
        store_session_fork(parent_paths, sub_paths);
    }
    if (store_session_init(sub_paths, 1) != 0) return -1;
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
        if (entry->d_name[0] == '.' || strncmp(entry->d_name, "sub_", 4) == 0) continue;
        /* 尝试解析目录名为时间戳: YYYYMMDD-HHMMSS-XXXX */
        struct stat st;
        sb_truncate(&buf, 0);
        sb_appendf(&buf, "%s/.bash-agent/projects/%s/%s", home, key, entry->d_name);
        if (stat(buf.data, &st) != 0 || !S_ISDIR(st.st_mode)) continue;
        /* 优先用 events.jsonl 的 mtime，fallback 到目录 mtime（对齐 bash/rust） */
        time_t mtime = st.st_mtime;
        size_t base_len = buf.len;
        sb_append(&buf, "/events.jsonl");
        struct stat events_st;
        if (stat(buf.data, &events_st) == 0) {
            mtime = events_st.st_mtime;
        }
        sb_truncate(&buf, base_len);
        if (mtime > latest_time) {
            latest_time = mtime;
            free(latest_id);
            latest_id = util_strdup(entry->d_name);
        }
    }
    closedir(dir);
    sb_free(&buf);
    free(key);
    return latest_id;
}

int store_session_list_rows(const char *home, const char *cwd, StrBuf *out) {
    char *key = store_session_project_key(cwd);
    StrBuf buf;
    sb_init(&buf);
    sb_appendf(&buf, "%s/.bash-agent/projects/%s", home, key);

    struct dirent **namelist;
    int n = scandir(buf.data, &namelist, NULL, alphasort);
    if (n < 0) { sb_free(&buf); free(key); return 0; }

    /* 收集有效 session 的 name 和 mtime */
    char **names = calloc(n, sizeof(char *));
    time_t *mtimes = calloc(n, sizeof(time_t));
    int valid = 0;

    for (int i = 0; i < n; i++) {
        struct dirent *entry = namelist[i];
        if (entry->d_name[0] == '.') { free(entry); continue; }
        struct stat st;
        sb_truncate(&buf, 0);
        sb_appendf(&buf, "%s/.bash-agent/projects/%s/%s", home, key, entry->d_name);
        if (stat(buf.data, &st) != 0 || !S_ISDIR(st.st_mode)) { free(entry); continue; }
        names[valid] = util_strdup(entry->d_name);
        mtimes[valid] = st.st_mtime;
        valid++;
        free(entry);
    }
    free(namelist);

    /* 按 mtime 降序排序 */
    /* 间接排序：用索引数组 */
    int *order = calloc(valid, sizeof(int));
    for (int i = 0; i < valid; i++) order[i] = i;
    /* 简单选择排序（session 数量通常不大）—— 用 mtimes[order[i]] 比较 */
    for (int i = 0; i < valid - 1; i++) {
        for (int j = i + 1; j < valid; j++) {
            if (mtimes[order[j]] > mtimes[order[i]]) {
                int tmp = order[i]; order[i] = order[j]; order[j] = tmp;
            }
        }
    }

    int count = 0;
    for (int idx = 0; idx < valid; idx++) {
        int i = order[idx];
        struct stat st;
        sb_truncate(&buf, 0);
        sb_appendf(&buf, "%s/.bash-agent/projects/%s/%s", home, key, names[i]);
        stat(buf.data, &st);

        /* modified: 目录 mtime，格式 YYYY-MM-DD HH:MM（对齐 bash） */
        char time_buf[32];
        struct tm *tm = localtime(&st.st_mtime);
        strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M", tm);

        /* preview: 从 summary.txt 取第一行非空内容，超 60 字符截断为 57 + ... */
        char preview[1024];
        preview[0] = '\0';
        size_t base_len = buf.len;
        sb_append(&buf, "/summary.txt");
        FILE *fp = fopen(buf.data, "r");
        if (fp) {
            char line[1024];
            while (fgets(line, sizeof(line), fp)) {
                /* trim leading/trailing whitespace */
                char *start = line;
                while (*start && isspace((unsigned char)*start)) start++;
                if (*start) {
                    size_t len = strlen(start);
                    while (len > 0 && isspace((unsigned char)start[len - 1])) start[--len] = '\0';
                    strncpy(preview, start, sizeof(preview) - 1);
                    preview[sizeof(preview) - 1] = '\0';
                    break;
                }
            }
            fclose(fp);
        }
        sb_truncate(&buf, base_len);

        /* UTF-8 字符数截断（对齐 bash ${#preview} / rust chars().count()） */
        util_truncate_chars(preview, 60);

        sb_appendf(out, "%-40s %-16s %s\n", names[i], time_buf, preview);
        count++;
    }

    for (int i = 0; i < valid; i++) FREE_PTR(names[i]);
    free(names);
    free(mtimes);
    free(order);
    sb_free(&buf);
    free(key);
    return count;
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
    *out = NULL;
    *out_count = 0;

    FILE *f = fopen(path, "r");
    if (!f) return -1;

    int cap = 64;
    int count = 0;
    char **lines = malloc(cap * sizeof(char *));
    char *line = NULL;
    size_t line_cap = 0;
    ssize_t read_len;
    if (!lines) goto fail;

    /* getline 会按真实换行符扩容，不能将超长 JSONL 记录误当成多行。 */
    while ((read_len = getline(&line, &line_cap, f)) != -1) {
        /* 去除尾部换行 */
        size_t len = (size_t)read_len;
        while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r'))
            line[--len] = '\0';
        if (len == 0) continue;

        if (count >= cap) {
            int new_cap = cap * 2;
            char **new_lines = realloc(lines, new_cap * sizeof(char *));
            if (!new_lines) goto fail;
            lines = new_lines;
            cap = new_cap;
        }
        lines[count] = util_strdup(line);
        if (!lines[count]) goto fail;
        count++;
    }

    free(line);
    fclose(f);
    *out = lines;
    *out_count = count;
    return 0;

fail:
    free(line);
    fclose(f);
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);
    return -1;
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

static void stats_write_canonical(const char *path,
                                  int current_turn_count,
                                  int agent_request_count,
                                  int compact_request_count,
                                  int sub_agent_request_count,
                                  int total_input_tokens,
                                  int total_output_tokens,
                                  int total_cache_read_tokens,
                                  int total_cache_creation_tokens,
                                  int current_context_tokens,
                                  const char *last_updated) {
    StrBuf buf;
    sb_init(&buf);
    sb_appendf(&buf, "{\"current_turn_count\":%d,\"agent_request_count\":%d,"
               "\"compact_request_count\":%d,\"sub_agent_request_count\":%d,"
               "\"total_input_tokens\":%d,\"total_output_tokens\":%d,"
               "\"total_cache_read_tokens\":%d,\"total_cache_creation_tokens\":%d,"
               "\"current_context_tokens\":%d,\"last_updated\":",
               current_turn_count, agent_request_count, compact_request_count,
               sub_agent_request_count, total_input_tokens, total_output_tokens,
               total_cache_read_tokens, total_cache_creation_tokens,
               current_context_tokens);
    sb_append_json_string(&buf, last_updated ? last_updated : "");
    sb_append(&buf, "}\n");
    util_write_file(path, buf.data);
    sb_free(&buf);
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

/* 设置 stats 文件中的整数字段。
 * 读取已有字段；缺失/无效字段按 0 处理；写回标准 stats JSON。
 * 这样旧版本缺字段时，下一次正常写入会自然补齐，不做历史回算。 */
void store_stats_set_int_file(const char *path, const char *key, int value) {
    int current_turn_count = 0, agent_request_count = 0;
    int compact_request_count = 0, sub_agent_request_count = 0;
    int total_input_tokens = 0, total_output_tokens = 0;
    int total_cache_read_tokens = 0, total_cache_creation_tokens = 0;
    int current_context_tokens = 0;

    char *content = store_stats_read(path);
    if (content && content[0]) {
        JsonParse jp = json_parse_root(content);
        if (!jp.error) {
            current_turn_count = json_get_int(jp.val, "current_turn_count");
            agent_request_count = json_get_int(jp.val, "agent_request_count");
            compact_request_count = json_get_int(jp.val, "compact_request_count");
            sub_agent_request_count = json_get_int(jp.val, "sub_agent_request_count");
            total_input_tokens = json_get_int(jp.val, "total_input_tokens");
            total_output_tokens = json_get_int(jp.val, "total_output_tokens");
            total_cache_read_tokens = json_get_int(jp.val, "total_cache_read_tokens");
            total_cache_creation_tokens = json_get_int(jp.val, "total_cache_creation_tokens");
            current_context_tokens = json_get_int(jp.val, "current_context_tokens");
        }
    }

    if (strcmp(key, "current_turn_count") == 0) current_turn_count = value;
    else if (strcmp(key, "agent_request_count") == 0) agent_request_count = value;
    else if (strcmp(key, "compact_request_count") == 0) compact_request_count = value;
    else if (strcmp(key, "sub_agent_request_count") == 0) sub_agent_request_count = value;
    else if (strcmp(key, "total_input_tokens") == 0) total_input_tokens = value;
    else if (strcmp(key, "total_output_tokens") == 0) total_output_tokens = value;
    else if (strcmp(key, "total_cache_read_tokens") == 0) total_cache_read_tokens = value;
    else if (strcmp(key, "total_cache_creation_tokens") == 0) total_cache_creation_tokens = value;
    else if (strcmp(key, "current_context_tokens") == 0) current_context_tokens = value;

    time_t now = time(NULL);
    struct tm tm_buf;
    gmtime_r(&now, &tm_buf);
    char ts[32];
    strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", &tm_buf);
    stats_write_canonical(path, current_turn_count, agent_request_count,
                          compact_request_count, sub_agent_request_count,
                          total_input_tokens, total_output_tokens,
                          total_cache_read_tokens, total_cache_creation_tokens,
                          current_context_tokens, ts);
    if (content) {
        free(content);
    }
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

static _Thread_local int g_store_event_stream_json = 0;

void store_event_set_stream_json(int enabled) {
    g_store_event_stream_json = enabled ? 1 : 0;
}

int store_event_stream_json_enabled(void) {
    return g_store_event_stream_json;
}

int store_event_append(const SessionPaths *p, const char *json_str) {
    if (g_store_event_stream_json) {
        printf("%s\n", json_str);
        fflush(stdout);
    }
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
