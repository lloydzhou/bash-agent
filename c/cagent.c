/*
 * cagent.c — C 版 bash-agent 入口
 *
 * 用法: cagent [选项] [prompt]
 *   --provider claude|openai    API 提供者 (默认: claude)
 *   --model MODEL              模型名称
 *   --api-key KEY              API 密钥
 *   --base-url URL             API 基础 URL
 *   --session ID               会话 ID
 *   --continue                 继续最近的会话
 *   --list-sessions            列出所有会话
 *   --interactive              强制交互模式
 *   --verbose                  详细日志
 *   --output human|stream-json 输出格式
 */

#include "agent.h"
#include "msgqueue.h"
#include "readline.h"
#include "display.h"
#include "store.h"
#include "util.h"
#include "linenoise.h"
#include <curl/curl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <termios.h>

static void usage(const char *prog) {
    fprintf(stderr, "Usage: %s [options] [prompt]\n", prog);
    fprintf(stderr, "Options:\n");
    fprintf(stderr, "  --provider claude|openai    API provider (default: claude)\n");
    fprintf(stderr, "  --model MODEL              Model name\n");
    fprintf(stderr, "  --api-key KEY              API key\n");
    fprintf(stderr, "  --base-url URL             API base URL\n");
    fprintf(stderr, "  --session ID               Session ID\n");
    fprintf(stderr, "  --continue                 Continue last session\n");
    fprintf(stderr, "  --fork                     When resuming, create a new forked session (use with --session or --continue)\n");
    fprintf(stderr, "  --interactive              Force interactive mode\n");
    fprintf(stderr, "  --verbose                  Verbose logging\n");
    fprintf(stderr, "  --output human|stream-json Output format\n");
    fprintf(stderr, "  -h, --help                 Show this help\n");
    fprintf(stderr, "Environment:\n");
    fprintf(stderr, "  *_API_KEY               API key (ANTHROPIC / OPENAI / DEEPSEEK auto-detected)\n");
    fprintf(stderr, "  *_BASE_URL              Override API base URL (ANTHROPIC / OPENAI)\n");
    fprintf(stderr, "  BASH_AGENT_HOME         Override session storage (default: $HOME)\n");
    fprintf(stderr, "  BASH_AGENT_BASH_MODE    Bash tool permissions (default: 0467)\n");
}

static char *g_paste_session_dir = NULL;
static void image_paste_wrapper(char **out, size_t *outlen) {
    agent_image_clipboard_paste(g_paste_session_dir, out, outlen);
}

/* 崩溃信号处理：恢复终端 raw mode 后重新发出信号以生成 core dump。
 * 仅使用 async-signal-safe 函数。 */
static void crash_handler(int sig) {
    linenoiseRestoreTerminal();
    /* 输出换行，避免终端残留 prompt 行 */
    const char msg[] = "\n\rcagent: fatal signal received, terminal restored.\n\r";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    /* 恢复默认 handler 并重新发送信号，让 OS 生成 core dump */
    signal(sig, SIG_DFL);
    raise(sig);
    _exit(128 + sig); /* 理论上不会到达 */
}

int main(int argc, char *argv[]) {
    srand((unsigned int)time(NULL) ^ (unsigned int)getpid());
    /* 默认值 */
    const char *provider = util_env("BASH_AGENT_PROVIDER", "claude");
    const char *model = NULL;
    const char *api_key = NULL;
    const char *base_url = NULL;
    const char *session_id = "";
    const char *output_fmt = "human";
    const char *max_context_str = NULL;
    const char *max_tokens_str = NULL;
    const char *max_turns_str = NULL;
    const char *effort_str = NULL;
    const char *thinking_str = NULL;
    const char *tool_timeout_str = NULL;
    int do_continue = 0;
    int do_fork = 0;
    int force_interactive = 0;
    int verbose = 0;
    int do_print = 0;
    const char *prompt = NULL;

    /* Skills */
    #define MAX_SKILLS 32
    char *skill_names[MAX_SKILLS];
    int skill_count = 0;

    /* 解析参数 */
    for (int i = 1; i < argc; i++) {
        if ((strcmp(argv[i], "-p") == 0 || strcmp(argv[i], "--provider") == 0) && i + 1 < argc) {
            provider = argv[++i];
        } else if ((strcmp(argv[i], "-m") == 0 || strcmp(argv[i], "--model") == 0) && i + 1 < argc) {
            model = argv[++i];
        } else if (strcmp(argv[i], "--api-key") == 0 && i + 1 < argc) {
            api_key = argv[++i];
        } else if (strcmp(argv[i], "--base-url") == 0 && i + 1 < argc) {
            base_url = argv[++i];
        } else if (strcmp(argv[i], "--session") == 0) {
            if (i + 1 < argc && argv[i+1][0] != '-') {
                session_id = argv[++i];
            } else {
                session_id = ""; /* auto-generate */
            }
        } else if (strcmp(argv[i], "--continue") == 0) {
            do_continue = 1;
        } else if (strcmp(argv[i], "--fork") == 0) {
            do_fork = 1;
        } else if (strcmp(argv[i], "--interactive") == 0 || strcmp(argv[i], "-i") == 0) {
            force_interactive = 1;
        } else if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0) {
            verbose = 1;
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_fmt = argv[++i];
        } else if (strcmp(argv[i], "--output-format") == 0 && i + 1 < argc) {
            output_fmt = argv[++i];
        } else if (strcmp(argv[i], "--print") == 0) {
            do_print = 1;
        } else if (strcmp(argv[i], "--skill") == 0 && i + 1 < argc) {
            if (skill_count < MAX_SKILLS) {
                skill_names[skill_count++] = argv[++i];
            }
        } else if (strcmp(argv[i], "--max-context") == 0 && i + 1 < argc) {
            max_context_str = argv[++i];
        } else if (strcmp(argv[i], "--max-tokens") == 0 && i + 1 < argc) {
            max_tokens_str = argv[++i];
        } else if (strcmp(argv[i], "--max-turns") == 0 && i + 1 < argc) {
            max_turns_str = argv[++i];
        } else if (strcmp(argv[i], "--effort") == 0 && i + 1 < argc) {
            effort_str = argv[++i];
        } else if (strcmp(argv[i], "--thinking") == 0 && i + 1 < argc) {
            thinking_str = argv[++i];
        } else if (strcmp(argv[i], "--tool-timeout") == 0 && i + 1 < argc) {
            tool_timeout_str = argv[++i];
        } else if (strcmp(argv[i], "--list-sessions") == 0) {
            char list_cwd[4096];
            getcwd(list_cwd, sizeof(list_cwd));
            const char *list_env_h = util_env("BASH_AGENT_HOME", NULL);
            const char *list_h = (list_env_h && list_env_h[0]) ? list_env_h : util_env("HOME", util_home_dir());
            StrBuf list_rows;
            sb_init(&list_rows);
            int list_count = store_session_list_rows(list_h, list_cwd, &list_rows);
            if (list_count > 0) {
                printf("%-40s %-16s %s\n", "NAME", "MODIFIED", "PREVIEW");
                fputs(list_rows.data, stdout);
            } else {
                printf("No sessions found.\n");
            }
            sb_free(&list_rows);
            return 0;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else if (argv[i][0] != '-') {
            prompt = argv[i];
        }
    }

    if (do_print) output_fmt = "stream-json";

    /* 校验 --max-context（在 API key 检查之前，与 bash 版一致） */
    if (max_context_str) {
        long val = util_parse_size(max_context_str);
        if (val <= 0) {
            fprintf(stderr, "Error: Invalid --max-context: %s\n", max_context_str);
            return 1;
        }
        /* val 合法，稍后设到 agent 上 */
    }

    /* 解析 API key */
    char *effective_api_key = NULL;
    char *effective_model = NULL;
    char *effective_base_url = NULL;

    if (strcmp(provider, "claude") == 0) {
        effective_api_key = util_strdup(api_key ? api_key : util_env("ANTHROPIC_API_KEY", ""));
        effective_base_url = util_strdup(base_url ? base_url : util_env("ANTHROPIC_BASE_URL", ""));
        effective_model = util_strdup(model ? model : (getenv("MODEL") && getenv("MODEL")[0] ? getenv("MODEL") : "claude-sonnet-4-20250514"));

        /* DeepSeek 自动检测 */
        if (!effective_api_key[0] && !effective_base_url[0]) {
            const char *ds_key = getenv("DEEPSEEK_API_KEY");
            if (ds_key && ds_key[0]) {
                free(effective_api_key);
                free(effective_base_url);
                effective_api_key = util_strdup(ds_key);
                effective_base_url = util_strdup("https://api.deepseek.com/anthropic");
                if (!model) {
                    free(effective_model);
                    effective_model = util_strdup("deepseek-v4-flash");
                }
            }
        }

        if (!effective_api_key[0] && !effective_base_url[0]) {
            fprintf(stderr, "Error: no API key. Set ANTHROPIC_API_KEY or use --api-key\n");
            return 1;
        }
    } else if (strcmp(provider, "openai") == 0) {
        effective_api_key = util_strdup(api_key ? api_key : util_env("OPENAI_API_KEY", ""));
        effective_base_url = util_strdup(base_url ? base_url : util_env("OPENAI_BASE_URL", ""));
        effective_model = util_strdup(model ? model : (getenv("MODEL") && getenv("MODEL")[0] ? getenv("MODEL") : "gpt-4o"));

        if (!effective_api_key[0] && !effective_base_url[0]) {
            fprintf(stderr, "Error: no API key. Set OPENAI_API_KEY or use --api-key\n");
            return 1;
        }
    } else {
        fprintf(stderr, "Error: unknown provider '%s' (use claude|openai)\n", provider);
        return 1;
    }

    /* 继续 session */
    char *effective_session = util_strdup(session_id);
    if ((do_continue || do_fork) && (!effective_session || !effective_session[0])) {
        char cwd_buf[4096];
        getcwd(cwd_buf, sizeof(cwd_buf));
        const char *env_h = util_env("BASH_AGENT_HOME", NULL);
        const char *h = (env_h && env_h[0]) ? env_h : util_env("HOME", util_home_dir());
        char *cont = store_session_resolve_continue(h, cwd_buf);
        if (cont) {
            free(effective_session);
            effective_session = cont;
        }
    }

    /* 获取 cwd 和 home */
    char cwd[4096];
    getcwd(cwd, sizeof(cwd));
    const char *env_home = util_env("BASH_AGENT_HOME", NULL);
    const char *home = (env_home && env_home[0]) ? env_home : util_env("HOME", util_home_dir());

    /* 判断交互模式 */
    int interactive = force_interactive ||
        (!prompt && isatty(STDIN_FILENO));

    /* 忽略 SIGPIPE：多线程中 SubAgent/bg-bash 线程的 HTTP 或 pipe 写入
     * 可能触发 SIGPIPE，默认行为是终止整个进程 */
    signal(SIGPIPE, SIG_IGN);

    /* SIGSEGV / SIGABRT handler：进程崩溃时恢复终端 raw mode，避免
     * linenoise 设置的 raw mode 残留导致终端排版错乱。
     * handler 内仅调用 async-signal-safe 函数（tcsetattr / write / _exit）。 */
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_handler;
    sa.sa_flags = SA_RESETHAND; /* 恢复默认行为，允许 core dump */
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGFPE, &sa, NULL);

    /* 初始化 curl */
    curl_global_init(CURL_GLOBAL_DEFAULT);

    /* --fork：effective_session 此时已是源 session（上方 session 解析已统一处理 resolve） */
    char *fork_source_id = NULL;
    if (do_fork) {
        fork_source_id = util_strdup(effective_session);
    }

    /* 自动生成 session_id（如果未指定或为空；fork 模式生成全新 ID） */
    if (do_fork) {
        free(effective_session);
        effective_session = session_new_id();
    } else if (!effective_session || !effective_session[0]) {
        free(effective_session);
        effective_session = session_new_id();
    }


    /* 创建消息队列 */
    MsgQueue input_queue, display_queue;
    mq_init(&input_queue);
    mq_init(&display_queue);

    store_event_set_stream_json(strcmp(output_fmt, "stream-json") == 0);

    /* --fork：先复制源 session 数据，agent_create 内部的 store_session_init 再补全 events/stats */
    if (do_fork && fork_source_id) {
        SessionPaths new_paths = store_session_paths_for(home, cwd, effective_session);
        SessionPaths src_paths = store_session_paths_for(home, cwd, fork_source_id);
        store_session_fork(&src_paths, &new_paths);
        store_session_paths_free(&new_paths);
        store_session_paths_free(&src_paths);
    }

    /* 创建 Agent */
    Agent *agent = agent_create(provider, effective_model,
                                effective_api_key, effective_base_url,
                                cwd, home, effective_session,
                                interactive,
                                skill_names, skill_count,
                                &input_queue, &display_queue);
    if (!agent) {
        fprintf(stderr, "Error: failed to create agent\n");
        return 1;
    }
    agent->verbose = verbose;
    agent->output_format = (strcmp(output_fmt, "stream-json") == 0) ? 1 : 0;

    /* 设置 CLI 参数到 agent — 支持 k/m/g 后缀 */
    {
        long v;
        if (max_tokens_str) {
            v = util_parse_size(max_tokens_str);
            if (v > 0) agent->max_tokens = (int)v;
        }
        if (max_turns_str) {
            v = util_parse_size(max_turns_str);
            if (v > 0) agent->max_turns = (int)v;
        }
        if (tool_timeout_str) {
            v = util_parse_size(tool_timeout_str);
            if (v > 0) agent->tool_timeout_secs = (int)v;
        }
        if (effort_str) { free(agent->effort); agent->effort = util_strdup(effort_str); }
        if (thinking_str) { free(agent->thinking); agent->thinking = util_strdup(thinking_str); }
    }

    /* 设置 --max-context（已在参数解析阶段校验） */
    if (max_context_str) {
        long val = util_parse_size(max_context_str);
        if (val > 0) agent->max_context_tokens = (int)val;
    }

    if (interactive) {
        /* 交互模式：启动 readline + display 线程 */
        fprintf(stderr, "\x1b[36mbash-agent interactive mode (type 'exit' or Ctrl+D to quit)\x1b[0m\n");

        /* display 线程 */
        pthread_t display_thread;
        DisplayConfig dcfg;
        dcfg.queue = &display_queue;
        dcfg.format = OUTPUT_HUMAN;
        dcfg.interactive = 1;
        display_thread_start(&display_thread, &dcfg);

        /* Replay 最近 10 轮事件（复用 display 线程渲染） */
        int replayed = 0;
        if (!agent->output_format) replayed = agent_replay_events(agent, 10);
        /* replay 后输出换行 */
        if (!agent->output_format && replayed) {
            DisplayMessage *dm = malloc(sizeof(DisplayMessage));
            *dm = display_msg_text("\n");
            mq_push(&display_queue, dm);
        }
          /* 等待 display 线程消费完所有 replay 消息，
           * 防止 readline 线程启动后进入 raw mode 与 display 线程争抢终端 */
          if (!agent->output_format) display_flush(&display_queue);
        /* 对齐 bash/Rust 版: replay 后更新终端标题 (idle) */
        agent_update_title_status(agent, "idle");


        /* readline 线程 */
        pthread_t readline_thread;
        ReadlineConfig rcfg;
        memset(&rcfg, 0, sizeof(rcfg));
        rcfg.input_queue = &input_queue;
        rcfg.interactive = 1;
        rcfg.home = home;
        /* 设置 agent 的 interrupted 和 running 指针，供 Ctrl+C 中断使用 */
        readline_set_agent_interrupted(&agent->interrupted, &agent->running);
        /* 注册图像粘贴回调（Ctrl+V） */
        
        linenoiseSetImagePasteCallback(image_paste_wrapper);
        g_paste_session_dir = agent->paths.session_dir;

        /* 注册 Ctrl+O inject callback */
        readline_set_inject_queues(agent->sub_result_queue, &input_queue);
        linenoiseSetInjectCallback(inject_callback);

        readline_thread_start(&readline_thread, &rcfg);

        /* 主循环 */
        agent_main_loop(agent);

        /* 等待线程结束 */
        /* 注意：readline 线程可能已经 close 了 input_queue（Ctrl+D/exit），
         * 也可能没有（agent 出错退出）。安全起见再 close 一次（重复 close 无害）。 */
        mq_close(&input_queue);
        pthread_join(readline_thread, NULL);
        display_thread_stop(&display_queue);
        pthread_join(display_thread, NULL);

        fprintf(stderr, "\x1b[36mGoodbye!\x1b[0m\n");
        fprintf(stderr, "\x1b[90mResume with: --session %s  or  --continue\x1b[0m\n",
                effective_session ? effective_session : "?");
    } else {
        /* 非交互模式：通过 input_queue 走 agent_main_loop（与 bash 一致） */
        pthread_t display_thread;
        DisplayConfig dcfg;
        dcfg.queue = &display_queue;
        dcfg.format = OUTPUT_HUMAN;
        dcfg.interactive = 0;
        display_thread_start(&display_thread, &dcfg);

        if (prompt) {
            InputMessage *msg = malloc(sizeof(InputMessage));
            if (msg) {
                memset(msg, 0, sizeof(*msg));
                msg->type = MSG_USER_INPUT;
                msg->data.user_input.text = util_strdup(prompt);
                mq_push(&input_queue, msg);
            }
        } else {
            /* 从 stdin 读取 */
            char linebuf[65536];
            while (fgets(linebuf, sizeof(linebuf), stdin)) {
                util_rtrim(linebuf);
                if (linebuf[0] == '\0') continue;
                InputMessage *msg = malloc(sizeof(InputMessage));
                if (!msg) break;
                memset(msg, 0, sizeof(*msg));
                msg->type = MSG_USER_INPUT;
                msg->data.user_input.text = util_strdup(linebuf);
                if (mq_push(&input_queue, msg) != 0) {
                    input_message_free(msg);
                    free(msg);
                    break;
                }
            }
        }

        agent_main_loop(agent);

        /* 主循环若因输入队列关闭而提前返回，仍须从子结果队列回收任务。
         * 否则 agent_destroy 会释放仍被 detached 工作线程使用的队列。 */
        agent_wait_for_sub_agents(agent);

        display_thread_stop(&display_queue);
        pthread_join(display_thread, NULL);
    }

    /* 清理 */
    agent_destroy(agent);
    mq_destroy(&input_queue);
    mq_destroy(&display_queue);
    free(effective_api_key);
    free(effective_model);
    free(effective_base_url);
    free(effective_session);
    free(fork_source_id);
    curl_global_cleanup();

    return 0;
}
