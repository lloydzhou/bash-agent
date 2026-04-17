use crate::config::Config;
use crate::prompt;
use crate::safety;
use anyhow::{Result, anyhow, bail};
use serde::Deserialize;
use serde_json::Value;
use std::fs;
use std::io::{BufRead, BufReader, Read as IoRead};
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

pub struct Runner {
    pub config: Config,
    pub todo_file: std::path::PathBuf,
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
                }
                let args: Args = serde_json::from_value(input.clone())?;
                self.read(&args.path)
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
                }
                let args: Args = serde_json::from_value(input.clone())?;
                self.bash(&args.command)
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

    fn read(&self, path: &str) -> Result<String> {
        if path.is_empty() {
            bail!("Error: no path provided");
        }
        let data = fs::read_to_string(path)
            .map_err(|_| anyhow!("Error: file not found or unreadable: {path}"))?;
        Ok(data)
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
                "Error: old_string not found in {path}. Hint: Read the file and copy exact bytes (including whitespace/indent/newlines) before retrying Edit."
            );
        }
        let updated = content.replacen(old_s, new_s, 1);
        if updated.is_empty() {
            bail!("Error: edit produced empty result, reverted");
        }
        let diff = unified_diff(path, &content, &updated)?;
        fs::write(path, updated)?;
        if diff.is_empty() {
            Ok(format!("Edit({path}) [no changes]"))
        } else {
            Ok(diff)
        }
    }

    fn bash(&self, command: &str) -> Result<String> {
        if command.trim().is_empty() {
            bail!("Error: no command provided");
        }
        if let Some(reason) = safety::deny_bash_command_reason(command) {
            bail!("Error: command blocked by bash safety policy ({reason})");
        }
        let timeout_secs = self.config.tool_timeout_secs as u64;
        let timeout = Duration::from_secs(if timeout_secs > 0 { timeout_secs } else { 600 });

        let mut child = Command::new("bash")
            .arg("-lc")
            .arg(command)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()?;

        // Take stdout/stderr handles before polling; spawn reader threads that
        // accumulate output into a shared buffer so we don't deadlock on large
        // output while waiting for the process to exit.
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

        // Wait briefly for reader threads to finish draining
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

    fn grep(&self, pattern: &str, path: &str, glob: &str) -> Result<String> {
        if pattern.is_empty() {
            bail!("Error: no pattern provided");
        }
        let _ = Command::new("rg")
            .arg("--version")
            .output()
            .map_err(|_| anyhow!("Error: rg is required for grep"))?;
        let mut cmd = Command::new("rg");
        cmd.args(["-n", "--color", "never"]);
        if !glob.is_empty() {
            cmd.args(["--glob", glob]);
        }
        cmd.args(["--", pattern, path]);
        let output = cmd.stdout(Stdio::piped()).stderr(Stdio::null()).output()?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    fn todo_write(&self, todos: Vec<TodoArg>) -> Result<String> {
        if self.todo_file.as_os_str().is_empty() {
            bail!("Error: todo file not configured");
        }
        let mut lines = Vec::new();
        let mut in_progress = 0;
        for t in todos {
            let content = t.content.as_str();
            let status = t.status.as_str();
            if content.is_empty() {
                bail!("Error: todo item content is required");
            }
            match status {
                "pending" => lines.push(format!("- [ ] {content}")),
                "in_progress" => {
                    in_progress += 1;
                    lines.push(format!("- [ ] {content}"));
                }
                "completed" => lines.push(format!("- [x] {content}")),
                _ => bail!("Error: invalid todo status: {status}"),
            }
        }
        if in_progress > 1 {
            bail!("Error: todo_write allows at most one in_progress item");
        }
        let checklist = lines.join("\n");
        fs::write(&self.todo_file, format!("{checklist}\n"))?;
        Ok(checklist)
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

/// Reads from a child process pipe (stdout or stderr) line-by-line into a
/// shared buffer. This prevents deadlocks when the child produces more output
/// than the OS pipe buffer can hold while the parent is waiting on `try_wait()`.
fn stream_reader<R: std::io::Read>(pipe: R, buf: Arc<Mutex<String>>) {
    let mut reader = BufReader::new(pipe);
    let mut line = String::new();
    loop {
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => break, // EOF
            Ok(_) => {
                if let Ok(mut guard) = buf.lock() {
                    guard.push_str(&line);
                }
            }
            Err(_) => break,
        }
    }
    // Flush any remaining bytes not terminated by a newline
    let mut tail = String::new();
    if reader.read_to_string(&mut tail).is_ok() && !tail.is_empty() {
        if let Ok(mut guard) = buf.lock() {
            guard.push_str(&tail);
        }
    }
}

fn unified_diff(path: &str, old_content: &str, new_content: &str) -> Result<String> {
    let old_path = std::env::temp_dir().join(format!("edit-old-{}", std::process::id()));
    let new_path = std::env::temp_dir().join(format!("edit-new-{}", std::process::id()));
    fs::write(&old_path, old_content)?;
    fs::write(&new_path, new_content)?;
    let diff = Command::new("diff")
        .args([
            "-u",
            "--label",
            &format!("a/{}", path.trim_start_matches('/')),
            "--label",
            &format!("b/{}", path.trim_start_matches('/')),
            old_path.to_str().unwrap_or(""),
            new_path.to_str().unwrap_or(""),
        ])
        .output()?;
    let _ = fs::remove_file(&old_path);
    let _ = fs::remove_file(&new_path);
    if diff.status.success() || diff.status.code() == Some(1) {
        Ok(String::from_utf8_lossy(&diff.stdout).to_string())
    } else {
        bail!("Error: diff failed");
    }
}

pub fn format_tool_result(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let marker = format!(
        "\n[... omitted, original result was {} bytes ...]\n",
        s.len()
    );
    let marker_len = marker.len();
    let available = max.saturating_sub(marker_len);
    if available < 2 {
        return utf8_prefix_by_bytes(s, max).to_string();
    }
    let head = available / 2;
    let tail = available - head;
    let left = utf8_prefix_by_bytes(s, head);
    let right = utf8_suffix_by_bytes(s, tail);
    format!("{left}{marker}{right}")
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

fn utf8_suffix_by_bytes(s: &str, max_bytes: usize) -> &str {
    if max_bytes >= s.len() {
        return s;
    }
    let len = s.len();
    let mut start = len;
    for (i, _) in s.char_indices() {
        if len.saturating_sub(i) <= max_bytes {
            start = i;
            break;
        }
    }
    &s[start..]
}

#[cfg(test)]
mod tests {
    use super::Runner;
    use crate::config::Config;
    use serde_json::json;
    use std::fs;
    use std::path::PathBuf;
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
            todo_file: PathBuf::new(),
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
