use crate::protocol::ToolCallEvent;
use anyhow::{Result, anyhow, bail};
use serde_json::Value;
use std::collections::BTreeMap;

pub fn build_tool_call_event(name: &str, id: &str, input: &str) -> Result<ToolCallEvent> {
    let trimmed = if input.trim().is_empty() {
        "{}"
    } else {
        input.trim()
    };
    let obj: Value = serde_json::from_str(trimmed).map_err(|e| anyhow!("parse tool input: {e}"))?;
    let mut event = ToolCallEvent {
        name: name.to_string(),
        id: id.to_string(),
        input_json: obj.clone(),
        fields: BTreeMap::new(),
        order: Vec::new(),
    };
    if name == "TodoWrite" {
        let (checklist, summary) = todo_fields(&obj)?;
        event.order = vec!["checklist".to_string(), "summary".to_string()];
        event.fields.insert("checklist".to_string(), checklist);
        event.fields.insert("summary".to_string(), summary);
        return Ok(event);
    }
    let map = obj
        .as_object()
        .ok_or_else(|| anyhow!("tool input must be object"))?;
    for (k, v) in map {
        event.order.push(k.clone());
        event.fields.insert(k.clone(), json_scalar_string(v));
    }
    Ok(event)
}

fn json_scalar_string(v: &Value) -> String {
    match v {
        Value::Null => "null".to_string(),
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        _ => v.to_string(),
    }
}

fn todo_fields(obj: &Value) -> Result<(String, String)> {
    let todos = obj
        .get("todos")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("invalid TodoWrite input: missing todos"))?;
    let mut lines = Vec::new();
    let mut completed = 0;
    let mut in_progress = 0;
    let total = todos.len();
    for t in todos {
        let content = t.get("content").and_then(Value::as_str).unwrap_or("");
        let status = t.get("status").and_then(Value::as_str).unwrap_or("");
        if content.is_empty() {
            bail!("Error: todo item content is required");
        }
        match status {
            "pending" => lines.push(format!("- [ ] {content}")),
            "in_progress" => {
                in_progress += 1;
                lines.push(format!("- [ ] {content}"));
            }
            "completed" => {
                completed += 1;
                lines.push(format!("- [x] {content}"));
            }
            _ => bail!("Error: invalid todo status: {status}"),
        }
    }
    if in_progress > 1 {
        bail!("Error: todo_write allows at most one in_progress item");
    }
    Ok((lines.join("\n"), format!("{completed}/{total}")))
}
