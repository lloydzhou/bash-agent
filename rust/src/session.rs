use anyhow::{Result, bail};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Paths {
    pub base_dir: PathBuf,
    pub conversation: PathBuf,
    pub events: PathBuf,
    pub summary: PathBuf,
    pub todo: PathBuf,
    pub plan: PathBuf,
}

pub fn project_key(cwd: &Path) -> String {
    let s = cwd.to_string_lossy();
    // Strip leading separator, matching the bash version: cwd="${cwd#/}"
    let stripped = s.strip_prefix(std::path::MAIN_SEPARATOR).unwrap_or(&s);
    let mut clean = stripped.replace(std::path::MAIN_SEPARATOR, "-");
    while clean.contains("--") {
        clean = clean.replace("--", "-");
    }
    let mut out = String::from("-");
    for ch in clean.chars() {
        if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-' {
            out.push(ch);
        } else {
            out.push('-');
        }
    }
    out.trim_end_matches('-').to_string()
}

pub fn paths_for(home: &Path, cwd: &Path, session_id: &str) -> Paths {
    let project_dir = home.join(".bash-agent/projects").join(project_key(cwd));
    let base = project_dir.join(session_id);
    Paths {
        base_dir: project_dir,
        conversation: base.with_extension("jsonl"),
        events: base.with_extension("events.jsonl"),
        summary: base.with_extension("summary.txt"),
        todo: base.with_extension("todo.md"),
        plan: base.with_extension("plan.md"),
    }
}

pub fn ensure_dir(path: &Path) -> Result<()> {
    fs::create_dir_all(path)?;
    Ok(())
}

pub fn continue_session(home: &Path, cwd: &Path) -> Result<String> {
    let dir = home.join(".bash-agent/projects").join(project_key(cwd));
    let mut newest: Option<(std::time::SystemTime, String)> = None;
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.ends_with(".jsonl") || name.ends_with(".events.jsonl") {
            continue;
        }
        let mt = entry.metadata()?.modified()?;
        let sid = name.trim_end_matches(".jsonl").to_string();
        match &newest {
            Some((ts, _)) if *ts >= mt => {}
            _ => newest = Some((mt, sid)),
        }
    }
    if let Some((_, sid)) = newest {
        Ok(sid)
    } else {
        bail!("no sessions found")
    }
}
