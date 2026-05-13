use anyhow::{Result, bail};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Paths {
    pub base_dir: PathBuf,
    pub session_dir: PathBuf,
    pub conversation: PathBuf,
    pub events: PathBuf,
    pub summary: PathBuf,
    pub plan: PathBuf,
    pub plan_draft: PathBuf,
    pub stats: PathBuf,
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
    let session_dir = project_dir.join(session_id);
    Paths {
        base_dir: project_dir,
        session_dir: session_dir.clone(),
        conversation: session_dir.join("conversation.jsonl"),
        events: session_dir.join("events.jsonl"),
        summary: session_dir.join("summary.txt"),
        plan: session_dir.join("plan.md"),
        plan_draft: session_dir.join("plan.draft"),
        stats: session_dir.join("stats.json"),
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
        if !entry.path().is_dir() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        let mt = session_activity_mod_time(&entry.path())?;
        match &newest {
            Some((ts, _)) if *ts >= mt => {}
            _ => newest = Some((mt, name)),
        }
    }
    if let Some((_, sid)) = newest {
        Ok(sid)
    } else {
        bail!("no sessions found")
    }
}

fn session_activity_mod_time(session_dir: &Path) -> Result<std::time::SystemTime> {
    let events = session_dir.join("events.jsonl");
    if let Ok(meta) = fs::metadata(&events) {
        return Ok(meta.modified()?);
    }
    Ok(fs::metadata(session_dir)?.modified()?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread::sleep;
    use std::time::Duration;

    fn unique_path(prefix: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        path.push(format!("{prefix}-{stamp}-{}", std::process::id()));
        path
    }

    #[test]
    fn continue_session_uses_events_mtime() {
        let home = unique_path("bash-agent-home");
        let cwd = unique_path("bash-agent-cwd");
        fs::create_dir_all(&cwd).unwrap();

        let project_dir = home.join(".bash-agent/projects").join(project_key(&cwd));
        let session_a = project_dir.join("session-a");
        let session_b = project_dir.join("session-b");
        fs::create_dir_all(&session_a).unwrap();
        fs::create_dir_all(&session_b).unwrap();
        fs::write(session_a.join("events.jsonl"), "{}\n").unwrap();
        sleep(Duration::from_millis(20));
        fs::write(session_b.join("events.jsonl"), "{}\n").unwrap();
        sleep(Duration::from_millis(20));
        fs::write(session_a.join("events.jsonl"), "{}\n{}\n").unwrap();

        let got = continue_session(&home, &cwd).unwrap();
        assert_eq!(got, "session-a");
    }
}
