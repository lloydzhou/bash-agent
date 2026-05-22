package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ═══════════════════════════════════════════
// Agent — 核心编排层 (agent_*)
// ═══════════════════════════════════════════

type Agent struct {
	cfg              Config
	store            SessionStore
	llm              Transport
	tools            *ToolDispatcher
	display          *TermDisplay
	toolDefs         string // JSON 格式工具定义
	ctxTokens        int    // 当前上下文 token 数
	pendingSubAgents int    // 等待中的子 agent 数量
	subResultCh      chan SubAgentResult
	subMu            sync.Mutex
}

type SubAgentResult struct {
	SessionID    string
	Status       string // "ok" or "failed"
	Thinking     string
	Text         string
	InputTokens  int
	OutputTokens int
	CacheRead    int
	CacheWrite   int
	Requests     int
}

func NewAgent(cfg Config, store SessionStore, llm Transport, tools *ToolDispatcher, display *TermDisplay) *Agent {
	a := &Agent{
		cfg:         cfg,
		store:       store,
		llm:         llm,
		tools:       tools,
		display:     display,
		subResultCh: make(chan SubAgentResult, 8),
	}
	// 设置回调
	a.tools.SetSubAgentLauncher(a.LaunchSubAgent)
	a.tools.SetPlanConfirm(a.HandlePlanConfirm)
	a.tools.SetPlanClear(a.HandlePlanClear)
	a.tools.SetSkillLoader(a.LoadSkill)
	return a
}

// SetToolDefs 设置工具定义 JSON
func (a *Agent) SetToolDefs(toolDefs string) {
	a.toolDefs = toolDefs
}

// ─── agent_build_prompt: 构建 system prompt ───

func (a *Agent) BuildPrompt() string {
	locale := os.Getenv("LC_ALL")
	if locale == "" {
		locale = os.Getenv("LC_MESSAGES")
	}
	if locale == "" {
		locale = os.Getenv("LANG")
	}
	if locale == "" {
		locale = "en_US"
	}
	locale = strings.SplitN(locale, ".", 2)[0]

	var sections []string
	appendSection := func(tag, content string, name string) {
		if content == "" {
			return
		}
		var sb strings.Builder
		sb.WriteString("<")
		sb.WriteString(tag)
		if name != "" {
			sb.WriteString(" name=\"")
			sb.WriteString(name)
			sb.WriteString("\"")
		}
		sb.WriteString(">\n")
		sb.WriteString(content)
		sb.WriteString("\n</")
		sb.WriteString(tag)
		sb.WriteString(">")
		sections = append(sections, sb.String())
	}

	// agent-identity
	identity := "You are bash-agent, a lightweight coding agent that works in a terminal."
	if strings.HasPrefix(locale, "zh") {
		identity = "你是 bash-agent，一个在终端中运行的轻量级编码智能体。"
	}
	appendSection("agent-identity", identity, "")

	// environment — platform 与 bash 的 uname -s 输出一致
	platform := runtime.GOOS
	switch platform {
	case "darwin":
		platform = "Darwin"
	case "linux":
		platform = "Linux"
	}
	env := fmt.Sprintf("lang: %s\npwd: %s\nhome: %s\nplatform: %s\nshell: %s",
		locale, mustGetwd(), os.Getenv("HOME"), platform, os.Getenv("SHELL"))
	appendSection("environment", env, "")

	// rules
	rules := "- Be concise and concrete. No pleasantries, no explanations unless asked. Raw results only.\n" +
		"- Prefer safe, exact edits.\n- Report failures clearly."
	appendSection("rules", rules, "")

	// tool guidance
	toolGuidance := "- Use Read for a single file. If you need multiple files, call Read multiple times.\n" +
		"- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n" +
		"- Use Glob and Grep for one pattern at a time.\n" +
		"- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n" +
		"- Use multiple tool calls in one response when they are independent.\n" +
		"- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n" +
		"- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n" +
		"- For skills, first check the skill-index section, then use Skill(name) for the matching skill.\n" +
		"- SubAgent launches a background agent session. Results are injected back into your conversation when complete. Use for parallelizable or independent sub-tasks. See sub-agent-guidance section for context inheritance rules."
	appendSection("using-your-tools", toolGuidance, "")

	// sub-agent guidance
	subAgentGuidance := "- **When to use**: delegating independent sub-tasks that do NOT need your current conversation context — e.g. investigating a separate file, running a focused search, testing a hypothesis in isolation.\n" +
		"- **When NOT to use**: tasks that depend on your working context, conversation history, or intermediate state. The child agent starts with a blank slate.\n" +
		"- **Fork mode**: pass `fork=true` to inherit parent session context (conversation history, plan, skills). Use when the child needs your working context.\n" +
		"- **Prompt design**: write a complete, self-contained prompt. Include all file paths, function names, error messages, and constraints the child needs. Assume zero shared context.\n" +
		"- **Result handling**: when the child completes, its result is injected as a user message: `[sub-agent <id>] <status> (in=<n>, out=<n>)\nThinking: ...\nText: ...`. You then get another LLM turn to interpret and act on it.\n" +
		"- **Parallelism**: multiple SubAgent calls in one turn run concurrently. Use this to parallelize independent investigations. **IMPORTANT**: results return asynchronously as each sub-agent finishes — they do NOT return together. When you receive a result for one sub-agent, the others are still running. Simply wait for all results to arrive before acting. Do NOT re-launch a sub-agent just because another one finished first — match results by session_id.\n" +
		"- **Failure**: if the child fails (status=failed), the result text may be partial or empty. Handle gracefully — do not retry automatically."
	appendSection("sub-agent-guidance", subAgentGuidance, "")

	// todo guidance
	todoGuidance := "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n" +
		"- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n" +
		"- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n" +
		"- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n" +
		"- Keep the checklist short, concrete, and actionable.\n" +
		"- Prefer exactly one in_progress item when work is actively underway.\n" +
		"- Mark items completed immediately after finishing them, and remove stale items that no longer matter."
	appendSection("todo-guidance", todoGuidance, "")

	// plan lifecycle
	pdPath, pPath := a.store.PlanDraftPath(), a.store.PlanPath()
	if pdPath == "" {
		pdPath = "<not set>"
	}
	if pPath == "" {
		pPath = "<not set>"
	}
	planGuidance := "- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n" +
		"- **Files**: PLAN_DRAFT_FILE: " + pdPath + " | PLAN_FILE: " + pPath + "\n" +
		"- **Why draft first?** Writing to PLAN_FILE immediately invalidates the system prompt cache. Use PLAN_DRAFT_FILE for all drafting iterations to avoid this cost.\n" +
		"- **Drafting phase** (PLAN_DRAFT_FILE non-empty → you are drafting):\n" +
		"  Every user reply MUST be classified as exactly ONE of:\n" +
		"  ① REVISE (any feedback/question/change) → Edit PLAN_DRAFT_FILE → ask confirmation → stay in drafting\n" +
		"  ② CONFIRM (explicit ok/go/confirmed) → call PlanConfirm IMMEDIATELY (before any other action) → TodoWrite checklist → execute\n" +
		"  ③ CANCEL (explicit cancel/forget it) → Bash `: > PLAN_DRAFT_FILE` → exit to idle\n" +
		"  ⚠ On CONFIRM you MUST call PlanConfirm first — no edits, no tool calls before it.\n" +
		"- **Execution phase**: after PlanConfirm → TodoWrite checklist → execute tasks → PlanClear when all done\n" +
		"- **Plan vs Todo**: PLAN_FILE=locked plan (only via PlanConfirm), PLAN_DRAFT_FILE=draft (edit freely), TodoWrite=progress tracker. Do NOT mix."
	appendSection("plan-lifecycle-guidance", planGuidance, "")

	// instruction files
	instructions := a.buildInstructionsSection()
	appendSection("instruction-files", instructions, "")

	// skill index
	skillIndex := a.buildSkillIndex()
	appendSection("skill-index", skillIndex, "")

	// selected skills
	for _, sn := range a.cfg.SkillNames {
		if content, err := a.loadSkillContent(sn); err == nil {
			appendSection("skill", content, sn)
		}
	}

	// current plan (with plan file name as attribute)
	if plan, err := a.store.GetPlan(); err == nil && plan != "" {
		appendSection("current-plan", plan, pPath)
	}

	// context snapshot (summary)
	if summary, err := a.store.GetSummary(); err == nil && summary != "" {
		appendSection("context-snapshot", summary, "")
	}

	// output language — 必须放在最后
	outputLang := "MUST use \"" + locale + "\" for all output, including your Chain of Thought/reasoning/thinking! Never mix languages! Code, commands, and file content remain as-is."
	if strings.HasPrefix(locale, "zh") {
		outputLang = "再次强调：必须使用中文进行所有输出，包括你的思考过程（Chain of Thought/推理/thinking）！严禁在思考或回答中出现任何英文内容！"
	}
	appendSection("output-language", outputLang, "")

	return strings.Join(sections, "\n")
}

// ─── agent_record_usage: 记录 token 用量 ───

func (a *Agent) RecordUsage(usage Usage, kind, model string) int {
	ctxTokens := usage.InputTokens + usage.OutputTokens + usage.CacheRead + usage.CacheWrite
	a.ctxTokens = ctxTokens
	_ = a.store.UpdateStats(usage, model)
	// 更新 ContextTokens 到 stats
	a.store.SetContextTokens(ctxTokens)
	return ctxTokens
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		return "?"
	}
	return wd
}

// ─── Skill / Instruction 辅助函数 ───

// findSkillDirs 返回 skill 搜索目录列表（按优先级）
func (a *Agent) findSkillDirs() []string {
	var dirs []string
	cwd := mustGetwd()
	home := os.Getenv("HOME")

	if dirExists(cwd + "/.claude/skills") {
		dirs = append(dirs, cwd+"/.claude/skills")
	}
	if dirExists(cwd + "/skills") {
		dirs = append(dirs, cwd+"/skills")
	}
	if home != "" {
		if dirExists(home + "/.claude/skills") {
			dirs = append(dirs, home+"/.claude/skills")
		}
	}
	return dirs
}

// buildSkillIndex 扫描所有 skill 目录，生成 "name: summary" 列表
func (a *Agent) buildSkillIndex() string {
	seen := make(map[string]bool)
	var lines []string
	for _, base := range a.findSkillDirs() {
		entries, err := os.ReadDir(base)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() {
				continue
			}
			name := e.Name()
			if seen[name] {
				continue
			}
			seen[name] = true
			skillFile := base + "/" + name + "/SKILL.md"
			summary := extractSkillSummary(skillFile)
			line := "- " + name
			if summary != "" {
				line += ": " + summary
			}
			lines = append(lines, line)
		}
	}
	return strings.Join(lines, "\n")
}

// loadSkillContent 加载指定 skill 的完整内容（含路径替换）
func (a *Agent) loadSkillContent(name string) (string, error) {
	for _, base := range a.findSkillDirs() {
		skillFile := base + "/" + name + "/SKILL.md"
		data, err := os.ReadFile(skillFile)
		if err != nil {
			continue
		}
		skillDir := base + "/" + name
		content := strings.ReplaceAll(string(data), "${BASH_AGENT_SKILL_DIR}", skillDir)
		return "Base directory: " + skillDir + "\n\n" + content, nil
	}
	return "", fmt.Errorf("skill not found: %s", name)
}

// findInstructionFile 在给定目录查找 instruction 文件
func findInstructionFile(dir string) string {
	candidates := []string{
		dir + "/AGENTS.md",
		dir + "/AGENT.md",
		dir + "/CLAUDE.md",
		dir + "/.claude/CLAUDE.md",
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c
		}
	}
	return ""
}

// buildInstructionsSection 查找全局和项目级 instruction 文件
func (a *Agent) buildInstructionsSection() string {
	var sections []string
	home := os.Getenv("HOME")

	// 全局: ~/.bash-agent/AGENTS.md 等
	if home != "" {
		if f := findInstructionFile(home + "/.bash-agent"); f != "" {
			data, err := os.ReadFile(f)
			if err == nil {
				sections = append(sections, "<instruction-file name=\"global\">\n"+string(data)+"\n</instruction-file>")
			}
		}
	}

	// 项目: $PWD/AGENTS.md 等
	if f := findInstructionFile(mustGetwd()); f != "" {
		data, err := os.ReadFile(f)
		if err == nil {
			sections = append(sections, "<instruction-file name=\"project\">\n"+string(data)+"\n</instruction-file>")
		}
	}

	return strings.Join(sections, "\n")
}

// ─── agent_compact_context: 上下文压缩 ───

func (a *Agent) CompactContext(ctx context.Context, trigger string) (bool, error) {
	stats := a.store.GetStats()

	// 从 stats 恢复 ctxTokens（首次调用 a.ctxTokens 可能为 0）
	if a.ctxTokens == 0 && stats.ContextTokens > 0 {
		a.ctxTokens = stats.ContextTokens
	}

	// DP 决策
	keepLines, err := a.store.CompactDPDecision(a.cfg)
	if err != nil {
		keepLines = 0
	}

	totalLines, _ := a.store.ConvLineCount()
	if totalLines == 0 {
		return false, nil
	}

	// DP 返回 0 或 >= total → 尝试 fallback
	if keepLines == 0 || keepLines >= totalLines {
		if trigger == "plan_clear" || trigger == "plan_confirm" ||
			(a.ctxTokens > 0 && a.ctxTokens > a.cfg.MaxContextTokens*90/100) {
			keepLines, _ = a.store.ConvTurnKeep(a.cfg.DPMinKeepRatio)
		} else {
			return false, nil
		}
	}

	if keepLines <= 0 || keepLines >= totalLines {
		if trigger != "plan_clear" && trigger != "plan_confirm" {
			return false, nil
		}
		if keepLines >= totalLines {
			return false, nil
		}
	}

	drop := totalLines - keepLines
	droppedMessages, err := a.store.ConvHeadTo(drop)
	if err != nil {
		return false, fmt.Errorf("read dropped messages: %w", err)
	}

	summaryResponse, err := a.llm.SummaryCall(ctx, droppedMessages)
	if err != nil {
		return false, fmt.Errorf("summary call failed: %w", err)
	}

	_ = a.store.SetSummary(summaryResponse)
	if keepLines < totalLines {
		_ = a.store.ConvTrimTail(keepLines)
	}

	// 更新 compact 计数
	_ = a.store.IncrementCompact()

	// 重置 turn count 为剩余 user turn 数（与 bash 版一致）
	remainingTurns, _ := a.store.ConvUserTurnCount()
	_ = a.store.SetTurnCount(remainingTurns)

	return true, nil
}

// ─── 工具回调实现 ───

func (a *Agent) HandlePlanConfirm() (string, error) {
	empty, _ := a.store.PlanDraftIsEmpty()
	if !empty {
		ctx := context.Background()
		a.CompactContext(ctx, "plan_confirm")
		_ = a.store.PlanConfirm()
		return "Plan confirmed and locked in.", nil
	}
	return "Error: no plan draft found to confirm.", nil
}

func (a *Agent) HandlePlanClear() (string, error) {
	ctx := context.Background()
	a.CompactContext(ctx, "plan_clear")
	_ = a.store.PlanClear()
	return "Plan cleared.", nil
}

func (a *Agent) LoadSkill(name string) (string, error) {
	paths := []string{
		".claude/skills/" + name + "/SKILL.md",
		os.Getenv("HOME") + "/.claude/skills/" + name + "/SKILL.md",
	}
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err == nil {
			return string(data), nil
		}
	}
	return "", fmt.Errorf("skill not found: %s", name)
}

// ─── RunLoop: 单次用户输入的 LLM 循环 ───

func (a *Agent) isStreamJSON() bool {
	return a.cfg.OutputFormat == "stream-json"
}

// streamJSON 输出一行 JSON（仅 stream-json 模式）
func (a *Agent) emitJSON(obj map[string]interface{}) {
	// 始终写 events.jsonl（与 bash 版 agent_event 一致）
	if data, err := json.Marshal(obj); err == nil {
		_ = a.store.AppendEvent(string(data))
	}
	// stream-json 模式额外输出到 stdout
	if a.isStreamJSON() {
		data, _ := json.Marshal(obj)
		fmt.Fprintf(os.Stdout, "%s\n", data)
	}
}

func (a *Agent) RunLoop(ctx context.Context, userInput, turnKind string) error {
	// 记录 user_input 事件（提前到 AddUserMessage 之前，与 bash 版一致）
	if turnKind == "user_input" {
		ev := map[string]interface{}{"type": "user_input", "content": userInput}
		evJSON, _ := json.Marshal(ev)
		_ = a.store.AppendEvent(string(evJSON))
	}

	// 添加用户消息
	_ = a.store.AddUserMessage(userInput)

	// 用户输入时递增 turn（与 bash 版一致：store_stats_update current_turn_count=+1）
	_ = a.store.IncrementTurn()

	// 中断处理：用 context.WithCancel 包装，Ctrl+C 同时取消 context（取消 HTTP 请求）
	interrupted := false
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT)
	defer signal.Stop(sigCh)

	go func() {
		<-sigCh
		interrupted = true
		cancel()
	}()

	for turn := 0; turn < a.cfg.MaxTurns; turn++ {
		// Compact
		if compacted, _ := a.CompactContext(ctx, "auto"); compacted {
			a.display.ShowEvent(Event{Type: EventContextUpdate, Fields: []string{"CONTEXT_UPDATE", "compact", "auto"}})
		}

		// 获取 messages
		messages, err := a.store.GetMessages()
		if err != nil {
			return fmt.Errorf("get messages: %w", err)
		}
		systemPrompt := a.BuildPrompt()

		// LLM 调用
		ch, err := a.llm.Call(ctx, messages, systemPrompt, a.toolDefs, a.cfg.MaxTokens, a.cfg.Thinking)
		if err != nil {
			a.display.ShowEvent(Event{Type: EventError, Fields: []string{"ERROR", err.Error()}})
			return err
		}

		var text, thinking string
		var toolCalls []ToolCallInfo
		var stopReason string
		var usage Usage
		var loopErr string

		for ev := range ch {
			if interrupted {
				stopReason = "interrupted"
				break
			}

			switch ev.Type {
			case EventText:
				a.display.ShowEvent(ev)
				if len(ev.Fields) > 1 {
					text += ev.Fields[1]
					a.emitJSON(map[string]interface{}{"type": "text", "content": ev.Fields[1]})
				}
			case EventThinking:
				a.display.ShowEvent(ev)
				if len(ev.Fields) > 1 {
					thinking += ev.Fields[1]
					a.emitJSON(map[string]interface{}{"type": "thinking", "content": ev.Fields[1]})
				}
			case EventToolCall:
				if len(ev.Fields) >= 4 {
					tc := ToolCallInfo{
						Name:  ev.Fields[1],
						ID:    ev.Fields[2],
						Input: ev.Fields[3],
					}
					toolCalls = append(toolCalls, tc)

					// 生成 CallSummary 并显示（替代 transport 的原始事件）
					params := ExtractToolParams(tc.Name, json.RawMessage(tc.Input))
					callSummary := a.tools.CallSummary(tc.Name, params)
					a.display.ShowEvent(Event{Type: EventToolCall, Fields: []string{"TOOL_CALL", tc.Name, tc.ID, tc.Input, callSummary}})

					// 执行工具
					output, toolErr := a.tools.Dispatch(ctx, tc.Name, params)
					if toolErr != nil {
						output = "Error: " + toolErr.Error()
					}
					output = FormatToolResult(output)

					// 对 Read/Write 加 FileSummary 前缀
					switch tc.Name {
					case "Read", "Write":
						pathParam := params["path"]
						fs := FileSummary(tc.Name, pathParam)
						output = fs + "\n" + output
					}

					// 显示结果
					a.display.ShowEvent(Event{Type: EventToolResult, Fields: []string{"TOOL_RESULT", tc.ID, tc.Name, output}})

					// stream-json + events.jsonl: 分别写 tool_call 和 tool_result（与 bash 版一致）
					a.emitJSON(map[string]interface{}{
						"type":  "tool_call",
						"name":  tc.Name,
						"id":    tc.ID,
						"input": json.RawMessage(tc.Input),
					})
					a.emitJSON(map[string]interface{}{
						"type":       "tool_result",
						"tool_use_id": tc.ID,
						"name":       tc.Name,
						"content":    output,
					})

					// 添加工具结果到 conversation
					results := []ToolResultInfo{
						{ToolID: tc.ID, ToolName: tc.Name, Output: output},
					}
					_ = a.store.AddToolResults(results)
				}
			case EventUsage:
				if u, ok := ev.Payload.(Usage); ok {
					usage = u
					a.emitJSON(map[string]interface{}{
						"type":                         "usage",
						"input_tokens":                 u.InputTokens,
						"output_tokens":                u.OutputTokens,
						"cache_read_input_tokens":      u.CacheRead,
						"cache_creation_input_tokens":   u.CacheWrite,
						"kind":                         "agent",
					})
				}
			case EventStop:
				a.display.ShowEvent(ev)
				if len(ev.Fields) > 1 {
					stopReason = ev.Fields[1]
				}
				a.emitJSON(map[string]interface{}{"type": "stop", "reason": stopReason})
			case EventError:
				a.display.ShowEvent(ev)
				if len(ev.Fields) > 1 {
					loopErr = ev.Fields[1]
				}
				stopReason = "error"
				a.emitJSON(map[string]interface{}{"type": "error", "message": loopErr})
				// 与 bash 版对齐：ERROR 立即 break 出事件循环
				break
			default:
				a.display.ShowEvent(ev)
			}
		}

		// 记录 usage
		ctxTokens := a.RecordUsage(usage, "agent", a.cfg.Model)
		_ = ctxTokens

		// 更新终端标题（与 bash 版 store_stats_update 后调 display_term_title 一致）
		a.display.SetTitle(a.store.FormatTitle(a.cfg.Model))

		if interrupted {
			a.display.ShowEvent(Event{Type: EventStop, Fields: []string{"STOP", "interrupted"}})
			_ = a.store.AppendEvent(`{"type":"stop","reason":"interrupted"}`)
			return nil
		}

		// 致命停止原因
		switch stopReason {
		case "error", "max_tokens", "length":
			if stopReason != "error" {
				a.display.ShowEvent(Event{Type: EventError, Fields: []string{"ERROR", "Response truncated (max_tokens reached)"}})
			}
			if loopErr != "" {
				return fmt.Errorf("LLM error: %s", loopErr)
			}
			return fmt.Errorf("stopped: %s", stopReason)
		}

		// 保存 assistant 消息
		_ = a.store.AddAssistantMessage(text, thinking, toolCalls)

		// tool_use → 继续循环
		if stopReason == "tool_use" || stopReason == "tool_calls" {
			continue
		}

		// end_turn 但有等待中的子 agent → 等待结果并继续
		a.subMu.Lock()
		hasPending := a.pendingSubAgents > 0
		a.subMu.Unlock()
		if hasPending {
			select {
			case r := <-a.subResultCh:
				a.handleSubAgentResult(r)
				continue
			case <-ctx.Done():
				return ctx.Err()
			}
		}

		// 其他 stop reason → 退出
		break
	}

	return nil
}

// ─── SubAgent 启动（异步 goroutine）───

func (a *Agent) LaunchSubAgent(ctx context.Context, prompt, description, fork string) (string, error) {
	sessionID := "sub_" + UtilNewSessionID()

	// 记录 sub_agent_start 事件
	startEvent := map[string]interface{}{
		"type":        "sub_agent_start",
		"session_id":  sessionID,
		"timestamp":   time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"prompt":      prompt,
		"description": description,
		"fork":        fork == "true",
	}
	startJSON, _ := json.Marshal(startEvent)
	_ = a.store.AppendEvent(string(startJSON))

	// 增加计数
	a.subMu.Lock()
	a.pendingSubAgents++
	a.subMu.Unlock()

	// 启动子 agent goroutine
	go func() {
		result := a.runSubAgent(ctx, sessionID, prompt, fork)
		a.subResultCh <- result
	}()

	return fmt.Sprintf("Sub-agent started: session_id=%s", sessionID), nil
}

func (a *Agent) runSubAgent(ctx context.Context, sessionID, prompt, fork string) SubAgentResult {
	result := SubAgentResult{
		SessionID: sessionID,
		Status:    "failed",
	}

	// 构建子 agent 命令
	self, err := os.Executable()
	if err != nil {
		return result
	}

	args := []string{
		"-p", a.cfg.Provider,
		"--base-url", a.cfg.BaseURL,
		"-m", a.cfg.Model,
		"--api-key", a.cfg.APIKey,
		"--session", sessionID,
		"--max-turns", "10",
		prompt,
	}

	// 设置 BASH_AGENT_HOME
	homeDir := os.Getenv("BASH_AGENT_HOME")
	if homeDir == "" {
		homeDir = os.Getenv("HOME") + "/.bash-agent"
	}
	env := os.Environ()
	env = append(env, "BASH_AGENT_HOME="+homeDir)

	// fork 模式需要复制 conversation
	if fork == "true" {
		parentDir := filepath.Join(a.store.GetDir(), a.store.SessionID())
		childDir := filepath.Join(a.store.GetDir(), sessionID)
		_ = a.store.Fork(parentDir, childDir)
	}

	cmd := exec.CommandContext(ctx, self, args...)
	cmd.Env = env

	// 子 agent 完全静默：stdin/stdout/stderr 全部指向 /dev/null
	// （与 bash 版 exec </dev/null >/dev/null 2>&1 一致）
	devNull, _ := os.Open(os.DevNull)
	cmd.Stdin = devNull
	cmd.Stdout = devNull
	cmd.Stderr = devNull

	err = cmd.Run()
	if err != nil {
		result.Status = "failed"
		result.Text = err.Error()
	} else {
		result.Status = "ok"
	}

	// 从子 agent 的 conversation.jsonl 提取最后一条 assistant 消息的 thinking 和 text
	// （与 bash 版 send_sub_result.awk 逻辑一致）
	if thinking, text, err := a.store.GetSubAgentResult(sessionID); err == nil {
		result.Thinking = thinking
		if result.Status == "ok" {
			result.Text = text
		}
	}

	// 解析子 agent 的 stats 获取 token 信息
	if stats, err := a.store.GetSubAgentStats(sessionID); err == nil {
		result.InputTokens = stats.InputTokens
		result.OutputTokens = stats.OutputTokens
		result.CacheRead = stats.CacheRead
		result.CacheWrite = stats.CacheWrite
		result.Requests = stats.TotalRequests
	}

	return result
}

// handleSubAgentResult 处理子 agent 结果
func (a *Agent) handleSubAgentResult(r SubAgentResult) {
	a.subMu.Lock()
	a.pendingSubAgents--
	a.subMu.Unlock()

	// 记录 usage 事件（带 kind=sub_agent, sub_session_id）
	usageEvent := map[string]interface{}{
		"type":                        "usage",
		"input_tokens":                r.InputTokens,
		"output_tokens":               r.OutputTokens,
		"cache_read_input_tokens":     r.CacheRead,
		"cache_creation_input_tokens": r.CacheWrite,
		"kind":                        "sub_agent",
		"sub_session_id":              r.SessionID,
	}
	usageJSON, _ := json.Marshal(usageEvent)
	_ = a.store.AppendEvent(string(usageJSON))

	// 记录 sub_agent_result 事件（供 replay 和 stream-json 复现）
	resultEvent := map[string]interface{}{
		"type":         "sub_agent_result",
		"session_id":   r.SessionID,
		"status":       r.Status,
		"input_tokens":  r.InputTokens,
		"output_tokens": r.OutputTokens,
		"thinking":     r.Thinking,
		"text":         r.Text,
	}
	resultJSON, _ := json.Marshal(resultEvent)
	_ = a.store.AppendEvent(string(resultJSON))

	// 记录 sub_agent_end 事件
	endEvent := map[string]interface{}{
		"type":       "sub_agent_end",
		"session_id": r.SessionID,
		"timestamp":  time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"status":     r.Status,
	}
	endJSON, _ := json.Marshal(endEvent)
	_ = a.store.AppendEvent(string(endJSON))

	// 显示结果（统一走 Display 接口）
	a.display.ShowEvent(Event{
		Type: EventSubAgentResult,
		Fields: []string{
			"SUB_AGENT_RESULT",
			r.SessionID,
			r.Status,
			fmt.Sprintf("%d", r.InputTokens),
			fmt.Sprintf("%d", r.OutputTokens),
			r.Thinking,
			r.Text,
		},
	})

	// 更新 store 的 stats（与 bash 版 store_stats_update total_input_tokens=+_in ... agent_request_count=+_reqs 一致）
	a.store.UpdateSubAgentStats(r.InputTokens, r.OutputTokens, r.CacheRead, r.CacheWrite, r.Requests)

	// 构造注入消息
	injectMsg := fmt.Sprintf("[sub-agent %s] %s (in=%d, out=%d)\nThinking: %s\nText: %s",
		r.SessionID, r.Status, r.InputTokens, r.OutputTokens, r.Thinking, r.Text)

	// 注入为用户消息（不记录 user_input 事件，与 bash 版 agent_loop turn_kind=sub_agent_result 一致）
	_ = a.store.AddUserMessage(injectMsg)

	// stream-json 输出（含 thinking/text，与 bash 版一致）
	a.emitJSON(map[string]interface{}{
		"type":          "sub_agent_result",
		"session_id":    r.SessionID,
		"status":        r.Status,
		"input_tokens":  r.InputTokens,
		"output_tokens": r.OutputTokens,
		"thinking":      r.Thinking,
		"text":          r.Text,
	})
}
