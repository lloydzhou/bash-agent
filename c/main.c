#define _POSIX_C_SOURCE 200809L
#include "agent.h"
#include "store.h"
#include "msgqueue.h"
#include "util.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// 使用说明
static void usage(void) {
    printf("Usage: cagent [options] [prompt]\n"
           "\n"
           "Options:\n"
           "  -p, --provider PROV     LLM provider: claude | openai (default: claude)\n"
           "  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)\n"
           "  --max-tokens N          Max output tokens (default: 4096)\n"
           "  --tool-timeout N        Tool execution timeout in seconds (default: 600)\n"
           "  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md\n"
           "  --max-turns N           Max agent turns (default: 40)\n"
           "  --max-context N         Max context tokens before compact (default: 200000)\n"
           "  --api-key KEY           API key (default from env)\n"
           "  --base-url URL          Override API base URL\n"
           "  --effort LEVEL          Thinking effort: low|medium|high|xhigh|max (default: high)\n"
           "  --thinking MODE         Thinking mode: adaptive|enabled|disabled (default: adaptive)\n"
           "  --output-format FMT     Output format: human | stream-json\n"
           "  --print                 Alias for --output-format stream-json\n"
           "  --session [NAME]        Use named session (persist conversation)\n"
           "  --continue              Continue most recent session\n"
           "  --list-sessions         List all saved sessions\n"
           "  -v, --verbose           Verbose mode\n"
           "  -i, --interactive       Interactive mode (REPL)\n"
           "  -h, --help              Show this help\n"
           "\n"
           "Environment:\n"
           "  ANTHROPIC_API_KEY       API key for Claude\n"
           "  OPENAI_API_KEY          API key for OpenAI\n"
           "  DEEPSEEK_API_KEY        API key for DeepSeek\n"
           "  ANTHROPIC_BASE_URL      Claude API base URL\n"
           "  OPENAI_BASE_URL         OpenAI API base URL\n"
           "  BASH_AGENT_HOME         Override base directory for session storage\n"
           "  EFFORT                  Default thinking effort\n"
           "  THINKING                Default thinking mode\n"
           "  MODEL                   Default model name\n"
           "\n"
           "Examples:\n"
           "  ./cagent \"Read /etc/hostname and tell me what it says\"\n"
           "  ./cagent -m claude-sonnet-4-20250514 \"List files in /tmp\"\n"
           "  ./cagent --session code-review \"Analyze this code\"\n"
           "  ./cagent --output-format stream-json \"Hello\" | jq -r 'select(.type==\"text\") .content'\n"
           "  echo \"prompt\" | ./cagent --print\n"
           "  ./cagent -i\n");
    exit(0);
}

// 列出会话
static void list_sessions(void) {
    store_init(NULL, false);
    
    size_t count;
    char **rows = store_session_list_rows(&count);
    
    if (count == 0) {
        printf("No sessions found.\n");
    } else {
        printf("%-40s %-16s %s\n", "NAME", "MODIFIED", "PREVIEW");
        for (size_t i = 0; i < count; i++) {
            printf("%s\n", rows[i]);
        }
    }
    
    store_session_list_free(rows, count);
    store_cleanup();
}

// 解析参数
int main(int argc, char *argv[]) {
    // 调试日志：记录到文件
    FILE *_dbg = fopen("/tmp/cagent_debug.log", "a");
    if (_dbg) { fprintf(_dbg, "=== cagent main() called, argc=%d ===\n", argc); fclose(_dbg); }
    agent_config_t config = {
        .provider = "claude",
        .model = NULL,
        .api_key = NULL,
        .base_url = NULL,
        .max_tokens = 4096,
        .tool_timeout = 600,
        .max_turns = 40,
        .max_context_tokens = 200000,
        .effort = "high",
        .thinking = "adaptive",
        .output_format = "human",
        .session_id = NULL,
        .is_continue = false,
        .verbose = false,
        .interactive = false
    };
    
    char *user_input = NULL;
    char *input_buffer = NULL;
    
    // 解析参数
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 || strcmp(argv[i], "--provider") == 0) {
            if (i + 1 < argc) config.provider = argv[++i];
        } else if (strcmp(argv[i], "-m") == 0 || strcmp(argv[i], "--model") == 0) {
            if (i + 1 < argc) config.model = argv[++i];
        } else if (strcmp(argv[i], "--max-tokens") == 0) {
            if (i + 1 < argc) config.max_tokens = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--tool-timeout") == 0) {
            if (i + 1 < argc) config.tool_timeout = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--skill") == 0) {
            if (i + 1 < argc) i++;
        } else if (strcmp(argv[i], "--max-turns") == 0) {
            if (i + 1 < argc) config.max_turns = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--max-context") == 0) {
            if (i + 1 < argc) {
                long max_context;
                if (util_parse_size(argv[++i], &max_context)) {
                    config.max_context_tokens = max_context;
                } else {
                    fprintf(stderr, "Error: Invalid max-context value: %s\n", argv[i]);
                    return 1;
                }
            }
        } else if (strcmp(argv[i], "--api-key") == 0) {
            if (i + 1 < argc) config.api_key = argv[++i];
        } else if (strcmp(argv[i], "--base-url") == 0) {
            if (i + 1 < argc) config.base_url = argv[++i];
        } else if (strcmp(argv[i], "--effort") == 0) {
            if (i + 1 < argc) config.effort = argv[++i];
        } else if (strcmp(argv[i], "--thinking") == 0) {
            if (i + 1 < argc) config.thinking = argv[++i];
        } else if (strcmp(argv[i], "--output-format") == 0) {
            if (i + 1 < argc) config.output_format = argv[++i];
        } else if (strcmp(argv[i], "--print") == 0) {
            config.output_format = "stream-json";
        } else if (strcmp(argv[i], "--session") == 0) {
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                config.session_id = argv[++i];
            } else {
                config.session_id = "default";
            }
        } else if (strcmp(argv[i], "--continue") == 0) {
            config.is_continue = true;
        } else if (strcmp(argv[i], "--list-sessions") == 0) {
            list_sessions();
            return 0;
        } else if (strcmp(argv[i], "-v") == 0 || strcmp(argv[i], "--verbose") == 0) {
            config.verbose = true;
        } else if (strcmp(argv[i], "-i") == 0 || strcmp(argv[i], "--interactive") == 0) {
            config.interactive = true;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage();
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            return 1;
        } else {
            // 非选项参数作为 prompt
            if (user_input) {
                // 多个参数用空格连接
                size_t old_len = strlen(user_input);
                size_t new_len = strlen(argv[i]);
                user_input = realloc(user_input, old_len + new_len + 2);
                if (user_input) {
                    user_input[old_len] = ' ';
                    memcpy(user_input + old_len + 1, argv[i], new_len + 1);
                }
            } else {
                user_input = strdup(argv[i]);
            }
        }
    }
    
    // 检查是否有输入（参数或 stdin）
    if (!user_input && !config.interactive && isatty(STDIN_FILENO)) {
        // 交互模式：无参数且 stdin 是终端
        config.interactive = true;
    }
    // 设置默认模型
    const char *default_model = "claude-sonnet-4-20250514";
    if (strcmp(config.provider, "openai") == 0) {
        default_model = "gpt-4o";
    }
    
    // 检查环境变量中的模型
    const char *env_model = getenv("MODEL");
    if (env_model && !config.model) {
        config.model = (char *)env_model;
    }
    
    if (!config.model) {
        config.model = (char *)default_model;
    }
    
    // 检查环境变量中的 API key
    if (!config.api_key) {
        if (strcmp(config.provider, "claude") == 0) {
            config.api_key = (char *)getenv("ANTHROPIC_API_KEY");
        } else if (strcmp(config.provider, "openai") == 0) {
            config.api_key = (char *)getenv("OPENAI_API_KEY");
        }
    }
    
    // 检查环境变量中的 base URL
    if (!config.base_url) {
        if (strcmp(config.provider, "claude") == 0) {
            config.base_url = (char *)getenv("ANTHROPIC_BASE_URL");
        } else if (strcmp(config.provider, "openai") == 0) {
            config.base_url = (char *)getenv("OPENAI_BASE_URL");
        }
    }
    
    if (!config.api_key) {
        fprintf(stderr, "Error: No API key found. Set ANTHROPIC_API_KEY or OPENAI_API_KEY.\n");
        free(user_input);
        return 1;
    }
    
    // 初始化 agent
    if (!agent_init(&config)) {
        fprintf(stderr, "Error: Failed to initialize agent\n");
        free(user_input);
        return 1;
    }
    
    mq_queue_t *input_queue = agent_get_input_queue();
    
    // 交互模式
    if (config.interactive) {
        printf("Welcome to cagent (C version)!\n");
        printf("Type your message and press Enter. Type 'exit' to quit.\n\n");
        
        char line[4096];
        while (1) {
            printf("> ");
            fflush(stdout);
            
            if (!fgets(line, sizeof(line), stdin)) {
                break;
            }
            
            // 去除换行符
            size_t len = strlen(line);
            while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
                line[--len] = '\0';
            }
            
            // 检查退出命令
            if (strcmp(line, "exit") == 0 || strcmp(line, "quit") == 0) {
                break;
            }
            
            // 跳过空行
            if (len == 0) continue;
            
            // 发送到输入队列
            mq_msg_t msg = {0};
            msg.type = MQ_USER_INPUT;
            msg.content = line;
            mq_send(input_queue, &msg);
            
            // 运行主循环
            int status = agent_main_loop();
            if (status != 0) {
                fprintf(stderr, "Error: Agent loop failed with status %d\n", status);
                break;
            }
        }
        
        printf("\nGoodbye!\n");
    } else {
        // 非交互模式
        if (!user_input) {
            // 从 stdin 读取
            size_t capacity = 4096;
            size_t length = 0;
            input_buffer = malloc(capacity);
            if (!input_buffer) {
                fprintf(stderr, "Error: Failed to allocate input buffer\n");
                agent_cleanup();
                return 1;
            }
            
            char chunk[4096];
            size_t bytes_read;
            while ((bytes_read = fread(chunk, 1, sizeof(chunk), stdin)) > 0) {
                while (length + bytes_read >= capacity) {
                    capacity *= 2;
                    input_buffer = realloc(input_buffer, capacity);
                    if (!input_buffer) {
                        fprintf(stderr, "Error: Failed to allocate input buffer\n");
                        agent_cleanup();
                        return 1;
                    }
                }
                memcpy(input_buffer + length, chunk, bytes_read);
                length += bytes_read;
            }
            input_buffer[length] = '\0';
            
            user_input = input_buffer;
        }
        
        if (!user_input || strlen(user_input) == 0) {
            fprintf(stderr, "Error: No input provided\n");
            free(input_buffer);
            agent_cleanup();
            return 1;
        }
        
        // 发送到输入队列
        mq_msg_t msg = {0};
        msg.type = MQ_USER_INPUT;
        msg.content = user_input;
        mq_send(input_queue, &msg);
        
        // 运行主循环
        int status = agent_main_loop();
        if (status != 0) {
            fprintf(stderr, "Error: Agent loop failed with status %d\n", status);
            free(input_buffer);
            agent_cleanup();
            return 1;
        }
    }
    
    // 清理
    free(input_buffer);
    free(user_input);
    agent_cleanup();
    
    return 0;
}
