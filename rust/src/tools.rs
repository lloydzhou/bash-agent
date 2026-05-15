use crate::config::Config;
    use crate::prompt;
    use anyhow::{Result, anyhow, bail};
    use once_cell::sync::Lazy;
    use regex::Regex;
    use serde::Deserialize;
    use serde_json::Value;
    use std::fs;
    use std::io::{BufRead, BufReader, Read as IoRead};
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::{Duration, Instant};

    static RE_FIND_DELETE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"(?i)(^|[;&|])\s*find\b.*\bdelete\b").expect("regex"));
    static RE_FORK_BOMB: Lazy<Regex> =
        Lazy::new(|| Regex::new(r":\(\)\{:\|:&\};:").expect("regex"));
    static RE_BLOCK_DEVICE_WRITE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"(?i)(^|\s)(of=|>|1>|>>|1>>)\s*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)(\s|$)")
            .expect("regex")
    });

    pub struct Runner {
        pub config: Config,
        pub cwd: std::path::PathBuf,
        pub home: std::path::PathBuf,
    }

    #[derive(Debug, Clone, Deserialize)]
    pub struct TodoArg {
        pub content: String,
        pub status: String,
    }

    impl Runner {
        pub fn dispatch(&self, name: &str, input: &Value) -> Result<String> {
            match name {
                "Read" => {
                    #[derive(Deserialize)]
                    struct Args {
                        path: String,
                        #[serde(default)]
                        offset: Option<usize>,
                        #[serde(default)]
                        limit: Option<usize>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.read(&args.path, args.offset, args.limit)
                }
                "Write" => {
                    #[derive(Deserialize)]
                    struct Args {
                        path: String,
                        content: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.write(&args.path, &args.content)
                }
                "Edit" => {
                    #[derive(Deserialize)]
                    struct Args {
                        path: String,
                        old_string: String,
                        new_string: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.edit(&args.path, &args.old_string, &args.new_string)
                }
                "Bash" => {
                    #[derive(Deserialize)]
                    struct Args {
                        command: String,
                        #[serde(default)]
                        timeout: Option<u64>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.bash(&args.command, args.timeout)
                }
                "Glob" => {
                    #[derive(Deserialize)]
                    struct Args {
                        pattern: String,
                        #[serde(default)]
                        path: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.glob(
                        &args.pattern,
                        if args.path.is_empty() {
                            "."
                        } else {
                            &args.path
                        },
                    )
                }
                "Grep" => {
                    #[derive(Deserialize)]
                    struct Args {
                        pattern: String,
                        #[serde(default)]
                        path: String,
                        #[serde(default)]
                        glob: String,
                        #[serde(default)]
                        context: Option<usize>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.grep(
                        &args.pattern,
                        if args.path.is_empty() {
                            "."
                        } else {
                            &args.path
                        },
                        &args.glob,
                        args.context,
                    )
                }
                "TodoWrite" => {
                    #[derive(Deserialize)]
                    struct Args {
                        todos: Vec<TodoArg>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.todo_write(args.todos)
                }
                "Skill" => {
                    #[derive(Deserialize)]
                    struct Args {
                        name: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.tool_skill(&args.name)
                }
                "WebSearch" => {
                    #[derive(Deserialize)]
                    struct Args {
                        query: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.web_search(&args.query)
                }
                "WebFetch" => {
                    #[derive(Deserialize)]
                    struct Args {
                        url: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.web_fetch(&args.url)
                }
                _ => bail!("unknown tool: {name}"),
            }
        }

        fn read(&self, path: &str, offset: Option<usize>, limit: Option<usize>) -> Result<String> {
            if path.is_empty() {
                bail!("Error: no path provided");
            }
            let data = fs::read_to_string(path)
                .map_err(|_| anyhow!("Error: file not found or unreadable: {path}"))?;
            if offset.is_none() && limit.is_none() {
                return Ok(data);
            }

            let mut lines: Vec<&str> = data.split('\n').collect();
            if !lines.is_empty() && lines.last().map(|l| l.is_empty()).unwrap_or(false) {
                lines.pop();
            }
            let total_lines = lines.len();

            let start = match offset {
                Some(o) if o > 1 => {
                    if o > total_lines {
                        bail!(
                            "Error: offset {} exceeds total lines {} in {}",
                            o,
                            total_lines,
                            path
                        );
                    }
                    o - 1
                }
                _ => 0,
            };

            let end = match limit {
                Some(l) if l > 0 => (start + l).min(total_lines),
                _ => total_lines,
            };

            let selected = &lines[start..end];
            Ok(selected.join("\n"))
        }

        fn write(&self, path: &str, content: &str) -> Result<String> {
            if path.is_empty() {
                bail!("Error: no path provided");
            }
            if content.len() > self.config.file_write_max_bytes {
                bail!(
                    "Error: content too large for write_file ({} bytes > {} bytes)",
                    content.len(),
                    self.config.file_write_max_bytes
                );
            }
            if let Some(dir) = Path::new(path).parent() {
                fs::create_dir_all(dir)?;
            }
            fs::write(path, content)?;
            let sz = fs::metadata(path)?.len();
            Ok(format!("OK: wrote {sz} bytes to {path}"))
        }

        fn edit(&self, path: &str, old_s: &str, new_s: &str) -> Result<String> {
            if path.is_empty() {
                bail!("Error: no path provided");
            }
            if old_s.is_empty() {
                bail!("Error: empty old_string");
            }
            let content =
                fs::read_to_string(path).map_err(|_| anyhow!("Error: file not found: {path}"))?;
            if content.len() > self.config.file_write_max_bytes {
                bail!(
                    "Error: file too large for edit_file ({} bytes > {} bytes)",
                    content.len(),
                    self.config.file_write_max_bytes
                );
            }
            if !content.contains(old_s) {
                bail!(
                    "Error: old_string not found in {path}. Hint: use Grep to locate the target lines, then Read the relevant portion (with offset/limit) to copy the exact text before retrying Edit."
                );
            }
            let updated = content.replacen(old_s, new_s, 1);
            if updated.is_empty() {
                bail!("Error: edit produced empty result, reverted");
            }
            let diff = unified_diff_color(path, &content, &updated)?;
            fs::write(path, updated)?;
            if diff.is_empty() {
                Ok(format!("Edit({path}) [no changes]"))
            } else {
                let (added, removed) = count_diff_lines(&diff);
                let summary = format!("Edit({path}) [+{added} -{removed} lines]");
                Ok(format!("{summary}\n{diff}\n"))
            }
        }

        fn bash(&self, command: &str, timeout_secs: Option<u64>) -> Result<String> {
            if command.trim().is_empty() {
                bail!("Error: no command provided");
            }
            if let Some(reason) = deny_bash_command_reason(command) {
                bail!("Error: command blocked by bash safety policy ({reason})");
            }
            let timeout = match timeout_secs {
                Some(t) if t > 0 => Duration::from_secs(t),
                _ => Duration::from_secs(if self.config.tool_timeout_secs > 0 {
                    self.config.tool_timeout_secs as u64
                } else {
                    600
                }),
            };

            let mut child = Command::new("bash")
                .arg("-lc")
                .arg(command)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()?;

            let stdout_buf: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
            let stderr_buf: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));

            if let Some(stdout) = child.stdout.take() {
                let buf = stdout_buf.clone();
                thread::spawn(move || stream_reader(stdout, buf));
            }
            if let Some(stderr) = child.stderr.take() {
                let buf = stderr_buf.clone();
                thread::spawn(move || stream_reader(stderr, buf));
            }

            let start = Instant::now();
            let mut timed_out = false;
            loop {
                match child.try_wait() {
                    Ok(Some(_status)) => break,
                    Ok(None) => {
                        if start.elapsed() >= timeout {
                            let _ = child.kill();
                            let _ = child.wait();
                            timed_out = true;
                            break;
                        }
                        thread::sleep(Duration::from_millis(50));
                    }
                    Err(e) => {
                        bail!("Error: failed to wait on child process: {e}");
                    }
                }
            }

            thread::sleep(Duration::from_millis(30));

            let mut out = stdout_buf.lock().unwrap().clone();
            let stderr = stderr_buf.lock().unwrap().clone();
            if !stderr.is_empty() {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&stderr);
            }

            if timed_out {
                out.push_str(&format!(
                    "\n[... truncated, command timed out after {} seconds ...]",
                    timeout.as_secs()
                ));
            }
            Ok(out)
        }

        fn glob(&self, pattern: &str, path: &str) -> Result<String> {
            if pattern.is_empty() {
                bail!("Error: no pattern provided");
            }
            let _ = Command::new("rg")
                .arg("--version")
                .output()
                .map_err(|_| anyhow!("Error: rg is required for glob"))?;
            let output = Command::new("rg")
                .args(["--files", path, "-g", pattern])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .output()?;
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }

        fn grep(
            &self,
            pattern: &str,
            path: &str,
            glob: &str,
            context: Option<usize>,
        ) -> Result<String> {
            if pattern.is_empty() {
                bail!("Error: no pattern provided");
            }
            let _ = Command::new("rg")
                .arg("--version")
                .output()
                .map_err(|_| anyhow!("Error: rg is required for grep"))?;
            let mut cmd = Command::new("rg");
            cmd.args(["-n", "--color", "never", "--heading"]);
            if let Some(c) = context {
                if c > 0 {
                    cmd.args(["-C", &c.to_string()]);
                }
            }
            if !glob.is_empty() {
                cmd.args(["--glob", glob]);
            }
            if pattern.starts_with('-') {
                cmd.args(["-e", pattern]);
            } else {
                cmd.args(["--", pattern]);
            }
            cmd.arg(path);
            let output = cmd.stdout(Stdio::piped()).stderr(Stdio::null()).output()?;
            let result = String::from_utf8_lossy(&output.stdout).to_string();
            Ok(result.trim_end_matches('\n').to_string())
        }

        fn todo_write(&self, todos: Vec<TodoArg>) -> Result<String> {
            let mut lines = Vec::new();
            for t in todos {
                let content = t.content.as_str();
                let status = t.status.as_str();
                if content.is_empty() {
                    bail!("Error: todo item content is required");
                }
                match status {
                    "pending" => lines.push(format!("- [ ] {content}")),
                    "in_progress" => {
                        lines.push(format!("- [ ] {content}"));
                    }
                    "completed" => lines.push(format!("- [x] {content}")),
                    _ => bail!("Error: invalid todo status: {status}"),
                }
            }
            Ok(lines.join("\n"))
        }

        fn tool_skill(&self, name: &str) -> Result<String> {
            let name = name.trim();
            if name.is_empty() {
                bail!("Error: no skill name provided");
            }
            let Some(skill_file) = prompt::resolve_skill_file(&self.cwd, &self.home, name) else {
                bail!("Error: skill not found: {name}");
            };
            let base_dir = skill_file.parent().unwrap_or(Path::new(""));
            let content = fs::read_to_string(&skill_file)?
                .replace("${BASH_AGENT_SKILL_DIR}", &base_dir.display().to_string());
            Ok(format!(
                "Skill: {name}\nBase directory: {}\n\n{content}",
                base_dir.display()
            ))
        }

        fn web_search(&self, query: &str) -> Result<String> {
            if query.is_empty() {
                bail!("Error: no query provided");
            }
            let client = reqwest::blocking::Client::new();
            let mut req = client
                .get("https://s.jina.ai/")
                .query(&[("q", query)])
                .header("X-Respond-With", "no-content")
                .timeout(std::time::Duration::from_secs(30));
            if let Ok(key) = std::env::var("JINA_API_KEY") {
                if !key.is_empty() {
                    req = req.header("Authorization", format!("Bearer {key}"));
                }
            }
            let resp = req.send()?;
            let body = resp.text()?;
            Ok(body)
        }

        fn web_fetch(&self, url: &str) -> Result<String> {
            if url.is_empty() {
                bail!("Error: no url provided");
            }
            let client = reqwest::blocking::Client::new();
            let mut req = client
                .get("https://r.jina.ai/")
                .query(&[("url", url)])
                .timeout(std::time::Duration::from_secs(60));
            if let Ok(key) = std::env::var("JINA_API_KEY") {
                if !key.is_empty() {
                    req = req.header("Authorization", format!("Bearer {key}"));
                }
            }
            let resp = req.send()?;
            let body = resp.text()?;
            Ok(body)
        }
    }

    fn deny_bash_command_reason(command: &str) -> Option<&'static str> {
        let trimmed = command.trim();
        if trimmed.is_empty() {
            return Some("empty command");
        }

        let lower = trimmed.to_lowercase();
        for p in [
            "sudo ", "shutdown", "reboot", "halt", "poweroff", "mkfs", "fdisk",
        ] {
            if lower.starts_with(p) {
                return Some("dangerous command prefix");
            }
        }
        if lower.contains("rm -rf /") || lower.contains("rm -fr /") {
            return Some("destructive root delete pattern");
        }
        if RE_FIND_DELETE.is_match(trimmed) {
            return Some("blocked destructive find -delete pattern");
        }
        if RE_FORK_BOMB.is_match(trimmed) {
            return Some("fork bomb pattern");
        }
        if RE_BLOCK_DEVICE_WRITE.is_match(trimmed) {
            return Some("block device write pattern");
        }
        None
    }

    impl crate::traits::ToolDispatcher for Runner {
        fn dispatch(&self, name: &str, input: &Value) -> anyhow::Result<String> {
            Runner::dispatch(self, name, input)
        }
    }

    pub fn tool_dispatch(runner: &Runner, name: &str, input: &Value) -> Result<String> {
        runner.dispatch(name, input)
    }

    pub fn tool_read(runner: &Runner, path: &str, offset: Option<usize>, limit: Option<usize>) -> Result<String> {
        runner.read(path, offset, limit)
    }

    pub fn tool_write(runner: &Runner, path: &str, content: &str) -> Result<String> {
        runner.write(path, content)
    }

    pub fn tool_edit(runner: &Runner, path: &str, old_string: &str, new_string: &str) -> Result<String> {
        runner.edit(path, old_string, new_string)
    }

    pub fn tool_bash(runner: &Runner, command: &str, timeout_secs: Option<u64>) -> Result<String> {
        runner.bash(command, timeout_secs)
    }

    pub fn tool_glob(runner: &Runner, pattern: &str, path: &str) -> Result<String> {
        runner.glob(pattern, path)
    }

    pub fn tool_grep(
        runner: &Runner,
        pattern: &str,
        path: &str,
        glob: &str,
        context: Option<usize>,
    ) -> Result<String> {
        runner.grep(pattern, path, glob, context)
    }

    pub fn tool_skill(runner: &Runner, name: &str) -> Result<String> {
        runner.tool_skill(name)
    }

    pub fn tool_web_search(runner: &Runner, query: &str) -> Result<String> {
        runner.web_search(query)
    }

    pub fn tool_web_fetch(runner: &Runner, url: &str) -> Result<String> {
        runner.web_fetch(url)
    }

    pub fn tool_format_result(s: &str, max: usize) -> String {
        format_tool_result(s, max)
    }

    fn stream_reader<R: std::io::Read>(pipe: R, buf: Arc<Mutex<String>>) {
        let mut reader = BufReader::new(pipe);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break,
                Ok(_) => {
                    if let Ok(mut guard) = buf.lock() {
                        guard.push_str(&line);
                    }
                }
                Err(_) => break,
            }
        }
        let mut tail = String::new();
        if reader.read_to_string(&mut tail).is_ok() && !tail.is_empty() {
            if let Ok(mut guard) = buf.lock() {
                guard.push_str(&tail);
            }
        }
    }

    fn unified_diff_color(path: &str, old_content: &str, new_content: &str) -> Result<String> {
        let old_path = std::env::temp_dir().join(format!("edit-old-{}", std::process::id()));
        let new_path = std::env::temp_dir().join(format!("edit-new-{}", std::process::id()));
        fs::write(&old_path, old_content)?;
        fs::write(&new_path, new_content)?;
        let label = path.trim_start_matches('/');
        let diff = Command::new("diff")
            .args([
                "-u",
                "--color=always",
                "--label",
                &format!("a/{label}"),
                "--label",
                &format!("b/{label}"),
                old_path.to_str().unwrap_or(""),
                new_path.to_str().unwrap_or(""),
            ])
            .output();
        let _ = fs::remove_file(&old_path);
        let _ = fs::remove_file(&new_path);
        match diff {
            Ok(output) => {
                if output.status.success() || output.status.code() == Some(1) {
                    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                    if stdout.contains("unsupported --color")
                        || stdout.contains("unrecognized option '--color'")
                    {
                        let old_path2 =
                            std::env::temp_dir().join(format!("edit-old2-{}", std::process::id()));
                        let new_path2 =
                            std::env::temp_dir().join(format!("edit-new2-{}", std::process::id()));
                        fs::write(&old_path2, old_content)?;
                        fs::write(&new_path2, new_content)?;
                        let diff2 = Command::new("diff")
                            .args([
                                "-u",
                                "--label",
                                &format!("a/{label}"),
                                "--label",
                                &format!("b/{label}"),
                                old_path2.to_str().unwrap_or(""),
                                new_path2.to_str().unwrap_or(""),
                            ])
                            .output();
                        let _ = fs::remove_file(&old_path2);
                        let _ = fs::remove_file(&new_path2);
                        match diff2 {
                            Ok(o) if o.status.success() || o.status.code() == Some(1) => {
                                Ok(String::from_utf8_lossy(&o.stdout).to_string())
                            }
                            _ => bail!("Error: diff failed"),
                        }
                    } else {
                        Ok(stdout)
                    }
                } else {
                    bail!("Error: diff failed")
                }
            }
            Err(_) => bail!("Error: diff failed"),
        }
    }

    fn count_diff_lines(diff: &str) -> (usize, usize) {
        let mut added = 0usize;
        let mut removed = 0usize;
        for line in diff.lines() {
            let stripped = strip_ansi(line);
            if stripped.starts_with('+') && !stripped.starts_with("+++") {
                added += 1;
            }
            if stripped.starts_with('-') && !stripped.starts_with("---") {
                removed += 1;
            }
        }
        (added, removed)
    }

    fn strip_ansi(s: &str) -> String {
        let bytes = s.as_bytes();
        let mut out = String::with_capacity(s.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
                let mut j = i + 2;
                while j < bytes.len()
                    && ((bytes[j] >= 0x30 && bytes[j] <= 0x3f)
                        || (bytes[j] >= 0x20 && bytes[j] <= 0x2f))
                {
                    j += 1;
                }
                if j < bytes.len() && bytes[j] >= 0x40 && bytes[j] <= 0x7e {
                    j += 1;
                }
                i = j;
            } else {
                out.push(bytes[i] as char);
                i += 1;
            }
        }
        out
    }

    pub fn format_tool_result(s: &str, max: usize) -> String {
        if s.len() <= max {
            return s.to_string();
        }
        let size = s.len();
        let marker = format!(
            "\n\n[... truncated: showing first/last portions of {} bytes ...]\n\n",
            size
        );
        let marker_len = marker.len() + 20;
        let tail_lines = 5;
        let tail_text = last_n_lines(s, tail_lines);
        let tail_len = tail_text.len();
        let mut head_len = max.saturating_sub(marker_len + tail_len);
        if head_len == 0 {
            head_len = max / 2;
        }
        let head_text = utf8_prefix_by_bytes(s, head_len);
        format!("{head_text}{marker}{tail_text}")
    }

    fn last_n_lines(s: &str, n: usize) -> &str {
        let mut count = 0usize;
        for (i, ch) in s.char_indices().rev() {
            if ch == '\n' {
                count += 1;
                if count >= n {
                    return &s[i + ch.len_utf8()..];
                }
            }
        }
        s
    }

    fn utf8_prefix_by_bytes(s: &str, max_bytes: usize) -> &str {
        if max_bytes >= s.len() {
            return s;
        }
        let mut end = 0;
        for (i, ch) in s.char_indices() {
            let next = i + ch.len_utf8();
            if next > max_bytes {
                break;
            }
            end = next;
        }
        &s[..end]
    }

    #[cfg(test)]
    mod tests {
        use super::Runner;
        use crate::config::Config;
        use serde_json::json;
        use std::fs;
        use std::time::{SystemTime, UNIX_EPOCH};

        #[test]
        fn dispatch_skill_reads_content() {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!("rustagent-skill-test-{unique}"));
            let skill_dir = root.join("skills/test-skill");
            fs::create_dir_all(&skill_dir).unwrap();
            fs::write(
                skill_dir.join("SKILL.md"),
                "description: test\nPath: ${BASH_AGENT_SKILL_DIR}/helper.sh\n",
            )
            .unwrap();

            let runner = Runner {
                config: Config::default(),
                cwd: root.clone(),
                home: root.join("home"),
            };
            let result = runner
                .dispatch("Skill", &json!({ "name": "test-skill" }))
                .unwrap();
            assert!(result.contains("Skill: test-skill"));
            assert!(result.contains("description: test"));
            assert!(result.contains("/helper.sh"));

            let _ = fs::remove_dir_all(root);
        }
    }
