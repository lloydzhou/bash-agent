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

int main(void) {
    test_continue_skips_sub_sessions();
    test_continue_rejects_only_sub_sessions();
    test_explicit_sub_session_paths_remain_available();
    return failures == 0 ? 0 : 1;
}
