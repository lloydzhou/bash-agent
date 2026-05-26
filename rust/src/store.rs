use anyhow::Result;
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};

    use crate::types::Message;
    use crate::util;

    /// 文件系统存储实现
    pub struct FileStore {
        base_dir: PathBuf,
    }

    impl FileStore {
        pub fn new(cwd: &str, session_id: &str) -> Result<Self> {
            let project_path = util::path_to_project_id(cwd);
            let home_dir = std::env::var_os("BASH_AGENT_HOME")
                .or_else(|| std::env::var_os("HOME"))
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."));
            let base_dir = home_dir
                .join(".bash-agent/projects")
                .join(&project_path)
                .join(session_id);

            Ok(Self {
                base_dir,
            })
        }

        pub fn get_dir(&self) -> &PathBuf {
            &self.base_dir
        }

        pub fn init(&self) -> Result<()> {
            fs::create_dir_all(&self.base_dir)?;
            Ok(())
        }

        pub fn add_message(&self, message: &Message) -> Result<()> {
            store_jsonl_append(&self.base_dir.join("conversation.jsonl"), &serde_json::to_value(message)?)
        }

        pub fn get_messages(&self) -> Result<Vec<Message>> {
            store_jsonl_read_messages(&self.base_dir.join("conversation.jsonl"))
        }

        pub fn stats_inc(&self, key: &str, value: i64) -> Result<()> {
            store_stats_update(&self.base_dir.join("stats.json"), |stats| {
                let current = stats.get(key).and_then(|v| v.as_i64()).unwrap_or(0);
                stats[key] = serde_json::json!(current + value);
            })
        }

        pub fn stats_set(&self, key: &str, value: i64) -> Result<()> {
            store_stats_update(&self.base_dir.join("stats.json"), |stats| {
                stats[key] = serde_json::json!(value);
            })
        }

        pub fn stats_get(&self, key: &str) -> Result<i64> {
            let stats = store_stats_read(&self.base_dir.join("stats.json"))?;
            Ok(stats.get(key).and_then(|v| v.as_i64()).unwrap_or(0))
        }

        pub fn set_summary(&self, summary: &str) -> Result<()> {
            store_text_write(&self.base_dir.join("summary.txt"), summary)
        }

        pub fn get_summary(&self) -> Result<String> {
            store_text_read(&self.base_dir.join("summary.txt"))
        }

        pub fn set_plan(&self, plan: &str) -> Result<()> {
            store_text_write(&self.base_dir.join("plan.md"), plan)
        }

        pub fn get_plan(&self) -> Result<String> {
            store_text_read(&self.base_dir.join("plan.md"))
        }

        pub fn set_plan_draft(&self, draft: &str) -> Result<()> {
            store_text_write(&self.base_dir.join("plan.draft"), draft)
        }

        pub fn get_plan_draft(&self) -> Result<String> {
            store_text_read(&self.base_dir.join("plan.draft"))
        }

        pub fn append_event(&self, event: &str) -> Result<()> {
            store_text_append(&self.base_dir.join("events.jsonl"), event)
        }
    }

    impl crate::traits::SessionStore for FileStore {
        fn init(&self) -> Result<()> {
            FileStore::init(self)
        }

        fn add_user(&self, message: &Message) -> Result<()> {
            self.add_message(message)
        }

        fn add_assistant(&self, message: &Message) -> Result<()> {
            self.add_message(message)
        }

        fn add_tool_results(&self, message: &Message) -> Result<()> {
            self.add_message(message)
        }

        fn get_messages(&self) -> Result<Vec<Message>> {
            FileStore::get_messages(self)
        }

        fn append_event(&self, event: &str) -> Result<()> {
            self.append_event(event)
        }
    }

    pub fn store_init(store: &FileStore) -> Result<()> {
        store.init()
    }

    pub fn store_add_user(store: &FileStore, message: &Message) -> Result<()> {
        store.add_message(message)
    }

    pub fn store_add_assistant(store: &FileStore, message: &Message) -> Result<()> {
        store.add_message(message)
    }

    pub fn store_add_tool_results(store: &FileStore, message: &Message) -> Result<()> {
        store.add_message(message)
    }

    pub fn store_get_messages(store: &FileStore) -> Result<Vec<Message>> {
        store.get_messages()
    }

    pub fn store_append_event(store: &FileStore, event: &str) -> Result<()> {
        store.append_event(event)
    }

    pub fn store_stats_inc(store: &FileStore, key: &str, value: i64) -> Result<()> {
        store.stats_inc(key, value)
    }

    pub fn store_stats_set(store: &FileStore, key: &str, value: i64) -> Result<()> {
        store.stats_set(key, value)
    }

    pub fn store_stats_get(store: &FileStore, key: &str) -> Result<i64> {
        store.stats_get(key)
    }

    pub fn store_stats_read(stats_path: &Path) -> Result<serde_json::Map<String, Value>> {
        let mut stats = default_stats();
        if let Ok(data) = fs::read_to_string(stats_path) {
            if let Ok(parsed) = serde_json::from_str::<serde_json::Map<String, Value>>(&data) {
                for (k, v) in parsed {
                    stats.insert(k, v);
                }
            }
        }
        Ok(stats)
    }

    pub fn store_stats_write(stats_path: &Path, stats: &serde_json::Map<String, Value>) -> Result<()> {
        fs::write(stats_path, serde_json::to_string(stats)? + "\n")?;
        Ok(())
    }

    pub fn store_stats_update<F>(stats_path: &Path, update: F) -> Result<()>
    where
        F: FnOnce(&mut serde_json::Map<String, Value>),
    {
        let mut stats = store_stats_read(stats_path)?;
        update(&mut stats);
        store_stats_write(stats_path, &stats)
    }

    pub fn store_set_summary(store: &FileStore, summary: &str) -> Result<()> {
        store.set_summary(summary)
    }

    pub fn store_get_summary(store: &FileStore) -> Result<String> {
        store.get_summary()
    }

    pub fn store_set_plan(store: &FileStore, plan: &str) -> Result<()> {
        store.set_plan(plan)
    }

    pub fn store_get_plan(store: &FileStore) -> Result<String> {
        store.get_plan()
    }

    pub fn store_set_plan_draft(store: &FileStore, draft: &str) -> Result<()> {
        store.set_plan_draft(draft)
    }

    pub fn store_get_plan_draft(store: &FileStore) -> Result<String> {
        store.get_plan_draft()
    }

    pub fn store_get_dir(store: &FileStore) -> &PathBuf {
        store.get_dir()
    }

    pub fn store_get_latest_dir(home: &std::path::Path, cwd: &std::path::Path) -> Result<PathBuf> {
        let session_id = continue_session(home, cwd)?;
        Ok(paths_for(home, cwd, &session_id).session_dir)
    }

    pub fn store_resolve_continue(home: &std::path::Path, cwd: &std::path::Path) -> Result<String> {
        continue_session(home, cwd)
    }

    pub fn store_session_init(paths: &Paths, new_session: bool) -> Result<()> {
        fs::create_dir_all(&paths.base_dir)?;
        fs::create_dir_all(&paths.session_dir)?;
        for path in [
            &paths.conversation,
            &paths.events,
            &paths.summary,
            &paths.plan,
            &paths.plan_draft,
        ] {
            if !path.exists() {
                fs::File::create(path)?;
            }
        }
        if new_session {
            store_stats_write(&paths.stats, &default_stats())?;
        }
        Ok(())
    }

    pub fn store_session_fork(parent: &Paths, child: &Paths) -> Result<()> {
        let files_to_copy: [(&Path, &Path); 3] = [
            (&parent.conversation, &child.conversation),
            (&parent.summary, &child.summary),
            (&parent.plan, &child.plan),
        ];
        for (src, dst) in files_to_copy {
            if src.exists() {
                let _ = fs::copy(src, dst);
            }
        }
        Ok(())
    }

    #[derive(Debug, Clone)]
    pub struct SessionListRow {
        pub name: String,
        pub modified: std::time::SystemTime,
        pub summary: String,
    }

    pub fn store_event_append_json(paths: &Paths, value: &Value) -> Result<()> {
        store_jsonl_append(&paths.events, value)
    }

    pub fn store_event_lines(paths: &Paths) -> Result<Vec<Value>> {
        store_jsonl_read_values(&paths.events)
    }

    pub fn store_summary_set(paths: &Paths, summary: &str) -> Result<()> {
        store_text_write(&paths.summary, &format!("{summary}\n"))
    }

    pub fn store_summary_get(paths: &Paths) -> Result<String> {
        store_text_read(&paths.summary)
    }

    pub fn store_plan_set(paths: &Paths, plan: &str) -> Result<()> {
        store_text_write(&paths.plan, plan)
    }

    pub fn store_plan_clear(paths: &Paths) -> Result<()> {
        store_text_write(&paths.plan, "")
    }

    pub fn store_plan_get(paths: &Paths) -> Result<String> {
        store_text_read(&paths.plan)
    }

    pub fn store_plan_draft_set(paths: &Paths, draft: &str) -> Result<()> {
        store_text_write(&paths.plan_draft, draft)
    }

    pub fn store_plan_draft_get(paths: &Paths) -> Result<String> {
        store_text_read(&paths.plan_draft)
    }

    pub fn store_plan_draft_clear(paths: &Paths) -> Result<()> {
        store_text_write(&paths.plan_draft, "")
    }

    pub fn store_plan_draft_has(paths: &Paths) -> bool {
        paths.plan_draft.exists()
    }

    pub fn store_conv_ensure(path: &Path) -> Result<()> {
        store_touch(path)
    }

    pub fn store_conv_add_json(path: &Path, value: &Value) -> Result<()> {
        store_jsonl_append(path, value)
    }

    pub fn store_conv_lines(path: &Path) -> Result<Vec<Value>> {
        store_jsonl_read_values(path)
    }

    pub fn store_conv_total_bytes(path: &Path) -> Result<usize> {
        Ok(fs::read(path)?.len())
    }

    pub fn store_conv_total_lines(path: &Path) -> Result<usize> {
        Ok(store_conv_lines(path)?.len())
    }

    pub fn store_conv_count_user_inputs(path: &Path) -> Result<usize> {
        let events_path = path.to_string_lossy().replace("conversation.jsonl", "events.jsonl");
        let data = fs::read_to_string(&events_path)?;
        Ok(data
            .lines()
            .filter(|line| line.contains("\"type\":\"user_input\""))
            .count())
    }

    pub fn store_conv_trim_keep_last(path: &Path, keep_lines: usize) -> Result<()> {
        let data = fs::read_to_string(path)?;
        let raw_lines: Vec<&str> = data.lines().filter(|l| !l.trim().is_empty()).collect();
        if keep_lines >= raw_lines.len() {
            return Ok(());
        }
        let kept = &raw_lines[raw_lines.len() - keep_lines..];
        let mut out = String::new();
        for line in kept {
            out.push_str(line);
            out.push('\n');
        }
        fs::write(path, out)?;
        Ok(())
    }

    pub fn store_conv_keep_line_count(path: &Path, target_bytes: usize) -> Result<usize> {
        let lines = store_conv_lines(path)?;
        if lines.is_empty() {
            return Ok(0);
        }
        let sizes: Vec<usize> = lines
            .iter()
            .map(|v| serde_json::to_string(v).map(|s| s.len() + 1))
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let turn_start: Vec<bool> = lines
            .iter()
            .map(|v| {
                v.get("role").and_then(Value::as_str) == Some("user")
                    && v.get("content").is_some_and(Value::is_string)
            })
            .collect();

        let mut keep = 0usize;
        let mut bytes = 0usize;
        for i in (0..lines.len()).rev() {
            if keep > 0 && bytes + sizes[i] > target_bytes {
                break;
            }
            bytes += sizes[i];
            keep += 1;
        }
        if keep == 0 {
            keep = 1;
        }
        let mut start = lines.len() - keep;
        let mut adjusted = start;
        while adjusted < lines.len() && !turn_start[adjusted] {
            adjusted += 1;
        }
        if adjusted < lines.len() {
            start = adjusted;
        } else {
            while start > 0 && !turn_start[start] {
                start -= 1;
            }
        }
        Ok(lines.len() - start)
    }

    pub fn store_list_sessions(home: &Path, cwd: &Path) -> Result<Vec<SessionListRow>> {
        let dir = home.join(".bash-agent/projects").join(project_key(cwd));
        let entries = match fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(_) => return Ok(Vec::new()),
        };
        let mut rows = Vec::new();
        for entry in entries {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let session_name = entry.file_name().to_string_lossy().to_string();
            let summary_path = path.join("summary.txt");
            let mut summary = String::new();
            if let Ok(data) = fs::read_to_string(&summary_path) {
                for line in data.lines() {
                    let trimmed = line.trim();
                    if !trimmed.is_empty() {
                        summary = trimmed.to_string();
                        break;
                    }
                }
            }
            rows.push(SessionListRow {
                name: session_name,
                modified: entry.metadata()?.modified().unwrap_or(std::time::UNIX_EPOCH),
                summary,
            });
        }
        rows.sort_by(|a, b| b.modified.cmp(&a.modified));
        Ok(rows)
    }

    fn default_stats() -> serde_json::Map<String, Value> {
        let mut stats = serde_json::Map::new();
        stats.insert("current_turn_count".to_string(), Value::Number(0.into()));
        stats.insert("agent_request_count".to_string(), Value::Number(0.into()));
        stats.insert("compact_request_count".to_string(), Value::Number(0.into()));
        stats.insert("sub_agent_request_count".to_string(), Value::Number(0.into()));
        stats.insert("total_input_tokens".to_string(), Value::Number(0.into()));
        stats.insert("total_output_tokens".to_string(), Value::Number(0.into()));
        stats.insert("total_cache_read_tokens".to_string(), Value::Number(0.into()));
        stats.insert("total_cache_creation_tokens".to_string(), Value::Number(0.into()));
        stats.insert("current_context_tokens".to_string(), Value::Number(0.into()));
        stats.insert("last_updated".to_string(), Value::String(String::new()));
        stats
    }

    fn store_touch(path: &Path) -> Result<()> {
        if !path.exists() {
            fs::File::create(path)?;
        }
        Ok(())
    }

    fn store_text_write(path: &Path, text: &str) -> Result<()> {
        fs::write(path, text)?;
        Ok(())
    }

    fn store_text_read(path: &Path) -> Result<String> {
        if !path.exists() {
            return Ok(String::new());
        }
        Ok(fs::read_to_string(path)?)
    }

    fn store_text_append(path: &Path, line: &str) -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        use std::io::Write;
        writeln!(file, "{}", line)?;
        Ok(())
    }

    fn store_jsonl_append(path: &Path, value: &Value) -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        use std::io::Write;
        writeln!(file, "{}", serde_json::to_string(value)?)?;
        Ok(())
    }

    fn store_jsonl_read_values(path: &Path) -> Result<Vec<Value>> {
        if !path.exists() {
            return Ok(Vec::new());
        }
        let data = fs::read_to_string(path)?;
        Ok(data
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect())
    }

    fn store_jsonl_read_messages(path: &Path) -> Result<Vec<Message>> {
        if !path.exists() {
            return Ok(Vec::new());
        }
        let content = fs::read_to_string(path)?;
        let messages: Vec<Message> = content
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        Ok(messages)
    }

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

    pub fn project_key(cwd: &std::path::Path) -> String {
        let s = cwd.to_string_lossy();
        let stripped = s.strip_prefix(std::path::MAIN_SEPARATOR).unwrap_or(&s);
        let mut clean = String::new();
        let mut prev_dash = false;
        for ch in stripped.chars() {
            let mapped = if ch == std::path::MAIN_SEPARATOR {
                '-'
            } else if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-' {
                ch
            } else {
                '-'
            };
            if mapped == '-' && prev_dash {
                continue;
            }
            clean.push(mapped);
            prev_dash = mapped == '-';
        }
        format!("-{}", clean.trim_matches('-'))
    }

    pub fn paths_for(home: &std::path::Path, cwd: &std::path::Path, session_id: &str) -> Paths {
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

    pub fn ensure_dir(path: &std::path::Path) -> Result<()> {
        fs::create_dir_all(path)?;
        Ok(())
    }

    pub fn continue_session(home: &std::path::Path, cwd: &std::path::Path) -> Result<String> {
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
            anyhow::bail!("no sessions found")
        }
    }

    fn session_activity_mod_time(session_dir: &std::path::Path) -> Result<std::time::SystemTime> {
        let events = session_dir.join("events.jsonl");
        if let Ok(meta) = fs::metadata(&events) {
            return Ok(meta.modified()?);
        }
        Ok(fs::metadata(session_dir)?.modified()?)
    }
