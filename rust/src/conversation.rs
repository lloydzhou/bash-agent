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
    pub content: String,
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

    pub fn add_assistant(&self, text: &str, calls: &[ToolCallEvent]) -> Result<()> {
        let mut content = Vec::new();
        if !text.is_empty() {
            content.push(json!({"type":"text","text":text}));
        }
        for c in calls {
            content.push(json!({"type":"tool_use","id":c.id,"name":c.name,"input":c.input_json}));
        }
        self.append_line(&json!({"role":"assistant","content":content}))
    }

    pub fn add_tool_results(&self, results: &[ToolResult]) -> Result<()> {
        let content: Vec<Value> = results
            .iter()
            .map(|r| json!({"type":"tool_result","tool_use_id":r.tool_use_id,"content":r.content}))
            .collect();
        self.append_line(&json!({"role":"user","content":content}))
    }

    pub fn read_tool_result_summary(path: &str) -> String {
        if path.is_empty() {
            return String::from("Read");
        }
        match fs::read(path) {
            Ok(data) => format!("Read({path}) [{} lines, {} bytes]", line_count(&data), data.len()),
            Err(_) => format!("Read({path})"),
        }
    }

    pub fn write_tool_result_summary(path: &str, content: &str) -> String {
        format!("Write({path}) [{} lines, {} bytes]", line_count(content.as_bytes()), content.len())
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

    pub fn trim_keep_last(&self, keep_lines: usize) -> Result<()> {
        let lines = self.lines()?;
        if keep_lines >= lines.len() {
            return Ok(());
        }
        let kept = &lines[lines.len() - keep_lines..];
        let mut out = String::new();
        for v in kept {
            out.push_str(&serde_json::to_string(v)?);
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
                        let completed = arr.iter().filter(|item| {
                            item.get("status").and_then(Value::as_str) == Some("completed")
                        }).count();
                        label = format!("{completed}/{total}");
                    }
                }
            }
        }
        "Skill" => label = fields.get("name").cloned().unwrap_or_default(),
        _ => {}
    }
    if label.is_empty() {
        name.to_string()
    } else {
        format!("{name}({label})")
    }
}
