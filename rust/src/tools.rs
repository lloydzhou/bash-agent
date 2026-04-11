use crate::config::Config;
use crate::safety;
use anyhow::{Result, anyhow, bail};
use once_cell::sync::Lazy;
use regex::Regex;
use serde::Deserialize;
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::process::{Command, Stdio};

pub struct Runner {
    pub config: Config,
    pub todo_file: std::path::PathBuf,
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
            bail!("Error: old_string not found in {path}");
        }
        let updated = content.replacen(old_s, new_s, 1);
        if updated.is_empty() {
            bail!("Error: edit produced empty result, reverted");
        }
        fs::write(path, updated)?;
        Ok(format!("OK: edited {path}"))
    }

    fn bash(&self, command: &str) -> Result<String> {
        if command.trim().is_empty() {
            bail!("Error: no command provided");
        }
        if let Some(reason) = safety::deny_bash_command_reason(command) {
            bail!("Error: command blocked by bash safety policy ({reason})");
        }
        let output = Command::new("bash")
            .arg("-lc")
            .arg(command)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output()?;
        let mut s = String::new();
        s.push_str(&String::from_utf8_lossy(&output.stdout));
        s.push_str(&String::from_utf8_lossy(&output.stderr));
        Ok(s)
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
}

static RE_ANSI: Lazy<Regex> = Lazy::new(|| Regex::new(r"\x1b\[[0-9;]*[[:alpha:]]").expect("regex"));

pub fn strip_ansi(s: &str) -> String {
    RE_ANSI.replace_all(s, "").to_string()
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
        return s[..max.min(s.len())].to_string();
    }
    let head = available / 2;
    let tail = available - head;
    let left = &s[..head.min(s.len())];
    let right_start = s.len().saturating_sub(tail);
    let right = &s[right_start..];
    format!("{left}{marker}{right}")
}
