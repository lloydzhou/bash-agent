package prompt

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type Builder struct {
	Cwd         string
	Home        string
	Skills      []string
	SummaryFile string
	TodoFile    string
	PlanFile    string
}

func (b Builder) BuildSystemPrompt() (string, error) {
	sections := make([]string, 0, 8)
	sections = appendSection(sections, "agent-identity", "You are bash-agent, a lightweight coding agent that works in a terminal.", "")
	locale := "en_US"
	for _, key := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if v := os.Getenv(key); v != "" {
			locale = v
			break
		}
	}
	// Strip encoding suffix (e.g., zh_CN.UTF-8 -> zh_CN)
	if idx := strings.Index(locale, "."); idx >= 0 {
		locale = locale[:idx]
	}
	environment := "lang: " + locale + "\npwd: " + b.Cwd + "\nhome: " + b.Home + "\nplatform: " + runtime.GOOS
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "unknown"
	}
	environment += "\nshell: " + shell
	sections = appendSection(sections, "environment", environment, "")
	rules := fmt.Sprintf("- Be concise and concrete.\n- Prefer safe, exact edits.\n- Report failures clearly.\n- No pleasantries. No explanations unless asked. Raw results only.\n- MUST use %s for all output, including thinking/reasoning. Never mix languages. Code, commands, and file content remain as-is.", locale)
	sections = appendSection(sections, "rules", rules, "")
	sections = appendSection(sections, "using-your-tools", "- Use Read for a single file. If you need multiple files, call Read multiple times.\n- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n- Use Glob and Grep for one pattern at a time.\n- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n- Use multiple tool calls in one response when they are independent.\n- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n- For skills, first check the skill-index section, then use Skill(name) for the matching skill.", "")
	sections = appendSection(sections, "todo-guidance", "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.", "")
	planFile := b.PlanFile
	if planFile == "" {
		planFile = "<not set>"
	}
	planLifecycleGuidance := fmt.Sprintf(`- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)
- **Step-by-step**:
  1. Write plan to PLAN_FILE using Edit (markdown: goal, analysis, steps, notes)
  2. Ask user to confirm the plan before execution
  3. After user confirms, create TodoWrite checklist based on plan
  4. Execute tasks following todo checklist (update progress in TodoWrite)
  5. When all tasks complete, clear plan: Bash ": > PLAN_FILE"
- **Plan vs Todo separation**:
  - PLAN_FILE: planning document for analysis and strategy
  - TodoWrite: execution checklist for real-time progress tracking
  - Do NOT mix todo checkboxes into plan file
- **PLAN_FILE**: %s`, planFile)
	sections = appendSection(sections, "plan-lifecycle-guidance", planLifecycleGuidance, "")
	if section, err := b.buildInstructionFilesSection(); err != nil {
		return "en_US", err
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
	if section, err := readOptionalFile(b.PlanFile); err != nil {
		return "", err
	} else {
		sections = appendSection(sections, "current-plan", section, b.PlanFile)
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
	bases := findSkillBaseDirs(b.Cwd, b.Home)
	if len(bases) == 0 {
		return "", nil
	}
	seen := map[string]struct{}{}
	var lines []string
	for _, base := range bases {
		entries, err := os.ReadDir(base)
		if err != nil {
			return "", err
		}
		for _, entry := range entries {
			if !entry.IsDir() {
				continue
			}
			if _, ok := seen[entry.Name()]; ok {
				continue
			}
			skillFile := filepath.Join(base, entry.Name(), "SKILL.md")
			data, err := os.ReadFile(skillFile)
			if err != nil {
				continue
			}
			seen[entry.Name()] = struct{}{}
			summary := extractSkillSummary(string(data))
			if summary != "" {
				lines = append(lines, fmt.Sprintf("- %s: %s", entry.Name(), summary))
			} else {
				lines = append(lines, "- "+entry.Name())
			}
		}
	}
	return strings.Join(lines, "\n"), nil
}

func (b Builder) buildSelectedSkillsSection() (string, error) {
	if len(b.Skills) == 0 {
		return "", nil
	}
	bases := findSkillBaseDirs(b.Cwd, b.Home)
	if len(bases) == 0 {
		return "", nil
	}
	var sections []string
	for _, skill := range b.Skills {
		skillFile := findSkillFile(bases, skill)
		if skillFile == "" {
			return "", fmt.Errorf("skill not found: %s (expected .claude/skills/%s/SKILL.md or ~/.claude/skills/%s/SKILL.md)", skill, skill, skill)
		}
		data, err := os.ReadFile(skillFile)
		if err != nil {
			return "", err
		}
		content := strings.ReplaceAll(string(data), "${BASH_AGENT_SKILL_DIR}", filepath.Dir(skillFile))
		full := fmt.Sprintf("Base directory for this skill: %s\n\n%s", filepath.Dir(skillFile), content)
		sections = appendSection(sections, "skill", full, skill)
	}
	return strings.Join(sections, "\n"), nil
}

func findSkillBaseDirs(cwd, home string) []string {
	dirs := []string{}
	project := filepath.Join(cwd, ".claude", "skills")
	if info, err := os.Stat(project); err == nil && info.IsDir() {
		dirs = append(dirs, project)
	}
	projectDev := filepath.Join(cwd, "skills")
	if info, err := os.Stat(projectDev); err == nil && info.IsDir() {
		dirs = append(dirs, projectDev)
	}
	if home != "" {
		global := filepath.Join(home, ".claude", "skills")
		if info, err := os.Stat(global); err == nil && info.IsDir() {
			dirs = append(dirs, global)
		}
	}
	return dirs
}

func findSkillFile(bases []string, skill string) string {
	for _, base := range bases {
		path := filepath.Join(base, skill, "SKILL.md")
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

func ResolveSkillFile(cwd, home, skill string) string {
	return findSkillFile(findSkillBaseDirs(cwd, home), skill)
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
	var fallback string
	lines := strings.Split(content, "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "description:") {
			desc := strings.TrimSpace(strings.TrimPrefix(trimmed, "description:"))
			if len(desc) >= 2 {
				if strings.HasPrefix(desc, "\"") {
					desc = strings.TrimPrefix(desc, "\"")
					desc = strings.TrimSuffix(desc, "\"")
				} else if strings.HasPrefix(desc, "'") {
					desc = strings.TrimPrefix(desc, "'")
					desc = strings.TrimSuffix(desc, "'")
				}
			}
			return desc
		}
		if fallback == "" &&
			!strings.HasPrefix(trimmed, "#") &&
			trimmed != "---" &&
			!strings.HasPrefix(trimmed, "```") {
			fallback = trimmed
		}
	}
	return fallback
}
