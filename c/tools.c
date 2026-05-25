#include "tools.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <errno.h>
#include <ctype.h>
#include <glob.h>
#include <fcntl.h>
#include <time.h>
#include <signal.h>

void tool_result_free(ToolResult *r) {
    if (!r) return;
    FREE_PTR(r->output);
}

/* 截断过长的工具结果，保留头部和尾部 */
char *tool_format_result(const char *output, int max_bytes) {
    if (!output) return util_strdup("(empty)");
    size_t len = strlen(output);
    if ((int)len <= max_bytes) return util_strdup(output);

    /* 取尾部 5 行 */
    int tail_lines = 5;
    const char *p = output + len;
    int nl_count = 0;
    while (p > output) {
        p--;
        if (*p == '\n') {
            nl_count++;
            if (nl_count >= tail_lines) { p++; break; }
        }
    }
    if (nl_count < tail_lines) p = output;
    size_t tail_len = strlen(p);

    const char *marker_fmt = "\n\n[... truncated: showing first/last portions of %zu bytes ...]\n\n";
    char marker[256];
    snprintf(marker, sizeof(marker), marker_fmt, len);
    size_t marker_len = strlen(marker);

    size_t head_len = max_bytes - marker_len - tail_len;
    if (head_len > len) head_len = len / 2;

    StrBuf buf;
    sb_init(&buf);
    sb_appendn(&buf, output, head_len);
    sb_append(&buf, marker);
    sb_append(&buf, p);
    return buf.data;
}

/* ============================================================
 * 工具实现
 * ============================================================ */

static ToolResult tool_read(const char *input_json, int max_bytes) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *path = json_get_string(jp.val, "path");
    if (!path) {
        r.output = util_strdup("Error: missing 'path' parameter");
        r.exit_code = 1;
        return r;
    }
    int offset = json_get_int(jp.val, "offset");
    int limit = json_get_int(jp.val, "limit");

    /* 读取文件 */
    char *content = util_read_file(path);
    if (!content) {
        r.output = util_strdup("Error: file not found or cannot read");
        r.exit_code = 1;
        free(path);
        return r;
    }

    /* 按行分割，添加行号 */
    StrBuf buf;
    sb_init(&buf);
    int line_num = 1;
    const char *p = content;
    int start_line = (offset > 0) ? offset : 1;
    int end_line = (limit > 0) ? start_line + limit - 1 : 0x7FFFFFFF;

    while (*p) {
        if (line_num >= start_line && line_num <= end_line) {
            const char *eol = strchr(p, '\n');
            if (!eol) eol = p + strlen(p);
            sb_appendf(&buf, "%6d  %.*s\n", line_num, (int)(eol - p), p);
        }
        /* 跳到下一行 */
        const char *eol = strchr(p, '\n');
        if (!eol) break;
        p = eol + 1;
        line_num++;
        if (line_num > end_line) break;
    }

    /* 截断由 agent_loop 中的 tool_format_result 统一处理 */

    r.output = buf.data;
    free(content);
    free(path);
    return r;
}

static ToolResult tool_write(const char *input_json) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *path = json_get_string(jp.val, "path");
    char *content = json_get_string(jp.val, "content");
    if (!path || !content) {
        r.output = util_strdup("Error: missing 'path' or 'content'");
        r.exit_code = 1;
        free(path);
        free(content);
        return r;
    }
    if (util_write_file(path, content) != 0) {
        r.output = util_strdup("Error: cannot write file");
        r.exit_code = 1;
    } else {
        /* 输出格式: OK: wrote N bytes to path */
        StrBuf buf;
        sb_init(&buf);
        long fsize = (long)strlen(content);
        sb_appendf(&buf, "OK: wrote %ld bytes to %s", fsize, path);
        r.output = buf.data;
    }
    free(path);
    free(content);
    return r;
}

static ToolResult tool_edit(const char *input_json) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *path = json_get_string(jp.val, "path");
    char *old_str = json_get_string(jp.val, "old_string");
    char *new_str = json_get_string(jp.val, "new_string");
    if (!path || !old_str || !new_str) {
        r.output = util_strdup("Error: missing parameters");
        r.exit_code = 1;
        free(path); free(old_str); free(new_str);
        return r;
    }

    char *content = util_read_file(path);
    if (!content) {
        r.output = util_strdup("Error: file not found");
        r.exit_code = 1;
        free(path); free(old_str); free(new_str);
        return r;
    }

    /* 查找 old_string */
    char *pos = strstr(content, old_str);
    if (!pos) {
        r.output = util_strdup("Error: old_string not found in file");
        r.exit_code = 1;
        free(content); free(path); free(old_str); free(new_str);
        return r;
    }

    /* 检查是否有多处匹配 */
    if (strstr(pos + 1, old_str)) {
        r.output = util_strdup("Error: old_string found multiple times, must be unique");
        r.exit_code = 1;
        free(content); free(path); free(old_str); free(new_str);
        return r;
    }

    /* 替换 */
    size_t old_len = strlen(old_str);
    size_t new_len = strlen(new_str);
    size_t prefix_len = pos - content;
    size_t suffix_len = strlen(pos + old_len);

    char *new_content = malloc(prefix_len + new_len + suffix_len + 1);
    memcpy(new_content, content, prefix_len);
    memcpy(new_content + prefix_len, new_str, new_len);
    memcpy(new_content + prefix_len + new_len, pos + old_len, suffix_len + 1);

    util_write_file(path, new_content);

    /* 生成 diff 摘要（计算 +/- 行数） */
    /* 精确计算：数 old_str 和 new_str 的行数差异 */
    int old_lines = 0, new_lines = 0;
    if (old_len > 0) { old_lines = 1; for (size_t i = 0; i < old_len; i++) if (old_str[i] == '\n') old_lines++; }
    if (new_len > 0) { new_lines = 1; for (size_t i = 0; i < new_len; i++) if (new_str[i] == '\n') new_lines++; }

    StrBuf buf;
    sb_init(&buf);
    sb_appendf(&buf, "Edit(%s) [+%d -%d lines]", path,
               new_lines > old_lines ? new_lines - old_lines : 0,
               old_lines > new_lines ? old_lines - new_lines : 0);
    r.output = buf.data;

    free(content);
    free(new_content);
    free(path);
    free(old_str);
    free(new_str);
    return r;
}

static const char *bash_deny_reason(const char *cmd) {
    if (!cmd || !*cmd) return NULL;
    /* 危险命令前缀 */
    if (strncmp(cmd, "sudo ", 5) == 0) return "blocked dangerous command prefix";
    if (strncmp(cmd, "shutdown", 8) == 0) return "blocked dangerous command prefix";
    if (strncmp(cmd, "reboot", 6) == 0) return "blocked dangerous command prefix";
    if (strncmp(cmd, "halt", 4) == 0) return "blocked dangerous command prefix";
    if (strncmp(cmd, "poweroff", 8) == 0) return "blocked dangerous command prefix";
    if (strncmp(cmd, "mkfs", 4) == 0) return "blocked dangerous command prefix";
    if (strncmp(cmd, "fdisk", 5) == 0) return "blocked dangerous command prefix";
    /* rm -rf / */
    if (strstr(cmd, "rm -rf /") || strstr(cmd, "rm -fr /"))
        return "blocked destructive root deletion pattern";
    /* find ... -delete */
    if (strstr(cmd, "find ") && strstr(cmd, " -delete"))
        return "blocked destructive find -delete pattern";
    /* fork bomb */
    if (strstr(cmd, ":(){:|:&};:"))
        return "blocked fork bomb pattern";
    return NULL;
}

static ToolResult tool_bash(const char *input_json, int timeout_secs) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *cmd = json_get_string(jp.val, "command");
    if (!cmd || !*cmd) {
        r.output = util_strdup("Error: no command provided");
        r.exit_code = 1;
        FREE_PTR(cmd);
        return r;
    }

    /* 安全策略检查 */
    const char *deny = bash_deny_reason(cmd);
    if (deny) {
        StrBuf deny_buf;
        sb_init(&deny_buf);
        sb_append(&deny_buf, "Error: command blocked by bash safety policy (");
        sb_append(&deny_buf, deny);
        sb_append(&deny_buf, ")");
        r.output = deny_buf.data;
        r.exit_code = 1;
        free(cmd);
        return r;
    }

    /* 从工具参数中获取 per-call timeout（可选） */
    int effective_timeout = timeout_secs;
    int per_call_timeout = json_get_int(jp.val, "timeout");
    if (per_call_timeout > 0) effective_timeout = per_call_timeout;

    /* 使用 fork/exec/waitpid 以支持超时 */
    int pipefd[2];
    if (pipe(pipefd) < 0) {
        r.output = util_strdup("Error: pipe failed");
        r.exit_code = 1;
        free(cmd);
        return r;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        r.output = util_strdup("Error: fork failed");
        r.exit_code = 1;
        free(cmd);
        return r;
    }

    if (pid == 0) {
        /* 子进程 */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        dup2(pipefd[1], STDERR_FILENO);
        close(pipefd[1]);
        execl("/bin/bash", "bash", "-lc", cmd, (char *)NULL);
        _exit(127);
    }

    /* 父进程 */
    close(pipefd[1]);

    /* 设置 pipe 为非阻塞 */
    int flags = fcntl(pipefd[0], F_GETFL, 0);
    fcntl(pipefd[0], F_SETFL, flags | O_NONBLOCK);

    StrBuf buf;
    sb_init(&buf);
    char linebuf[65536];
    ssize_t n;
    int timed_out = 0;
    time_t deadline = (effective_timeout > 0) ? time(NULL) + effective_timeout : 0;

    while (1) {
        n = read(pipefd[0], linebuf, sizeof(linebuf) - 1);
        if (n > 0) {
            linebuf[n] = '\0';
            sb_append(&buf, linebuf);
        } else if (n == 0) {
            /* EOF */
            break;
        } else {
            /* EAGAIN — 没有数据可读 */
            if (errno != EAGAIN && errno != EWOULDBLOCK) break;
        }

        /* 检查超时 */
        if (effective_timeout > 0 && time(NULL) >= deadline) {
            kill(pid, SIGKILL);
            timed_out = 1;
            break;
        }
        usleep(10000); /* 10ms */
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    if (timed_out) {
        char tmsg[128];
        snprintf(tmsg, sizeof(tmsg),
                 "\n[... command timed out after %d seconds ...]", effective_timeout);
        sb_append(&buf, tmsg);
        r.exit_code = 1;
    } else {
        r.exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : 1;
    }

    r.output = buf.data;
    free(cmd);
    return r;
}

static ToolResult tool_glob(const char *input_json, const char *cwd) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *pattern = json_get_string(jp.val, "pattern");
    char *path = json_get_string(jp.val, "path");
    if (!pattern) {
        r.output = util_strdup("Error: missing 'pattern'");
        r.exit_code = 1;
        free(path);
        return r;
    }

    const char *base = (path && path[0]) ? path : cwd;
    char *full_pattern = util_path_join(base, pattern);

    StrBuf buf;
    sb_init(&buf);

    glob_t gl;
    int rc = glob(full_pattern, GLOB_NOSORT, NULL, &gl);
    if (rc == 0) {
        for (size_t i = 0; i < gl.gl_pathc; i++) {
            if (i > 0) sb_append(&buf, "\n");
            sb_append(&buf, gl.gl_pathv[i]);
        }
        globfree(&gl);
    } else if (rc == GLOB_NOMATCH) {
        /* 无匹配，返回空 */
    }

    r.output = buf.data[0] ? buf.data : util_strdup("(no matches)");
    if (r.output == buf.data) {
        /* buf.data 已被使用，不要 free */
    } else {
        sb_free(&buf);
    }
    free(full_pattern);
    free(pattern);
    free(path);
    return r;
}

static ToolResult tool_grep(const char *input_json, const char *cwd) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *pattern = json_get_string(jp.val, "pattern");
    if (!pattern) {
        r.output = util_strdup("Error: missing 'pattern'");
        r.exit_code = 1;
        return r;
    }
    char *path = json_get_string(jp.val, "path");
    char *glob_pat = json_get_string(jp.val, "glob");
    int context = json_get_int(jp.val, "context");

    const char *base = (path && path[0]) ? path : cwd;

    /* 构建 ripgrep 命令 */
    StrBuf cmd;
    sb_init(&cmd);
    sb_append(&cmd, "rg --no-heading ");
    if (context > 0) sb_appendf(&cmd, "-C %d ", context);
    if (glob_pat && glob_pat[0]) sb_appendf(&cmd, "-g '%s' ", glob_pat);
    sb_append_json_string(&cmd, pattern);
    sb_append(&cmd, " ");
    sb_append_json_string(&cmd, base);
    sb_append(&cmd, " 2>&1 || true");

    /* 执行 */
    FILE *pipe = popen(cmd.data, "r");
    StrBuf buf;
    sb_init(&buf);
    if (pipe) {
        char linebuf[65536];
        while (fgets(linebuf, sizeof(linebuf), pipe)) {
            sb_append(&buf, linebuf);
        }
        pclose(pipe);
    }
    r.output = buf.data[0] ? buf.data : util_strdup("(no matches)");
    if (r.output != buf.data) sb_free(&buf);

    sb_free(&cmd);
    free(pattern);
    free(path);
    free(glob_pat);
    return r;
}

static ToolResult tool_todo_write(const char *input_json) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }

    JsonVal todos_arr = json_get(jp.val, "todos");
    if (todos_arr.type == JSON_ARRAY) {
        StrBuf buf;
        sb_init(&buf);
        int total = json_array_len(todos_arr);

        for (int i = 0; i < total; i++) {
            JsonVal item = json_array_get(todos_arr, i);
            char *content = json_get_string(item, "content");
            char *status = json_get_string(item, "status");
            int is_completed = (status && strcmp(status, "completed") == 0);

            sb_append(&buf, "- [");
            sb_append(&buf, is_completed ? "x" : " ");
            sb_append(&buf, "] ");
            sb_append(&buf, content ? content : "");
            sb_append(&buf, "\n");

            free(content);
            free(status);
        }

        /* 去掉末尾换行 */
        if (buf.len > 0 && buf.data[buf.len - 1] == '\n') {
            buf.data[buf.len - 1] = '\0';
        }

        r.output = buf.data;
    } else {
        r.output = util_strdup("OK");
    }
    return r;
}

static ToolResult tool_plan_confirm(const SessionPaths *paths) {
    ToolResult r = {NULL, 0};
    if (paths && store_plan_draft_read(paths) && store_plan_draft_read(paths)[0]) {
        char *draft = store_plan_draft_read(paths);
        store_plan_set(paths, draft);
        store_plan_draft_clear(paths);
        free(draft);
        r.output = util_strdup("Plan confirmed.");
    } else {
        r.output = util_strdup("No plan draft to confirm.");
    }
    return r;
}

static ToolResult tool_plan_clear(const SessionPaths *paths) {
    ToolResult r = {NULL, 0};
    if (paths) {
        store_plan_clear(paths);
    }
    r.output = util_strdup("Plan cleared.");
    return r;
}

static ToolResult tool_skill(const char *input_json, const char *home, const char *cwd) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *name = json_get_string(jp.val, "name");
    if (!name) {
        r.output = util_strdup("Error: missing 'name'");
        r.exit_code = 1;
        return r;
    }
    /* 搜索路径: .claude/skills/NAME/SKILL.md, skills/NAME/SKILL.md, ~/.claude/skills/NAME/SKILL.md */
    const char *search_paths[] = { ".claude/skills", "skills", NULL };
    char *content = NULL;
    for (int d = 0; search_paths[d]; d++) {
        StrBuf sp;
        sb_init(&sp);
        sb_appendf(&sp, "%s/%s/SKILL.md", search_paths[d], name);
        content = util_read_file(sp.data);
        sb_free(&sp);
        if (content) break;
    }
    if (!content) {
        StrBuf sp;
        sb_init(&sp);
        sb_appendf(&sp, "%s/.claude/skills/%s/SKILL.md", home, name);
        content = util_read_file(sp.data);
        sb_free(&sp);
    }
    if (content && content[0]) {
        StrBuf buf;
        sb_init(&buf);
        sb_appendf(&buf, "Skill: %s\n\n%s", name, content);
        r.output = buf.data;
        free(content);
    } else {
        StrBuf buf;
        sb_init(&buf);
        sb_appendf(&buf, "Skill '%s' not found", name);
        r.output = buf.data;
        r.exit_code = 1;
    }
    free(name);
    return r;
}

static ToolResult tool_web_search(const char *input_json) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *query = json_get_string(jp.val, "query");
    if (!query) {
        r.output = util_strdup("Error: missing 'query'");
        r.exit_code = 1;
        return r;
    }
    r.output = util_strdup("WebSearch not implemented in C version");
    free(query);
    return r;
}

static ToolResult tool_web_fetch(const char *input_json) {
    ToolResult r = {NULL, 0};
    r.output = util_strdup("WebFetch not implemented in C version");
    return r;
}

/* ============================================================
 * 工具调度器
 * ============================================================ */

ToolResult tool_dispatch(const char *name, const char *input_json,
                         const char *cwd, const char *home,
                         int timeout_secs, int max_bytes,
                         const SessionPaths *paths) {
    (void)home;

    if (strcmp(name, "Read") == 0) return tool_read(input_json, max_bytes);
    if (strcmp(name, "Write") == 0) return tool_write(input_json);
    if (strcmp(name, "Edit") == 0) return tool_edit(input_json);
    if (strcmp(name, "Bash") == 0) return tool_bash(input_json, timeout_secs);
    if (strcmp(name, "Glob") == 0) return tool_glob(input_json, cwd);
    if (strcmp(name, "Grep") == 0) return tool_grep(input_json, cwd);
    if (strcmp(name, "TodoWrite") == 0) return tool_todo_write(input_json);
    if (strcmp(name, "PlanConfirm") == 0) return tool_plan_confirm(paths);
    if (strcmp(name, "PlanClear") == 0) return tool_plan_clear(paths);
    if (strcmp(name, "Skill") == 0) return tool_skill(input_json, home, cwd);
    if (strcmp(name, "WebSearch") == 0) return tool_web_search(input_json);
    if (strcmp(name, "WebFetch") == 0) return tool_web_fetch(input_json);
    if (strcmp(name, "SubAgent") == 0) {
        ToolResult r;
        r.output = util_strdup("SubAgent handled by agent layer");
        r.exit_code = 0;
        return r;
    }

    ToolResult r;
    StrBuf buf;
    sb_init(&buf);
    sb_appendf(&buf, "Unknown tool: %s", name);
    r.output = buf.data;
    r.exit_code = 1;
    return r;
}

/* ============================================================
 * 工具调用摘要
 * ============================================================ */

char *tool_call_summary(const char *name, JsonVal input) {
    StrBuf buf;
    sb_init(&buf);

    /* 根据工具类型提取摘要字段 */
    char *field = NULL;
    if (strcmp(name, "Read") == 0 || strcmp(name, "Write") == 0 || strcmp(name, "Edit") == 0) {
        field = json_get_string(input, "path");
    } else if (strcmp(name, "Glob") == 0 || strcmp(name, "Grep") == 0) {
        field = json_get_string(input, "pattern");
    } else if (strcmp(name, "Bash") == 0) {
        field = json_get_string(input, "command");
    } else if (strcmp(name, "Skill") == 0) {
        field = json_get_string(input, "name");
    } else if (strcmp(name, "SubAgent") == 0) {
        field = json_get_string(input, "description");
    }

    if (field) {
        /* 截断过长的命令（UTF-8 安全） */
        int len = (int)strlen(field);
        if (len > 80) {
            int slen = (int)util_utf8_truncate_len(field, 77);
            sb_appendf(&buf, "%s(%.*s...)", name, slen, field);
        } else {
            sb_appendf(&buf, "%s(%s)", name, field);
        }
        free(field);
    } else {
        sb_append(&buf, name);
    }

    return buf.data;
}
