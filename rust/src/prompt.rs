use anyhow::Result;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

pub struct Builder {
    pub cwd: PathBuf,
    pub home: PathBuf,
    pub skills: Vec<String>,
    pub summary_file: PathBuf,
    pub plan_file: PathBuf,
    pub plan_draft_file: PathBuf,
}

impl Builder {
    pub fn build_system_prompt(&self) -> Result<String> {
        let mut sections = Vec::new();
        let locale_raw = ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
            .unwrap_or_else(|| "en_US".to_string());
        // Strip encoding suffix (e.g., zh_CN.UTF-8 -> zh_CN)
        let locale = locale_raw
            .split('.')
            .next()
            .unwrap_or(&locale_raw)
            .to_string();
        let identity = if locale.starts_with("zh") {
            "你是 bash-agent，一个在终端中运行的轻量级编码智能体。".to_string()
        } else {
            format!("You are bash-agent, a lightweight coding agent that works in a terminal.")
        };
        sections.push(wrap_section("agent-identity", &identity, None));
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "unknown".to_string());
        let platform = std::env::consts::OS;
        let environment = format!(
            "lang: {}\npwd: {}\nhome: {}\nplatform: {}\nshell: {}",
            locale,
            self.cwd.display(),
            self.home.display(),
            platform,
            shell
        );
        sections.push(wrap_section("environment", &environment, None));
        let rules_str = "- Be concise and concrete. No pleasantries, no explanations unless asked. Raw results only.\n- Prefer safe, exact edits.\n- Report failures clearly.";
        sections.push(wrap_section("rules", &rules_str, None));
        sections.push(wrap_section(
            "using-your-tools",
            "- Use Read for a single file. If you need multiple files, call Read multiple times.\n- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n- Use Glob and Grep for one pattern at a time.\n- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n- Use multiple tool calls in one response when they are independent.\n- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n- For skills, first check the skill-index section, then use Skill(name) for the matching skill.",
            None,
        ));
        sections.push(wrap_section(
            "sub-agent-guidance",
            "- **When to use**: delegating independent sub-tasks that do NOT need your current conversation context — e.g. investigating a separate file, running a focused search, testing a hypothesis in isolation.\n- **When NOT to use**: tasks that depend on your working context, conversation history, or intermediate state. The child agent starts with a blank slate.\n- **Prompt design**: write a complete, self-contained prompt. Include all file paths, function names, error messages, and constraints the child needs. Assume zero shared context.\n- **Result handling**: when the child completes, its result is injected as a user message: `[sub-agent <id>] <status> (in=<n>, out=<n>)\nThinking: ...\nText: ...`. You then get another LLM turn to interpret and act on it.\n- **Parallelism**: multiple SubAgent calls in one turn run concurrently. Use this to parallelize independent investigations.\n- **Failure**: if the child fails (status=failed), the result text may be partial or empty. Handle gracefully — do not retry automatically.\n- **Fork mode**: pass `fork=true` to inherit parent session context (conversation history, plan, skills). Use when the child needs your working context.",
            None,
        ));
        sections.push(wrap_section(
            "todo-guidance",
            "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.",
            None,
        ));
        let plan_file_display = if self.plan_file.as_os_str().is_empty() {
            "<not set>".to_string()
        } else {
            self.plan_file.display().to_string()
        };
        let plan_draft_file_display = if self.plan_draft_file.as_os_str().is_empty() {
            "<not set>".to_string()
        } else {
            self.plan_draft_file.display().to_string()
        };
        let plan_lifecycle_guidance = format!(
            "- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n\
             - **Why draft first?** Writing to PLAN_FILE immediately invalidates the system prompt cache. Use PLAN_DRAFT_FILE for all drafting iterations to avoid this cost.\n\
             - **Step-by-step**:\n\
               1. Write draft to PLAN_DRAFT_FILE using Edit (markdown: goal, analysis, steps, notes)\n\
               2. Ask user to confirm the plan before execution\n\
               3. **Draft revision loop**: while PLAN_DRAFT_FILE is non-empty and user has NOT said \"confirmed\"/\"ok\"/\"go ahead\" (or equivalent), ANY user reply (questions, suggestions, objections, or implicit change requests) MUST be treated as revision feedback. ALWAYS update PLAN_DRAFT_FILE to reflect the discussion, then ask for confirmation again. NEVER just answer without updating the draft.\n\
               4. If user explicitly cancels/abandons: use Bash to clear PLAN_DRAFT_FILE (e.g. `: > PLAN_DRAFT_FILE`). Do NOT use PlanClear.\n\
               5. When user confirms: call PlanConfirm tool — this moves draft → PLAN_FILE and triggers a context compaction (cache invalidation is already happening, so we reclaim space at the same time).\n\
               6. After PlanConfirm, create TodoWrite checklist based on plan\n\
               7. Execute tasks following todo checklist (update progress in TodoWrite)\n\
               8. When all tasks complete, use PlanClear tool to clear plan and compact context\n\
             - **Plan vs Todo separation**:\n\
               - PLAN_FILE: locked-in plan (only written via PlanConfirm)\n\
               - PLAN_DRAFT_FILE: working draft during planning (safe to edit freely)\n\
               - TodoWrite: execution checklist for real-time progress tracking\n\
               - Do NOT mix todo checkboxes into plan files\n\
             - **Files**:\n\
               - PLAN_DRAFT_FILE: {}\n\
               - PLAN_FILE: {}",
            plan_draft_file_display, plan_file_display
        );
        sections.push(wrap_section(
            "plan-lifecycle-guidance",
            &plan_lifecycle_guidance,
            None,
        ));
        if let Some(s) = self.build_instruction_files_section()? {
            sections.push(wrap_section("instruction-files", &s, None));
        }
        if let Some(s) = self.build_skill_index_section()? {
            sections.push(wrap_section("skill-index", &s, None));
        }
        if let Some(s) = self.build_selected_skills_section()? {
            sections.push(wrap_section("selected-skills", &s, None));
        }
        if let Some(s) = read_optional_file(&self.plan_file)? {
            sections.push(wrap_section(
                "current-plan",
                &s,
                Some(&self.plan_file.display().to_string()),
            ));
        }
        if let Some(s) = read_optional_file(&self.summary_file)? {
            sections.push(wrap_section("context-snapshot", &s, None));
        }
        let output_language = if locale.starts_with("zh") {
            "再次强调：必须使用中文进行所有输出，包括你的思考过程（Chain of Thought/推理/thinking）！严禁在思考或回答中出现任何英文内容！".to_string()
        } else {
            format!(
                "MUST use \"{}\" for all output, including your Chain of Thought/reasoning/thinking! Never mix languages! Code, commands, and file content remain as-is.",
                locale
            )
        };
        sections.push(wrap_section("output-language", &output_language, None));
        Ok(sections.join("\n"))
    }

    fn build_instruction_files_section(&self) -> Result<Option<String>> {
        let global_file = find_instruction_file_in_dir(&self.home.join(".bash-agent"));
        let project_file = find_instruction_file_in_dir(&self.cwd);
        let mut out = Vec::new();
        if let Some(f) = global_file {
            out.push(wrap_section(
                "instruction-file",
                &fs::read_to_string(f)?,
                Some("global"),
            ));
        }
        if let Some(f) = project_file {
            out.push(wrap_section(
                "instruction-file",
                &fs::read_to_string(f)?,
                Some("project"),
            ));
        }
        if out.is_empty() {
            Ok(None)
        } else {
            Ok(Some(out.join("\n")))
        }
    }

    fn build_skill_index_section(&self) -> Result<Option<String>> {
        let bases = find_skill_base_dirs(&self.cwd, &self.home);
        if bases.is_empty() {
            return Ok(None);
        }
        let mut seen = HashSet::new();
        let mut lines = Vec::new();
        for base in bases {
            for entry in fs::read_dir(base)? {
                let entry = entry?;
                if !entry.file_type()?.is_dir() {
                    continue;
                }
                let name = entry.file_name().to_string_lossy().to_string();
                if seen.contains(&name) {
                    continue;
                }
                let skill_file = entry.path().join("SKILL.md");
                let Ok(data) = fs::read_to_string(skill_file) else {
                    continue;
                };
                seen.insert(name.clone());
                let summary = extract_skill_summary(&data);
                if summary.is_empty() {
                    lines.push(format!("- {name}"));
                } else {
                    lines.push(format!("- {name}: {summary}"));
                }
            }
        }
        if lines.is_empty() {
            Ok(None)
        } else {
            Ok(Some(lines.join("\n")))
        }
    }

    fn build_selected_skills_section(&self) -> Result<Option<String>> {
        if self.skills.is_empty() {
            return Ok(None);
        }
        let bases = find_skill_base_dirs(&self.cwd, &self.home);
        if bases.is_empty() {
            return Ok(None);
        }
        let mut sections = Vec::new();
        for skill in &self.skills {
            let Some(skill_file) = find_skill_file(&bases, skill) else {
                return Err(anyhow::anyhow!(
                    "skill not found: {skill} (expected .claude/skills/{skill}/SKILL.md or ~/.claude/skills/{skill}/SKILL.md)"
                ));
            };
            let content = fs::read_to_string(&skill_file)?;
            let full = format!(
                "Base directory for this skill: {}\n\n{}",
                skill_file.parent().unwrap_or(Path::new("")).display(),
                content.replace(
                    "${BASH_AGENT_SKILL_DIR}",
                    &skill_file
                        .parent()
                        .unwrap_or(Path::new(""))
                        .display()
                        .to_string()
                )
            );
            sections.push(wrap_section("skill", &full, Some(skill)));
        }
        Ok(Some(sections.join("\n")))
    }
}

fn wrap_section(tag: &str, content: &str, name: Option<&str>) -> String {
    if content.trim().is_empty() {
        return String::new();
    }
    match name {
        Some(n) => format!("<{tag} name=\"{}\">\n{}\n</{tag}>", escape_attr(n), content),
        None => format!("<{tag}>\n{}\n</{tag}>", content),
    }
}

fn escape_attr(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn read_optional_file(path: &Path) -> Result<Option<String>> {
    if !path.exists() {
        return Ok(None);
    }
    let s = fs::read_to_string(path)?;
    if s.trim().is_empty() {
        Ok(None)
    } else {
        Ok(Some(s))
    }
}

fn find_skill_base_dirs(cwd: &Path, home: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let project = cwd.join(".claude/skills");
    if project.is_dir() {
        out.push(project);
    }
    let project_dev = cwd.join("skills");
    if project_dev.is_dir() {
        out.push(project_dev);
    }
    let global = home.join(".claude/skills");
    if global.is_dir() {
        out.push(global);
    }
    out
}

fn find_skill_file(bases: &[PathBuf], skill: &str) -> Option<PathBuf> {
    for base in bases {
        let path = base.join(skill).join("SKILL.md");
        if path.is_file() {
            return Some(path);
        }
    }
    None
}

pub fn resolve_skill_file(cwd: &Path, home: &Path, skill: &str) -> Option<PathBuf> {
    find_skill_file(&find_skill_base_dirs(cwd, home), skill)
}

fn find_instruction_file_in_dir(dir: &Path) -> Option<PathBuf> {
    let candidates = [
        dir.join("AGENTS.md"),
        dir.join("AGENT.md"),
        dir.join("CLAUDE.md"),
        dir.join(".claude/CLAUDE.md"),
    ];
    candidates.into_iter().find(|p| p.is_file())
}

fn extract_skill_summary(content: &str) -> String {
    let mut fallback = String::new();
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with("description:") {
            let desc = trimmed.trim_start_matches("description:").trim();
            // Remove quotes if present
            let desc = if desc.len() >= 2 {
                let first_char = desc.chars().next().unwrap();
                if first_char == '"' {
                    desc.trim_start_matches('"').trim_end_matches('"')
                } else if first_char == '\'' {
                    desc.trim_start_matches('\'').trim_end_matches('\'')
                } else {
                    desc
                }
            } else {
                desc
            };
            return desc.to_string();
        }
        if fallback.is_empty()
            && !trimmed.starts_with('#')
            && trimmed != "---"
            && !trimmed.starts_with("```")
        {
            fallback = trimmed.to_string();
        }
    }
    fallback
}
