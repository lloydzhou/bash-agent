use anyhow::Result;
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

pub struct Builder {
    pub cwd: PathBuf,
    pub home: PathBuf,
    pub skills: Vec<String>,
    pub summary_file: PathBuf,
    pub todo_file: PathBuf,
    pub plan_file: PathBuf,
}

impl Builder {
    pub fn build_system_prompt(&self) -> Result<String> {
        let mut sections = Vec::new();
        sections.push(wrap_section(
            "agent-identity",
            "You are bash-agent, a lightweight coding agent that works in a terminal.",
            None,
        ));
        let locale_raw = ["LC_ALL", "LC_MESSAGES", "LANG"]
            .iter()
            .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
            .unwrap_or_else(|| "en_US".to_string());
        // Strip encoding suffix (e.g., zh_CN.UTF-8 -> zh_CN)
        let locale = locale_raw.split('.').next().unwrap_or(&locale_raw).to_string();
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "unknown".to_string());
        let platform = std::env::consts::OS;
        let environment = format!("lang: {}\npwd: {}\nhome: {}\nplatform: {}\nshell: {}\nlocale: MUST USE \"{}\" FOR ALL OUTPUT, INCLUDING THINKING/REASONING!!",
            locale,
            self.cwd.display(),
            self.home.display(),
            platform,
            shell,
            locale);
        sections.push(wrap_section("environment", &environment, None));
        let rules_str = format!("- MUST use \"{}\" for all output, including thinking/reasoning! Never mix languages! Code, commands, and file content remain as-is.\n- Be concise and concrete. No pleasantries, no explanations unless asked. Raw results only.\n- Prefer safe, exact edits.\n- Report failures clearly.", locale);
        sections.push(wrap_section("rules", &rules_str, None));
        sections.push(wrap_section(
            "using-your-tools",
            "- Use Read for a single file. If you need multiple files, call Read multiple times.\n- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n- Use Glob and Grep for one pattern at a time.\n- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n- Use multiple tool calls in one response when they are independent.\n- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n- For skills, first check the skill-index section, then use Skill(name) for the matching skill.",
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
        let plan_lifecycle_guidance = format!(
            "- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n\
             - **Step-by-step**:\n\
               1. Write plan to PLAN_FILE using Edit (markdown: goal, analysis, steps, notes)\n\
               2. Ask user to confirm the plan before execution\n\
               3. After user confirms, create TodoWrite checklist based on plan\n\
               4. Execute tasks following todo checklist (update progress in TodoWrite)\n\
               5. When all tasks complete, clear plan: Bash \": > PLAN_FILE\"\n\
             - **Plan vs Todo separation**:\n\
               - PLAN_FILE: planning document for analysis and strategy\n\
               - TodoWrite: execution checklist for real-time progress tracking\n\
               - Do NOT mix todo checkboxes into plan file\n\
             - **PLAN_FILE**: {}",
            plan_file_display
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
            sections.push(wrap_section("context-summary", &s, None));
        }
        if let Some(s) = read_optional_file(&self.todo_file)? {
            sections.push(wrap_section("current-todo", &s, None));
        }
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
