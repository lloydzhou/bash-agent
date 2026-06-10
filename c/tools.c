#include "tools.h"
#include "util.h"

/* When building test_classify, expose static functions */
#ifdef TEST_CLASSIFY
#define STATIC
#else
#define STATIC static
#endif

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
#include <curl/curl.h>

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
    if (!path || !path[0]) {
        r.output = util_strdup("Error: no path provided");
        r.exit_code = 1;
        return r;
    }
    int offset = json_get_int(jp.val, "offset");
    int limit = json_get_int(jp.val, "limit");

    /* 读取文件 */
    char *content = util_read_file(path);
    if (!content) {
        StrBuf buf;
        sb_init(&buf);
        sb_appendf(&buf, "Error: file not found: %s", path);
        r.output = buf.data;
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
    if (!path || !path[0]) {
        r.output = util_strdup("Error: no path provided");
        r.exit_code = 1;
        free(path);
        free(content);
        return r;
    }
    if (!content) {
        r.output = util_strdup("Error: no content provided");
        r.exit_code = 1;
        free(path);
        free(content);
        return r;
    }
    if (util_write_file(path, content) != 0) {
        r.output = util_strdup("Error: write failed");
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
    if (!path || !path[0]) {
        r.output = util_strdup("Error: no path provided");
        r.exit_code = 1;
        free(path); free(old_str); free(new_str);
        return r;
    }
    if (!old_str || !old_str[0]) {
        r.output = util_strdup("Error: empty old_string");
        r.exit_code = 1;
        free(path); free(old_str); free(new_str);
        return r;
    }
    if (!new_str) {
        r.output = util_strdup("Error: no new_string provided");
        r.exit_code = 1;
        free(path); free(old_str); free(new_str);
        return r;
    }

    char *content = util_read_file(path);
    if (!content) {
        StrBuf buf;
        sb_init(&buf);
        sb_appendf(&buf, "Error: file not found: %s", path);
        r.output = buf.data;
        r.exit_code = 1;
        free(path); free(old_str); free(new_str);
        return r;
    }

    /* 查找 old_string */
    char *pos = strstr(content, old_str);
    if (!pos) {
        StrBuf buf;
        sb_init(&buf);
        sb_appendf(&buf, "Error: old_string not found in %s. Hint: use Grep to locate the target lines, then Read the relevant portion (with offset/limit) to copy the exact text before retrying Edit.", path);
        r.output = buf.data;
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

    if (new_content[0] == '\0') {
        r.output = util_strdup("Error: edit produced empty result");
        r.exit_code = 1;
        free(content); free(new_content); free(path); free(old_str); free(new_str);
        return r;
    }

    /* 生成 diff 摘要 — 对齐 bash 版: diff -u --label a/$label --label b/$label */
    int added = 0, removed = 0;
    StrBuf diffout;
    sb_init(&diffout);
    {
        char tmppath_old[256], tmppath_new[256];
        snprintf(tmppath_old, sizeof(tmppath_old), "/tmp/edit_diff_old_%d.tmp", (int)getpid());
        snprintf(tmppath_new, sizeof(tmppath_new), "/tmp/edit_diff_new_%d.tmp", (int)getpid());
        FILE *tmpf_old = fopen(tmppath_old, "w");
        FILE *tmpf_new = fopen(tmppath_new, "w");
        if (tmpf_old && tmpf_new) {
            fputs(content, tmpf_old);
            fclose(tmpf_old);
            fputs(new_content, tmpf_new);
            fclose(tmpf_new);
            StrBuf diffcmd;
            sb_init(&diffcmd);
            const char *label = path;
            if (label[0] == '/') label++;
            sb_appendf(&diffcmd, "diff -u --color=always --label 'a/%s' --label 'b/%s' -- '%s' '%s' 2>/dev/null || true",
                       label, label, tmppath_old, tmppath_new);
            FILE *dp = popen(diffcmd.data, "r");
            if (dp) {
                char lbuf[65536];
                while (fgets(lbuf, sizeof(lbuf), dp)) {
                    const char *p = lbuf;
                    while (*p == '\x1b' && *(p+1) == '[') {
                        p += 2;
                        while (*p && !(('A' <= *p && *p <= 'Z') || ('a' <= *p && *p <= 'z'))) p++;
                        if (*p) p++;
                    }
                    if (*p == '+' && *(p+1) != '+') added++;
                    else if (*p == '-' && *(p+1) != '-') removed++;
                    sb_append(&diffout, lbuf);
                }
                pclose(dp);
            }
            sb_free(&diffcmd);
            remove(tmppath_old);
            remove(tmppath_new);
        } else {
            if (tmpf_old) fclose(tmpf_old);
            if (tmpf_new) fclose(tmpf_new);
        }
    }
    /* 统一输出（对齐 bash 版：只有一个 Success 输出点） */
    {
        StrBuf buf;
        sb_init(&buf);
        sb_appendf(&buf, "Success: Edit(%s) [+%d -%d lines]\n", path, added, removed);
        if (diffout.len > 0) {
            sb_append(&buf, diffout.data);
        }
        r.output = buf.data;
    }
    sb_free(&diffout);

    if (util_write_file(path, new_content) != 0) {
        r.output = util_strdup("Error: cannot write file");
        r.exit_code = 1;
        free(content);
        free(new_content);
        free(path);
        free(old_str);
        free(new_str);
        return r;
    }

    free(content);
    free(new_content);
    free(path);
    free(old_str);
    free(new_str);
    return r;
}

STATIC int bash_starts_with(const char *s, const char *prefix) {
    return s && prefix && strncmp(s, prefix, strlen(prefix)) == 0;
}

STATIC int bash_contains(const char *s, const char *needle) {
    return s && needle && strstr(s, needle) != NULL;
}

static void bash_mode_normalize(const char *mode, char out[5]) {
    int i;
    const char *src = (mode && *mode) ? mode : "0467";
    for (i = 0; i < 4 && src[i]; i++) {
        if (src[i] < '0' || src[i] > '7') break;
        out[i] = src[i];
    }
    if (i == 4 && src[4] == '\0') {
        out[4] = '\0';
        return;
    }
    memcpy(out, "0000", 5);
}

static char g_cwd[1024] = "";

STATIC void bash_add_mode(unsigned short *mask, int scopes, int perms) {
    if (scopes & 8) *mask |= (unsigned short)(perms << 9);
    if (scopes & 4) *mask |= (unsigned short)(perms << 6);
    if (scopes & 2) *mask |= (unsigned short)(perms << 3);
    if (scopes & 1) *mask |= (unsigned short)perms;
}

STATIC int bash_is_system_path(const char *path) {
    const char *sys[] = {"/etc", "/usr", "/bin", "/sbin", "/var", "/library", "/system", "/dev", NULL};
    for (int i = 0; sys[i]; i++) {
        size_t n = strlen(sys[i]);
        if (strncmp(path, sys[i], n) == 0 && (path[n] == '\0' || path[n] == '/')) return 1;
    }
    return 0;
}

STATIC int bash_is_sensitive_path(const char *path) {
    size_t len = strlen(path);
    return strstr(path, "/.ssh") || strstr(path, "/.gnupg") || strstr(path, "/.aws") ||
           strstr(path, "/.docker") || (len >= 4 && strcmp(path + len - 4, ".env") == 0) ||
           (len >= 4 && strcmp(path + len - 4, ".pem") == 0) || (len >= 4 && strcmp(path + len - 4, ".key") == 0) ||
           strstr(path, "token") || strstr(path, "credential") || strstr(path, "secret");
}

STATIC void bash_add_path(unsigned short *mask, const char *path, int perms) {
    char buf[1024];
    size_t len;
    int scope = 1;
    if (!path || !*path) return;
    snprintf(buf, sizeof(buf), "%s", path);
    if (buf[0] == '"' || buf[0] == '\'') memmove(buf, buf + 1, strlen(buf));
    len = strlen(buf);
    while (len > 0 && (buf[len - 1] == '"' || buf[len - 1] == '\'' || buf[len - 1] == ';' || buf[len - 1] == ',' || buf[len - 1] == ')')) buf[--len] = '\0';
    if (strncmp(buf, "of=", 3) == 0) memmove(buf, buf + 3, strlen(buf + 3) + 1);
    if (!buf[0] || strcmp(buf, "/tmp") == 0 || strncmp(buf, "/tmp/", 5) == 0 || strcmp(buf, "/dev/null") == 0 || buf[0] == '&') return;
    if (strncmp(buf, "/dev/tcp", 8) == 0) scope = 2;
    else if (bash_is_sensitive_path(buf) || bash_is_system_path(buf)) scope = 8;
    else if (g_cwd[0] != '\0' && (strcmp(buf, g_cwd) == 0 || (strncmp(buf, g_cwd, strlen(g_cwd)) == 0 && buf[strlen(g_cwd)] == '/'))) scope = 1;
    else if ((buf[0] == '/' && buf[1]) || strncmp(buf, "~/", 2) == 0 || strncmp(buf, "$home", 5) == 0 || strstr(buf, "..")) scope = 4;
    bash_add_mode(mask, scope, perms);
}

STATIC int bash_is_block_device_path(const char *path) {
    const char *dev = strstr(path, "/dev/");
    if (!dev) return 0;
    dev += 5;
    return strncmp(dev, "sd", 2) == 0 || strncmp(dev, "vd", 2) == 0 || strncmp(dev, "hd", 2) == 0 ||
           strncmp(dev, "xvd", 3) == 0 || strncmp(dev, "disk", 4) == 0 || strncmp(dev, "rdisk", 5) == 0 ||
           strncmp(dev, "nvme", 4) == 0;
}

STATIC void bash_scan_segment(unsigned short *mask, const char *seg) {
    char *copy, *save = NULL, *tok;
    int redir = 0, path_bits = 4, flags = 0;
    if (bash_starts_with(seg, "sudo ") || bash_starts_with(seg, "su ") || bash_starts_with(seg, "doas ") ||
        bash_starts_with(seg, "shutdown") || bash_starts_with(seg, "reboot") || bash_starts_with(seg, "halt") ||
        bash_starts_with(seg, "poweroff")) bash_add_mode(mask, 8, 1);
    else if (bash_starts_with(seg, "mkfs") || bash_starts_with(seg, "fdisk") || bash_starts_with(seg, "diskutil") ||
             bash_starts_with(seg, "mount ") || bash_starts_with(seg, "umount ")) bash_add_mode(mask, 8, 2);
    if (bash_contains(seg, "curl ") || bash_contains(seg, "wget ") || bash_contains(seg, "http ") ||
        bash_contains(seg, "https://") || bash_contains(seg, "http://") || bash_starts_with(seg, "git clone") ||
        bash_starts_with(seg, "git fetch") || bash_starts_with(seg, "git pull") || bash_starts_with(seg, "git ls-remote"))
        bash_add_mode(mask, 2, 4);
    if (bash_starts_with(seg, "git push") || bash_contains(seg, "scp ") || bash_contains(seg, "curl -d ") ||
        bash_contains(seg, "curl --data") || bash_contains(seg, "curl -f ") || bash_contains(seg, "curl -t "))
        bash_add_mode(mask, 2, 2);
    else if ((bash_contains(seg, "| bash") || bash_contains(seg, "| sh") || bash_contains(seg, "eval ") ||
              bash_contains(seg, "source <(") || bash_contains(seg, "bash -c $(") || bash_contains(seg, "sh -c $(")) &&
             (bash_contains(seg, "curl ") || bash_contains(seg, "wget ") || bash_contains(seg, "http://") || bash_contains(seg, "https://")))
        bash_add_mode(mask, 2, 1);
    if (bash_contains(seg, "rm -rf /") || bash_contains(seg, "rm -fr /")) bash_add_mode(mask, 8, 2);
    if (bash_is_block_device_path(seg) && (bash_contains(seg, "of=/dev/") || bash_contains(seg, "> /dev/") || bash_contains(seg, ">/dev/")))
        bash_add_mode(mask, 8, 2);
    if (bash_starts_with(seg, "./") || bash_starts_with(seg, "bash ") || bash_starts_with(seg, "sh ") || bash_starts_with(seg, "zsh ") ||
        bash_starts_with(seg, "python") || bash_starts_with(seg, "node ") || bash_starts_with(seg, "ruby ") || bash_starts_with(seg, "perl ") ||
        bash_starts_with(seg, "npm test") || bash_starts_with(seg, "npm run") || bash_starts_with(seg, "make") ||
        bash_starts_with(seg, "cargo test") || bash_starts_with(seg, "cargo build") || bash_starts_with(seg, "go test") ||
          bash_starts_with(seg, "git commit") || bash_starts_with(seg, "git add") || bash_starts_with(seg, "git checkout") ||
          bash_starts_with(seg, "git merge") || bash_starts_with(seg, "git rebase") || bash_starts_with(seg, "git stash") ||
          bash_starts_with(seg, "git cherry-pick") ||
        bash_contains(seg, "function ") || bash_contains(seg, "()") || bash_contains(seg, "{") || bash_contains(seg, " if ") ||
        bash_starts_with(seg, "if ") || bash_contains(seg, " for ") || bash_starts_with(seg, "for ") || bash_contains(seg, " while ") ||
        bash_starts_with(seg, "while ") || bash_contains(seg, " case ") || bash_starts_with(seg, "case ") || bash_contains(seg, ":(){:|:&};:"))
        bash_add_mode(mask, 1, 1);
    if (bash_contains(seg, ">") || bash_contains(seg, "tee ") || bash_starts_with(seg, "mkdir ") || bash_starts_with(seg, "touch ") ||
        bash_starts_with(seg, "cp ") || bash_starts_with(seg, "mv ") || bash_starts_with(seg, "rm ") || bash_contains(seg, " rm ") ||
        bash_contains(seg, "sed -i") || bash_contains(seg, " -delete") || bash_starts_with(seg, "git fetch") ||
        bash_starts_with(seg, "git pull") || bash_starts_with(seg, "git clone") || bash_starts_with(seg, "npm install") ||
        bash_starts_with(seg, "pnpm install") || bash_starts_with(seg, "yarn install") || bash_starts_with(seg, "cargo build") ||
          bash_starts_with(seg, "git commit") || bash_starts_with(seg, "git add") || bash_starts_with(seg, "git checkout") ||
          bash_starts_with(seg, "git merge") || bash_starts_with(seg, "git rebase") || bash_starts_with(seg, "git stash") ||
        bash_starts_with(seg, "go test") || bash_starts_with(seg, "npm test")) {
        path_bits = 6;
        flags = 1;
    }
    copy = util_strdup(seg);
    for (tok = strtok_r(copy, " \t\r\n", &save); tok; tok = strtok_r(NULL, " \t\r\n", &save)) {
        if (redir) {
            bash_add_path(mask, tok, redir);
            flags = 3;
            redir = 0;
            continue;
        }
        if (!strcmp(tok, ">") || !strcmp(tok, ">>") || !strcmp(tok, "1>") || !strcmp(tok, "1>>")) {
            redir = 2;
        } else if (!strcmp(tok, "<>")) {
            redir = 6;
        } else if (!strncmp(tok, "2>", 2)) {
        } else if (tok[0] == '>') {
            while (*tok == '>') tok++;
            bash_add_path(mask, tok, 2);
            flags = 3;
        } else if (!strncmp(tok, "<>", 2)) {
            bash_add_path(mask, tok + 2, 6);
            flags = 3;
        } else if (tok[0] == '/' || !strncmp(tok, "./", 2) || !strncmp(tok, "../", 3) || !strncmp(tok, "~/", 2)) {
            bash_add_path(mask, tok, path_bits);
            flags = 3;
        } else if (bash_is_sensitive_path(tok)) {
            bash_add_path(mask, tok, path_bits);
            flags = 3;
        }
    }
    free(copy);
    if (flags == 1 && !bash_contains(seg, "/tmp/")) bash_add_mode(mask, 1, 2);
}

STATIC void bash_classify_required_mode(const char *cmd, char out[5]) {
    char *lower, *cursor, *segment, *save = NULL;
    unsigned short mask = 0;
    size_t n;
    /* Set CWD for path classification */
    if (getcwd(g_cwd, sizeof(g_cwd) - 1)) {
        for (cursor = g_cwd; *cursor; cursor++) *cursor = (char)tolower((unsigned char)*cursor);
    } else {
        g_cwd[0] = '\0';
    }
    if (!cmd || !*cmd) {
        memcpy(out, "0000", 5);
        return;
    }
    lower = util_strdup(cmd);
    for (cursor = lower; *cursor; cursor++) *cursor = (char)tolower((unsigned char)*cursor);
    for (cursor = lower; *cursor; cursor++) {
        if (cursor[0] == '\\' && cursor[1] == '\n') { cursor[0] = ' '; cursor[1] = ' '; }
    }
    if (strstr(lower, "/dev/tcp")) bash_add_mode(&mask, 2, 6);
    for (cursor = lower; *cursor; cursor++) {
        if ((*cursor == '&' && cursor[1] == '&') || (*cursor == '|' && cursor[1] == '|')) {
            *cursor = '\n';
            cursor[1] = '\n';
        } else if (*cursor == ';') {
            *cursor = '\n';
        }
    }
    for (segment = strtok_r(lower, "\n", &save); segment; segment = strtok_r(NULL, "\n", &save)) {
        while (*segment && isspace((unsigned char)*segment)) segment++;
        n = strlen(segment);
        while (n > 0 && isspace((unsigned char)segment[n - 1])) segment[--n] = '\0';
        if (*segment) bash_scan_segment(&mask, segment);
    }
    free(lower);
    if (!mask) bash_add_mode(&mask, 1, 4);
    snprintf(out, 5, "%04o", mask);
}

static int bash_mode_allows(const char *allowed_mode, const char *required_mode) {
    char allowed[5], required[5];
    long allowed_val, required_val;
    bash_mode_normalize(allowed_mode, allowed);
    bash_mode_normalize(required_mode, required);
    allowed_val = strtol(allowed, NULL, 8);
    required_val = strtol(required, NULL, 8);
    return (required_val & (4095 ^ allowed_val)) == 0;
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
    {
        char allowed_mode[5], required_mode[5];
        bash_mode_normalize(util_env("BASH_AGENT_BASH_MODE", "0467"), allowed_mode);
        bash_classify_required_mode(cmd, required_mode);
        if (!bash_mode_allows(allowed_mode, required_mode)) {
            StrBuf deny_buf;
            sb_init(&deny_buf);
            sb_appendf(&deny_buf, "Error: command blocked by bash safety policy (required=%s allowed=%s; mode=system/external/network/workspace bits=4:read,2:write,1:execute)",
                       required_mode, allowed_mode);
            r.output = deny_buf.data;
            r.exit_code = 1;
            free(cmd);
            return r;
        }
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

    /* UTF-8 sanitize：与 bash 版 awk/sanitize_utf8.awk 对齐 */
    char *sanitized = util_sanitize_utf8(buf.data);
    free(buf.data);
    r.output = sanitized;
    free(cmd);
    return r;
}

static char *tool_take_buf_or(StrBuf *buf, const char *fallback) {
    if (buf->data && buf->data[0]) return buf->data;
    sb_free(buf);
    return util_strdup(fallback);
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
    if (!pattern || !pattern[0]) {
        r.output = util_strdup("Error: no pattern provided");
        r.exit_code = 1;
        free(path);
        return r;
    }

    const char *base = (path && path[0]) ? path : cwd;

    /* 对齐 bash 版: rg --files "$path" -g "$pattern" — 递归搜索 */
    StrBuf cmd;
    sb_init(&cmd);
    sb_append(&cmd, "rg --files ");
    sb_append_shell_arg(&cmd, base);
    sb_append(&cmd, " -g ");
    sb_append_shell_arg(&cmd, pattern);
    sb_append(&cmd, " 2>/dev/null || true");

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
    /* 去掉尾部换行 */
    if (buf.len > 0 && buf.data[buf.len - 1] == '\n') {
        buf.data[--buf.len] = '\0';
    }

    r.output = tool_take_buf_or(&buf, "");

    sb_free(&cmd);
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
    if (!pattern || !pattern[0]) {
        r.output = util_strdup("Error: no pattern provided");
        r.exit_code = 1;
        return r;
    }
    char *path = json_get_string(jp.val, "path");
    char *glob_pat = json_get_string(jp.val, "glob");
    int context = json_get_int(jp.val, "context");

    const char *base = (path && path[0]) ? path : cwd;

    /* 构建 ripgrep 命令 — 对齐 bash 版: rg -n --color never --heading [-C N] [-g GLOB] -- PATTERN PATH */
    StrBuf cmd;
    sb_init(&cmd);
    sb_append(&cmd, "rg -n --color never --heading ");
    if (context > 0) sb_appendf(&cmd, "-C %d ", context);
    if (glob_pat && glob_pat[0]) {
        sb_append(&cmd, "-g ");
        sb_append_shell_arg(&cmd, glob_pat);
        sb_append_char(&cmd, ' ');
    }
    sb_append(&cmd, "-- ");
    sb_append_shell_arg(&cmd, pattern);
    sb_append(&cmd, " ");
    sb_append_shell_arg(&cmd, base);
    sb_append(&cmd, " 2>/dev/null || true");

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
    r.output = tool_take_buf_or(&buf, "");

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
    /* 只检查 draft 是否存在，不做 mv — mv 由 agent_loop 在 compact 之后执行
     * 对齐 bash 版: agent_compact_context(plan_confirm) → store_plan_confirm(mv) */
    char *draft = paths ? store_plan_draft_read(paths) : NULL;
    if (draft && draft[0]) {
        r.output = util_strdup("Plan confirmed and locked in.");
    } else {
        r.output = util_strdup("Error: no plan draft found to confirm.");
    }
    free(draft);
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
    if (!name || !name[0]) {
        r.output = util_strdup("Error: no skill name provided");
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
        sb_appendf(&buf, "Error: skill not found: %s", name);
        r.output = buf.data;
        r.exit_code = 1;
    }
    free(name);
    return r;
}

/* HTTP GET 辅助函数 */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} WebBuf;

static size_t web_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
    WebBuf *buf = (WebBuf *)userdata;
    size_t total = size * nmemb;
    if (buf->len + total + 1 > buf->cap) {
        size_t newcap = buf->cap ? buf->cap * 2 : 4096;
        while (newcap < buf->len + total + 1) newcap *= 2;
        buf->data = realloc(buf->data, newcap);
        buf->cap = newcap;
    }
    memcpy(buf->data + buf->len, ptr, total);
    buf->len += total;
    buf->data[buf->len] = '\0';
    return total;
}

static char *web_get(const char *url, const char **headers, int header_count, long timeout_secs) {
    CURL *curl = curl_easy_init();
    if (!curl) return util_strdup("Error: curl init failed");

    WebBuf buf = {NULL, 0, 0};
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, web_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, timeout_secs);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);

    struct curl_slist *slist = NULL;
    for (int i = 0; i < header_count; i++) {
        slist = curl_slist_append(slist, headers[i]);
    }
    if (slist) curl_easy_setopt(curl, CURLOPT_HTTPHEADER, slist);

    CURLcode res = curl_easy_perform(curl);
    curl_slist_free_all(slist);

    if (res != CURLE_OK) {
        char *err = util_strdup(curl_easy_strerror(res));
        curl_easy_cleanup(curl);
        free(buf.data);
        return err;
    }

    curl_easy_cleanup(curl);
    if (!buf.data) return util_strdup("");
    return buf.data;
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
    if (!query || !query[0]) {
        r.output = util_strdup("Error: no query provided");
        r.exit_code = 1;
        return r;
    }

    /* 构建 URL: https://s.jina.ai/?q=<encoded_query> */
    StrBuf url;
    sb_init(&url);
    sb_append(&url, "https://s.jina.ai/");

    /* URL 编码 query */
    CURL *curl = curl_easy_init();
    if (curl) {
        char *encoded = curl_easy_escape(curl, query, 0);
        if (encoded) {
            sb_append(&url, "?q=");
            sb_append(&url, encoded);
            curl_free(encoded);
        }
        curl_easy_cleanup(curl);
    }

    /* 构建 headers */
    const char *api_key = getenv("JINA_API_KEY");
    const char *headers[2];
    int header_count = 0;
    char auth_header[512];
    if (api_key && api_key[0]) {
        snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", api_key);
        headers[header_count++] = auth_header;
    }
    headers[header_count++] = "X-Respond-With: no-content";

    r.output = web_get(url.data, headers, header_count, 30);
    sb_free(&url);
    free(query);
    return r;
}

static ToolResult tool_web_fetch(const char *input_json) {
    ToolResult r = {NULL, 0};
    JsonParse jp = json_parse_root(input_json);
    if (jp.error) {
        r.output = util_strdup("Error: invalid JSON");
        r.exit_code = 1;
        return r;
    }
    char *url = json_get_string(jp.val, "url");
    if (!url || !url[0]) {
        r.output = util_strdup("Error: no url provided");
        r.exit_code = 1;
        return r;
    }

    /* 构建 URL: https://r.jina.ai/<url> */
    StrBuf full_url;
    sb_init(&full_url);
    sb_append(&full_url, "https://r.jina.ai/");
    sb_append(&full_url, url);

    /* 构建 headers */
    const char *api_key = getenv("JINA_API_KEY");
    const char *headers[1];
    int header_count = 0;
    char auth_header[512];
    if (api_key && api_key[0]) {
        snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", api_key);
        headers[header_count++] = auth_header;
    }

    r.output = web_get(full_url.data, headers, header_count, 60);
    sb_free(&full_url);
    free(url);
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
        sb_appendf(&buf, "%s()", name);
    }

    return buf.data;
}
