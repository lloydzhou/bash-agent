package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const defaultToolResultMaxBytes = 30000

func getToolResultMaxBytes() int {
	if v := os.Getenv("TOOL_RESULT_MAX_BYTES"); v != "" {
		var n int
		if _, err := fmt.Sscanf(v, "%d", &n); err == nil && n > 0 {
			return n
		}
	}
	return defaultToolResultMaxBytes
}

// ═══════════════════════════════════════════
// ToolDispatcher — 工具调度与执行
// ═══════════════════════════════════════════

// SubAgentLauncher 子 agent 启动回调
type SubAgentLauncher func(ctx context.Context, prompt, description, fork string) (string, error)

// ToolDispatcher 工具调度器
type ToolDispatcher struct {
	cfg             Config
	launcher        SubAgentLauncher
	planConfirmFn   func() (string, error)
	planClearFn     func() (string, error)
	skillLoader     func(name string) (string, error)
	bashSafetyCheck func(cmd string) string
}

// NewToolDispatcher 创建工具调度器
func NewToolDispatcher(cfg Config) *ToolDispatcher {
	td := &ToolDispatcher{cfg: cfg}
	td.bashSafetyCheck = ToolDenyBashReason
	return td
}

// SetSubAgentLauncher 设置子 agent 启动回调
func (td *ToolDispatcher) SetSubAgentLauncher(fn SubAgentLauncher) {
	td.launcher = fn
}

// SetPlanConfirm 设置 plan confirm 回调
func (td *ToolDispatcher) SetPlanConfirm(fn func() (string, error)) {
	td.planConfirmFn = fn
}

// SetPlanClear 设置 plan clear 回调
func (td *ToolDispatcher) SetPlanClear(fn func() (string, error)) {
	td.planClearFn = fn
}

// SetSkillLoader 设置 skill 加载回调
func (td *ToolDispatcher) SetSkillLoader(fn func(name string) (string, error)) {
	td.skillLoader = fn
}

// ─── Dispatch: 按 name 调度工具 ───

func (td *ToolDispatcher) Dispatch(ctx context.Context, name string, params map[string]string) (string, error) {
	switch name {
	case "Read":
		return td.toolRead(params["path"], params["offset"], params["limit"])
	case "Write":
		return td.toolWrite(params["path"], params["content"])
	case "Edit":
		return td.toolEdit(params["path"], params["old_string"], params["new_string"])
	case "Bash":
		return td.toolBash(ctx, params["command"], params["timeout"])
	case "Glob":
		return td.toolGlob(params["pattern"], params["path"])
	case "Grep":
		return td.toolGrep(params["pattern"], params["path"], params["glob"], params["context"])
	case "TodoWrite":
		return td.toolTodoWrite(params)
	case "PlanConfirm":
		return td.toolPlanConfirm()
	case "PlanClear":
		return td.toolPlanClear()
	case "Skill":
		return td.toolSkill(params["name"])
	case "WebSearch":
		return td.toolWebSearch(ctx, params["query"])
	case "WebFetch":
		return td.toolWebFetch(ctx, params["url"])
	case "SubAgent":
		return td.toolSubAgent(ctx, params["prompt"], params["description"], params["fork"])
	default:
		return "", fmt.Errorf("unknown tool: %s", name)
	}
}

// ─── ParamKeys: 返回工具的参数名列表 ───

func (td *ToolDispatcher) ParamKeys(name string) []string {
	switch name {
	case "Read":
		return []string{"path", "offset", "limit"}
	case "Write":
		return []string{"path", "content"}
	case "Edit":
		return []string{"path", "old_string", "new_string"}
	case "Bash":
		return []string{"command", "timeout"}
	case "Glob":
		return []string{"pattern", "path"}
	case "Grep":
		return []string{"pattern", "path", "glob", "context"}
	case "TodoWrite":
		return []string{"todos", "checklist"}
	case "Skill":
		return []string{"name"}
	case "WebSearch":
		return []string{"query"}
	case "WebFetch":
		return []string{"url"}
	case "SubAgent":
		return []string{"prompt", "description", "fork"}
	default:
		return nil
	}
}

// CallSummary 生成工具调用的简短摘要
func (td *ToolDispatcher) CallSummary(name string, params map[string]string) string {
	var key string
	switch name {
	case "Read", "Write", "Edit":
		key = "path"
	case "Bash":
		key = "command"
	case "Glob", "Grep":
		key = "pattern"
	case "TodoWrite":
		// 从 todos JSON 生成 "completed/total" 格式
		if v, ok := params["todos"]; ok && v != "" {
			var todos []struct {
				Status string `json:"status"`
			}
			if json.Unmarshal([]byte(v), &todos) == nil {
				completed, total := 0, len(todos)
				for _, t := range todos {
					if t.Status == "completed" {
						completed++
					}
				}
				return fmt.Sprintf("TodoWrite(%d/%d)", completed, total)
			}
		}
		key = "summary"
	case "Skill":
		key = "name"
	case "WebSearch":
		key = "query"
	case "WebFetch":
		key = "url"
	case "SubAgent":
		key = "description"
	}
	value := params[key]
	if name == "Bash" && len(value) > 80 {
		value = value[:77] + "..."
		value = strings.ReplaceAll(value, "\n", " ")
	}
	if value != "" {
		return fmt.Sprintf("%s(%s)", name, value)
	}
	return name
}

// ─── 工具实现 ───

// toolRead 读取文件（支持 offset/limit）
func (td *ToolDispatcher) toolRead(p, offsetStr, limitStr string) (string, error) {
	if p == "" {
		return "", fmt.Errorf("no path provided")
	}
	if _, err := os.Stat(p); os.IsNotExist(err) {
		return "", fmt.Errorf("file not found: %s", p)
	}

	data, err := os.ReadFile(p)
	if err != nil {
		return "", fmt.Errorf("read error: %w", err)
	}

	lines := strings.Split(string(data), "\n")
	// offset 默认 1
	offset := 1
	if offsetStr != "" {
		fmt.Sscanf(offsetStr, "%d", &offset)
	}
	if offset < 1 {
		offset = 1
	}

	limit := 0
	if limitStr != "" {
		fmt.Sscanf(limitStr, "%d", &limit)
	}

	start := offset - 1 // 0-indexed
	if start >= len(lines) {
		return "", nil
	}

	end := len(lines)
	if limit > 0 && start+limit < end {
		end = start + limit
	}

	// 带行号输出
	var buf strings.Builder
	for i := start; i < end; i++ {
		buf.WriteString(fmt.Sprintf("%6d\t%s\n", i+1, lines[i]))
	}
	return buf.String(), nil
}

// toolWrite 写入文件（返回空，由 agent 层加 FileSummary 前缀）
func (td *ToolDispatcher) toolWrite(p, content string) (string, error) {
	if p == "" {
		return "", fmt.Errorf("no path provided")
	}
	dir := filepath.Dir(p)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return "", fmt.Errorf("create directory: %w", err)
	}
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		return "", err
	}
	return "OK", nil
}

// toolEdit 精确替换文件内容
func (td *ToolDispatcher) toolEdit(p, oldStr, newStr string) (string, error) {
	if p == "" {
		return "", fmt.Errorf("no path provided")
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return "", fmt.Errorf("file not found: %s", p)
	}

	content := string(data)
	if !strings.Contains(content, oldStr) {
		return "", fmt.Errorf("old_string not found in %s", p)
	}

	newContent := strings.Replace(content, oldStr, newStr, 1)
	if err := os.WriteFile(p, []byte(newContent), 0644); err != nil {
		return "", err
	}

	// 统计添加/删除行数
	added := strings.Count(newStr, "\n")
	removed := strings.Count(oldStr, "\n")
	if !strings.HasSuffix(oldStr, "\n") {
		removed++
	}
	if !strings.HasSuffix(newStr, "\n") {
		added++
	}

	return fmt.Sprintf("Edit(%s) [+%d -%d lines]", p, added, removed), nil
}

// toolBash 执行 shell 命令
func (td *ToolDispatcher) toolBash(ctx context.Context, cmd, timeoutStr string) (string, error) {
	if cmd == "" {
		return "", fmt.Errorf("no command provided")
	}

	// 安全检查
	if td.bashSafetyCheck != nil {
		if reason := td.bashSafetyCheck(cmd); reason != "" {
			return "", fmt.Errorf("command blocked by bash safety policy (%s)", reason)
		}
	}

	timeoutSecs := td.cfg.ToolTimeoutSecs
	if timeoutStr != "" {
		if t, err := time.ParseDuration(timeoutStr + "s"); err == nil {
			timeoutSecs = int(t.Seconds())
		}
	}

	var cmdCtx context.Context
	var cancel context.CancelFunc
	if timeoutSecs > 0 {
		cmdCtx, cancel = context.WithTimeout(ctx, time.Duration(timeoutSecs)*time.Second)
	} else {
		cmdCtx, cancel = context.WithCancel(ctx)
	}
	defer cancel()

	execCmd := exec.CommandContext(cmdCtx, "bash", "-lc", cmd)
	execCmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var stdout, stderr bytes.Buffer
	execCmd.Stdout = &stdout
	execCmd.Stderr = &stderr

	// 超时后 kill 整个进程组
	go func() {
		<-cmdCtx.Done()
		if execCmd.Process != nil {
			syscall.Kill(-execCmd.Process.Pid, syscall.SIGKILL)
		}
	}()

	err := execCmd.Run()
	output := stdout.String()
	if stderr.Len() > 0 {
		if output != "" {
			output += "\n"
		}
		output += stderr.String()
	}

	if cmdCtx.Err() == context.DeadlineExceeded {
		// 超时后 kill 整个进程组
		syscall.Kill(-execCmd.Process.Pid, syscall.SIGKILL)
		output += fmt.Sprintf("\n[... command timed out after %d seconds ...]", timeoutSecs)
	} else if err != nil {
		output += fmt.Sprintf("\n[exit code %d]", execCmd.ProcessState.ExitCode())
	}

	return FormatToolResult(output), nil
}

// toolGlob 文件匹配
func (td *ToolDispatcher) toolGlob(pattern, dir string) (string, error) {
	if pattern == "" {
		return "", fmt.Errorf("no pattern provided")
	}
	if dir == "" {
		dir = "."
	}
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return "", fmt.Errorf("directory not found: %s", dir)
	}

	// 使用 ripgrep 如果可用
	if rgPath, _ := exec.LookPath("rg"); rgPath != "" {
		cmd := exec.Command(rgPath, "--files", dir, "-g", pattern)
		out, _ := cmd.Output()
		return string(out), nil
	}

	// 回退到 filepath.Glob
	matches, err := filepath.Glob(filepath.Join(dir, pattern))
	if err != nil {
		return "", err
	}
	return strings.Join(matches, "\n") + "\n", nil
}

// toolGrep 搜索文件内容
func (td *ToolDispatcher) toolGrep(pattern, dir, glob, contextStr string) (string, error) {
	if pattern == "" {
		return "", fmt.Errorf("no pattern provided")
	}
	if dir == "" {
		dir = "."
	}
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		return "", fmt.Errorf("path not found: %s", dir)
	}

	rgPath, _ := exec.LookPath("rg")
	if rgPath == "" {
		return "", fmt.Errorf("rg is required for grep")
	}

	args := []string{"-n", "--color", "never", "--heading"}
	if contextStr != "" {
		args = append(args, "-C", contextStr)
	}
	if glob != "" {
		args = append(args, "--glob", glob)
	}
	args = append(args, "--", pattern, dir)

	cmd := exec.Command(rgPath, args...)
	out, _ := cmd.Output()
	return string(out), nil
}

// ─── Skill ───

func (td *ToolDispatcher) toolSkill(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("no skill name provided")
	}
	if td.skillLoader != nil {
		content, err := td.skillLoader(name)
		if err != nil {
			return "", fmt.Errorf("skill not found: %s", name)
		}
		return fmt.Sprintf("Skill: %s\n%s", name, content), nil
	}
	return "", fmt.Errorf("skill loader not configured")
}

// ─── TodoWrite ───

func (td *ToolDispatcher) toolTodoWrite(params map[string]string) (string, error) {
	// 优先处理 todos JSON 数组格式
	if todosJSON, ok := params["todos"]; ok && todosJSON != "" {
		var todos []struct {
			Content string `json:"content"`
			Status  string `json:"status"`
		}
		if err := json.Unmarshal([]byte(todosJSON), &todos); err == nil {
			var lines []string
			for _, t := range todos {
				if t.Status == "completed" {
					lines = append(lines, "- [x] "+t.Content)
				} else {
					lines = append(lines, "- [ ] "+t.Content)
				}
			}
			return strings.Join(lines, "\n"), nil
		}
	}
	// 兼容 checklist 文本格式
	if checklist, ok := params["checklist"]; ok && checklist != "" {
		return checklist, nil
	}
	return "", nil
}

// ─── PlanConfirm ───

func (td *ToolDispatcher) toolPlanConfirm() (string, error) {
	if td.planConfirmFn != nil {
		return td.planConfirmFn()
	}
	return "Error: plan confirm not configured", nil
}

// ─── PlanClear ───

func (td *ToolDispatcher) toolPlanClear() (string, error) {
	if td.planClearFn != nil {
		return td.planClearFn()
	}
	return "Error: plan clear not configured", nil
}

// ─── WebSearch ───

func (td *ToolDispatcher) toolWebSearch(ctx context.Context, query string) (string, error) {
	if query == "" {
		return "", fmt.Errorf("no query provided")
	}
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequestWithContext(ctx, "GET", "https://s.jina.ai/", nil)
	if err != nil {
		return "", err
	}
	q := req.URL.Query()
	q.Set("q", query)
	req.URL.RawQuery = q.Encode()
	if td.cfg.JinaAPIKey != "" {
		req.Header.Set("Authorization", "Bearer "+td.cfg.JinaAPIKey)
	}
	req.Header.Set("X-Respond-With", "no-content")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return string(body), nil
}

// ─── WebFetch ───

func (td *ToolDispatcher) toolWebFetch(ctx context.Context, url string) (string, error) {
	if url == "" {
		return "", fmt.Errorf("no url provided")
	}
	client := &http.Client{Timeout: 60 * time.Second}
	req, err := http.NewRequestWithContext(ctx, "GET", "https://r.jina.ai/"+url, nil)
	if err != nil {
		return "", err
	}
	if td.cfg.JinaAPIKey != "" {
		req.Header.Set("Authorization", "Bearer "+td.cfg.JinaAPIKey)
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	return string(body), nil
}

// ─── SubAgent ───

func (td *ToolDispatcher) toolSubAgent(ctx context.Context, prompt, description, fork string) (string, error) {
	if prompt == "" {
		return "", fmt.Errorf("no prompt provided for sub-agent")
	}
	if td.launcher != nil {
		return td.launcher(ctx, prompt, description, fork)
	}
	return "", fmt.Errorf("sub-agent launcher not configured")
}

// ─── FormatToolResult 截断过长输出 ───

func FormatToolResult(output string) string {
	maxBytes := getToolResultMaxBytes()
	if len(output) <= maxBytes {
		return output
	}

	size := len(output)
	tailLines := 5
	lines := strings.Split(output, "\n")
	var tailText string
	if len(lines) > tailLines {
		tailText = strings.Join(lines[len(lines)-tailLines:], "\n")
	} else {
		tailText = output
	}
	tailLen := len(tailText)
	headLen := maxBytes - 200 - tailLen
	if headLen <= 0 {
		headLen = maxBytes / 2
	}
	if headLen > len(output) {
		headLen = len(output)
	}

	marker := fmt.Sprintf("\n\n[... truncated: showing first/last portions of %d bytes ...]\n\n", size)
	return output[:headLen] + marker + tailText
}

// ─── FileSummary 文件信息摘要 ───

func FileSummary(kind, path string) string {
	if path == "" {
		return fmt.Sprintf("%s()", kind)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Sprintf("%s(%s)", kind, path)
	}
	// 统计行数
	data, err := os.ReadFile(path)
	lines := 0
	if err == nil {
		lines = strings.Count(string(data), "\n")
	}
	return fmt.Sprintf("%s(%s) [%d lines, %d bytes]", kind, path, lines, info.Size())
}

// ─── ExtractToolParams 从 JSON 消息中提取工具参数 ───

func ExtractToolParams(name string, raw json.RawMessage) map[string]string {
	params := make(map[string]string)
	if raw == nil {
		return params
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		// 尝试直接作为字符串解析
		var s string
		if err2 := json.Unmarshal(raw, &s); err2 == nil {
			// 单字符串参数
			params["_raw"] = s
		}
		return params
	}
	for k, v := range m {
		var s string
		if err := json.Unmarshal(v, &s); err == nil {
			params[k] = s
		} else {
			params[k] = string(v)
		}
	}
	return params
}

