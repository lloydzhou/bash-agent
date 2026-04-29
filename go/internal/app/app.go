package app

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	goprompt "github.com/joeycumines/go-prompt"
	"golang.org/x/sys/unix"
	"golang.org/x/term"

	"github.com/lloydzhou/bash-agent/internal/assets"
	"github.com/lloydzhou/bash-agent/internal/config"
	"github.com/lloydzhou/bash-agent/internal/conversation"
	"github.com/lloydzhou/bash-agent/internal/httpclient"
	"github.com/lloydzhou/bash-agent/internal/prompt"
	"github.com/lloydzhou/bash-agent/internal/protocol"
	"github.com/lloydzhou/bash-agent/internal/provider"
	"github.com/lloydzhou/bash-agent/internal/session"
	"github.com/lloydzhou/bash-agent/internal/tools"
	"github.com/lloydzhou/bash-agent/internal/transport"
)

type runtime struct {
	cfg         config.Config
	cwd         string
	home        string
	stdin       io.Reader
	stdout      io.Writer
	stderr      io.Writer
	apiURL      string
	toolsJSON   []byte
	paths       session.Paths
	conv        conversation.Store
	http        httpclient.StreamClient
	transport   transport.Transport
	escTTY      *os.File
	escState    *term.State
	escStop     chan struct{}
	escDone     chan struct{}
	interrupted atomic.Bool
	lastContextTokens       int
	lastInputTokens        int
	lastOutputTokens       int
	lastCacheReadTokens    int
	lastCacheCreationTokens int
}

var errInterrupted = errors.New("interrupted")

func (rt *runtime) writeHuman(s string) (int, error) {
	if rt.cfg.Interactive {
		s = strings.ReplaceAll(s, "\n", "\r\n")
	}
	return fmt.Fprint(rt.stdout, s)
}

func (rt *runtime) nl() string {
	if rt.cfg.Interactive {
		return "\r\n"
	}
	return "\n"
}

func normalizeDisplayText(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	return s
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
	home := os.Getenv("BASH_AGENT_HOME")
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil {
			return err
		}
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
	if err := rt.applyProviderDefaults(); err != nil {
		return err
	}
	if err := rt.initState(); err != nil {
		return err
	}
	if rt.cfg.Interactive || (rt.cfg.Prompt == "" && isTTY(os.Stdin)) {
		rt.cfg.Interactive = true
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
	rt.transport = transport.New(rt.cfg)
	return nil
}

func (rt *runtime) initState() error {
	rt.toolsJSON = append([]byte(nil), assets.ToolsJSON...)

	sessionID := rt.cfg.SessionID
	if sessionID == "" && rt.cfg.ContinueSession {
		if id, err := session.ContinueSession(rt.home, rt.cwd); err == nil {
			sessionID = id
		}
	}
	if sessionID == "" {
		now := time.Now()
		sessionID = fmt.Sprintf("%s-%04x", now.Format("20060102-150405"), now.Nanosecond()%0xffff)
	}
	rt.cfg.SessionID = sessionID
	rt.paths = session.PathsFor(rt.home, rt.cwd, sessionID)
	if err := session.EnsureDir(rt.paths.BaseDir); err != nil {
		return err
	}
	if err := session.EnsureDir(rt.paths.SessionDir); err != nil {
		return err
	}
	newSession := !fileExists(rt.paths.Events)
	for _, path := range []string{rt.paths.Conversation, rt.paths.Events, rt.paths.Summary, rt.paths.Todo, rt.paths.Plan} {
		if err := touch(path); err != nil {
			return err
		}
	}
	if newSession {
		_ = rt.appendEvent(map[string]any{"type": "session_start", "session_id": sessionID})
		// Write initial stats
		statsData := `{"current_turn_count":0,"agent_request_count":0,"compact_request_count":0,"total_input_tokens":0,"total_output_tokens":0,"total_cache_read_tokens":0,"total_cache_creation_tokens":0,"current_context_tokens":0,"last_updated":""}`
		_ = os.WriteFile(rt.paths.Stats, []byte(statsData+"\n"), 0o644)
	}
	rt.updateTermTitle()
	rt.conv = conversation.Store{Path: rt.paths.Conversation}
	return nil
}

func (rt *runtime) interactiveMode() error {
	_, _ = fmt.Fprintln(rt.stdout, "bash-agent interactive mode (type 'exit' or Ctrl+D to quit)")

	// Replay recent turns for resumed sessions
	rt.replayLastTurns()

	historyPath := filepath.Join(rt.home, ".bash-agent", "history")
	_ = os.MkdirAll(filepath.Dir(historyPath), 0o755)

	// Load history
	var history []string
	if data, err := os.ReadFile(historyPath); err == nil {
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") {
				history = append(history, line)
			}
		}
	}

	executor := func(in string) {
		input := strings.TrimSpace(in)
		if input == "" || input == "exit" || input == "quit" {
			return
		}
		// Append to history file
		if f, err := os.OpenFile(historyPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			_, _ = fmt.Fprintln(f, input)
			f.Close()
		}
		if err := rt.agentLoop(input); err != nil {
			rt.error("%v", err)
		}
	}

	p := goprompt.New(
		executor,
		goprompt.WithPrefix("> "),
		goprompt.WithPrefixTextColor(goprompt.Green),
		goprompt.WithHistory(history),
		goprompt.WithExecuteOnEnterCallback(func(p *goprompt.Prompt, indentSize int) (int, bool) {
			return 0, true
		}),
		goprompt.WithExitChecker(func(in string, breakline bool) bool {
			return strings.TrimSpace(in) == "exit" || strings.TrimSpace(in) == "quit"
		}),
	)

	_ = p.RunNoExit()
	_, _ = fmt.Fprintln(rt.stdout, "Goodbye!")
	if rt.cfg.SessionID != "" {
		_, _ = fmt.Fprintf(rt.stdout, "\033[90mResume with: --session %s  or  --continue\033[0m\n", rt.cfg.SessionID)
	}
	return nil
}

// replayEvent is a simplified event from events.jsonl used for session replay.
type replayEvent struct {
	Type      string          `json:"type"`
	Content   string          `json:"content,omitempty"`
	ToolUseID string          `json:"tool_use_id,omitempty"`
	Name      string          `json:"name,omitempty"`
	ID        string          `json:"id,omitempty"`
	Input     json.RawMessage `json:"input,omitempty"`
	Text      string          `json:"text,omitempty"`
	ToolCalls []struct {
		Name  string          `json:"name"`
		ID    string          `json:"id"`
		Input json.RawMessage `json:"input"`
	} `json:"tool_calls,omitempty"`
}

// displayReplayEvent mirrors bash's display_event exactly for replay purposes.
// It handles: USER_MESSAGE, TEXT, THINKING, TOOL_CALL, TOOL_RESULT, STOP, ERROR
func (rt *runtime) displayReplayEvent(state *displayState, evtType string, fields map[string]string) {
	switch evtType {
	case "TEXT":
		content := fields["content"]
		// Insert newline when transitioning from thinking to text
		if state.prevWasThinking && state.lastChar != "\n" {
			_, _ = rt.writeHuman(rt.nl())
			state.lastChar = "\n"
		}
		state.prevWasThinking = false
		if content != "" {
			displayContent := normalizeDisplayText(content)
			_, _ = rt.writeHuman(displayContent)
			if strings.HasSuffix(displayContent, "\n") {
				state.lastChar = "\n"
			} else {
				state.lastChar = displayContent[len(displayContent)-1:]
			}
		}
	case "THINKING":
		content := fields["content"]
		if content != "" {
			displayContent := normalizeDisplayText(content)
			_, _ = rt.writeHuman(fmt.Sprintf("\033[90m%s\033[0m", displayContent))
			if strings.HasSuffix(displayContent, "\n") {
				state.lastChar = "\n"
			} else {
				state.lastChar = displayContent[len(displayContent)-1:]
			}
		}
		state.prevWasThinking = true
	case "TOOL_CALL":
		// display_ensure_newline
		if state.lastChar != "\n" {
			_, _ = rt.writeHuman(rt.nl())
		}
		name := fields["name"]
		summary := conversation.BuildToolCallSummary(name, fields)
		_, _ = fmt.Fprintf(rt.stdout, "\033[33m[tool] %s\033[0m\n", summary)
		state.lastChar = "\n"
		state.prevWasThinking = false
	case "TOOL_RESULT":
		name := fields["name"]
		content := fields["content"]
		var trText string
		if name == "Edit" {
			// Content already has colorized diff from tool layer — use as-is
			trText = normalizeDisplayText(content)
			if !strings.HasSuffix(trText, "\n") {
				trText += "\n"
			}
		} else if name == "Read" || name == "Write" {
			// Summary already prepended; use first line
			trText = conversation.FirstLine(normalizeDisplayText(content)) + "\n"
		} else {
			trText = truncateRunes(normalizeDisplayText(content), 200) + "\n"
		}
		// Insert newline when transitioning from thinking to text
		if state.prevWasThinking && state.lastChar != "\n" {
			_, _ = rt.writeHuman(rt.nl())
			state.lastChar = "\n"
		}
		state.prevWasThinking = false
		if trText != "" {
			_, _ = rt.writeHuman(trText)
			if strings.HasSuffix(trText, "\n") {
				state.lastChar = "\n"
			} else {
				state.lastChar = trText[len(trText)-1:]
			}
		}
	case "USER_MESSAGE":
		// display_ensure_newline
		if state.lastChar != "\n" {
			_, _ = rt.writeHuman(rt.nl())
		}
		content := truncateRunes(firstLine(fields["content"]), 77)
		_, _ = fmt.Fprintf(rt.stdout, "\033[32m> %s\033[0m\n", content)
		state.lastChar = "\n"
		state.prevWasThinking = false
	case "STOP":
		if state.lastChar != "\n" {
			_, _ = rt.writeHuman(rt.nl())
			state.lastChar = "\n"
		}
	case "ERROR":
		if state.lastChar != "\n" {
			_, _ = rt.writeHuman(rt.nl())
		}
		_, _ = fmt.Fprintf(rt.stderr, "\033[31mError: %s\033[0m\n", fields["message"])
	}
}

func (rt *runtime) replayLastTurns() {
	if rt.paths.Events == "" {
		return
	}
	data, err := os.ReadFile(rt.paths.Events)
	if err != nil || len(data) == 0 {
		return
	}

	lines := strings.Split(string(data), "\n")
	// Find line positions of user_input events (which mark turn boundaries)
	var userInputLines []int
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, `"type":"user_input"`) || strings.Contains(line, `"type":"user_message"`) {
			userInputLines = append(userInputLines, i)
		}
	}
	if len(userInputLines) == 0 {
		return
	}

	// Take last 10 user turns (match bash)
	fromIdx := 0
	if len(userInputLines) > 10 {
		fromIdx = userInputLines[len(userInputLines)-10]
	}

	state := displayState{lastChar: "\n"}
	var accText string
	var accThinking string
	var hadTurns bool

	// Flush accumulated text/thinking through displayReplayEvent (matches bash event_replay.awk)
	flushAccumulated := func() {
		if accThinking != "" {
			rt.displayReplayEvent(&state, "THINKING", map[string]string{"content": accThinking})
			accThinking = ""
		}
		if accText != "" {
			rt.displayReplayEvent(&state, "TEXT", map[string]string{"content": accText})
			accText = ""
		}
	}

	for _, line := range lines[fromIdx:] {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var evt replayEvent
		if err := json.Unmarshal([]byte(line), &evt); err != nil {
			continue
		}

		switch evt.Type {
		case "session_start", "usage", "stop", "retry":
			continue
		case "user_input", "user_message":
			flushAccumulated()
			content := evt.Content
			if content == "" {
				continue
			}
			hadTurns = true
			rt.displayReplayEvent(&state, "USER_MESSAGE", map[string]string{"content": content})
		case "todo_update":
			flushAccumulated()
		case "thinking":
			// Flush text, accumulate thinking (match bash event_replay.awk)
			if accText != "" {
				rt.displayReplayEvent(&state, "TEXT", map[string]string{"content": accText})
				accText = ""
			}
			accThinking += evt.Content
		case "text":
			// Flush thinking, accumulate text (match bash event_replay.awk)
			if accThinking != "" {
				rt.displayReplayEvent(&state, "THINKING", map[string]string{"content": accThinking})
				accThinking = ""
			}
			accText += evt.Content
		case "tool_call":
			flushAccumulated()
			fields := parseInputFields(evt.Input)
			fields["name"] = evt.Name
			rt.displayReplayEvent(&state, "TOOL_CALL", fields)
		case "tool_result":
			flushAccumulated()
			displayContent := evt.Content
			// Truncate for replay (match bash: 200 chars)
			if len(displayContent) > 200 {
				displayContent = displayContent[:200] + "..."
			}
			rt.displayReplayEvent(&state, "TOOL_RESULT", map[string]string{
				"name":    evt.Name,
				"content": displayContent,
			})
		case "error":
			flushAccumulated()
			rt.displayReplayEvent(&state, "ERROR", map[string]string{"message": evt.Content})
		case "assistant_message":
			// Legacy format: emit TEXT + TOOL_CALL per tool_call (match bash event_replay.awk)
			flushAccumulated()
			if evt.Text != "" {
				rt.displayReplayEvent(&state, "TEXT", map[string]string{"content": evt.Text})
			}
			for _, tc := range evt.ToolCalls {
				fields := parseInputFields(tc.Input)
				fields["name"] = tc.Name
				rt.displayReplayEvent(&state, "TOOL_CALL", fields)
			}
		}
	}
	flushAccumulated()
	if hadTurns {
		_, _ = fmt.Fprintln(rt.stdout)
	}
}

// parseInputFields extracts key-value pairs from a tool call input JSON object.
func parseInputFields(input json.RawMessage) map[string]string {
	if len(input) == 0 {
		return nil
	}
	var m map[string]any
	if err := json.Unmarshal(input, &m); err != nil {
		return nil
	}
	fields := make(map[string]string, len(m))
	for k, v := range m {
		switch val := v.(type) {
		case string:
			fields[k] = val
		default:
			b, _ := json.Marshal(val)
			fields[k] = string(b)
		}
	}
	return fields
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func truncateRunes(s string, limit int) string {
	if limit <= 0 {
		return ""
	}
	runes := []rune(s)
	if len(runes) <= limit {
		return s
	}
	return string(runes[:limit]) + "..."
}

func (rt *runtime) agentLoop(userInput string) error {
	err := rt.agentLoopStream(userInput)
	// Match bash: update terminal title with current stats after each turn
	rt.updateTermTitle()
	return err
}

type displayState struct {
	lastChar        string
	prevWasThinking bool
}

func (rt *runtime) agentLoopStream(userInput string) error {
	rt.interrupted.Store(false)
	rt.startEscInterruptListener()
	defer rt.stopEscInterruptListener()

	if err := rt.conv.AddUser(userInput); err != nil {
		return err
	}
	_ = rt.appendEvent(map[string]any{"type": "user_input", "content": userInput})
	// Increment turn count
	rt.incrementTurnCount()

	turn := 0
	state := displayState{lastChar: "\n"}
	for turn < rt.cfg.MaxTurns {
		turn++
		text := ""
		thinking := ""
		var calls []protocol.ToolCallEvent
		var toolResults []conversation.ToolResult
		stop := ""
		var loopError string
		if rt.cfg.Verbose {
			if messages, err := rt.conv.MessagesJSON(); err == nil {
				rt.debug("messages: %.500s...", string(messages))
			}
		}

		runner := tools.Runner{
			Config:   rt.cfg,
			TodoFile: rt.paths.Todo,
			Cwd:      rt.cwd,
			Home:     rt.home,
		}

		err := rt.llmCall(func(evt protocol.Event) error {
			if rt.interrupted.Load() {
				return errInterrupted
			}
			if rt.cfg.Verbose {
				rt.debug("<%s>", evt.Render())
			}
			switch e := evt.(type) {
			case protocol.TextEvent:
				if err := rt.displayEvent(&state, e); err != nil {
					return err
				}
				text += e.Content
			case protocol.ThinkingEvent:
				if err := rt.displayEvent(&state, e); err != nil {
					return err
				}
				thinking += e.Content
			case protocol.ToolCallEvent:
				if err := rt.displayEvent(&state, e); err != nil {
					return err
				}
				calls = append(calls, e)

				// Inline dispatch: execute tool immediately
				if rt.interrupted.Load() {
					return errInterrupted
				}
				result := runner.Dispatch(e.Name, e.InputJSON)
				if rt.interrupted.Load() {
					return errInterrupted
				}
				output := result.Output
				if result.Err != nil {
					output = "Error: tool execution failed: " + outputOrErr(output, result.Err)
				}
				output = tools.FormatToolResult(output, rt.cfg.ToolResultMaxBytes)
				var convContent string
				if e.Name == "Edit" {
					// Tool output = summary_line + "\n" + colorized_diff + "\n" (matches bash tool_edit)
					// Conv file gets summary only (matches bash: result_for_conv = first line)
					convContent = conversation.FirstLine(output)
				} else if e.Name == "Read" || e.Name == "Write" {
					// Prepend file summary to content (matches bash behavior)
					fileSummary := conversation.BuildFileToolResultSummary(e.Name, e.Fields["path"])
					output = fileSummary + "\n" + output
				}
				toolResults = append(toolResults, conversation.ToolResult{
					ToolUseID:   e.ID,
					ToolName:    e.Name,
					ToolArgs:    e.Fields,
					Content:     output,
					ConvContent: convContent,
				})
				// Display tool result immediately
				if err := rt.displayEvent(&state, toolResults[len(toolResults)-1]); err != nil {
					return err
				}
				// Handle TodoWrite event
				if e.Name == "TodoWrite" && result.Err == nil {
					if data, err := os.ReadFile(rt.paths.Todo); err == nil && len(data) > 0 {
						todoContent := strings.TrimRight(string(data), "\n")
						_ = rt.appendEvent(map[string]any{"type": "todo_update", "content": todoContent})
						if rt.isStreamJSONMode() {
							_ = rt.emitStream(map[string]any{"type": "todo_update", "content": todoContent})
						}
					}
				}
			case protocol.UsageEvent:
				if err := rt.displayEvent(&state, e); err != nil {
					return err
				}
			case protocol.StopEvent:
				stop = e.Reason
				if err := rt.displayEvent(&state, e); err != nil {
					return err
				}
			case protocol.ErrorEvent:
				loopError = e.Message
				stop = "error"
				_ = rt.displayEvent(&state, e)
				return fmt.Errorf("%s", e.Message)
			case protocol.RetryEvent:
				_ = rt.displayEvent(&state, e)
				text = ""
				thinking = ""
				calls = calls[:0]
				toolResults = toolResults[:0]
			}
			return nil
		})
		if err != nil {
			if errors.Is(err, errInterrupted) {
				stop = "interrupted"
			} else if loopError == "" {
				// Pre-stream HTTP/network error — record to events.jsonl before returning
				_ = rt.emitAndAppendEvent(map[string]any{"type": "error", "message": err.Error()})
				_ = rt.emitAndAppendEvent(map[string]any{"type": "stop", "reason": "error"})
				if !rt.isStreamJSONMode() {
					rt.error("%s", err.Error())
				}
				return err
			}
		}

		// Fatal stop reasons exit immediately
		switch stop {
		case "error", "max_tokens", "length":
			if stop == "error" {
				if loopError != "" {
					return fmt.Errorf("%s", loopError)
				}
				return fmt.Errorf("unknown API error")
			}
			if stop != "error" {
				rt.error("Response truncated (max_tokens reached)")
			}
			return nil
		}

		// Tools already executed inline; persist unless interrupted
		if !rt.interrupted.Load() {
			if err := rt.conv.AddAssistant(text, thinking, calls); err != nil {
				return err
			}
			if len(toolResults) > 0 {
				if err := rt.conv.AddToolResults(toolResults); err != nil {
					return err
				}
				// Note: granular tool_result events already written by displayEvent inline
			}
			// Update stats with captured usage from this turn (matches bash agent_loop_stream)
			if rt.lastInputTokens > 0 {
				rt.updateStatsFromLastUsage()
			}
			_, _ = rt.compactContextWindow()
			// tool_use/tool_calls → loop continues; anything else → break
			if stop != "tool_use" && stop != "tool_calls" {
				return nil
			}
		} else {
			// Match bash: write stop interrupted event to events.jsonl (always)
			// and to stdout if stream-json mode
			_ = rt.emitAndAppendEvent(map[string]any{"type": "stop", "reason": "interrupted"})
			if rt.isStreamJSONMode() {
				// In stream-json mode the JSON was already printed by emitAndAppendEvent
			} else {
				if state.lastChar != "\n" {
					_, _ = fmt.Fprint(rt.stdout, rt.nl())
				}
				_, _ = fmt.Fprint(rt.stdout, "Interrupted."+rt.nl())
			}
			return nil
		}
	}
	rt.error("Max turns (%d) reached", rt.cfg.MaxTurns)
	return nil
}

func (rt *runtime) llmCall(emit func(protocol.Event) error) error {
	body, err := rt.buildLLMRequest()
	if err != nil {
		return err
	}

	const maxRetries = 2
	for attempt := 0; attempt <= maxRetries; attempt++ {
		respBody, err := rt.postLLMRequest(body)
		if err != nil {
			if attempt < maxRetries {
				continue
			}
			return err
		}

		done := make(chan struct{})
		events, streamErr := rt.streamLLMEvents(respBody, done)

		for evt := range events {
			if err := emit(evt); err != nil {
				close(done)
				respBody.Close()
				return err
			}
		}

		streamError := <-streamErr
		close(done)
		respBody.Close()

		if streamError == nil {
			return nil
		}

		// Stream error: retry if retryable and attempts remain
		if httpclient.IsRetryableStreamError(streamError) && attempt < maxRetries {
			_ = emit(protocol.RetryEvent{})
			continue
		}

		return streamError
	}
	return nil
}

func (rt *runtime) buildLLMRequest() ([]byte, error) {
	lines, err := rt.conv.Lines()
	if err != nil {
		return nil, fmt.Errorf("build_request: %w", err)
	}
	systemPrompt, err := prompt.Builder{
		Cwd:         rt.cwd,
		Home:        rt.home,
		Skills:      rt.cfg.Skills,
		SummaryFile: rt.paths.Summary,
		TodoFile:    rt.paths.Todo,
		PlanFile:    rt.paths.Plan,
	}.BuildSystemPrompt()
	if err != nil {
		return nil, fmt.Errorf("build_request: %w", err)
	}
	claudeBody, err := provider.BuildClaudeRequest(rt.cfg, lines, rt.toolsJSON, systemPrompt, rt.cfg.MaxTokens, rt.cfg.ThinkingBudget)
	if err != nil {
		return nil, fmt.Errorf("build_request: %w", err)
	}
	body, err := rt.transport.ConvertBody(claudeBody)
	if err != nil {
		return nil, fmt.Errorf("body_convert: %w", err)
	}
	if rt.cfg.Verbose {
		rt.verbose("Request body (%dKB): %.200s...", len(body)/1024, string(body))
	}
	return body, nil
}

func (rt *runtime) postLLMRequest(body []byte) (io.ReadCloser, error) {
	headers := rt.headers()
	respBody, err := rt.http.Post(rt.apiURL, headers, body)
	if err != nil {
		var httpErr httpclient.HTTPError
		if errors.As(err, &httpErr) {
			return nil, fmt.Errorf("http_post: %s", httpErr.FormatDetailed())
		}
		return nil, fmt.Errorf("http_post: %w", err)
	}
	return respBody, nil
}

func (rt *runtime) streamLLMEvents(respBody io.Reader, done <-chan struct{}) (<-chan protocol.Event, <-chan error) {
	events := make(chan protocol.Event, 16)
	errCh := make(chan error, 1)
	go func() {
		defer close(events)
		defer close(errCh)
		emit := func(evt protocol.Event) error {
			select {
			case <-done:
				return errInterrupted
			case events <- evt:
			}
			return nil
		}
		if err := rt.transport.ParseSSE(respBody, emit); err != nil {
			errCh <- fmt.Errorf("sse_parse: %w", err)
			return
		}
		errCh <- nil
	}()
	return events, errCh
}

// emitAndAppendEvent writes an event to events.jsonl (always) and to stdout (only in stream-json mode).
// Mirrors bash's agent_loop which does: session_append_line + (stream-json || human display).
func (rt *runtime) emitAndAppendEvent(v map[string]any) error {
	_ = rt.appendEvent(v)
	if rt.isStreamJSONMode() {
		return rt.emitStream(v)
	}
	return nil
}

func (rt *runtime) displayEvent(state *displayState, evt any) error {
	switch e := evt.(type) {
	case protocol.TextEvent:
		// Always write to events.jsonl, and to stdout if stream-json mode
		if err := rt.emitAndAppendEvent(map[string]any{"type": "text", "content": e.Content}); err != nil {
			return err
		}
		if rt.isStreamJSONMode() {
			return nil
		}
		// Insert newline when transitioning from thinking to text
		if state.prevWasThinking && state.lastChar != "\n" {
			if _, err := rt.writeHuman(rt.nl()); err != nil {
				return err
			}
			state.lastChar = "\n"
		}
		state.prevWasThinking = false
		displayContent := normalizeDisplayText(e.Content)
		if _, err := rt.writeHuman(displayContent); err != nil {
			return err
		}
		if displayContent != "" {
			if strings.HasSuffix(displayContent, "\n") {
				state.lastChar = "\n"
			} else {
				state.lastChar = displayContent[len(displayContent)-1:]
			}
		}
	case protocol.ThinkingEvent:
		if err := rt.emitAndAppendEvent(map[string]any{"type": "thinking", "content": e.Content}); err != nil {
			return err
		}
		if rt.isStreamJSONMode() {
			return nil
		}
		displayContent := normalizeDisplayText(e.Content)
		if _, err := rt.writeHuman(fmt.Sprintf("\033[90m%s\033[0m", displayContent)); err != nil {
			return err
		}
		if displayContent != "" {
			if strings.HasSuffix(displayContent, "\n") {
				state.lastChar = "\n"
			} else {
				state.lastChar = displayContent[len(displayContent)-1:]
			}
		}
		state.prevWasThinking = true
	case protocol.ToolCallEvent:
		toolCallEvt := map[string]any{
			"type":  "tool_call",
			"name":  e.Name,
			"id":    e.ID,
			"input": json.RawMessage(e.InputJSON),
		}
		if err := rt.emitAndAppendEvent(toolCallEvt); err != nil {
			return err
		}
		if rt.isStreamJSONMode() {
			return nil
		}
		// display_ensure_newline (match bash)
		if state.lastChar != "\n" {
			if _, err := rt.writeHuman(rt.nl()); err != nil {
				return err
			}
		}
		state.lastChar = "\n"
		if _, err := rt.writeHuman(fmt.Sprintf("\033[33m[tool] %s\033[0m\n", conversation.BuildToolCallSummary(e.Name, e.Fields))); err != nil {
			return err
		}
	case protocol.UsageEvent:
		usageEvt := map[string]any{
			"type":                     "usage",
			"input_tokens":             e.InputTokens,
			"output_tokens":            e.OutputTokens,
			"cache_read_input_tokens":  e.CacheReadInputTokens,
			"cache_creation_input_tokens": e.CacheCreationInputTokens,
		}
		if err := rt.emitAndAppendEvent(usageEvt); err != nil {
			return err
		}
		// Track context tokens and usage for compact and stats
		// context = input + output + cache_read + cache_creation
		rt.lastContextTokens = e.InputTokens + e.OutputTokens + e.CacheReadInputTokens + e.CacheCreationInputTokens
		rt.lastInputTokens = e.InputTokens
		rt.lastOutputTokens = e.OutputTokens
		rt.lastCacheReadTokens = e.CacheReadInputTokens
		rt.lastCacheCreationTokens = e.CacheCreationInputTokens
	case protocol.StopEvent:
		if err := rt.emitAndAppendEvent(map[string]any{"type": "stop", "reason": e.Reason}); err != nil {
			return err
		}
		if rt.isStreamJSONMode() {
			return nil
		}
		if state.lastChar != "\n" {
			if _, err := rt.writeHuman(rt.nl()); err != nil {
				return err
			}
			state.lastChar = "\n"
		}
	case protocol.ErrorEvent:
		_ = rt.emitAndAppendEvent(map[string]any{"type": "error", "message": e.Message})
		return fmt.Errorf("%s", e.Message)
	case protocol.RetryEvent:
		_ = rt.emitAndAppendEvent(map[string]any{"type": "retry"})
	case conversation.ToolResult:
		toolResultEvt := map[string]any{
			"type":        "tool_result",
			"tool_use_id": e.ToolUseID,
			"name":        e.ToolName,
			"content":     e.Content,
		}
		if err := rt.emitAndAppendEvent(toolResultEvt); err != nil {
			return err
		}
		if rt.isStreamJSONMode() {
			return nil
		}
		// Match bash display_event TOOL_RESULT exactly:
		// All tools: content already finalized at stream layer — just use as-is
		var trText string
		if e.ToolName == "Edit" {
			// Content = summary_line + "\n" + colorized_diff + "\n" (from tool layer)
			trText = normalizeDisplayText(e.Content)
			// Ensure trailing newline
			if !strings.HasSuffix(trText, "\n") {
				trText += "\n"
			}
		} else if e.ToolName == "Read" || e.ToolName == "Write" {
			// Summary is already prepended to content; use first line for display
			trText = conversation.FirstLine(normalizeDisplayText(e.Content)) + "\n"
		} else {
			trText = normalizeDisplayText(e.Content) + "\n"
		}
		// Insert newline when transitioning from thinking to text
		if state.prevWasThinking && state.lastChar != "\n" {
			if _, err := rt.writeHuman(rt.nl()); err != nil {
				return err
			}
			state.lastChar = "\n"
		}
		state.prevWasThinking = false
		if trText != "" {
			if _, err := rt.writeHuman(trText); err != nil {
				return err
			}
			if strings.HasSuffix(trText, "\n") {
				state.lastChar = "\n"
			} else if trText != "" {
				state.lastChar = trText[len(trText)-1:]
			}
		}
	}
	return nil
}

func (rt *runtime) startEscInterruptListener() {
	if !rt.cfg.Interactive {
		return
	}
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return
	}
	rt.stopEscInterruptListener()
	oldState, err := term.MakeRaw(int(tty.Fd()))
	if err != nil {
		_ = tty.Close()
		return
	}
	stop := make(chan struct{})
	done := make(chan struct{})
	rt.escTTY = tty
	rt.escState = oldState
	rt.escStop = stop
	rt.escDone = done

	go func() {
		defer close(done)
		fd := int(tty.Fd())
		buf := make([]byte, 1)
		for {
			select {
			case <-stop:
				return
			default:
			}

			var readfds unix.FdSet
			readfds.Set(fd)
			timeout := unix.Timeval{Sec: 0, Usec: 100000} // 100ms
			n, err := unix.Select(fd+1, &readfds, nil, nil, &timeout)
			if err != nil {
				if errors.Is(err, unix.EINTR) {
					continue
				}
				select {
				case <-stop:
					return
				default:
				}
				return
			}
			if n == 0 || !readfds.IsSet(fd) {
				continue
			}
			n, err = unix.Read(fd, buf)
			if err != nil {
				if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
					continue
				}
				return
			}
			if n == 1 && buf[0] == 0x1b {
				rt.interrupted.Store(true)
			}
		}
	}()
}

func (rt *runtime) stopEscInterruptListener() {
	if rt.escStop != nil {
		close(rt.escStop)
		rt.escStop = nil
	}
	if rt.escDone != nil {
		<-rt.escDone
		rt.escDone = nil
	}
	if rt.escTTY != nil && rt.escState != nil {
		_ = term.Restore(int(rt.escTTY.Fd()), rt.escState)
		rt.escState = nil
	}
	if rt.escTTY != nil {
		_ = rt.escTTY.Close()
		rt.escTTY = nil
	}
}

func (rt *runtime) compactContextWindow() (bool, error) {
	stats := rt.readStats()
	contextTokens := int(statsFloat64(stats, "current_context_tokens"))
	currentTurn := int(statsFloat64(stats, "current_turn_count"))
	prevCompactions := int(statsFloat64(stats, "compact_request_count"))

	// L: avg LLM calls per user input (auto-compute from stats)
	totalRequests := int(statsFloat64(stats, "agent_request_count"))
	L := rt.cfg.DPL
	if L <= 0 {
		if currentTurn > 0 && totalRequests > 0 {
			L = float64(totalRequests) / float64(currentTurn)
		}
		if L < 1 {
			L = 5.0
		}
	}

	// avg: average input tokens per LLM request
	totalInputTokens := int(statsFloat64(stats, "total_input_tokens"))
	avgPerRequest := 4000
	if totalRequests > 0 {
		avgPerRequest = totalInputTokens / totalRequests
	}

	// DP decision
	dpCfg := conversation.DPCompactConfig{
		PInput:        rt.cfg.DPPInput,
		PCache:       rt.cfg.DPPCache,
		POut:         rt.cfg.DPPOut,
		V:            rt.cfg.DPV,
		S:            rt.cfg.DPS,
		Avg:          avgPerRequest,
		L:            L,
		BaselineE:    rt.cfg.DPBaselineE,
		EFixed:       rt.cfg.DPEFixed,
		R:            rt.cfg.DPR,
		Beta:         rt.cfg.DPBeta,
		MinKeepRatio: rt.cfg.DPMinKeepRatio,
	}

	keepLines, err := rt.conv.CompactDPDecision(dpCfg, prevCompactions, currentTurn)
	if err != nil {
		return false, err
	}

	if keepLines == 0 {
		// Safety valve: DP says no, but check context size
		if contextTokens > 0 && contextTokens > rt.cfg.MaxContextTokens*90/100 {
			totalLines, _ := rt.conv.TotalLines()
			minKeep := int(float64(totalLines)*dpCfg.MinKeepRatio + 0.5)
			if minKeep < 3 {
				minKeep = 3
			}
			if minKeep >= totalLines {
				return false, nil
			}
			keepLines = minKeep
		} else {
			return false, nil
		}
	}

	totalLines, err := rt.conv.TotalLines()
	if err != nil {
		return false, err
	}
	if keepLines >= totalLines {
		return false, nil
	}
	drop := totalLines - keepLines

	allLines, err := rt.conv.Lines()
	if err != nil {
		return false, err
	}
	summary, err := rt.runSummaryCall(allLines[:drop])
	if err != nil {
		return false, err
	}
	if err := os.WriteFile(rt.paths.Summary, []byte(summary+"\n"), 0o644); err != nil {
		return false, err
	}
	if err := rt.conv.TrimKeepLast(keepLines); err != nil {
		return false, err
	}
	// Recalculate turn count based on remaining conversation history
	remainingTurns, err := rt.conv.CountUserInputs()
	if err == nil {
		stats := rt.readStats()
		stats["current_turn_count"] = float64(remainingTurns)
		stats["last_updated"] = time.Now().UTC().Format("2006-01-02T15:04:05Z")
		rt.writeStats(stats)
	}
	if rt.isStreamJSONMode() {
		_ = rt.emitStream(map[string]any{"type": "context_update", "kind": "compact", "trigger": "auto"})
	} else {
		rt.info("Context compacted automatically.")
	}
	return true, nil
}

func (rt *runtime) runSummaryCall(droppedLines []json.RawMessage) (string, error) {
	// Build messages: dropped conversation lines + summary instruction
	// Uses same system prompt + tools + thinking as normal requests for cache reuse
	summaryInstruction := "The conversation context above needs to be compacted. Summarize the key information from the messages above into a concise context summary. Update the existing summary snapshot using the messages above. Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:"
	msg, err := json.Marshal(map[string]any{
		"role":    "user",
		"content": summaryInstruction,
	})
	if err != nil {
		return "", err
	}
	lines := make([]json.RawMessage, 0, len(droppedLines)+1)
	lines = append(lines, droppedLines...)
	lines = append(lines, msg)

	systemPrompt, err := prompt.Builder{
		Cwd:         rt.cwd,
		Home:        rt.home,
		Skills:      rt.cfg.Skills,
		SummaryFile: rt.paths.Summary,
		TodoFile:    rt.paths.Todo,
		PlanFile:    rt.paths.Plan,
	}.BuildSystemPrompt()
	if err != nil {
		return "", fmt.Errorf("build_system_prompt: %w", err)
	}
	claudeBody, err := provider.BuildClaudeRequest(rt.cfg, lines, rt.toolsJSON, systemPrompt, rt.cfg.SummaryMaxTokens, rt.cfg.ThinkingBudget)
	if err != nil {
		return "", fmt.Errorf("build_summary_request: %w", err)
	}
	body, err := rt.transport.ConvertBody(claudeBody)
	if err != nil {
		return "", fmt.Errorf("body_convert: %w", err)
	}
	if rt.cfg.Verbose {
		rt.verbose("Summary request body (%dKB): %.200s...", len(body)/1024, string(body))
	}
	respBody, err := rt.http.Post(rt.apiURL, rt.headers(), body)
	if err != nil {
		var httpErr httpclient.HTTPError
		if errors.As(err, &httpErr) {
			return "", fmt.Errorf("http_post: %s", httpErr.FormatDetailed())
		}
		return "", fmt.Errorf("http_post: %w", err)
	}
	defer respBody.Close()
	var b strings.Builder
	parserEmit := func(evt protocol.Event) error {
		switch e := evt.(type) {
		case protocol.TextEvent:
			b.WriteString(e.Content)
		case protocol.UsageEvent:
			_ = rt.recordUsage("compact", "compact_request_count", e)
		case protocol.ErrorEvent:
			return fmt.Errorf("%s", e.Message)
		}
		return nil
	}
	if err := rt.transport.ParseSSE(respBody, parserEmit); err != nil {
		return "", fmt.Errorf("sse_parse: %w", err)
	}
	if b.Len() == 0 {
		return "", errors.New("failed to generate context summary")
	}
	return b.String(), nil
}

func (rt *runtime) headers() map[string]string {
	headers := map[string]string{
		"Content-Type": "application/json",
		"User-Agent":   "claude-cli/1.0.33 (max, cli)",
	}
	switch rt.cfg.Provider {
	case "claude":
		headers["x-api-key"] = rt.cfg.APIKey
		headers["anthropic-version"] = "2023-06-01"
		headers["x-app"] = "cli"
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

// incrementTurnCount increments the current_turn_count in stats.json.
func (rt *runtime) incrementTurnCount() {
	stats := rt.readStats()
	stats["current_turn_count"] = statsFloat64(stats, "current_turn_count") + 1
	stats["last_updated"] = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	rt.writeStats(stats)
}

// recordUsage logs a usage event and updates stats. Returns context token count.
func (rt *runtime) recordUsage(kind, counterKey string, e protocol.UsageEvent) int {
	evt := map[string]any{
		"type":                        "usage",
		"input_tokens":                e.InputTokens,
		"output_tokens":               e.OutputTokens,
		"cache_read_input_tokens":     e.CacheReadInputTokens,
		"cache_creation_input_tokens": e.CacheCreationInputTokens,
		"kind":                        kind,
	}
	_ = rt.appendEvent(evt)
	stats := rt.readStats()
	stats[counterKey] = statsFloat64(stats, counterKey) + 1
	stats["total_input_tokens"] = statsFloat64(stats, "total_input_tokens") + float64(e.InputTokens)
	stats["total_output_tokens"] = statsFloat64(stats, "total_output_tokens") + float64(e.OutputTokens)
	stats["total_cache_read_tokens"] = statsFloat64(stats, "total_cache_read_tokens") + float64(e.CacheReadInputTokens)
	stats["total_cache_creation_tokens"] = statsFloat64(stats, "total_cache_creation_tokens") + float64(e.CacheCreationInputTokens)
	rt.writeStats(stats)
	return e.InputTokens + e.OutputTokens + e.CacheReadInputTokens + e.CacheCreationInputTokens
}

// updateStatsFromLastUsage updates stats.json with last turn's usage (matches bash).
// Uses the last captured usage data to increment counters and update context_tokens.
func (rt *runtime) updateStatsFromLastUsage() {
	stats := rt.readStats()
	stats["agent_request_count"] = statsFloat64(stats, "agent_request_count") + 1
	stats["total_input_tokens"] = statsFloat64(stats, "total_input_tokens") + float64(rt.lastInputTokens)
	stats["total_output_tokens"] = statsFloat64(stats, "total_output_tokens") + float64(rt.lastOutputTokens)
	stats["total_cache_read_tokens"] = statsFloat64(stats, "total_cache_read_tokens") + float64(rt.lastCacheReadTokens)
	stats["total_cache_creation_tokens"] = statsFloat64(stats, "total_cache_creation_tokens") + float64(rt.lastCacheCreationTokens)
	// context = input + output + cache_read + cache_creation
	stats["current_context_tokens"] = float64(rt.lastInputTokens + rt.lastOutputTokens + rt.lastCacheReadTokens + rt.lastCacheCreationTokens)
	stats["last_updated"] = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	rt.writeStats(stats)
}

// readStats reads and parses stats.json, returning default zero values if missing.
func (rt *runtime) readStats() map[string]any {
	stats := map[string]any{
		"current_turn_count":         float64(0),
		"agent_request_count":        float64(0),
		"compact_request_count":      float64(0),
		"total_input_tokens":         float64(0),
		"total_output_tokens":        float64(0),
		"total_cache_read_tokens":    float64(0),
		"total_cache_creation_tokens": float64(0),
		"current_context_tokens":     float64(0),
		"last_updated":               "",
	}
	data, err := os.ReadFile(rt.paths.Stats)
	if err != nil {
		return stats
	}
	var parsed map[string]any
	if err := json.Unmarshal(data, &parsed); err == nil {
		for k, v := range parsed {
			stats[k] = v
		}
	}
	return stats
}

// writeStats serializes and writes stats.json.
func (rt *runtime) writeStats(stats map[string]any) {
	data, err := json.Marshal(stats)
	if err != nil {
		return
	}
	_ = os.WriteFile(rt.paths.Stats, append(data, '\n'), 0o644)
}

// statsFloat64 safely extracts a float64 from a stats map.
func statsFloat64(m map[string]any, key string) float64 {
	if v, ok := m[key]; ok {
		if f, ok := v.(float64); ok {
			return f
		}
	}
	return 0
}

// updateTermTitle updates the terminal title with current stats (matches bash stats_show_osc).
func (rt *runtime) updateTermTitle() {
	stats := rt.readStats()
	tc := int(statsFloat64(stats, "current_turn_count"))
	ar := int(statsFloat64(stats, "agent_request_count"))
	ai := int(statsFloat64(stats, "total_input_tokens"))
	ao := int(statsFloat64(stats, "total_output_tokens"))
	ctx := int(statsFloat64(stats, "current_context_tokens"))
	_, _ = fmt.Fprintf(rt.stderr, "\033]0;T:%d R:%d I:%d O:%d C:%d\007", tc, ar, ai, ao, ctx)
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
	_, _ = fmt.Fprintf(rt.stderr, "\033[36m%s\033[0m%s", fmt.Sprintf(format, args...), rt.nl())
}

func (rt *runtime) error(format string, args ...any) {
	_, _ = fmt.Fprintf(rt.stderr, "\033[31mError: %s\033[0m%s", fmt.Sprintf(format, args...), rt.nl())
}

func (rt *runtime) verbose(format string, args ...any) {
	if rt.cfg.Verbose {
		_, _ = fmt.Fprintf(rt.stderr, "\033[90m[verbose] %s\033[0m%s", fmt.Sprintf(format, args...), rt.nl())
	}
}

func (rt *runtime) debug(format string, args ...any) {
	if rt.cfg.Verbose {
		_, _ = fmt.Fprintf(rt.stderr, "[debug] %s%s", fmt.Sprintf(format, args...), rt.nl())
	}
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "Usage: goagent [options] [prompt]")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Options:")
	fmt.Fprintln(w, "  -p, --provider PROV     LLM provider: claude | openai (default: claude)")
	fmt.Fprintln(w, "  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)")
	fmt.Fprintln(w, "  --max-tokens N          Max output tokens (default: 4096)")
	fmt.Fprintln(w, "  --tool-timeout N        Tool execution timeout in seconds (default: 600)")
	fmt.Fprintln(w, "  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)")
	fmt.Fprintln(w, "  --max-turns N           Max agent turns (default: 40)")
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
		name    string
		mod     time.Time
		summary string
	}
	var rows []row
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		sessionName := entry.Name()
		info, err := entry.Info()
		if err != nil {
			continue
		}
		summaryFile := filepath.Join(dir, sessionName, "summary.txt")
		var summary string
		if data, err := os.ReadFile(summaryFile); err == nil {
			lines := strings.Split(strings.TrimSpace(string(data)), "\n")
			for _, line := range lines {
				line = strings.TrimSpace(line)
				if line != "" {
					summary = line
					break
				}
			}
		}
		rows = append(rows, row{
			name:    sessionName,
			mod:     info.ModTime(),
			summary: summary,
		})
	}
	if len(rows) == 0 {
		fmt.Fprintln(w, "No sessions found.")
		return nil
	}
	fmt.Fprintf(w, "%-40s %-16s %s\n", "NAME", "MODIFIED", "PREVIEW")
	sort.Slice(rows, func(i, j int) bool { return rows[i].mod.After(rows[j].mod) })
	for _, row := range rows {
		preview := row.summary
		if len(preview) > 60 {
			preview = preview[:57] + "..."
		}
		fmt.Fprintf(w, "%-40s %-16s %s\n", row.name, row.mod.Format("2006-01-02 15:04"), preview)
	}
	return nil
}
