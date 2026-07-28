package agent

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const defaultToolResultMaxBytes = 100000

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

// AsyncBashLauncher 异步 bash 启动回调
type AsyncBashLauncher func(ctx context.Context, cmd string, timeoutSecs int) (string, error)

// ToolDispatcher 工具调度器
type ToolDispatcher struct {
	cfg                    Config
	launcher               SubAgentLauncher
	backgroundBashLauncher AsyncBashLauncher
	planConfirmFn          func() (string, error)
	planClearFn            func() (string, error)
	skillLoader            func(name string) (string, error)
}

// NewToolDispatcher 创建工具调度器
func NewToolDispatcher(cfg Config) *ToolDispatcher {
	return &ToolDispatcher{cfg: cfg}
}

// SetSubAgentLauncher 设置子 agent 启动回调
func (td *ToolDispatcher) SetSubAgentLauncher(fn SubAgentLauncher) {
	td.launcher = fn
}

// SetAsyncBashLauncher 设置异步 bash 启动回调
func (td *ToolDispatcher) SetAsyncBashLauncher(fn AsyncBashLauncher) {
	td.backgroundBashLauncher = fn
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
		if err := nativeFileModeGuard(name, params["path"], ""); err != nil {
			return "", err
		}
		return td.toolRead(params["path"], params["offset"], params["limit"])
	case "Write":
		if err := nativeFileModeGuard(name, params["path"], ""); err != nil {
			return "", err
		}
		return td.toolWrite(params["path"], params["content"])
	case "Edit":
		if err := nativeFileModeGuard(name, params["path"], ""); err != nil {
			return "", err
		}
		return td.toolEdit(params["path"], params["old_string"], params["new_string"])
	case "Bash":
		return td.toolBash(ctx, params["command"], params["timeout"], params["background"])
	case "Glob":
		if err := nativeFileModeGuard(name, params["path"], params["pattern"]); err != nil {
			return "", err
		}
		return td.toolGlob(params["pattern"], params["path"])
	case "Grep":
		if err := nativeFileModeGuard(name, params["path"], ""); err != nil {
			return "", err
		}
		return td.toolGrep(params["pattern"], params["path"], params["glob"], params["context"])
	case "TodoWrite":
		return td.toolTodoWrite(params)
	case "PlanConfirm":
		return td.toolPlanConfirm()
	case "PlanClear":
		return td.toolPlanClear()
	case "Skill":
		return td.toolSkill(params["name"])
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
		return []string{"command", "timeout", "async"}
	case "Glob":
		return []string{"pattern", "path"}
	case "Grep":
		return []string{"pattern", "path", "glob", "context"}
	case "TodoWrite":
		return []string{"todos", "checklist"}
	case "Skill":
		return []string{"name"}
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
	case "SubAgent":
		key = "description"
	}
	value := params[key]
	if name == "Bash" {
		value = strings.ReplaceAll(value, "\n", " ")
		if len(value) > 80 {
			value = value[:77] + "..."
		}
	}
	if value != "" {
		return fmt.Sprintf("%s(%s)", name, value)
	}
	return fmt.Sprintf("%s()", name)
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
		return "", fmt.Errorf("read error: %v", err)
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

	// 不加行号 — 对齐 Bash sed -n / Rust 原始文本输出
	var buf strings.Builder
	for i := start; i < end; i++ {
		buf.WriteString(lines[i])
		buf.WriteByte('\n')
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
		return "", fmt.Errorf("create directory: %v", err)
	}
	if err := os.WriteFile(p, []byte(content), 0644); err != nil {
		return "", fmt.Errorf("write failed: %v", err)
	}
	return "OK", nil
}

// toolEdit 精确替换文件内容
func (td *ToolDispatcher) toolEdit(p, oldStr, newStr string) (string, error) {
	if p == "" {
		return "", fmt.Errorf("no path provided")
	}
	if oldStr == "" {
		return "", fmt.Errorf("empty old_string")
	}
	data, err := os.ReadFile(p)
	if err != nil {
		return "", fmt.Errorf("file not found: %s", p)
	}

	content := string(data)
	if !strings.Contains(content, oldStr) {
		return "", fmt.Errorf("old_string not found in %s. Hint: use Grep to locate the target lines, then Read the relevant portion (with offset/limit) to copy the exact text before retrying Edit.", p)
	}

	newContent := strings.Replace(content, oldStr, newStr, 1)
	if len(newContent) == 0 {
		return "", fmt.Errorf("edit produced empty result")
	}

	// 生成 diff — 对齐 bash 版: diff -u --color=always
	label := p
	if strings.HasPrefix(label, "/") {
		label = label[1:]
	}
	oldFile, _ := os.CreateTemp("", "edit_diff_old_*.tmp")
	newFile, _ := os.CreateTemp("", "edit_diff_new_*.tmp")
	var diffOutput string
	if oldFile != nil && newFile != nil {
		os.WriteFile(oldFile.Name(), []byte(content), 0644)
		os.WriteFile(newFile.Name(), []byte(newContent), 0644)
		cmd := exec.Command("diff", "-u", "--color=always",
			"--label", "a/"+label, "--label", "b/"+label,
			oldFile.Name(), newFile.Name())
		out, _ := cmd.Output()
		diffOutput = string(out)
		if strings.Contains(diffOutput, "unsupported --color") || strings.Contains(diffOutput, "unrecognized option '--color'") {
			cmd = exec.Command("diff", "-u",
				"--label", "a/"+label, "--label", "b/"+label,
				oldFile.Name(), newFile.Name())
			out, _ = cmd.Output()
			diffOutput = string(out)
		}
		os.Remove(oldFile.Name())
		os.Remove(newFile.Name())
		oldFile.Close()
		newFile.Close()
	}

	if err := os.WriteFile(p, []byte(newContent), 0644); err != nil {
		return "", err
	}

	// 统计 added/removed 行数 — 跳过 ANSI escape (\x1b[...m)
	added := 0
	removed := 0
	for _, line := range strings.Split(diffOutput, "\n") {
		p := line
		for len(p) > 0 && p[0] == '\x1b' {
			if len(p) > 1 && p[1] == '[' {
				idx := strings.IndexAny(p[2:], "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
				if idx >= 0 {
					p = p[idx+3:]
				} else {
					break
				}
			} else {
				break
			}
		}
		if strings.HasPrefix(p, "+") && !strings.HasPrefix(p, "++") {
			added++
		} else if strings.HasPrefix(p, "-") && !strings.HasPrefix(p, "--") {
			removed++
		}
	}

	result := fmt.Sprintf("Success: Edit(%s) [+%d -%d lines]", p, added, removed)
	if diffOutput != "" {
		result += "\n" + diffOutput
	}
	return result, nil
}

var (
	toolBashReRootDelete   = regexp.MustCompile(`(^|[\s;|&])rm\s+-[^\s]*[rf][^\s]*\s+/(\s|$|[*])`)
	toolBashReSystemPath   = regexp.MustCompile(`(^|[\s"'` + "`" + `])(/etc|/usr|/bin|/sbin|/var|/library|/system|/dev)(/|[\s"'` + "`" + `]|$)`)
	toolBashReSensitive    = regexp.MustCompile(`(^|[\s"'` + "`" + `])(~|\$home)/(\.ssh|\.gnupg|\.aws|\.docker)(/|[\s"'` + "`" + `]|$)|(^|[\s"'` + "`" + `])([^\s"'` + "`" + `]*\.(env|pem|key)|[^\s"'` + "`" + `]*(token|credential|secret)[^\s"'` + "`" + `]*)`)
	toolBashReExternalPath = regexp.MustCompile(`(^|[\s"'` + "`" + `])(~|\$home)(/|[\s"'` + "`" + `]|$)|(^|[\s"'` + "`" + `])/[A-Za-z0-9._-]`)
	toolBashReDeviceWrite  = regexp.MustCompile(`(^|[\s])(of=|>|1>|>>|1>>)\s*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)([\s]|$)`)
)

func getWd() string {
	if wd, err := os.Getwd(); err == nil {
		return wd
	}
	return ""
}

func toolBashModeNormalize(mode string) string {
	if mode == "" {
		mode = "0467"
	}
	if len(mode) != 4 {
		return "0000"
	}
	for _, ch := range mode {
		if ch < '0' || ch > '7' {
			return "0000"
		}
	}
	return mode
}

func toolBashAddMode(mask *int, scopes, perms int) {
	if scopes&8 != 0 {
		*mask |= perms << 9
	}
	if scopes&4 != 0 {
		*mask |= perms << 6
	}
	if scopes&2 != 0 {
		*mask |= perms << 3
	}
	if scopes&1 != 0 {
		*mask |= perms
	}
}

func toolBashAddPath(mask *int, path string, perms int, cwd string) {
	scope := 1
	path = strings.Trim(path, `"'`)
	path = strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(path, ";"), ","), ")")
	path = strings.TrimPrefix(path, "of=")
	if path == "" || path == "/dev/null" || strings.HasPrefix(path, "&") {
		return
	}
	home := os.Getenv("BASH_AGENT_HOME")
	if home == "" {
		home = os.Getenv("HOME")
	}
	projects := filepath.Join(strings.ToLower(home), ".bash-agent/projects")
	if path == "/tmp" || strings.HasPrefix(path, "/tmp/") || path == projects || strings.HasPrefix(path, projects+"/") {
		// Traversal can escape a trusted root, so classify it conservatively as system.
		if strings.Contains(path, "..") {
			scope = 8
		} else {
			scope = 0
		}
	}
	if scope == 1 && strings.HasPrefix(path, "/dev/tcp") {
		scope = 2
	} else if scope == 1 && (path == "/" || path == "/*" || toolBashReSensitive.MatchString(path) || toolBashReSystemPath.MatchString(path)) {
		scope = 8
	} else if scope == 1 && cwd != "" && (path == cwd || strings.HasPrefix(path, cwd+"/")) {
		scope = 1
	} else if scope == 1 && (toolBashReExternalPath.MatchString(path) || strings.Contains(path, "..")) {
		scope = 4
	}
	toolBashAddMode(mask, scope, perms)
}

func toolBashScanSegment(mask *int, seg string, cwd string) {
	flags, pathBits, redir := 0, 4, 0
	switch {
	case seg == "sudo" || strings.HasPrefix(seg, "sudo "), seg == "su" || strings.HasPrefix(seg, "su "), seg == "doas" || strings.HasPrefix(seg, "doas "), strings.HasPrefix(seg, "shutdown"), strings.HasPrefix(seg, "reboot"), strings.HasPrefix(seg, "halt"), strings.HasPrefix(seg, "poweroff"):
		toolBashAddMode(mask, 8, 1)
	case strings.HasPrefix(seg, "mkfs"), strings.HasPrefix(seg, "fdisk"), strings.HasPrefix(seg, "diskutil"), strings.HasPrefix(seg, "mount "), strings.HasPrefix(seg, "umount "):
		toolBashAddMode(mask, 8, 2)
	}
	switch {
	case strings.Contains(seg, "curl "), strings.Contains(seg, "wget "), strings.Contains(seg, "http "), strings.Contains(seg, "https://"), strings.Contains(seg, "http://"), strings.HasPrefix(seg, "git clone"), strings.HasPrefix(seg, "git fetch"), strings.HasPrefix(seg, "git pull"), strings.HasPrefix(seg, "git ls-remote"):
		toolBashAddMode(mask, 2, 4)
	}
	switch {
	case strings.HasPrefix(seg, "git push"), strings.Contains(seg, "scp "), strings.Contains(seg, "curl -d "), strings.Contains(seg, "curl --data"), strings.Contains(seg, "curl -f "), strings.Contains(seg, "curl -t "):
		toolBashAddMode(mask, 2, 2)
	case (strings.Contains(seg, "| bash") || strings.Contains(seg, "| sh") || strings.Contains(seg, "eval ") || strings.Contains(seg, "source <(") || strings.Contains(seg, "bash -c $(") || strings.Contains(seg, "sh -c $(")) &&
		(strings.Contains(seg, "curl ") || strings.Contains(seg, "wget ") || strings.Contains(seg, "http://") || strings.Contains(seg, "https://")):
		toolBashAddMode(mask, 2, 1)
	}
	if toolBashReRootDelete.MatchString(seg) || toolBashReDeviceWrite.MatchString(seg) {
		toolBashAddMode(mask, 8, 2)
	}
	switch {
	case strings.HasPrefix(seg, "./"), strings.HasPrefix(seg, "bash "), strings.HasPrefix(seg, "sh "), strings.HasPrefix(seg, "zsh "), strings.HasPrefix(seg, "python"), strings.HasPrefix(seg, "node "), strings.HasPrefix(seg, "ruby "), strings.HasPrefix(seg, "perl "), strings.HasPrefix(seg, "npm test"), strings.HasPrefix(seg, "npm run"), strings.HasPrefix(seg, "make"), strings.HasPrefix(seg, "cargo test"), strings.HasPrefix(seg, "cargo build"), strings.HasPrefix(seg, "go test"), strings.HasPrefix(seg, "git commit"), strings.HasPrefix(seg, "git add"), strings.HasPrefix(seg, "git checkout"), strings.HasPrefix(seg, "git merge"), strings.HasPrefix(seg, "git rebase"), strings.HasPrefix(seg, "git stash"), strings.HasPrefix(seg, "git cherry-pick"), strings.Contains(seg, "function "), strings.Contains(seg, "()"), strings.Contains(seg, "{"), strings.Contains(seg, " if "), strings.HasPrefix(seg, "if "), strings.Contains(seg, " for "), strings.HasPrefix(seg, "for "), strings.Contains(seg, " while "), strings.HasPrefix(seg, "while "), strings.Contains(seg, " case "), strings.HasPrefix(seg, "case "), strings.Contains(seg, ":(){:|:&};:"):
		toolBashAddMode(mask, 1, 1)
	}
	switch {
	case strings.Contains(seg, ">"), strings.Contains(seg, "tee "), strings.HasPrefix(seg, "mkdir "), strings.HasPrefix(seg, "touch "), strings.HasPrefix(seg, "cp "), strings.HasPrefix(seg, "mv "), strings.HasPrefix(seg, "rm "), strings.Contains(seg, " rm "), strings.Contains(seg, "sed -i"), strings.Contains(seg, " -delete"), strings.HasPrefix(seg, "git fetch"), strings.HasPrefix(seg, "git pull"), strings.HasPrefix(seg, "git clone"), strings.HasPrefix(seg, "git commit"), strings.HasPrefix(seg, "git add"), strings.HasPrefix(seg, "git checkout"), strings.HasPrefix(seg, "git merge"), strings.HasPrefix(seg, "git rebase"), strings.HasPrefix(seg, "git stash"), strings.HasPrefix(seg, "npm install"), strings.HasPrefix(seg, "pnpm install"), strings.HasPrefix(seg, "yarn install"), strings.HasPrefix(seg, "cargo build"), strings.HasPrefix(seg, "go test"), strings.HasPrefix(seg, "npm test"):
		pathBits, flags = 6, 1
	}
	for _, tok := range strings.Fields(seg) {
		if redir != 0 {
			toolBashAddPath(mask, tok, redir, cwd)
			flags, redir = 3, 0
			continue
		}
		switch {
		case tok == ">" || tok == ">>" || tok == "1>" || tok == "1>>":
			redir = 2
		case tok == "<>":
			redir = 6
		case strings.HasPrefix(tok, "2>"):
		case strings.HasPrefix(tok, ">") || strings.HasPrefix(tok, ">>"):
			toolBashAddPath(mask, strings.TrimLeft(tok, ">"), 2, cwd)
			flags = 3
		case strings.HasPrefix(tok, "<>"):
			toolBashAddPath(mask, strings.TrimPrefix(tok, "<>"), 6, cwd)
			flags = 3
		case strings.HasPrefix(tok, "/") || strings.HasPrefix(tok, "./") || strings.HasPrefix(tok, "../") || strings.HasPrefix(tok, "~/"):
			toolBashAddPath(mask, tok, pathBits, cwd)
			flags = 3
		case toolBashReSensitive.MatchString(tok):
			toolBashAddPath(mask, tok, pathBits, cwd)
			flags = 3
		}
	}
	if flags == 1 {
		toolBashAddMode(mask, 1, 2)
	}
}

func toolBashScanScript(script string, cwd string) int {
	mask := 0
	script = strings.ReplaceAll(script, "\\\n", " ")
	if strings.Contains(script, "/dev/tcp") {
		toolBashAddMode(&mask, 2, 6)
	}
	replacer := strings.NewReplacer("&&", "\n", "||", "\n", ";", "\n")
	for _, segment := range strings.Split(replacer.Replace(script), "\n") {
		segment = strings.TrimSpace(segment)
		if segment != "" {
			toolBashScanSegment(&mask, segment, cwd)
		}
	}
	return mask
}

func ToolClassifyBashRequiredMode(cmd string) string {
	mask := 0
	if cmd == "" {
		return "0000"
	}
	cwd := strings.ToLower(getWd())
	mask = toolBashScanScript(strings.ToLower(cmd), cwd)
	if mask == 0 {
		toolBashAddMode(&mask, 1, 4)
	}
	return fmt.Sprintf("%04o", mask)
}

func ToolBashModeAllows(allowed, required string) bool {
	allowedVal, _ := strconv.ParseInt(toolBashModeNormalize(allowed), 8, 32)
	requiredVal, _ := strconv.ParseInt(toolBashModeNormalize(required), 8, 32)
	return requiredVal&(4095^allowedVal) == 0
}

func nativeFileModeGuard(name, path, pattern string) error {
	target := path
	if target == "" {
		target = "."
	}
	if !strings.HasPrefix(target, "/") && target != "~" && !strings.HasPrefix(target, "~/") && !strings.HasPrefix(target, "./") && !strings.HasPrefix(target, "../") {
		target = "./" + target
	}
	probe := ""
	switch name {
	case "Read", "Grep":
		probe = "cat " + target
	case "Write", "Edit":
		probe = ": > " + target
	case "Glob":
		if path == "" && (strings.HasPrefix(pattern, "/") || strings.Contains(pattern, "..")) {
			probe = "cat /"
		} else {
			probe = "cat " + target
		}
	default:
		return nil
	}
	allowedMode := toolBashModeNormalize(os.Getenv("BASH_AGENT_BASH_MODE"))
	requiredMode := ToolClassifyBashRequiredMode(probe)
	if !ToolBashModeAllows(allowedMode, requiredMode) {
		return fmt.Errorf("command blocked by bash safety policy (required=%s allowed=%s; mode=system/external/network/workspace bits=4:read,2:write,1:execute)", requiredMode, allowedMode)
	}
	return nil
}

// toolBash 执行 shell 命令
func (td *ToolDispatcher) toolBash(ctx context.Context, cmd, timeoutStr, backgroundStr string) (string, error) {
	if cmd == "" {
		return "", fmt.Errorf("no command provided")
	}
	allowedMode := toolBashModeNormalize(os.Getenv("BASH_AGENT_BASH_MODE"))
	requiredMode := ToolClassifyBashRequiredMode(cmd)
	if !ToolBashModeAllows(allowedMode, requiredMode) {
		return "", fmt.Errorf("command blocked by bash safety policy (required=%s allowed=%s; mode=system/external/network/workspace bits=4:read,2:write,1:execute)", requiredMode, allowedMode)
	}

	// 异步模式
	isAsync := backgroundStr == "true" || backgroundStr == "1"
	if isAsync && td.backgroundBashLauncher != nil {
		timeoutSecs := td.cfg.ToolTimeoutSecs
		if timeoutStr != "" {
			if t, err := time.ParseDuration(timeoutStr + "s"); err == nil {
				timeoutSecs = int(t.Seconds())
			}
		}
		return td.backgroundBashLauncher(ctx, cmd, timeoutSecs)
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
	execCmd.Stdin = nil
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
	// Sanitize: replace illegal UTF-8 bytes with literal \ufffd (matches bash sanitize_utf8.awk)
	output := sanitizeUTF8(stdout.Bytes())
	if stderr.Len() > 0 {
		if output != "" {
			output += "\n"
		}
		output += sanitizeUTF8(stderr.Bytes())
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

// ─── sanitizeUTF8: 过滤非法 UTF-8 字节，替换为字面 \ufffd ───
// 移植自 src/awk/sanitize_utf8.awk，确保 JSON 序列化不会因非法字节失败。
func sanitizeUTF8(data []byte) string {
	var buf strings.Builder
	buf.Grow(len(data))
	i := 0
	n := len(data)
	for i < n {
		b := data[i]
		if b < 0x80 {
			// ASCII (0x00-0x7F): 直接输出
			buf.WriteByte(b)
			i++
		} else if b >= 0xC2 && b <= 0xDF {
			// 2 字节序列: C2-DF + 80-BF
			if i+1 < n && data[i+1] >= 0x80 && data[i+1] <= 0xBF {
				buf.WriteByte(b)
				buf.WriteByte(data[i+1])
				i += 2
			} else {
				buf.WriteString(`\ufffd`)
				i++
			}
		} else if b >= 0xE0 && b <= 0xEF {
			// 3 字节序列: E0-EF + 80-BF + 80-BF
			if i+2 < n && data[i+1] >= 0x80 && data[i+1] <= 0xBF && data[i+2] >= 0x80 && data[i+2] <= 0xBF {
				buf.WriteByte(b)
				buf.WriteByte(data[i+1])
				buf.WriteByte(data[i+2])
				i += 3
			} else {
				buf.WriteString(`\ufffd`)
				i++
			}
		} else if b >= 0xF0 && b <= 0xF4 {
			// 4 字节序列: F0-F4 + 80-BF + 80-BF + 80-BF
			if i+3 < n && data[i+1] >= 0x80 && data[i+1] <= 0xBF && data[i+2] >= 0x80 && data[i+2] <= 0xBF && data[i+3] >= 0x80 && data[i+3] <= 0xBF {
				buf.WriteByte(b)
				buf.WriteByte(data[i+1])
				buf.WriteByte(data[i+2])
				buf.WriteByte(data[i+3])
				i += 4
			} else {
				buf.WriteString(`\ufffd`)
				i++
			}
		} else {
			// 非法字节: C0-C1(过长编码), 80-BF(孤立 continuation), F5-FF(超范围)
			buf.WriteString(`\ufffd`)
			i++
		}
	}
	return buf.String()
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

func FileSummary(kind, path, offset, limit string) string {
	if path == "" {
		return fmt.Sprintf("%s()", kind)
	}
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Sprintf("%s(%s)", kind, path)
	}
	// 统计行数 — 换行符个数，最后一行无换行补1
	data, err := os.ReadFile(path)
	lines := 0
	if err == nil {
		nl := strings.Count(string(data), "\n")
		if len(data) > 0 && data[len(data)-1] != '\n' {
			lines = nl + 1
		} else {
			lines = nl
		}
	}
	rng := ""
	if offset != "" || limit != "" {
		if offset == "" {
			offset = "1"
		}
		if limit == "" {
			limit = fmt.Sprintf("%d", lines)
		}
		rng = fmt.Sprintf(", offset=%s, limit=%s", offset, limit)
	}
	return fmt.Sprintf("%s(%s) [%d lines, %d bytes%s]", kind, path, lines, info.Size(), rng)
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
