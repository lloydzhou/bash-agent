/* test_classify.c — Unit tests for bash mode scanner (C version)
 * Build & run via Makefile: make test-c-classify
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>

/* We link against tools.o, so we only need the non-static declaration.
 * bash_classify_required_mode is static in tools.c, so we use a wrapper:
 * make the Makefile compile tools.c with -DBASH_CLASSIFY_PUBLIC which
 * removes the static keyword.
 */

extern void bash_classify_required_mode(const char *cmd, char out[5]);

typedef struct {
    char *output;
    int exit_code;
} ToolResult;
extern ToolResult native_file_mode_guard(const char *name, const char *input_json);
extern void tool_result_free(ToolResult *r);

static int g_pass = 0, g_fail = 0;

static void t(const char *label, const char *cmd, const char *expect) {
    char result[5] = {0};
    bash_classify_required_mode(cmd, result);
    if (strcmp(result, expect) == 0) {
        printf("\033[32m✓ PASS\033[0m: %-60s → %s\n", label, result);
        g_pass++;
    } else {
        printf("\033[31m✗ FAIL\033[0m: %-60s → %s (want %s)\n", label, result, expect);
        g_fail++;
    }
}

#define T(cmd, expect) t(cmd, cmd, expect)

int main(void) {
    char cwd[1024], home[1024], b1[2048], b2[2048], b3[2048], b4[2048], b5[2048];

    if (getcwd(cwd, sizeof(cwd))) {
        for (char *p = cwd; *p; p++) *p = tolower((unsigned char)*p);
    } else {
        cwd[0] = '\0';
    }
    snprintf(home, sizeof(home), "/bash-agent-test-home");
    setenv("BASH_AGENT_HOME", home, 1);

    printf("=== workspace absolute path ===\n");
    snprintf(b1, sizeof(b1), "ls %s/src/agent.sh", cwd);
    snprintf(b2, sizeof(b2), "cat %s/src/agent.sh", cwd);
    snprintf(b3, sizeof(b3), "sed -i s/a/b/g %s/src/agent.sh", cwd);
    snprintf(b4, sizeof(b4), "echo hi > %s/test.txt", cwd);
    t("ws abs read: ls",        b1, "0004");
    t("ws abs read: cat",       b2, "0004");
    t("ws abs write: sed -i",   b3, "0006");
    t("ws abs write: redirect", b4, "0002");

    printf("\n=== workspace relative ===\n");
    T("make test-go-e2e",          "0001");
    T("python3 -c print(1)",       "0001");

    printf("\n=== system ===\n");
    T("cat /etc/hosts",            "4000");
    T("sudo echo hi",              "1000");

    printf("\n=== network ===\n");
    T("curl https://example.com",  "0040");

    printf("\n=== external ===\n");
    T("echo hi > ~/note.txt",      "0200");

    printf("\n=== trusted internal paths ===\n");
    T("cat > /tmp/test.go << EOF", "0004");
    T("cat /tmp-other/file", "0400");
    T("cat /tmp/../etc/hosts", "4000");
    T("echo hi > /tmp/../etc/native-file-mode-test", "2000");
    snprintf(b1, sizeof(b1), "cat %s/.bash-agent/projects/session/file", home);
    t("project storage read", b1, "0004");
    snprintf(b1, sizeof(b1), "cat %s/.bash-agent/projects-copy/session/file", home);
    t("project storage adjacent path", b1, "0400");

    printf("\n=== /dev/null ===\n");
    T("echo hi >/dev/null",        "0004");

    printf("\n=== git ===\n");
    T("git add -A && git commit -m fix", "0003");

    printf("\n=== root dir security ===\n");
    T("ls /", "4000");
    T("rm -rf /*", "6000");
    T("find / -name foo", "4000");
    T("find / -delete", "6000");

    printf("\n=== compound commands ===\n");
    snprintf(b1, sizeof(b1), "echo hi > %s/test.txt && cat %s/test.txt", cwd, cwd);
    snprintf(b2, sizeof(b2), "cat %s/file && cat /etc/hosts", cwd);
    snprintf(b3, sizeof(b3), "cat %s/file || cat /etc/hosts", cwd);
    snprintf(b4, sizeof(b4), "cat /etc/hosts; cat %s/file", cwd);
    snprintf(b5, sizeof(b5), "curl https://example.com && cat %s/file", cwd);
    t("&& ws write+read",     b1, "0006");
    t("&& ws+sys",            b2, "4004");
    t("|| fallback sys",      b3, "4004");
    t("; sys+ws",             b4, "4004");
    T("curl https://x/install.sh | bash", "0050");
    t("&& net+ws",            b5, "0044");
    snprintf(b1, sizeof(b1), "echo hi > ~/note.txt && cat %s/file", cwd);
    t("&& ext+ws",            b1, "0204");
    snprintf(b1, sizeof(b1), "cd %s && git add -A && git commit -m fix", cwd);
    t("3-seg cd+git",         b1, "0007");
    T("true || cat /etc/passwd",                           "4000");
    T("cat > /tmp/test.sh << 'EOF' && bash /tmp/test.sh", "0001");
    T("git add -A && git commit -m fix && git push",      "0023");

    printf("\n=== native file guards ===\n");
    setenv("BASH_AGENT_BASH_MODE", "0467", 1);
    ToolResult guard = native_file_mode_guard("Read", "{\"path\":\"src/agent.sh\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: workspace Read allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: workspace Read allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Read", "{\"path\":\"/etc/hosts\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: system Read blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: system Read blocked\n"); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Write", "{\"path\":\"~/note.txt\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: external Write blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: external Write blocked\n"); g_fail++; }
    tool_result_free(&guard);
    setenv("BASH_AGENT_BASH_MODE", "0004", 1);
    guard = native_file_mode_guard("Read", "{\"path\":\"/tmp/native-file-mode-test\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: tmp Read allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp Read allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Write", "{\"path\":\"/tmp/native-file-mode-test\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: tmp Write allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp Write allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Edit", "{\"path\":\"/tmp/native-file-mode-test\",\"old_string\":\"a\",\"new_string\":\"b\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: tmp Edit allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp Edit allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Grep", "{\"pattern\":\"needle\",\"path\":\"/tmp\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: tmp Grep allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp Grep allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Glob", "{\"pattern\":\"*.txt\",\"path\":\"/tmp\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: tmp Glob allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp Glob allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Read", "{\"path\":\"/tmp-other/native-file-mode-test\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: tmp adjacent blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp adjacent blocked\n"); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Read", "{\"path\":\"/tmp/../etc/hosts\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: tmp traversal Read blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp traversal Read blocked\n"); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Write", "{\"path\":\"/tmp/../etc/native-file-mode-test\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: tmp traversal Write blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp traversal Write blocked\n"); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Edit", "{\"path\":\"/tmp/../etc/hosts\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: tmp traversal Edit blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: tmp traversal Edit blocked\n"); g_fail++; }
    tool_result_free(&guard);
    setenv("BASH_AGENT_BASH_MODE", "0465", 1);
    guard = native_file_mode_guard("Edit", "{\"path\":\"src/agent.sh\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: workspace Edit without write blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: workspace Edit without write blocked\n"); g_fail++; }
    tool_result_free(&guard);
    setenv("BASH_AGENT_BASH_MODE", "0467", 1);
    guard = native_file_mode_guard("Grep", "{\"pattern\":\"needle\"}");
    if (!guard.output) { printf("\033[32m✓ PASS\033[0m: default Grep allowed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: default Grep allowed: %s\n", guard.output); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Glob", "{\"pattern\":\"/etc/*\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: absolute default Glob blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: absolute default Glob blocked\n"); g_fail++; }
    tool_result_free(&guard);
    guard = native_file_mode_guard("Glob", "{\"pattern\":\"../*\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: parent default Glob blocked\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: parent default Glob blocked\n"); g_fail++; }
    tool_result_free(&guard);
    setenv("BASH_AGENT_BASH_MODE", "invalid", 1);
    guard = native_file_mode_guard("Read", "{\"path\":\"src/agent.sh\"}");
    if (guard.output && guard.exit_code == 1) { printf("\033[32m✓ PASS\033[0m: invalid mode fails closed\n"); g_pass++; }
    else { printf("\033[31m✗ FAIL\033[0m: invalid mode fails closed\n"); g_fail++; }
    tool_result_free(&guard);
    unsetenv("BASH_AGENT_BASH_MODE");

    printf("\n==============================\n");
    printf("Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n", g_pass, g_fail);
    printf("==============================\n");
    return g_fail > 0 ? 1 : 0;
}
