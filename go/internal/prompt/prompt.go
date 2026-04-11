package prompt

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type Builder struct {
	Cwd         string
	Home        string
	Skills      []string
	SummaryFile string
	TodoFile    string
}

func (b Builder) BuildSystemPrompt() (string, error) {
	sections := make([]string, 0, 8)
	sections = appendSection(sections, "agent-identity", "You are bash-agent, a lightweight coding agent that works in a terminal.", "")
	sections = appendSection(sections, "rules", "- Be concise and concrete.\n- Use tools when needed.\n- Prefer safe, exact edits.\n- Report failures clearly.", "")
	sections = appendSection(sections, "todo-guidance", "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.", "")
	if section, err := b.buildInstructionFilesSection(); err != nil {
		return "", err
	} else {
		sections = appendSection(sections, "instruction-files", section, "")
	}
	if section, err := b.buildSkillIndexSection(); err != nil {
		return "", err
	} else {
		sections = appendSection(sections, "skill-index", section, "")
	}
	if section, err := b.buildSelectedSkillsSection(); err != nil {
		return "", err
	} else {
		sections = appendSection(sections, "selected-skills", section, "")
	}
	if section, err := readOptionalFile(b.SummaryFile); err != nil {
		return "", err
	} else {
		sections = appendSection(sections, "context-summary", section, "")
	}
	if section, err := readOptionalFile(b.TodoFile); err != nil {
		return "", err
	} else {
		sections = appendSection(sections, "current-todo", section, "")
	}
	return strings.Join(sections, "\n"), nil
}

func BuildCompactSummarySystemPrompt() string {
	return strings.Join([]string{
		"You are compressing conversation context for a lightweight coding agent.",
		"",
		"Return only plain text.",
		"Do not include analysis, markdown fences, or extra commentary.",
		"Update the existing summary snapshot using the dropped messages.",
		"Keep the output concise and specific.",
		"",
		"Use exactly these fields:",
		"Task focus:",
		"Latest request:",
		"Progress:",
		"Tool evidence:",
	}, "\n")
}

func BuildCompactSummaryUserPrompt(currentSummary, droppedMessages string) string {
	return wrapSection("current-summary", currentSummary, "") + "\n\n" + wrapSection("dropped-messages", droppedMessages, "")
}

func appendSection(sections []string, tag, content, name string) []string {
	if strings.TrimSpace(content) == "" {
		return sections
	}
	return append(sections, wrapSection(tag, content, name))
}

func wrapSection(tag, content, name string) string {
	if strings.TrimSpace(content) == "" {
		return ""
	}
	if name != "" {
		return fmt.Sprintf("<%s name=\"%s\">\n%s\n</%s>", tag, escapeAttr(name), content, tag)
	}
	return fmt.Sprintf("<%s>\n%s\n</%s>", tag, content, tag)
}

func escapeAttr(s string) string {
	repl := strings.NewReplacer("&", "&amp;", "\"", "&quot;", "<", "&lt;", ">", "&gt;")
	return repl.Replace(s)
}

func readOptionalFile(path string) (string, error) {
	if path == "" {
		return "", nil
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	if len(data) == 0 {
		return "", nil
	}
	return string(data), nil
}

func (b Builder) buildInstructionFilesSection() (string, error) {
	var out []string
	globalFile := findInstructionFileInDir(filepath.Join(b.Home, ".bash-agent"))
	projectFile := findInstructionFileInDir(b.Cwd)
	if globalFile != "" {
		content, err := os.ReadFile(globalFile)
		if err != nil {
			return "", err
		}
		out = appendSection(out, "instruction-file", string(content), "global")
	}
	if projectFile != "" {
		content, err := os.ReadFile(projectFile)
		if err != nil {
			return "", err
		}
		out = appendSection(out, "instruction-file", string(content), "project")
	}
	return strings.Join(out, "\n"), nil
}

func (b Builder) buildSkillIndexSection() (string, error) {
	base := findSkillBaseDir(b.Cwd)
	if base == "" {
		return "", nil
	}
	entries, err := os.ReadDir(base)
	if err != nil {
		return "", err
	}
	var lines []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		skillFile := filepath.Join(base, entry.Name(), "SKILL.md")
		data, err := os.ReadFile(skillFile)
		if err != nil {
			continue
		}
		summary := extractSkillSummary(string(data))
		if summary != "" {
			lines = append(lines, fmt.Sprintf("- %s: %s", entry.Name(), summary))
		} else {
			lines = append(lines, "- "+entry.Name())
		}
	}
	return strings.Join(lines, "\n"), nil
}

func (b Builder) buildSelectedSkillsSection() (string, error) {
	if len(b.Skills) == 0 {
		return "", nil
	}
	base := findSkillBaseDir(b.Cwd)
	if base == "" {
		return "", nil
	}
	var sections []string
	for _, skill := range b.Skills {
		skillFile := filepath.Join(base, skill, "SKILL.md")
		data, err := os.ReadFile(skillFile)
		if err != nil {
			return "", fmt.Errorf("skill not found: %s", skill)
		}
		content := strings.ReplaceAll(string(data), "${BASH_AGENT_SKILL_DIR}", filepath.Dir(skillFile))
		full := fmt.Sprintf("Base directory for this skill: %s\n\n%s", filepath.Dir(skillFile), content)
		sections = appendSection(sections, "skill", full, skill)
	}
	return strings.Join(sections, "\n"), nil
}

func findSkillBaseDir(cwd string) string {
	path := filepath.Join(cwd, ".claude", "skills")
	if info, err := os.Stat(path); err == nil && info.IsDir() {
		return path
	}
	return ""
}

func findInstructionFileInDir(dir string) string {
	candidates := []string{
		filepath.Join(dir, "AGENTS.md"),
		filepath.Join(dir, "AGENT.md"),
		filepath.Join(dir, "CLAUDE.md"),
		filepath.Join(dir, ".claude", "CLAUDE.md"),
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}

func extractSkillSummary(content string) string {
	lines := strings.Split(content, "\n")
	heading := ""
	for _, line := range lines {
		if heading == "" && strings.HasPrefix(line, "# ") {
			heading = strings.TrimSpace(strings.TrimPrefix(line, "# "))
			continue
		}
		if strings.TrimSpace(line) == "" {
			continue
		}
		return strings.TrimSpace(line)
	}
	return heading
}
