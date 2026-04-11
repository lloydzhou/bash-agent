package app

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/peterh/liner"

	"github.com/lloydzhou/bash-agent/internal/assets"
	"github.com/lloydzhou/bash-agent/internal/config"
	"github.com/lloydzhou/bash-agent/internal/conversation"
	"github.com/lloydzhou/bash-agent/internal/httpclient"
	"github.com/lloydzhou/bash-agent/internal/prompt"
	"github.com/lloydzhou/bash-agent/internal/protocol"
	"github.com/lloydzhou/bash-agent/internal/provider"
	"github.com/lloydzhou/bash-agent/internal/session"
	"github.com/lloydzhou/bash-agent/internal/sse"
	"github.com/lloydzhou/bash-agent/internal/tools"
)

type runtime struct {
	cfg       config.Config
	cwd       string
	home      string
	stdin     io.Reader
	stdout    io.Writer
	stderr    io.Writer
	apiURL    string
	toolsJSON []byte
	paths     session.Paths
	conv      conversation.Store
	tmpDir    string
	http      httpclient.StreamClient
}

var newHTTPClient = func() *http.Client {
	return &http.Client{Timeout: 0}
}

func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	cfg, err := config.ParseArgs(args)
	if err != nil {
		if errors.Is(err, io.EOF) {
			printUsage(stdout)
			return nil
		}
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	if cfg.ListSessions {
		return listSessions(home, cwd, stdout)
	}
	rt := &runtime{
		cfg:    cfg,
		cwd:    cwd,
		home:   home,
		stdin:  stdin,
		stdout: stdout,
		stderr: stderr,
		http: httpclient.StreamClient{
			Client: newHTTPClient(),
		},
	}
	if cfg.Command != config.CommandCompact {
		if err := rt.applyProviderDefaults(); err != nil {
			return err
		}
	}
	if err := rt.initState(); err != nil {
		return err
	}
	defer rt.cleanup()

	if rt.cfg.Command == config.CommandCompact {
		compacted, err := rt.compactContextWindow("manual", true)
		if err != nil {
			return err
		}
		if rt.cfg.OutputFormat == config.OutputHuman {
			if compacted {
				rt.info("Context compacted.")
			} else {
				rt.info("Context is within budget; no compaction needed.")
			}
		}
		return nil
	}

	if rt.cfg.Interactive || (rt.cfg.Prompt == "" && isTTY(os.Stdin)) {
		return rt.interactiveMode()
	}
	if rt.cfg.Prompt != "" {
		return rt.agentLoop(rt.cfg.Prompt)
	}
	data, err := io.ReadAll(stdin)
	if err != nil {
		return err
	}
	return rt.agentLoop(string(data))
}

func (rt *runtime) applyProviderDefaults() error {
	env := map[string]string{
		"ANTHROPIC_API_KEY":  os.Getenv("ANTHROPIC_API_KEY"),
		"OPENAI_API_KEY":     os.Getenv("OPENAI_API_KEY"),
		"ANTHROPIC_BASE_URL": os.Getenv("ANTHROPIC_BASE_URL"),
		"OPENAI_BASE_URL":    os.Getenv("OPENAI_BASE_URL"),
	}
	if err := config.ApplyProviderDefaults(&rt.cfg, env); err != nil {
		return err
	}
	rt.apiURL = config.APIURL(rt.cfg)
	return nil
}

func (rt *runtime) initState() error {
	tmpDir, err := os.MkdirTemp("", "goagent.")
	if err != nil {
		return err
	}
	rt.tmpDir = tmpDir
	rt.toolsJSON = append([]byte(nil), assets.ToolsJSON...)

	if rt.cfg.Command == config.CommandCompact && !rt.cfg.SessionMode && !rt.cfg.ContinueSession && rt.cfg.SessionID == "" {
		rt.cfg.SessionMode = true
		rt.cfg.ContinueSession = true
	}

	if rt.cfg.SessionMode {
		sessionID := rt.cfg.SessionID
		if sessionID == "" && rt.cfg.ContinueSession {
			if id, err := session.ContinueSession(rt.home, rt.cwd); err == nil {
				sessionID = id
			} else if rt.cfg.Command == config.CommandCompact {
				return fmt.Errorf("no existing session found to compact")
			}
		}
		if sessionID == "" {
			sessionID = time.Now().Format("20060102-150405")
		}
		rt.cfg.SessionID = sessionID
		rt.paths = session.PathsFor(rt.home, rt.cwd, sessionID)
		if err := session.EnsureDir(rt.paths.BaseDir); err != nil {
			return err
		}
		newSession := !fileExists(rt.paths.Events)
		for _, path := range []string{rt.paths.Conversation, rt.paths.Events, rt.paths.Summary, rt.paths.Todo} {
			if err := touch(path); err != nil {
				return err
			}
		}
		if newSession {
			_ = rt.appendEvent(map[string]any{"type": "session_start", "session_id": sessionID})
		}
		rt.conv = conversation.Store{Path: rt.paths.Conversation}
		return nil
	}

	rt.paths = session.Paths{
		Conversation: filepath.Join(rt.tmpDir, "conv.jsonl"),
		Summary:      filepath.Join(rt.tmpDir, "summary.txt"),
		Todo:         filepath.Join(rt.tmpDir, "todo.md"),
	}
	for _, path := range []string{rt.paths.Conversation, rt.paths.Summary, rt.paths.Todo} {
		if err := touch(path); err != nil {
			return err
		}
	}
	rt.conv = conversation.Store{Path: rt.paths.Conversation}
	return nil
}

func (rt *runtime) cleanup() {
	if rt.tmpDir != "" {
		_ = os.RemoveAll(rt.tmpDir)
	}
}

func (rt *runtime) interactiveMode() error {
	rt.info("bash-agent interactive mode (type 'exit' or Ctrl+D to quit)")
	line := liner.NewLiner()
	defer line.Close()
	line.SetCtrlCAborts(true)
	historyPath := filepath.Join(rt.home, ".bash-agent", "goagent.history")
	_ = os.MkdirAll(filepath.Dir(historyPath), 0o755)
	if f, err := os.Open(historyPath); err == nil {
		_, _ = line.ReadHistory(f)
		_ = f.Close()
	}
	for {
		input, err := line.Prompt("> ")
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			if errors.Is(err, liner.ErrPromptAborted) {
				continue
			}
			return err
		}
		if input == "" {
			continue
		}
		if input == "exit" || input == "quit" {
			break
		}
		line.AppendHistory(input)
		if err := rt.agentLoop(input); err != nil {
			return err
		}
	}
	if f, err := os.Create(historyPath); err == nil {
		_, _ = line.WriteHistory(f)
		_ = f.Close()
	}
	rt.info("Goodbye!")
	return nil
}

func (rt *runtime) agentLoop(userInput string) error {
	if err := rt.conv.AddUser(userInput); err != nil {
		return err
	}
	_ = rt.appendEvent(map[string]any{"type": "user_message", "content": userInput})

	turn := 0
	humanLastChar := ""
	for turn < rt.cfg.MaxTurns {
		turn++
		text := ""
		var calls []protocol.ToolCallEvent
		stop := ""
		if rt.cfg.Verbose {
			if messages, err := rt.conv.MessagesJSON(); err == nil {
				rt.debug("messages: %.500s...", string(messages))
			}
		}

		err := rt.llmCall(func(evt protocol.Event) error {
			if rt.cfg.Verbose {
				rt.debug("<%s>", evt.Render())
			}
			switch e := evt.(type) {
			case protocol.TextEvent:
				if rt.isStreamJSONMode() {
					return rt.emitStream(map[string]any{"type": "text", "content": e.Content})
				}
				if _, err := fmt.Fprint(rt.stdout, e.Content); err != nil {
					return err
				}
				if e.Content != "" {
					humanLastChar = e.Content[len(e.Content)-1:]
				}
				text += e.Content
			case protocol.ToolCallEvent:
				if !rt.isStreamJSONMode() && humanLastChar != "\n" {
					if _, err := fmt.Fprint(rt.stdout, "\n"); err != nil {
						return err
					}
					humanLastChar = "\n"
				}
				if rt.isStreamJSONMode() {
					if err := rt.emitStream(map[string]any{
						"type":  "tool_call",
						"name":  e.Name,
						"id":    e.ID,
						"input": json.RawMessage(e.InputJSON),
					}); err != nil {
						return err
					}
				} else {
					if _, err := fmt.Fprintf(rt.stdout, "\033[33m[tool] %s\033[0m\n", conversation.BuildToolCallSummary(e.Name, e.Fields)); err != nil {
						return err
					}
				}
				calls = append(calls, e)
			case protocol.UsageEvent:
				if rt.isStreamJSONMode() {
					return rt.emitStream(map[string]any{
						"type":               "usage",
						"input_tokens":       e.InputTokens,
						"output_tokens":      e.OutputTokens,
						"cache_input_tokens": e.CacheInputTokens,
					})
				}
			case protocol.StopEvent:
				stop = e.Reason
				if rt.isStreamJSONMode() {
					return rt.emitStream(map[string]any{"type": "stop", "reason": e.Reason})
				}
				if humanLastChar != "\n" {
					if _, err := fmt.Fprint(rt.stdout, "\n"); err != nil {
						return err
					}
					humanLastChar = "\n"
				}
			case protocol.ErrorEvent:
				if rt.isStreamJSONMode() {
					_ = rt.emitStream(map[string]any{"type": "error", "message": e.Message})
				}
				return fmt.Errorf("%s", e.Message)
			}
			return nil
		})
		if err != nil {
			rt.error("%v", err)
			return err
		}

		if err := rt.conv.AddAssistant(text, calls); err != nil {
			return err
		}
		_ = rt.appendEvent(rt.buildAssistantEvent(text, calls))

		switch stop {
		case "end_turn", "stop", "done":
			_, _ = rt.compactContextWindow("auto", false)
			return nil
		case "tool_use", "tool_calls":
			results, err := rt.executeToolCalls(calls)
			if err != nil {
				return err
			}
			if err := rt.conv.AddToolResults(results); err != nil {
				return err
			}
			for _, result := range results {
				_ = rt.appendEvent(map[string]any{
					"type":        "tool_result",
					"tool_use_id": result.ToolUseID,
					"content":     result.Content,
				})
			}
			_, _ = rt.compactContextWindow("auto", false)
		case "max_tokens", "length":
			rt.error("Response truncated (max_tokens reached)")
			return nil
		default:
			rt.error("Unknown stop reason: %s", stop)
			return nil
		}
	}
	rt.error("Max turns (%d) reached", rt.cfg.MaxTurns)
	return nil
}

func (rt *runtime) llmCall(emit func(protocol.Event) error) error {
	lines, err := rt.conv.Lines()
	if err != nil {
		return err
	}
	systemPrompt, err := prompt.Builder{
		Cwd:         rt.cwd,
		Home:        rt.home,
		Skills:      rt.cfg.Skills,
		SummaryFile: rt.paths.Summary,
		TodoFile:    rt.paths.Todo,
	}.BuildSystemPrompt()
	if err != nil {
		return err
	}
	body, err := provider.BuildRequest(rt.cfg, lines, rt.toolsJSON, systemPrompt, rt.cfg.MaxTokens)
	if err != nil {
		return err
	}
	if rt.cfg.Verbose {
		rt.verbose("POST %s (%dKB body)", rt.apiURL, len(body)/1024)
		rt.verbose("Request body (%dKB): %.200s...", len(body)/1024, string(body))
	}
	headers := rt.headers()
	respBody, err := rt.http.Post(rt.apiURL, headers, body)
	if err != nil {
		return err
	}
	defer respBody.Close()

	switch rt.cfg.Provider {
	case "claude":
		return (sse.ClaudeParser{}).Parse(respBody, emit)
	case "openai":
		return (sse.OpenAIParser{}).Parse(respBody, emit)
	default:
		return fmt.Errorf("unknown provider: %s", rt.cfg.Provider)
	}
}

func (rt *runtime) executeToolCalls(calls []protocol.ToolCallEvent) ([]conversation.ToolResult, error) {
	runner := tools.Runner{
		Config:   rt.cfg,
		TodoFile: rt.paths.Todo,
	}
	results := make([]conversation.ToolResult, 0, len(calls))
	for _, call := range calls {
		result := runner.Dispatch(call.Name, call.InputJSON)
		output := result.Output
		if result.Err != nil {
			output = "Error: tool execution failed: " + outputOrErr(output, result.Err)
		}
		output = tools.StripANSI(output)
		output = tools.FormatToolResult(output, rt.cfg.ToolResultMaxBytes)
		results = append(results, conversation.ToolResult{
			ToolUseID: call.ID,
			Content:   output,
		})
		if call.Name == "TodoWrite" && result.Err == nil {
			if data, err := os.ReadFile(rt.paths.Todo); err == nil && len(data) > 0 {
				_ = rt.appendEvent(map[string]any{"type": "todo_update", "content": strings.TrimRight(string(data), "\n")})
				if rt.isStreamJSONMode() {
					_ = rt.emitStream(map[string]any{"type": "todo_update", "content": strings.TrimRight(string(data), "\n")})
				}
			}
		}
		if rt.isStreamJSONMode() {
			if err := rt.emitStream(map[string]any{
				"type":        "tool_result",
				"tool_use_id": call.ID,
				"content":     output,
			}); err != nil {
				return nil, err
			}
		} else if output != "" {
			if _, err := fmt.Fprintln(rt.stdout, output); err != nil {
				return nil, err
			}
		}
	}
	return results, nil
}

func (rt *runtime) compactContextWindow(trigger string, force bool) (bool, error) {
	totalBytes, err := rt.conv.TotalBytes()
	if err != nil {
		return false, err
	}
	if !force && totalBytes <= rt.cfg.MaxContextBytes {
		return false, nil
	}
	targetKeepBytes := rt.cfg.MaxContextBytes * rt.cfg.MaxContextKeepPct / 100
	if targetKeepBytes < 1 {
		targetKeepBytes = 1
	}
	keepLines, err := rt.conv.KeepLineCount(targetKeepBytes)
	if err != nil {
		return false, err
	}
	totalLines, err := rt.conv.TotalLines()
	if err != nil {
		return false, err
	}
	drop := totalLines - keepLines
	if drop <= 0 {
		return false, nil
	}
	allLines, err := rt.conv.Lines()
	if err != nil {
		return false, err
	}
	var dropped bytes.Buffer
	for _, line := range allLines[:drop] {
		dropped.Write(line)
		dropped.WriteByte('\n')
	}
	currentSummary, err := os.ReadFile(rt.paths.Summary)
	if err != nil && !os.IsNotExist(err) {
		return false, err
	}
	if trigger == "manual" && rt.apiURL == "" {
		if err := rt.applyProviderDefaults(); err != nil {
			return false, err
		}
	}
	summary, err := rt.runSummaryCall(string(currentSummary), strings.TrimRight(dropped.String(), "\n"))
	if err != nil {
		return false, err
	}
	if err := os.WriteFile(rt.paths.Summary, []byte(summary+"\n"), 0o644); err != nil {
		return false, err
	}
	if err := rt.conv.TrimKeepLast(keepLines); err != nil {
		return false, err
	}
	if rt.isStreamJSONMode() {
		_ = rt.emitStream(map[string]any{"type": "context_update", "kind": "compact", "trigger": trigger})
	} else if trigger == "auto" {
		rt.info("Context compacted automatically.")
	}
	return true, nil
}

func (rt *runtime) runSummaryCall(currentSummary, droppedMessages string) (string, error) {
	lines := []json.RawMessage{}
	userPrompt := prompt.BuildCompactSummaryUserPrompt(currentSummary, droppedMessages)
	msg, err := json.Marshal(map[string]any{
		"role":    "user",
		"content": userPrompt,
	})
	if err != nil {
		return "", err
	}
	lines = append(lines, msg)
	body, err := provider.BuildRequest(rt.cfg, lines, nil, prompt.BuildCompactSummarySystemPrompt(), rt.cfg.SummaryMaxTokens)
	if err != nil {
		return "", err
	}
	if rt.cfg.Verbose {
		rt.verbose("Summary request body (%dKB): %.200s...", len(body)/1024, string(body))
	}
	respBody, err := rt.http.Post(rt.apiURL, rt.headers(), body)
	if err != nil {
		return "", err
	}
	defer respBody.Close()
	var b strings.Builder
	parserEmit := func(evt protocol.Event) error {
		switch e := evt.(type) {
		case protocol.TextEvent:
			b.WriteString(e.Content)
		case protocol.ErrorEvent:
			return fmt.Errorf("%s", e.Message)
		}
		return nil
	}
	switch rt.cfg.Provider {
	case "claude":
		err = (sse.ClaudeParser{}).Parse(respBody, parserEmit)
	case "openai":
		err = (sse.OpenAIParser{}).Parse(respBody, parserEmit)
	default:
		err = fmt.Errorf("unknown provider: %s", rt.cfg.Provider)
	}
	if err != nil {
		return "", err
	}
	if b.Len() == 0 {
		return "", errors.New("failed to generate context summary")
	}
	return b.String(), nil
}

func (rt *runtime) headers() map[string]string {
	headers := map[string]string{
		"Content-Type": "application/json",
	}
	switch rt.cfg.Provider {
	case "claude":
		headers["x-api-key"] = rt.cfg.APIKey
		headers["anthropic-version"] = "2023-06-01"
	case "openai":
		headers["Authorization"] = "Bearer " + rt.cfg.APIKey
	}
	return headers
}

func (rt *runtime) appendEvent(v any) error {
	if rt.paths.Events == "" {
		return nil
	}
	line, err := json.Marshal(v)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(rt.paths.Events, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(line, '\n'))
	return err
}

func (rt *runtime) buildAssistantEvent(text string, calls []protocol.ToolCallEvent) map[string]any {
	toolCalls := make([]map[string]any, 0, len(calls))
	for _, call := range calls {
		toolCalls = append(toolCalls, map[string]any{
			"name":  call.Name,
			"id":    call.ID,
			"input": json.RawMessage(call.InputJSON),
		})
	}
	return map[string]any{
		"type":       "assistant_message",
		"text":       text,
		"tool_calls": toolCalls,
	}
}

func (rt *runtime) isStreamJSONMode() bool {
	return rt.cfg.OutputFormat == config.OutputStreamJSON
}

func (rt *runtime) emitStream(v any) error {
	data, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(rt.stdout, string(data))
	return err
}

func (rt *runtime) info(format string, args ...any) {
	_, _ = fmt.Fprintf(rt.stderr, "\033[36m%s\033[0m\n", fmt.Sprintf(format, args...))
}

func (rt *runtime) error(format string, args ...any) {
	_, _ = fmt.Fprintf(rt.stderr, "\033[31mError: %s\033[0m\n", fmt.Sprintf(format, args...))
}

func (rt *runtime) verbose(format string, args ...any) {
	if rt.cfg.Verbose {
		_, _ = fmt.Fprintf(rt.stderr, "\033[90m[verbose] %s\033[0m\n", fmt.Sprintf(format, args...))
	}
}

func (rt *runtime) debug(format string, args ...any) {
	if rt.cfg.Verbose {
		_, _ = fmt.Fprintf(rt.stderr, "[debug] %s\n", fmt.Sprintf(format, args...))
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: goagent [options] [prompt]")
	fmt.Fprintln(w, "       goagent compact [options]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Options:")
	fmt.Fprintln(w, "  -p, --provider PROV     LLM provider: claude | openai (default: claude)")
	fmt.Fprintln(w, "  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)")
	fmt.Fprintln(w, "  --max-tokens N          Max output tokens (default: 4096)")
	fmt.Fprintln(w, "  --tool-timeout N        Tool execution timeout in seconds (default: 600)")
	fmt.Fprintln(w, "  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md")
	fmt.Fprintln(w, "  --max-turns N           Max agent turns (default: 20)")
	fmt.Fprintln(w, "  --max-context N         Max stored context bytes before compact (default: 200000; supports k/m/g)")
	fmt.Fprintln(w, "  --api-key KEY           API key (default from env)")
	fmt.Fprintln(w, "  --base-url URL          Override API base URL")
	fmt.Fprintln(w, "  --output-format FMT     Output format: human | stream-json")
	fmt.Fprintln(w, "  --print                 Alias for --output-format stream-json")
	fmt.Fprintln(w, "  --session [NAME]        Use named session (persist conversation)")
	fmt.Fprintln(w, "  --continue              Continue most recent session")
	fmt.Fprintln(w, "  --list-sessions         List all saved sessions")
	fmt.Fprintln(w, "  -v, --verbose           Verbose mode")
	fmt.Fprintln(w, "  -i, --interactive       Interactive mode (REPL)")
	fmt.Fprintln(w, "  -h, --help              Show this help")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Environment:")
	fmt.Fprintln(w, "  ANTHROPIC_API_KEY       API key for Claude")
	fmt.Fprintln(w, "  OPENAI_API_KEY          API key for OpenAI")
	fmt.Fprintln(w, "  ANTHROPIC_BASE_URL      Claude API base URL")
	fmt.Fprintln(w, "  OPENAI_BASE_URL         OpenAI API base URL")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Examples:")
	fmt.Fprintln(w, `  goagent "Read /etc/hostname and tell me what it says"`)
	fmt.Fprintln(w, `  goagent -m claude-sonnet-4-20250514 "List files in /tmp"`)
	fmt.Fprintln(w, `  goagent --session code-review "Analyze this code"`)
	fmt.Fprintln(w, `  goagent --skill shell-safety "List files in /tmp"`)
	fmt.Fprintln(w, `  goagent --continue "What did we discuss?"`)
	fmt.Fprintln(w, `  goagent --output-format stream-json "Hello" | jq -r 'select(.type=="text") .content'`)
	fmt.Fprintln(w, `  echo "prompt" | goagent --print`)
	fmt.Fprintln(w, `  goagent compact --session code-review`)
	fmt.Fprintln(w, `  goagent -i`)
}

func isTTY(f *os.File) bool {
	info, err := f.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) != 0
}

func outputOrErr(output string, err error) string {
	if output != "" {
		return output
	}
	return err.Error()
}

func touch(path string) error {
	f, err := os.OpenFile(path, os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func listSessions(home, cwd string, w io.Writer) error {
	dir := filepath.Join(home, ".bash-agent", "projects", session.ProjectKey(cwd))
	entries, err := os.ReadDir(dir)
	if err != nil {
		fmt.Fprintln(w, "No sessions found.")
		return nil
	}
	type row struct {
		name string
		mod  time.Time
	}
	var rows []row
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".jsonl") || strings.HasSuffix(name, ".events.jsonl") {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			continue
		}
		rows = append(rows, row{
			name: strings.TrimSuffix(name, ".jsonl"),
			mod:  info.ModTime(),
		})
	}
	if len(rows) == 0 {
		fmt.Fprintln(w, "No sessions found.")
		return nil
	}
	fmt.Fprintf(w, "%-40s %s\n", "NAME", "MODIFIED")
	sort.Slice(rows, func(i, j int) bool { return rows[i].mod.After(rows[j].mod) })
	for _, row := range rows {
		fmt.Fprintf(w, "%-40s %s\n", row.name, row.mod.Format("2006-01-02 15:04"))
	}
	return nil
}
