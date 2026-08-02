#include "store.h"
#include "util.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int failures = 0;

static void check(int condition, const char *message) {
    if (condition) {
        printf("PASS: %s\n", message);
    } else {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

static char *make_temp_dir(const char *label) {
    char *path = NULL;
    if (asprintf(&path, "/tmp/cagent-%s-XXXXXX", label) < 0) return NULL;
    if (!mkdtemp(path)) {
        free(path);
        return NULL;
    }
    return path;
}

static void set_mtime(const char *path, time_t when) {
    struct timeval times[2] = {{when, 0}, {when, 0}};
    if (utimes(path, times) != 0) {
        perror("utimes");
        exit(1);
    }
}

static void test_continue_skips_sub_sessions(void) {
    char *home = make_temp_dir("continue-skip-sub");
    char *cwd = util_path_join(home, "project");
    util_mkdirs(cwd, 0755);
    char *key = store_session_project_key(cwd);
    char *project_dir = NULL;
    asprintf(&project_dir, "%s/.bash-agent/projects/%s", home, key);
    char *normal_dir = util_path_join(project_dir, "normal-session");
    char *sub_dir = util_path_join(project_dir, "sub_latest");
    util_mkdirs(normal_dir, 0755);
    util_mkdirs(sub_dir, 0755);
    char *normal_events = util_path_join(normal_dir, "events.jsonl");
    char *sub_events = util_path_join(sub_dir, "events.jsonl");
    util_write_file(normal_events, "{}\n");
    util_write_file(sub_events, "{}\n");
    time_t now = time(NULL);
    set_mtime(normal_events, now - 60);
    set_mtime(sub_events, now);

    char *resolved = store_session_resolve_continue(home, cwd);
    check(resolved && strcmp(resolved, "normal-session") == 0,
          "continue skips a newer sub session");

    free(resolved);
    free(sub_events);
    free(normal_events);
    free(sub_dir);
    free(normal_dir);
    free(project_dir);
    free(key);
    free(cwd);
    free(home);
}

static void test_continue_rejects_only_sub_sessions(void) {
    char *home = make_temp_dir("continue-only-sub");
    char *cwd = util_path_join(home, "project");
    util_mkdirs(cwd, 0755);
    char *key = store_session_project_key(cwd);
    char *project_dir = NULL;
    asprintf(&project_dir, "%s/.bash-agent/projects/%s", home, key);
    char *sub_dir = util_path_join(project_dir, "sub_only");
    util_mkdirs(sub_dir, 0755);

    char *resolved = store_session_resolve_continue(home, cwd);
    check(resolved == NULL, "continue finds no session when only sub sessions exist");

    free(resolved);
    free(sub_dir);
    free(project_dir);
    free(key);
    free(cwd);
    free(home);
}

static void test_explicit_sub_session_paths_remain_available(void) {
    char *home = make_temp_dir("explicit-sub");
    char *cwd = util_path_join(home, "project");
    util_mkdirs(cwd, 0755);
    SessionPaths paths = store_session_paths_for(home, cwd, "sub_manual");
    const char *name = strrchr(paths.session_dir, '/');
    check(name && strcmp(name + 1, "sub_manual") == 0,
          "explicit sub session IDs remain available");

    store_session_paths_free(&paths);
    free(cwd);
    free(home);
}

static void test_conv_long_line_survives_trim(void) {
    char *dir = make_temp_dir("conv-long-line");
    char *path = util_path_join(dir, "conversation.jsonl");
    StrBuf long_line;
    sb_init(&long_line);
    sb_append(&long_line, "{\"role\":\"user\",\"content\":\"");
    for (int i = 0; i < 70000; i++) sb_append_char(&long_line, 'x');
    sb_append(&long_line, "-long-record\"}");

    FILE *f = fopen(path, "w");
    if (!f) {
        check(0, "create long conversation fixture");
        sb_free(&long_line);
        free(path);
        rmdir(dir);
        free(dir);
        return;
    }
    fprintf(f, "{\"role\":\"user\",\"content\":\"first\"}\n");
    fprintf(f, "%s\n", long_line.data);
    fprintf(f, "{\"role\":\"assistant\",\"content\":\"last\"}\n");
    fclose(f);

    char **lines = NULL;
    int count = 0;
    int read_ok = store_conv_line_count(path, &lines, &count) == 0 && count == 3
        && strlen(lines[1]) == long_line.len
        && json_parse_root(lines[1]).error == NULL;
    check(read_ok, "read a JSONL record larger than 64 KiB as one line");
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);

    int trim_ok = store_conv_trim_tail(path, 2) == 0;
    lines = NULL;
    count = 0;
    trim_ok = trim_ok && store_conv_line_count(path, &lines, &count) == 0 && count == 2
        && strlen(lines[0]) == long_line.len
        && strstr(lines[0], "-long-record\"}") != NULL
        && json_parse_root(lines[0]).error == NULL
        && json_parse_root(lines[1]).error == NULL;
    check(trim_ok, "trim rewrites a JSONL record larger than 64 KiB without splitting it");
    for (int i = 0; i < count; i++) free(lines[i]);
    free(lines);

    sb_free(&long_line);
    unlink(path);
    free(path);
    rmdir(dir);
    free(dir);
}

int main(void) {
    test_continue_skips_sub_sessions();
    test_continue_rejects_only_sub_sessions();
    test_explicit_sub_session_paths_remain_available();
    test_conv_long_line_survives_trim();
    return failures == 0 ? 0 : 1;
}
