package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
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
	displayCh        chan Event
	displayWG        sync.WaitGroup
	toolDefs         string // JSON 格式工具定义
	ctxTokens        int    // 当前上下文 token 数
	pendingTasks     int    // 等待中的子 agent 数量
	subAgentDepth    int    // 主代理为 0，第一层子代理为 1
	subResultCh      chan SubAgentResult
	subMu            sync.Mutex
	runMu            sync.Mutex
	currentCancel    context.CancelFunc
	currentInterrupt *atomic.Bool
	running          atomic.Bool // 1 = agent 正在处理（RunLoop 执行中），0 = 空闲等待输入
}

type SubAgentResult struct {
	Kind         string // "sub_agent" (默认) 或 "async_task"
	SessionID    string
	Status       string // "ok" or "failed"
	Thinking     string
	Text         string
	InputTokens  int
	OutputTokens int
	CacheRead    int
	CacheWrite   int
	Requests     int
	// async_task 字段
	TaskID   string
	ExitCode int
	Output   string
}

// imageNextName returns the next sequential image filename.
func (a *Agent) imageNextName() string {
	dir := a.store.ImageDir()
	entries, _ := filepath.Glob(filepath.Join(dir, "*.png"))
	return fmt.Sprintf("%d.png", len(entries)+1)
}

// ImagePasteCallback is called from linenoise when Ctrl+V is pressed.
// It tries to read clipboard image and save to session cache.
func (a *Agent) ImagePasteCallback() string {
	name := a.imageNextName()
	path := filepath.Join(a.store.ImageDir(), name)

	// Try clipboard tools in order
	var data []byte
	if _, err := exec.LookPath("osascript"); err == nil {
		cmd := exec.Command("osascript", "-e",
			`set theImage to the clipboard as «class PNGf»`,
			"-e", fmt.Sprintf(`set theFile to open for access POSIX file "%s" with write permission`, path+".tmp"),
			"-e", `write theImage to theFile`,
			"-e", `close access theFile`)
		if err := cmd.Run(); err == nil {
			data, _ = os.ReadFile(path + ".tmp")
		}
		os.Remove(path + ".tmp")
	}
	if data == nil {
		if _, err := exec.LookPath("wl-paste"); err == nil {
			data, _ = exec.Command("wl-paste", "--type", "image/png").Output()
		}
	}
	if data == nil {
		if _, err := exec.LookPath("xclip"); err == nil {
			data, _ = exec.Command("xclip", "-selection", "clipboard", "-t", "image/png", "-o").Output()
		}
	}

	if len(data) == 0 {
		return ""
	}

	// Optional oxipng compression
	if _, err := exec.LookPath("oxipng"); err == nil {
		os.WriteFile(path+".tmp", data, 0644)
		exec.Command("oxipng", "-o", "4", "--strip", "safe", "-q", path+".tmp").Run()
		data, _ = os.ReadFile(path + ".tmp")
		os.Remove(path + ".tmp")
	}

	if err := os.WriteFile(path, data, 0644); err != nil {
		return ""
	}
	return fmt.Sprintf("[Image #%s]", name[:len(name)-4])
}

// imageDescribe calls GLM-4V-Flash to describe the given image files.
func (a *Agent) imageDescribe(paths []string) string {
	apiKey := os.Getenv("DESCRIBE_API_KEY")
	model := os.Getenv("DESCRIBE_MODEL")
	baseURL := os.Getenv("DESCRIBE_BASE_URL")
	if apiKey == "" || len(paths) == 0 {
		return ""
	}
	if model == "" {
		model = "glm-4v-flash"
	}
	if baseURL == "" {
		baseURL = "https://open.bigmodel.cn/api/paas/v4"
	}

	// Build content parts: text + image_url for each path
	var contentParts []map[string]interface{}
	contentParts = append(contentParts, map[string]interface{}{
		"type": "text",
		"text": "Output all visible text from each image, separated by a blank line between images. Transcribe every character including special symbols (arrows, prompts, dots, slashes). Preserve exact spacing and line breaks. Pay attention to date formats (month names, numbers). Do not summarize or describe - just output the raw text exactly as shown. If an image has no text, briefly describe what you see.",
	})
	for _, p := range paths {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		b64 := base64.StdEncoding.EncodeToString(data)
		contentParts = append(contentParts, map[string]interface{}{
			"type": "image_url",
			"image_url": map[string]string{
				"url": "data:image/png;base64," + b64,
			},
		})
	}

	body := map[string]interface{}{
		"model":    model,
		"stream":   true,
		"messages": []interface{}{map[string]interface{}{"role": "user", "content": contentParts}},
	}
	bodyJSON, _ := json.Marshal(body)

	req, err := http.NewRequest("POST", baseURL+"/chat/completions", bytes.NewReader(bodyJSON))
	if err != nil {
		return ""
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+apiKey)

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()

	// Parse SSE response, collect TEXT from choices[0].delta.content
	var desc strings.Builder
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		for _, c := range chunk.Choices {
			desc.WriteString(c.Delta.Content)
		}
	}
	return desc.String()
}

// expandImagePlaceholders scans [Image #N] in input, collects files,
// calls describe, and appends <attached-images> to the input.
func (a *Agent) expandImagePlaceholders(input string) string {
	re := regexp.MustCompile(`\[Image #(\d+)\]`)
	var paths []string
	for _, m := range re.FindAllStringSubmatch(input, -1) {
		p := filepath.Join(a.store.ImageDir(), m[1]+".png")
		if _, err := os.Stat(p); err == nil {
			paths = append(paths, p)
		}
	}
	desc := a.imageDescribe(paths)
	return fmt.Sprintf("%s\n\n<attached-images>\n%s\n</attached-images>", input, desc)
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
	if cfg.OutputFormat != "stream-json" {
		a.displayCh = make(chan Event, 128)
		a.displayWG.Add(1)
		go func() {
			defer a.displayWG.Done()
			for ev := range a.displayCh {
				if ev.Type == EventDisplayFlush {
					if ack, ok := ev.Payload.(chan struct{}); ok {
						close(ack)
					}
					continue
				}
				a.display.ShowEvent(ev)
			}
		}()
	}
	// 设置回调
	a.tools.SetSubAgentLauncher(a.LaunchSubAgent)
	a.tools.SetAsyncBashLauncher(a.LaunchAsyncBash)
	a.tools.SetPlanConfirm(a.HandlePlanConfirm)
	a.tools.SetPlanClear(a.HandlePlanClear)
	a.tools.SetSkillLoader(a.LoadSkill)
	return a
}

// Interrupt cancels the currently running agent turn. In raw terminal mode
// Ctrl+C is read by linenoise as byte 0x03 rather than delivered as SIGINT,
// so the readline goroutine calls this when it consumes Ctrl+C.
// Mirrors C version: only interrupts when agent is running (agent_loop active).
func (a *Agent) Interrupt() {
	if !a.running.Load() {
		return
	}
	a.runMu.Lock()
	if a.currentInterrupt != nil {
		a.currentInterrupt.Store(true)
	}
	if a.currentCancel != nil {
		a.currentCancel()
	}
	a.runMu.Unlock()
}

func (a *Agent) EmitDisplay(ev Event) {
	if a.displayCh == nil {
		return
	}
	a.displayCh <- ev
}

func (a *Agent) CloseDisplay() {
	if a.displayCh == nil {
		return
	}
	close(a.displayCh)
	a.displayWG.Wait()
	a.displayCh = nil
}

// FlushDisplay waits until the display goroutine has rendered all events
// queued before this call. Interactive linenoise must not redraw the prompt
// before asynchronous display output is drained.
func (a *Agent) FlushDisplay() {
	if a.displayCh == nil {
		return
	}
	ack := make(chan struct{})
	a.displayCh <- Event{Type: EventDisplayFlush, Payload: ack}
	<-ack
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
		content = strings.TrimRight(content, "\r\n")
		if content == "" {
			return
		}
		var sb strings.Builder
		sb.WriteString("<")
		sb.WriteString(tag)
		if name != "" {
			sb.WriteString(" name=\"")
			sb.WriteString(UtilJSONEscape(name))
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
	rules := "- Be concise and concrete. Lead with the answer. Use short sections or bullets when they improve readability. No pleasantries, no explanations unless asked. Raw results only.\n" +
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
		"- Bash supports background=true for long-running commands. Returns task_id immediately; output delivered asynchronously like SubAgent.\n" +
		"- SubAgent launches a background agent session. Results are injected back into your conversation when complete. Use for parallelizable or independent sub-tasks. See sub-agent-guidance section for context inheritance rules."
	appendSection("using-your-tools", toolGuidance, "")

	// sub-agent guidance
	subAgentGuidance := "- **When to use**: delegating independent sub-tasks that do NOT need your current conversation context — e.g. investigating a separate file, running a focused search, testing a hypothesis in isolation.\n" +
		"- **Recursion limit**: only the main agent may launch SubAgent. A child agent must not call SubAgent again; the runtime rejects nested launches.\n" +
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
	var selectedSkills strings.Builder
	for _, sn := range a.cfg.SkillNames {
		if content, err := a.loadSkillContent(sn); err == nil {
			UtilAppendSection(&selectedSkills, "skill", content, sn)
		}
	}
	appendSection("selected-skills", strings.TrimRight(selectedSkills.String(), "\n"), "")

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
	_ = a.store.UpdateStats(usage, model)
	// 仅在 ctxTokens > 0 时更新（与 bash 版 `if [[ -n "$_ctx_tokens" && "$_ctx_tokens" -gt 0 ]]` 一致）
	if ctxTokens > 0 {
		a.ctxTokens = ctxTokens
		a.store.SetContextTokens(ctxTokens)
	}
	return ctxTokens
}

func mustGetwd() string {
	wd, err := os.Getwd()
	if err != nil {
		return "?"
	}
	return wd
}

func firstLine(s string) string {
	if idx := strings.IndexByte(s, '\n'); idx >= 0 {
		return s[:idx]
	}
	return s
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
		content := strings.TrimRight(string(data), "\r\n")
		content = strings.ReplaceAll(content, "${BASH_AGENT_SKILL_DIR}", skillDir)
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
	var sections strings.Builder
	home := os.Getenv("HOME")

	// 全局: ~/.bash-agent/AGENTS.md 等
	if home != "" {
		if f := findInstructionFile(home + "/.bash-agent"); f != "" {
			data, err := os.ReadFile(f)
			if err == nil {
				UtilAppendSection(&sections, "instruction-file", string(data), "global")
			}
		}
	}

	// 项目: $PWD/AGENTS.md 等
	if f := findInstructionFile(mustGetwd()); f != "" {
		data, err := os.ReadFile(f)
		if err == nil {
			UtilAppendSection(&sections, "instruction-file", string(data), "project")
		}
	}

	return sections.String()
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
		/* plan_clear/plan_confirm 绕过守卫继续执行（对齐 Bash/C/Rust）
		 * 仅在 keepLines <= 0 时放弃 */
		if keepLines <= 0 {
			return false, nil
		}
	}

	drop := totalLines - keepLines
	droppedMessages, err := a.store.ConvHeadTo(drop)
	if err != nil {
		return false, fmt.Errorf("read dropped messages: %w", err)
	}

	systemPrompt := a.BuildPrompt()
	summaryResponse, summaryUsage, err := a.llm.SummaryCall(ctx, droppedMessages, systemPrompt, a.toolDefs)
	if err != nil {
		return false, fmt.Errorf("summary call failed: %w", err)
	}

	_ = a.store.SetSummary(summaryResponse)
	if keepLines < totalLines {
		_ = a.store.ConvTrimTail(keepLines)
	}

	if summaryUsage.InputTokens > 0 || summaryUsage.OutputTokens > 0 || summaryUsage.CacheRead > 0 || summaryUsage.CacheWrite > 0 {
		ev := map[string]interface{}{
			"type":                        "usage",
			"input_tokens":                summaryUsage.InputTokens,
			"output_tokens":               summaryUsage.OutputTokens,
			"cache_read_input_tokens":     summaryUsage.CacheRead,
			"cache_creation_input_tokens": summaryUsage.CacheWrite,
			"kind":                        "compact",
		}
		a.emitJSON(ev)
		_ = a.store.UpdateCompactStats(summaryUsage)
	}

	// 注意：不再重置 current_turn_count — 它应始终保持 session 累计计数

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

func (a *Agent) RunLoop(ctx context.Context, initialUserInput, initialTurnKind string) error {
	// 设置 running 标志：1 表示 agent 正在处理，readline 据此判断 Ctrl+C 是否应中断
	a.running.Store(true)
	defer a.running.Store(false)

	// 中断处理：在整个 RunLoop 期间共享一个 cancellable context
	// Ctrl+C 同时取消 context（取消 HTTP 请求和工具执行）
	var interrupted atomic.Bool
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	a.runMu.Lock()
	a.currentInterrupt = &interrupted
	a.currentCancel = cancel
	a.runMu.Unlock()
	defer func() {
		a.runMu.Lock()
		if a.currentInterrupt == &interrupted {
			a.currentInterrupt = nil
			a.currentCancel = nil
		}
		a.runMu.Unlock()
	}()
	sigCh := make(chan os.Signal, 1)
	sigDone := make(chan struct{})
	signal.Notify(sigCh, syscall.SIGINT)
	defer signal.Stop(sigCh)
	defer close(sigDone)

	go func() {
		select {
		case <-sigCh:
			interrupted.Store(true)
			cancel()
		case <-sigDone:
		}
	}()

	userInput := initialUserInput
	turnKind := initialTurnKind

	// 外层循环：每个 phase（user_input / sub_agent_result / async_task_result / user_notify）获得独立的 max_turns 预算
	// 对齐 Bash 版：agent_drain_notify_buf 在 turn loop 内消费（共享预算），
	// NOTIFY_PENDING 触发的 agent_run_loop "" notify 是嵌套调用（独立预算）
	for {
		// === Phase setup ===

		// notify turn 只负责消费 pending sub_result；stale wakeup 直接忽略
		if turnKind == "notify" {
			if !a.drainSubAgentResults(ctx) {
				return nil
			}
		} else if turnKind == "user_input" {
			// 记录 user_input 事件（使用原始文本，包含 [Image #N] 占位符）
			a.emitJSON(map[string]interface{}{"type": "user_input", "content": userInput})
		}

		// 展开图片占位符：events 记录原始文本，conversation/LLM 使用展开后的长文本
		if turnKind == "user_input" && strings.Contains(userInput, "[Image #") {
			expandedInput := a.expandImagePlaceholders(userInput)

			// 提取 <attached-images> 中的描述内容
			desc := ""
			if start := strings.Index(expandedInput, "<attached-images>"); start >= 0 {
				start += len("<attached-images>")
				if end := strings.Index(expandedInput[start:], "</attached-images>"); end >= 0 {
					desc = expandedInput[start : start+end]
				}
			}

			// 收集所有 [Image #N] 占位符
			re := regexp.MustCompile(`\[Image #\d+\]`)
			matches := re.FindAllString(userInput, -1)
			if len(matches) > 0 {
				images := strings.Join(matches, " ")

				// 记录 image_describe 事件
				a.emitJSON(map[string]interface{}{
					"type":    "image_describe",
					"images":  images,
					"content": desc,
				})

				// 推送 IMAGE_DESCRIBE 到 display
				a.EmitDisplay(Event{Type: EventImageDescribe, Fields: []string{"IMAGE_DESCRIBE", images, desc}})
			}

			userInput = expandedInput
		}

		// 添加用户消息；notify turn 的消息已由 drainSubAgentResults 注入
		if turnKind != "notify" {
			_ = a.store.AddUserMessage(userInput)
		}

		// 用户输入时递增 turn（与 bash 版一致：store_stats_update current_turn_count=+1）
		_ = a.store.IncrementTurn()
		// 对齐 bash版: store_stats_update 末尾调 display_term_title
		a.display.SetTitle(a.store.FormatTitle(a.cfg.Model, ""))

		// === Turn loop（独立 max_turns 预算）===
		phaseFatalErr := error(nil)

	TurnLoop:
		for turn := 0; turn < a.cfg.MaxTurns; turn++ {
			// Drain SubAgent results that arrived during previous LLM call（对齐 bash agent_drain_notify_buf）
			a.drainSubAgentResults(ctx)

			// Compact
			if compacted, _ := a.CompactContext(ctx, "auto"); compacted {
				a.EmitDisplay(Event{Type: EventContextUpdate, Fields: []string{"CONTEXT_UPDATE", "compact", "auto"}})
			}

			// 获取 messages
			messages, err := a.store.GetMessages()
			if err != nil {
				phaseFatalErr = fmt.Errorf("get messages: %w", err)
				break TurnLoop
			}
			systemPrompt := a.BuildPrompt()

			// LLM 调用
			ch, err := a.llm.Call(ctx, messages, systemPrompt, a.toolDefs, a.cfg.MaxTokens, a.cfg.Thinking)
			if err != nil {
				a.EmitDisplay(Event{Type: EventError, Fields: []string{"ERROR", err.Error()}})
				phaseFatalErr = err
				break TurnLoop
			}

			var text, thinking string
			var toolCalls []ToolCallInfo
			var toolResults []ToolResultInfo
			var stopReason string
			var usage Usage
			var loopErr string

			for ev := range ch {
				if interrupted.Load() {
					stopReason = "interrupted"
					break
				}

				switch ev.Type {
				case EventText:
					a.EmitDisplay(ev)
					if len(ev.Fields) > 1 {
						text += ev.Fields[1]
						a.emitJSON(map[string]interface{}{"type": "text", "content": ev.Fields[1]})
					}
				case EventThinking:
					a.EmitDisplay(ev)
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
						a.EmitDisplay(Event{Type: EventToolCall, Fields: []string{"TOOL_CALL", tc.Name, tc.ID, tc.Input, callSummary}})

						// 执行工具
						output, toolErr := a.tools.Dispatch(ctx, tc.Name, params)
						if toolErr != nil {
							output = "Error: " + toolErr.Error()
						}
						output = FormatToolResult(output)
						convOutput := output

						switch tc.Name {
						case "Read", "Write":
							pathParam := params["path"]
							fs := FileSummary(tc.Name, pathParam, params["offset"], params["limit"])
							output = fs + "\n" + output
						case "Edit":
							convOutput = firstLine(output)
						}

						// 显示结果
						a.EmitDisplay(Event{Type: EventToolResult, Fields: []string{"TOOL_RESULT", tc.ID, tc.Name, output}})

						// stream-json + events.jsonl: 分别写 tool_call 和 tool_result（与 bash 版一致）
						a.emitJSON(map[string]interface{}{
							"type":  "tool_call",
							"name":  tc.Name,
							"id":    tc.ID,
							"input": json.RawMessage(tc.Input),
						})
						a.emitJSON(map[string]interface{}{
							"type":        "tool_result",
							"tool_use_id": tc.ID,
							"name":        tc.Name,
							"content":     output,
						})

						toolResults = append(toolResults, ToolResultInfo{ToolID: tc.ID, ToolName: tc.Name, Output: output, ConvOutput: convOutput})
					}
				case EventUsage:
					if u, ok := ev.Payload.(Usage); ok {
						usage = u
						a.emitJSON(map[string]interface{}{
							"type":                        "usage",
							"input_tokens":                u.InputTokens,
							"output_tokens":               u.OutputTokens,
							"cache_read_input_tokens":     u.CacheRead,
							"cache_creation_input_tokens": u.CacheWrite,
							"kind":                        "agent",
						})
					}
				case EventStop:
					a.EmitDisplay(ev)
					if len(ev.Fields) > 1 {
						stopReason = ev.Fields[1]
					}
					a.emitJSON(map[string]interface{}{"type": "stop", "reason": stopReason})
				case EventError:
					a.EmitDisplay(ev)
					if len(ev.Fields) > 1 {
						loopErr = ev.Fields[1]
					}
					stopReason = "error"
					a.emitJSON(map[string]interface{}{"type": "error", "message": loopErr})
					// 与 bash 版对齐：ERROR 立即 break 出事件循环
					break
				case EventRetry:
					// 对齐 Rust: 清空当前累积状态
					text = ""
					thinking = ""
					toolCalls = nil
					toolResults = nil
					usage = Usage{}
					a.emitJSON(map[string]interface{}{"type": "retry"})
				default:
					a.EmitDisplay(ev)
				}
			}

			// 记录 usage
			ctxTokens := a.RecordUsage(usage, "agent", a.cfg.Model)
			_ = ctxTokens

			// 更新终端标题（与 bash 版 store_stats_update 后调 display_term_title 一致）
			a.display.SetTitle(a.store.FormatTitle(a.cfg.Model, ""))

			if interrupted.Load() {
				a.EmitDisplay(Event{Type: EventStop, Fields: []string{"STOP", "interrupted"}})
				a.emitJSON(map[string]interface{}{"type": "stop", "reason": "interrupted"})
				break
			}

			// 致命停止原因
			switch stopReason {
			case "error", "max_tokens", "length":
				if stopReason != "error" {
					a.EmitDisplay(Event{Type: EventError, Fields: []string{"ERROR", "Response truncated (max_tokens reached)"}})
				}
				if loopErr != "" {
					phaseFatalErr = fmt.Errorf("LLM error: %s", loopErr)
				} else {
					phaseFatalErr = fmt.Errorf("stopped: %s", stopReason)
				}
				break TurnLoop
			}

			// 保存 assistant 消息
			_ = a.store.AddAssistantMessage(text, thinking, toolCalls)
			if len(toolResults) > 0 {
				_ = a.store.AddToolResults(toolResults)
			}

			// tool_use → 继续循环
			if stopReason == "tool_use" || stopReason == "tool_calls" {
				continue
			}

			// end_turn 后先消费已到达的 notify/user inject；有内容则继续下一轮（共享 turn 预算）
			if a.drainSubAgentResults(ctx) {
				continue
			}

			// end_turn，无 drained 结果 → 退出 turn loop
			break
		}

		if interrupted.Load() {
			a.display.SetTitle(a.store.FormatTitle(a.cfg.Model, "idle"))
			return nil
		}

		// === Post-phase：检查是否有等待中的子 agent 结果 ===
		a.subMu.Lock()
		hasPending := a.pendingTasks > 0
		a.subMu.Unlock()

		if hasPending {
			select {
			case r := <-a.subResultCh:
				// 处理结果（events + stats + display），获取 context 和 turnKind
				context, tk := a.handleSubAgentResult(r)
				// 下一轮 phase：context 作为 userInput，由 phase setup 写入 conversation
				userInput = context
				turnKind = tk
				continue // 外层循环 → 新的 turn 预算
			case <-ctx.Done():
				a.display.SetTitle(a.store.FormatTitle(a.cfg.Model, "idle"))
				return ctx.Err()
			}
		}

		// 无 pending 子 agent → 退出
		if phaseFatalErr != nil {
			a.display.SetTitle(a.store.FormatTitle(a.cfg.Model, "idle"))
			return phaseFatalErr
		}
		break
	}

	// RunLoop 结束：恢复 idle 标题 + 清除 progress indicator
	a.display.SetTitle(a.store.FormatTitle(a.cfg.Model, "idle"))

	return nil
}

// drainSubAgentResults 消费所有已到达但未处理的 SubAgent 结果（对齐 bash agent_drain_notify_buf）
func (a *Agent) drainSubAgentResults(ctx context.Context) bool {
	drained := false
	for {
		select {
		case r := <-a.subResultCh:
			context, _ := a.handleSubAgentResult(r)
			if context != "" {
				_ = a.store.AddUserMessage(context)
			}
			drained = true
		case <-ctx.Done():
			return drained
		default:
			return drained
		}
	}
}

// ─── SubAgent 启动（异步 goroutine）───

func (a *Agent) LaunchSubAgent(ctx context.Context, prompt, description, fork string) (string, error) {
	if a.subAgentDepth >= 1 {
		return "", fmt.Errorf("sub-agent recursion limit reached; child agents cannot launch SubAgent")
	}
	if fork != "true" {
		fork = "false"
	}
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
	a.emitJSON(startEvent)

	// 增加计数
	a.subMu.Lock()
	a.pendingTasks++
	a.subMu.Unlock()

	// fork 模式：在 goroutine 前同步复制 conversation，避免竞态
	if fork == "true" {
		parentDir := filepath.Join(a.store.GetDir(), a.store.SessionID())
		childDir := filepath.Join(a.store.GetDir(), sessionID)
		_ = a.store.Fork(parentDir, childDir)
	}

	// 启动子 agent goroutine
	go func() {
		result := a.runSubAgent(ctx, sessionID, prompt, fork)
		a.subResultCh <- result
	}()

	return fmt.Sprintf("Sub-agent started: session_id=%s", sessionID), nil
}

// ─── Async Bash 启动（后台 goroutine）───

func (a *Agent) LaunchAsyncBash(ctx context.Context, cmd string, timeoutSecs int) (string, error) {
	taskID := "task_" + UtilNewSessionID()

	// 增加计数（复用 pendingTasks）
	a.subMu.Lock()
	a.pendingTasks++
	a.subMu.Unlock()

	// 启动 goroutine（对齐 Bash 版：无 timeout，无截断）
	go func() {
		execCmd := exec.Command("bash", "-lc", cmd)
		execCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		execCmd.Stdin = nil
		var stdout, stderr bytes.Buffer
		execCmd.Stdout = &stdout
		execCmd.Stderr = &stderr

		err := execCmd.Run()
		exitCode := 0
		if err != nil {
			if execCmd.ProcessState != nil {
				exitCode = execCmd.ProcessState.ExitCode()
			} else {
				exitCode = 1
			}
		}
		output := string(sanitizeUTF8(stdout.Bytes()))
		if stderr.Len() > 0 {
			if output != "" {
				output += "\n"
			}
			output += string(sanitizeUTF8(stderr.Bytes()))
		}

		result := SubAgentResult{
			Kind:     "async_task",
			TaskID:   taskID,
			ExitCode: exitCode,
			Output:   output,
		}
		a.subResultCh <- result
	}()

	return fmt.Sprintf("Async task started: task_id=%s", taskID), nil
}

func (a *Agent) runSubAgent(ctx context.Context, sessionID, prompt, fork string) (result SubAgentResult) {
	result = SubAgentResult{
		SessionID: sessionID,
		Status:    "failed",
	}
	defer func() {
		if r := recover(); r != nil {
			result.Status = "failed"
			result.Text = fmt.Sprintf("sub-agent panic: %v", r)
		}
	}()

	homeDir := a.store.GetHomeDir()
	cwd := a.store.GetCwd()

	childCfg := a.cfg
	childCfg.MaxTurns = a.cfg.MaxTurns
	// 子 agent 必须静默：不输出 stream-json，不写终端正文，不抢 title。
	childCfg.OutputFormat = "human"
	childCfg.Interactive = false

	childStore := NewFileStore(homeDir, cwd)
	if err := childStore.Init(sessionID); err != nil {
		result.Text = err.Error()
		return result
	}

	childDisplay := NewTermDisplay()
	childDisplay.SetSilent(true)
	childLLM := NewHTTPTransport(childCfg)
	childTools := NewToolDispatcher(childCfg)
	child := NewAgent(childCfg, childStore, childLLM, childTools, childDisplay)
	child.subAgentDepth = a.subAgentDepth + 1
	child.SetToolDefs(a.toolDefs)
	defer child.CloseDisplay()

	if err := child.RunLoop(ctx, prompt, "user_input"); err != nil {
		result.Status = "failed"
		result.Text = err.Error()
	} else {
		result.Status = "ok"
	}

	// 从子 agent 的 conversation.jsonl 提取最后一条 assistant 消息的 thinking 和 text
	// （与 bash 版 send_sub_result.awk 逻辑一致）
	if thinking, text, err := childStore.GetSubAgentResult(sessionID); err == nil {
		result.Thinking = thinking
		if result.Status == "ok" {
			result.Text = text
		}
	}

	stats := childStore.GetStats()
	result.InputTokens = stats.InputTokens
	result.OutputTokens = stats.OutputTokens
	result.CacheRead = stats.CacheRead
	result.CacheWrite = stats.CacheWrite
	result.Requests = stats.TotalRequests

	return result
}

// handleSubAgentResult 处理子 agent 结果
// 返回 (context, turnKind)：context 为注入 conversation 的文本，turnKind 为下一轮 RunLoop 的类型
// 不写入 conversation — 由调用方（drainSubAgentResults 或 RunLoop 外层循环）负责写入
func (a *Agent) handleSubAgentResult(r SubAgentResult) (string, string) {
	// user_notify 分支（Ctrl+O 中间介入）
	if r.Kind == "user_notify" {
		return a.handleUserNotify(r.Text), "user_notify"
	}
	// async_task 分支
	if r.Kind == "async_task" {
		return a.handleAsyncTaskResult(r), "async_task_result"
	}
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
	a.emitJSON(usageEvent)

	// 记录 sub_agent_result 事件（供 replay 和 stream-json 复现）
	resultEvent := map[string]interface{}{
		"type":          "sub_agent_result",
		"session_id":    r.SessionID,
		"status":        r.Status,
		"input_tokens":  r.InputTokens,
		"output_tokens": r.OutputTokens,
		"thinking":      r.Thinking,
		"text":          r.Text,
	}
	a.emitJSON(resultEvent)

	// 记录 sub_agent_end 事件
	endEvent := map[string]interface{}{
		"type":       "sub_agent_end",
		"session_id": r.SessionID,
		"timestamp":  time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"status":     r.Status,
	}
	a.emitJSON(endEvent)

	// 更新 store 的 stats（对齐 bash 顺序：events → stats → counter → display → conversation）
	a.store.UpdateSubAgentStats(r.InputTokens, r.OutputTokens, r.CacheRead, r.CacheWrite, r.Requests)

	// 递减活跃子 agent 计数（在事件和统计之后）
	a.subMu.Lock()
	a.pendingTasks--
	a.subMu.Unlock()

	// 显示结果（统一走 Display 接口）
	a.EmitDisplay(Event{
		Type: EventSubAgentResult,
		Fields: []string{
			"AGENT_RESULT",
			r.SessionID,
			r.Status,
			fmt.Sprintf("%d", r.InputTokens),
			fmt.Sprintf("%d", r.OutputTokens),
			r.Thinking,
			r.Text,
		},
	})

	// 构造注入消息
	injectMsg := fmt.Sprintf("[sub-agent %s] %s (in=%d, out=%d)\nThinking: %s\nText: %s",
		r.SessionID, r.Status, r.InputTokens, r.OutputTokens, r.Thinking, r.Text)

	return injectMsg, "sub_agent_result"
}

// handleAsyncTaskResult 处理异步 bash 任务结果，返回注入 conversation 的文本
func (a *Agent) handleAsyncTaskResult(r SubAgentResult) string {
	// 1. 记录 async_task_result 事件
	a.emitJSON(map[string]interface{}{
		"type":      "async_task_result",
		"task_id":   r.TaskID,
		"exit_code": r.ExitCode,
		"output":    r.Output,
	})

	// 3. 递减活跃计数（async task 无 token 消耗，跳过 stats）
	a.subMu.Lock()
	a.pendingTasks--
	a.subMu.Unlock()

	// 4. 显示结果
	preview := r.Output
	if len(preview) > 120 {
		preview = preview[:120] + "…"
	}
	a.EmitDisplay(Event{
		Type: EventSubAgentResult,
		Fields: []string{
			"ASYNC_TASK_RESULT",
			r.TaskID,
			fmt.Sprintf("%d", r.ExitCode),
			r.Output,
		},
	})

	// 5. 构造注入消息
	injectMsg := fmt.Sprintf("[bg-bash %s] exit_code=%d\nOutput: %s",
		r.TaskID, r.ExitCode, r.Output)
	return injectMsg
}

// handleUserNotify 处理用户 Ctrl+O 中间介入的输入，返回注入 conversation 的文本
func (a *Agent) handleUserNotify(text string) string {
	// 显示（统一走 Display 接口）
	a.EmitDisplay(Event{
		Type:   EventUserNotify,
		Fields: []string{"USER_NOTIFY", text},
	})

	// Ctrl+O 是用户自然输入；conversation 中保存原文，显示层才加 [user inject]
	return text
}

// EnqueueUserNotify 将用户 Ctrl+O 输入写入 notify/sub_result 通道。
func (a *Agent) EnqueueUserNotify(text string) {
	a.subResultCh <- SubAgentResult{Kind: "user_notify", Text: text}
}
