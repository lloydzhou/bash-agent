package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	agent "github.com/lloyd/claude-code/bash-agent/go2"
	"github.com/lloyd/claude-code/bash-agent/go2/linenoise"
)

func main() {
	// Crash recovery: linenoise readline runs the terminal in raw mode.
	// A panic or fatal signal (e.g. NULL deref in cgo) would leave the
	// terminal in raw mode — no echo, no newline processing. These handlers
	// restore the terminal before the process dies.
	defer func() {
		if r := recover(); r != nil {
			linenoise.RestoreTerminal()
			fmt.Fprintf(os.Stderr, "\ngoagent panic: %v\n", r)
			os.Exit(1)
		}
	}()
	crashSigCh := make(chan os.Signal, 1)
	signal.Notify(crashSigCh, syscall.SIGSEGV, syscall.SIGABRT, syscall.SIGBUS, syscall.SIGFPE)
	go func() {
		sig := <-crashSigCh
		linenoise.RestoreTerminal()
		signal.Reset(sig)
		p, _ := os.FindProcess(os.Getpid())
		_ = p.Signal(sig.(syscall.Signal))
		os.Exit(1)
	}()

	// 参数定义
	var (
		provider     string
		model        string
		maxTokens    string
		toolTimeout  int
		skills       stringSlice
		maxTurns     int
		maxContext   string
		apiKey       string
		baseURL      string
		outputFormat string
		printMode    bool
		session      string
		cont         bool
		fork         bool
		listSessions bool
		verbose      bool
		interactive  bool
		effort       string
		thinking     string
	)

	flag.StringVar(&provider, "provider", "claude", "LLM provider: claude | openai")
	flag.StringVar(&provider, "p", "claude", "LLM provider (shorthand)")
	flag.StringVar(&model, "model", "", "Model name")
	flag.StringVar(&model, "m", "", "Model name (shorthand)")
	flag.StringVar(&maxTokens, "max-tokens", "16384", "Max output tokens")
	flag.IntVar(&toolTimeout, "tool-timeout", 600, "Tool execution timeout in seconds")
	flag.Var(&skills, "skill", "Load a skill (repeatable)")
	flag.IntVar(&maxTurns, "max-turns", 1000, "Max agent turns")
	flag.StringVar(&maxContext, "max-context", "200000", "Max context tokens before compact")
	flag.StringVar(&apiKey, "api-key", "", "API key (default from env)")
	flag.StringVar(&baseURL, "base-url", "", "Override API base URL")
	flag.StringVar(&outputFormat, "output-format", "human", "Output format: human | stream-json")
	flag.BoolVar(&printMode, "print", false, "Alias for --output-format stream-json")
	flag.StringVar(&effort, "effort", "", "Thinking effort: low|medium|high|xhigh|max")
	flag.StringVar(&thinking, "thinking", "", "Thinking mode: adaptive|enabled|disabled")
	flag.StringVar(&session, "session", "", "Use named session")
	flag.BoolVar(&cont, "continue", false, "Continue most recent session")
	flag.BoolVar(&fork, "fork", false, "When resuming, create a new forked session instead of reusing the source (use with --session <id> or --continue)")
	flag.BoolVar(&listSessions, "list-sessions", false, "List all saved sessions")
	flag.BoolVar(&verbose, "verbose", false, "Verbose mode")
	flag.BoolVar(&verbose, "v", false, "Verbose mode (shorthand)")
	flag.BoolVar(&interactive, "interactive", false, "Interactive mode (REPL)")
	flag.BoolVar(&interactive, "i", false, "Interactive mode (shorthand)")

	flag.Usage = func() {
		fmt.Fprint(os.Stderr, `Usage: goagent [options] [prompt]

Options:
`)
		flag.PrintDefaults()
		fmt.Fprint(os.Stderr, `
Environment:
  *_API_KEY               API key (ANTHROPIC / OPENAI / DEEPSEEK auto-detected)
  *_BASE_URL              Override API base URL (ANTHROPIC / OPENAI)
  BASH_AGENT_HOME         Override session storage (default: $HOME)
  BASH_AGENT_BASH_MODE    Bash and local file tool permissions (default: 0467)

Examples:
  goagent "Read /etc/hostname and tell me what it says"
  goagent --continue "What did we discuss?"
  goagent --fork --continue "Branch off the last session"
  goagent -i
`)
	}

	if err := flag.CommandLine.Parse(normalizeSessionArgs(os.Args[1:])); err != nil {
		os.Exit(2)
	}

	// 收集位置参数作为 prompt
	userInput := strings.Join(flag.Args(), " ")

	// --print → stream-json
	if printMode {
		outputFormat = "stream-json"
	}

	// 构建配置
	cfg := agent.DefaultConfig()
	cfg.Provider = provider
	cfg.Verbose = verbose
	cfg.Interactive = interactive
	cfg.OutputFormat = outputFormat
	cfg.ToolTimeoutSecs = toolTimeout
	cfg.MaxTurns = maxTurns
	cfg.SkillNames = []string(skills)
	applyThinkingOptions(&cfg, thinking, effort)

	// 解析 size 参数
	if mt, err := agent.UtilParseSize(maxTokens); err == nil {
		cfg.MaxTokens = mt
	}
	if mc, err := agent.UtilParseSize(maxContext); err != nil {
		fmt.Fprintf(os.Stderr, "Error: --max-context: %v\n", err)
		os.Exit(1)
	} else {
		cfg.MaxContextTokens = mc
	}

	// API key 和 model
	if apiKey != "" {
		cfg.APIKey = apiKey
	}
	if baseURL != "" {
		cfg.BaseURL = baseURL
	}
	if model != "" {
		cfg.Model = model
	}

	// 先解析当前 provider 的显式参数和环境变量；DeepSeek 回退后才设置模型与传输配置。
	switch cfg.Provider {
	case "claude":
		if cfg.APIKey == "" {
			cfg.APIKey = os.Getenv("ANTHROPIC_API_KEY")
		}
		if cfg.BaseURL == "" {
			cfg.BaseURL = os.Getenv("ANTHROPIC_BASE_URL")
		}
	case "openai":
		if cfg.APIKey == "" {
			cfg.APIKey = os.Getenv("OPENAI_API_KEY")
		}
		if cfg.BaseURL == "" {
			cfg.BaseURL = os.Getenv("OPENAI_BASE_URL")
		}
	default:
		fmt.Fprintf(os.Stderr, "Unknown provider: %s (use claude|openai)\n", cfg.Provider)
		os.Exit(1)
	}

	// 仅当前 provider 没有显式配置时，自动回退至 DeepSeek。
	if cfg.APIKey == "" && cfg.BaseURL == "" && os.Getenv("DEEPSEEK_API_KEY") != "" {
		cfg.Provider = "claude"
		cfg.APIKey = os.Getenv("DEEPSEEK_API_KEY")
		cfg.BaseURL = "https://api.deepseek.com/anthropic"
		if cfg.Model == "" {
			cfg.Model = "deepseek-v4-flash"
		}
	}

	if cfg.Model == "" {
		if cfg.Provider == "openai" {
			cfg.Model = "gpt-4o"
		} else {
			cfg.Model = "claude-sonnet-4-20250514"
		}
	}

	// 创建组件
	home := os.Getenv("BASH_AGENT_HOME")
	if home == "" {
		home = os.Getenv("HOME")
	}
	cwd, _ := os.Getwd()
	store := agent.NewFileStore(home, cwd)

	// --list-sessions 不需要 API key（对齐 bash/rust/c）
	if listSessions {
		listAllSessions(store)
		return
	}

	// API key 校验
	if cfg.APIKey == "" && cfg.BaseURL == "" {
		fmt.Fprintf(os.Stderr, "No API key. Set %s_API_KEY or use --api-key\n", strings.ToUpper(provider))
		os.Exit(1)
	}

	display := agent.NewTermDisplay()
	if cfg.OutputFormat == "stream-json" {
		display.SetSilent(true)
	}
	llm := agent.NewHTTPTransport(cfg)
	tools := agent.NewToolDispatcher(cfg)

	// 创建 agent
	a := agent.NewAgent(cfg, store, llm, tools, display)
	defer a.CloseDisplay()

	// 加载工具定义（编译时嵌入的 tools.json）
	a.SetToolDefs(agent.UtilLoadToolDefs())

	// Session 管理：--fork 和 --continue 无 --session 时统一回退到最新 session
	sessionID := session
	if sessionID == "" && (fork || cont) {
		if id, err := store.ResolveContinue(); err == nil && id != "" {
			sessionID = id
		}
	}
	if sessionID == "" {
		sessionID = agent.UtilNewSessionID()
	}

	// 初始化 session
	// --fork：sessionID 此时已是源 session，生成新 ID 后先 Fork 复制再 Init 补全。
	if fork {
		sourceDir := filepath.Join(store.GetDir(), sessionID)
		sessionID = agent.UtilNewSessionID()
		store.Fork(sourceDir, filepath.Join(store.GetDir(), sessionID))
		store.Init(sessionID)
	} else if err := store.Init(sessionID); err != nil {
		fmt.Fprintf(os.Stderr, "Error: init session: %v\n", err)
		os.Exit(1)
	}

	// 设置标题
	display.SetTitle(store.FormatTitle(cfg.Model, "idle"))

	// 运行
	ctx := context.Background()

	if interactive {
		runInteractive(ctx, a, store, display, home, cfg.Model, userInput)
	} else if userInput != "" {
		if err := a.RunLoop(ctx, userInput, "user_input"); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	} else {
		stat, _ := os.Stdin.Stat()
		if (stat.Mode() & os.ModeCharDevice) == 0 {
			// 管道输入
			buf := make([]byte, 64*1024)
			n, _ := os.Stdin.Read(buf)
			userInput = strings.TrimSpace(string(buf[:n]))
			if err := a.RunLoop(ctx, userInput, "user_input"); err != nil {
				fmt.Fprintf(os.Stderr, "Error: %v\n", err)
				os.Exit(1)
			}
		} else {
			// 无 prompt 且 stdin 是终端 → 自动进入交互模式（与 bash 版一致）
			interactive = true
			cfg.Interactive = true
			runInteractive(ctx, a, store, display, home, cfg.Model, userInput)
		}
	}
}

// runInteractive 交互模式（使用 linenoise Hide/Show 架构）
func runInteractive(ctx context.Context, a *agent.Agent, store agent.SessionStore, display *agent.TermDisplay, home, model, initialInput string) {
	fmt.Println("\033[36mbash-agent interactive mode (type 'exit' or Ctrl+D to quit)\033[0m")

	// Replay 最近 10 个用户轮次（与 bash 版一致）
	replayEvents(a, store, display, 10)

	// 更新终端标题
	display.SetTitle(store.FormatTitle(model, "idle"))

	// 如果有初始输入，先执行
	if initialInput != "" {
		if err := a.RunLoop(ctx, initialInput, "user_input"); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		a.FlushDisplay()
	}

	// 启动 readline goroutine
	rl := NewReadline(home)
	rl.SetImagePasteCallback(a.ImagePasteCallback)
	rl.SetInterruptCallback(a.Interrupt)
	rl.SetInjectCallback(func(text string) {
		a.EnqueueUserNotify(text)
		rl.SendNotifyWakeup()
	})
	rl.Start()

	// 主循环：从 readline goroutine 接收输入，交给 agent 处理
	for input := range rl.Input() {
		turnKind := "user_input"
		if input == notifyWakeupInput {
			input = ""
			turnKind = "notify"
		}
		if err := a.RunLoop(ctx, input, turnKind); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		}
		a.FlushDisplay()
		// 不再调用 rl.Done() — readline goroutine 立即开始下一轮 EditStart
	}

	fmt.Printf("\033[36mGoodbye!\033[0m\n\033[90mResume with: --session %s  or  --continue\033[0m\n", store.SessionID())
}

// replayEvents 回放最近几个轮次的事件到终端
func replayEvents(a *agent.Agent, store agent.SessionStore, display *agent.TermDisplay, maxTurns int) {
	lines := store.GetRecentEvents(maxTurns)
	if len(lines) == 0 {
		return
	}

	for _, line := range lines {
		var ev map[string]interface{}
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		typ, _ := ev["type"].(string)

		switch typ {
		case "session_start", "usage", "sub_agent_start", "sub_agent_end", "context_update":
			continue
		case "user_input":
			content, _ := ev["content"].(string)
			if content != "" {
				display.ShowEvent(agent.Event{Type: agent.EventUserMessage, Fields: []string{"USER_INPUT", content}})
			}
		case "text":
			content, _ := ev["content"].(string)
			if content != "" {
				display.ShowEvent(agent.Event{Type: agent.EventText, Fields: []string{"TEXT", content}})
			}
		case "thinking":
			content, _ := ev["content"].(string)
			if content != "" {
				display.ShowEvent(agent.Event{Type: agent.EventThinking, Fields: []string{"THINKING", content}})
			}
		case "tool_call":
			name, _ := ev["name"].(string)
			id, _ := ev["id"].(string)
			input := "{}"
			if inp, ok := ev["input"]; ok {
				b, _ := json.Marshal(inp)
				if len(b) > 0 {
					input = string(b)
				}
			}
			display.ShowEvent(agent.Event{Type: agent.EventToolCall, Fields: []string{"TOOL_CALL", name, id, input, name}})
		case "tool_result":
			content, _ := ev["content"].(string)
			toolUseID, _ := ev["tool_use_id"].(string)
			name, _ := ev["name"].(string)
			// 截断长内容（replay 时避免刷屏，与 bash 版一致）
			if len(content) > 200 {
				content = content[:200] + "..."
			}
			display.ShowEvent(agent.Event{Type: agent.EventToolResult, Fields: []string{"TOOL_RESULT", toolUseID, name, content}})
		case "sub_agent_result":
			sid, _ := ev["session_id"].(string)
			status, _ := ev["status"].(string)
			in := "0"
			out := "0"
			if v, ok := ev["input_tokens"]; ok {
				switch n := v.(type) {
				case float64:
					in = fmt.Sprintf("%.0f", n)
				case string:
					in = n
				}
			}
			if v, ok := ev["output_tokens"]; ok {
				switch n := v.(type) {
				case float64:
					out = fmt.Sprintf("%.0f", n)
				case string:
					out = n
				}
			}
			thinking, _ := ev["thinking"].(string)
			text, _ := ev["text"].(string)
			display.ShowEvent(agent.Event{Type: agent.EventSubAgentResult, Fields: []string{"AGENT_RESULT", sid, status, in, out, thinking, text}})
		case "image_describe":
			images, _ := ev["images"].(string)
			desc, _ := ev["content"].(string)
			display.ShowEvent(agent.Event{Type: agent.EventImageDescribe, Fields: []string{"IMAGE_DESCRIBE", images, desc}})
		case "stop":
			// Don't emit STOP for replay
		case "error":
			msg, _ := ev["message"].(string)
			display.ShowEvent(agent.Event{Type: agent.EventError, Fields: []string{"ERROR", msg}})
		}
	}
	fmt.Println()
}

// listAllSessions 列出所有 session（与 bash 版 list_sessions 一致）
func listAllSessions(store agent.SessionStore) {
	rows := store.ListSessionRows()
	if len(rows) == 0 {
		fmt.Println("No sessions found.")
		return
	}
	fmt.Printf("%-40s %-16s %s\n", "NAME", "MODIFIED", "PREVIEW")
	for _, r := range rows {
		fmt.Printf("%-40s %-16s %s\n", r.Name, r.Modified, r.Preview)
	}
}

// applyThinkingOptions 仅用显式命令行值覆盖由环境变量或默认值产生的配置。
func applyThinkingOptions(cfg *agent.Config, thinking, effort string) {
	if thinking != "" {
		cfg.Thinking = thinking
	}
	if effort != "" {
		cfg.Effort = effort
	}
}

func normalizeSessionArgs(args []string) []string {
	out := make([]string, 0, len(args)+1)
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--session" {
			out = append(out, arg)
			if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
				out = append(out, args[i+1])
				i++
			} else {
				out = append(out, agent.UtilNewSessionID())
			}
			continue
		}
		out = append(out, arg)
	}
	return out
}

// stringSlice 实现 flag.Value 接口，支持重复 -skill
type stringSlice []string

func (s *stringSlice) String() string { return strings.Join(*s, ", ") }
func (s *stringSlice) Set(val string) error {
	*s = append(*s, val)
	return nil
}
