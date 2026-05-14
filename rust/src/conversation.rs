use crate::protocol::ToolCallEvent;
use anyhow::Result;
use serde_json::{Value, json};
use std::fs;
use std::io::Write;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Store {
    pub path: PathBuf,
}

#[derive(Debug, Clone)]
pub struct ToolResult {
    pub tool_use_id: String,
    pub tool_name: String,
    pub tool_args: std::collections::BTreeMap<String, String>,
    pub content: String, // Full output for events.jsonl TOOL_RESULT (matches bash)
    pub conv_content: String, // Summary only for conv file (matches bash: result_for_conv = first line of Edit output)
}

impl Store {
    pub fn ensure(&self) -> Result<()> {
        if !self.path.exists() {
            fs::File::create(&self.path)?;
        }
        Ok(())
    }

    pub fn add_user(&self, content: &str) -> Result<()> {
        self.append_line(&json!({"role":"user","content":content}))
    }

    pub fn add_assistant(&self, text: &str, thinking: &str, calls: &[ToolCallEvent]) -> Result<()> {
        let mut content = Vec::new();
        // Always emit thinking block (matches bash build_assistant_content_json)
        content.push(json!({"type":"thinking","thinking":thinking}));
        // Always emit text block (matches bash build_assistant_content_json)
        content.push(json!({"type":"text","text":text}));
        for c in calls {
            content.push(json!({"type":"tool_use","id":c.id,"name":c.name,"input":c.input_json}));
        }
        self.append_line(&json!({"role":"assistant","content":content}))
    }

    pub fn add_tool_results(&self, results: &[ToolResult]) -> Result<()> {
        let content: Vec<Value> = results
            .iter()
            .map(|r| {
                let conv_content = if r.conv_content.is_empty() {
                    &r.content
                } else {
                    &r.conv_content
                };
                json!({"type":"tool_result","tool_use_id":r.tool_use_id,"content":conv_content})
            })
            .collect();
        self.append_line(&json!({"role":"user","content":content}))
    }

    pub fn file_tool_result_summary(kind: &str, path: &str) -> String {
        if path.is_empty() {
            return kind.to_string();
        }
        match fs::read(path) {
            Ok(data) => format!(
                "{kind}({path}) [{} lines, {} bytes]",
                line_count(&data),
                data.len()
            ),
            Err(_) => format!("{kind}({path})"),
        }
    }

    pub fn lines(&self) -> Result<Vec<Value>> {
        let data = fs::read_to_string(&self.path)?;
        Ok(data
            .lines()
            .filter(|l| !l.trim().is_empty())
            .map(serde_json::from_str)
            .collect::<std::result::Result<Vec<Value>, _>>()?)
    }

    pub fn messages_json(&self) -> Result<Value> {
        Ok(Value::Array(self.lines()?))
    }

    pub fn total_bytes(&self) -> Result<usize> {
        Ok(fs::read(&self.path)?.len())
    }

    pub fn total_lines(&self) -> Result<usize> {
        Ok(self.lines()?.len())
    }

    /// Count user_input events in events.jsonl
    pub fn count_user_inputs(&self) -> Result<usize> {
        let events_path = self
            .path
            .to_string_lossy()
            .replace("conversation.jsonl", "events.jsonl");
        let data = fs::read_to_string(&events_path)?;
        let count = data
            .lines()
            .filter(|line| line.contains("\"type\":\"user_input\""))
            .count();
        Ok(count)
    }

    pub fn trim_keep_last(&self, keep_lines: usize) -> Result<()> {
        let data = fs::read_to_string(&self.path)?;
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
        fs::write(&self.path, out)?;
        Ok(())
    }

    pub fn keep_line_count(&self, target_bytes: usize) -> Result<usize> {
        let lines = self.lines()?;
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

    fn append_line(&self, value: &Value) -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{}", serde_json::to_string(value)?)?;
        Ok(())
    }
}

pub fn first_line(s: &str) -> &str {
    s.lines().next().unwrap_or(s)
}

pub fn edit_diff_summary(path: &str, diff: &str) -> String {
    let mut added = 0usize;
    let mut removed = 0usize;
    for line in diff.lines() {
        if line.starts_with('+') && !line.starts_with("+++") {
            added += 1;
        }
        if line.starts_with('-') && !line.starts_with("---") {
            removed += 1;
        }
    }
    format!("Edit({path}) [+{added} -{removed} lines]")
}

fn line_count(s: &[u8]) -> usize {
    if s.is_empty() {
        0
    } else {
        s.iter().filter(|&&c| c == b'\n').count() + 1
    }
}

pub fn build_tool_call_summary(
    name: &str,
    fields: &std::collections::BTreeMap<String, String>,
) -> String {
    let mut label = String::new();
    match name {
        "Read" | "Write" | "Edit" => label = fields.get("path").cloned().unwrap_or_default(),
        "Glob" | "Grep" => label = fields.get("pattern").cloned().unwrap_or_default(),
        "Bash" => {
            label = fields
                .get("command")
                .cloned()
                .unwrap_or_default()
                .replace('\n', " ");
            if label.chars().count() > 80 {
                let truncated: String = label.chars().take(77).collect();
                label = format!("{truncated}...");
            }
        }
        "TodoWrite" => {
            if let Some(summary) = fields.get("summary").cloned() {
                if !summary.is_empty() {
                    label = summary;
                }
            }
            if label.is_empty() {
                // Compute progress from todos array
                if let Some(todos) = fields.get("todos") {
                    // todos is a JSON array string; parse it
                    if let Ok(arr) = serde_json::from_str::<Vec<Value>>(todos) {
                        let total = arr.len();
                        let completed = arr
                            .iter()
                            .filter(|item| {
                                item.get("status").and_then(Value::as_str) == Some("completed")
                            })
                            .count();
                        label = format!("{completed}/{total}");
                    }
                }
            }
        }
        "Skill" => label = fields.get("name").cloned().unwrap_or_default(),
        "SubAgent" => label = fields.get("description").cloned().unwrap_or_default(),
        _ => {}
    }
    if label.is_empty() {
        name.to_string()
    } else {
        format!("{name}({label})")
    }
}
