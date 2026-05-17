package agent

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

//go:embed tools.json
var embeddedToolsJSON string

// ─── util_* 工具函数（23 个） ───

// UtilAwkRun 兼容占位 — Go 版本不需要 awk
// 保留签名以便 store 层 compact 逻辑的注释对齐

// UtilNewSessionID 生成新会话 ID
func UtilNewSessionID() string {
	now := time.Now()
	secondary := rand.Intn(0x10000)
	return fmt.Sprintf("%s-%04x", now.Format("20060102-150405"), secondary)
}

// UtilRunTimeout 带超时执行命令
func UtilRunTimeout(timeoutSecs int, name string, args ...string) (string, int) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutSecs)*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	output := stdout.String() + stderr.String()
	rc := 0
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return output + "\n[... command timed out ...]", 124
		}
		rc = 1
	}
	return output, rc
}

// UtilDie 打印错误并退出
func UtilDie(msg string) {
	fmt.Fprintf(os.Stderr, "\033[31mError: %s\033[0m\n", msg)
	os.Exit(1)
}

// UtilParseSize 解析人类可读大小（如 100k, 50m, 2g）→ 整数
func UtilParseSize(raw string) (int, error) {
	if raw == "" {
		return 0, fmt.Errorf("empty size")
	}
	lower := strings.ToLower(raw)
	multiplier := 1
	numStr := lower

	switch {
	case strings.HasSuffix(lower, "g"):
		numStr = strings.TrimSuffix(lower, "g")
		multiplier = 1000 * 1000 * 1000
	case strings.HasSuffix(lower, "m"):
		numStr = strings.TrimSuffix(lower, "m")
		multiplier = 1000 * 1000
	case strings.HasSuffix(lower, "k"):
		numStr = strings.TrimSuffix(lower, "k")
		multiplier = 1000
	}

	var num int
	_, err := fmt.Sscanf(numStr, "%d", &num)
	if err != nil {
		return 0, fmt.Errorf("invalid size: %s", raw)
	}
	return num * multiplier, nil
}

// UtilJSONEscape JSON 转义字符串（不含引号）
func UtilJSONEscape(s string) string {
	var buf strings.Builder
	buf.Grow(len(s) + 10)
	for _, r := range s {
		switch r {
		case '"':
			buf.WriteString(`\"`)
		case '\\':
			buf.WriteString(`\\`)
		case '\n':
			buf.WriteString(`\n`)
		case '\r':
			buf.WriteString(`\r`)
		case '\t':
			buf.WriteString(`\t`)
		case '\b':
			buf.WriteString(`\b`)
		case '\f':
			buf.WriteString(`\f`)
		default:
			if r < 0x20 {
				fmt.Fprintf(&buf, `\u%04x`, r)
			} else {
				buf.WriteRune(r)
			}
		}
	}
	return buf.String()
}

// UtilIsStreamJSON 检查是否为 stream-json 输出模式
func UtilIsStreamJSON(format string) bool {
	return format == "stream-json"
}

// UtilAppendSection 构建标签包裹的段落（对应 bash 的 util_append_section）
func UtilAppendSection(out *strings.Builder, tag, content, name string) {
	if content == "" {
		return
	}
	if name != "" {
		fmt.Fprintf(out, "<%s name=\"%s\">\n%s\n</%s>\n", tag, UtilJSONEscape(name), content, tag)
	} else {
		fmt.Fprintf(out, "<%s>\n%s\n</%s>\n", tag, content, tag)
	}
}

// UtilMsgToStream 将 Event 转换为 stream-json 格式的 JSON 行
func UtilMsgToStream(ev Event) (string, error) {
	switch ev.Type {
	case EventText:
		if len(ev.Fields) > 1 {
			return fmt.Sprintf(`{"type":"text","content":"%s"}`, UtilJSONEscape(ev.Fields[1])), nil
		}
	case EventThinking:
		if len(ev.Fields) > 1 {
			return fmt.Sprintf(`{"type":"thinking","content":"%s"}`, UtilJSONEscape(ev.Fields[1])), nil
		}
	case EventToolCall:
		if len(ev.Fields) >= 4 {
			return fmt.Sprintf(`{"type":"tool_call","name":"%s","id":"%s","input":%s}`,
				UtilJSONEscape(ev.Fields[1]), UtilJSONEscape(ev.Fields[2]), ev.Fields[3]), nil
		}
	case EventToolResult:
		if len(ev.Fields) >= 4 {
			return fmt.Sprintf(`{"type":"tool_result","tool_use_id":"%s","name":"%s","content":"%s"}`,
				UtilJSONEscape(ev.Fields[1]), UtilJSONEscape(ev.Fields[2]), UtilJSONEscape(ev.Fields[3])), nil
		}
	case EventUsage:
		in, out, cr, cc := "0", "0", "0", "0"
		if len(ev.Fields) >= 4 {
			in, out, cr, cc = ev.Fields[0], ev.Fields[1], ev.Fields[2], ev.Fields[3]
		}
		return fmt.Sprintf(`{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"kind":"agent"}`,
			in, out, cr, cc), nil
	case EventStop:
		reason := ""
		if len(ev.Fields) > 0 {
			reason = ev.Fields[0]
		}
		return fmt.Sprintf(`{"type":"stop","reason":"%s"}`, UtilJSONEscape(reason)), nil
	case EventContextUpdate:
		kind, trigger := "", ""
		if len(ev.Fields) >= 2 {
			kind, trigger = ev.Fields[0], ev.Fields[1]
		}
		return fmt.Sprintf(`{"type":"context_update","kind":"%s","trigger":"%s"}`, UtilJSONEscape(kind), UtilJSONEscape(trigger)), nil
	case EventError:
		msg := ""
		if len(ev.Fields) > 0 {
			msg = ev.Fields[0]
		}
		return fmt.Sprintf(`{"type":"error","message":"%s"}`, UtilJSONEscape(msg)), nil
	case EventRetry:
		return `{"type":"retry"}`, nil
	}
	return "", fmt.Errorf("unknown event type: %d", ev.Type)
}

// UtilReadOptional 读取可选文件内容
func UtilReadOptional(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	data, err := os.ReadFile(path)
	if err != nil || len(data) == 0 {
		return "", nil
	}
	return string(data), nil
}

// UtilFindSkillDirs 查找 skill 目录列表
func UtilFindSkillDirs() []string {
	var dirs []string
	cwd, _ := os.Getwd()
	home, _ := os.UserHomeDir()

	for _, base := range []string{cwd, cwd + "/.."} {
		abs, _ := filepath.Abs(base)
		if dir := filepath.Join(abs, ".claude", "skills"); dirExists(dir) {
			dirs = append(dirs, dir)
		}
		if dir := filepath.Join(abs, "skills"); dirExists(dir) {
			dirs = append(dirs, dir)
		}
	}
	if home != "" {
		if dir := filepath.Join(home, ".claude", "skills"); dirExists(dir) {
			dirs = append(dirs, dir)
		}
	}
	return dirs
}

// UtilLoadSkillContent 加载指定 skill 的内容
func UtilLoadSkillContent(skillName string) (string, error) {
	for _, base := range UtilFindSkillDirs() {
		skillFile := filepath.Join(base, skillName, "SKILL.md")
		if fileExists(skillFile) {
			data, err := os.ReadFile(skillFile)
			if err != nil {
				return "", err
			}
			skillDir := filepath.Dir(skillFile)
			content := strings.ReplaceAll(string(data), "${BASH_AGENT_SKILL_DIR}", skillDir)
			return fmt.Sprintf("Base directory: %s\n\n%s", skillDir, content), nil
		}
	}
	return "", fmt.Errorf("skill not found: %s", skillName)
}

// UtilBuildSkillIndex 构建 skill 索引摘要
func UtilBuildSkillIndex() string {
	var output strings.Builder
	seen := make(map[string]bool)

	for _, base := range UtilFindSkillDirs() {
		matches, _ := filepath.Glob(filepath.Join(base, "*", "SKILL.md"))
		for _, skillFile := range matches {
			skillName := filepath.Base(filepath.Dir(skillFile))
			if seen[skillName] {
				continue
			}
			seen[skillName] = true
			// 读取第一行非空内容作为摘要
			summary := extractSkillSummary(skillFile)
			if summary != "" {
				fmt.Fprintf(&output, "- %s: %s\n", skillName, summary)
			} else {
				fmt.Fprintf(&output, "- %s\n", skillName)
			}
		}
	}
	return strings.TrimRight(output.String(), "\n")
}

// UtilBuildSkillsSection 构建已选 skill 的完整内容段落
func UtilBuildSkillsSection(skillNames []string) string {
	var output strings.Builder
	for _, name := range skillNames {
		content, err := UtilLoadSkillContent(name)
		if err != nil {
			UtilDie(fmt.Sprintf("Skill not found: %s (%v)", name, err))
		}
		UtilAppendSection(&output, "skill", content, name)
	}
	return strings.TrimRight(output.String(), "\n")
}

// UtilFindInstructionFile 查找指令文件（AGENTS.md, AGENT.md, CLAUDE.md, .claude/CLAUDE.md）
func UtilFindInstructionFile(dir string) (string, error) {
	if dir == "" || !dirExists(dir) {
		return "", fmt.Errorf("directory not found: %s", dir)
	}
	candidates := []string{
		filepath.Join(dir, "AGENTS.md"),
		filepath.Join(dir, "AGENT.md"),
		filepath.Join(dir, "CLAUDE.md"),
		filepath.Join(dir, ".claude", "CLAUDE.md"),
	}
	for _, c := range candidates {
		if fileExists(c) {
			return c, nil
		}
	}
	return "", fmt.Errorf("no instruction file found in %s", dir)
}

// UtilBuildInstructionsSection 构建指令文件段落
func UtilBuildInstructionsSection() string {
	var output strings.Builder
	home, _ := os.UserHomeDir()
	cwd, _ := os.Getwd()

	if home != "" {
		if f, err := UtilFindInstructionFile(filepath.Join(home, ".bash-agent")); err == nil {
			if content, err := os.ReadFile(f); err == nil {
				UtilAppendSection(&output, "instruction-file", string(content), "global")
			}
		}
	}
	if cwd != "" {
		if f, err := UtilFindInstructionFile(cwd); err == nil {
			if content, err := os.ReadFile(f); err == nil {
				UtilAppendSection(&output, "instruction-file", string(content), "project")
			}
		}
	}
	return strings.TrimRight(output.String(), "\n")
}

// UtilBuildToolCallJSON 构建工具调用 JSON
func UtilBuildToolCallJSON(name, id, input, typ string) string {
	if typ == "tool_use" || typ == "" {
		return fmt.Sprintf(`{"type":"tool_use","id":"%s","name":"%s","input":%s}`,
			UtilJSONEscape(id), UtilJSONEscape(name), input)
	}
	return fmt.Sprintf(`{"name":"%s","id":"%s","input":%s}`,
		UtilJSONEscape(name), UtilJSONEscape(id), input)
}

// UtilBuildToolResultJSON 构建工具结果 JSON
func UtilBuildToolResultJSON(tid, result, typ string) string {
	if typ == "" {
		typ = "tool_result"
	}
	return fmt.Sprintf(`{"type":"%s","tool_use_id":"%s","content":"%s"}`,
		UtilJSONEscape(typ), UtilJSONEscape(tid), UtilJSONEscape(result))
}

// UtilBuildAssistantJSON 构建 assistant 消息 JSON content 数组
func UtilBuildAssistantJSON(text, thinking string, calls []ToolCallInfo) string {
	var buf bytes.Buffer
	buf.WriteString("[")
	fmt.Fprintf(&buf, `{"type":"thinking","thinking":"%s"}`, UtilJSONEscape(thinking))
	fmt.Fprintf(&buf, `,{"type":"text","text":"%s"}`, UtilJSONEscape(text))
	for _, tc := range calls {
		fmt.Fprintf(&buf, `,{"type":"tool_use","id":"%s","name":"%s","input":%s}`,
			UtilJSONEscape(tc.ID), UtilJSONEscape(tc.Name), tc.Input)
	}
	buf.WriteString("]")
	return buf.String()
}

// UtilLoadToolDefs 从 tools.json 加载工具定义，文件不存在时返回嵌入的默认定义。
func UtilLoadToolDefs(scriptDir string) (string, error) {
	toolsFile := filepath.Join(scriptDir, "tools.json")
	if fileExists(toolsFile) {
		data, err := os.ReadFile(toolsFile)
		if err != nil {
			return "", err
		}
		return string(data), nil
	}
	// 文件不存在时使用编译时嵌入的默认 tools.json
	if embeddedToolsJSON != "" {
		return embeddedToolsJSON, nil
	}
	return "", fmt.Errorf("cannot find tools.json: %s", toolsFile)
}

// ─── 内部辅助函数 ───

func dirExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

func fileExists(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir()
}

// extractSkillSummary 从 SKILL.md 提取摘要（第一行非空非标题内容）
func extractSkillSummary(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "---") || strings.HasPrefix(line, "#") {
			continue
		}
		return line
	}
	return ""
}

// ─── JSON 辅助函数 ───

// extractJSONString 从 map 中提取字符串字段
func extractJSONString(m map[string]json.RawMessage, key string) (string, bool) {
	raw, ok := m[key]
	if !ok {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return string(raw), true
	}
	return s, true
}

// osStderr 可被测试替换
var osStderr = os.Stderr

// ToolDenyBashReason 检查 bash 命令是否被安全策略阻止
// 返回阻止原因；空字符串表示允许执行
func ToolDenyBashReason(cmd string) string {
	if cmd == "" {
		return ""
	}

	// 危险命令前缀
	dangerous := []string{"sudo ", "shutdown", "reboot", "halt", "poweroff", "mkfs", "fdisk"}
	for _, d := range dangerous {
		if strings.HasPrefix(cmd, d) {
			return "blocked dangerous command prefix"
		}
	}

	// 根目录删除
	if strings.Contains(cmd, "rm -rf /") || strings.Contains(cmd, "rm -fr /") {
		return "blocked destructive root deletion pattern"
	}

	// 设备写入
	deviceRe := regexp.MustCompile(`(^|\s)(of=|>|1>|>>|1>>)\s*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)(\s|$)`)
	if deviceRe.MatchString(cmd) {
		return "blocked device write pattern"
	}

	// find -delete
	if strings.Contains(cmd, "find ") && strings.Contains(cmd, " -delete") {
		return "blocked destructive find -delete pattern"
	}

	// fork bomb
	if strings.Contains(cmd, ":(){:|:&};:") {
		return "blocked fork bomb pattern"
	}

	return ""
}
