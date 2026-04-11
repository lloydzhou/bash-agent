use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone)]
pub enum Event {
    Text(TextEvent),
    ToolCall(ToolCallEvent),
    Usage(UsageEvent),
    Stop(StopEvent),
    Error(ErrorEvent),
}

impl Event {
    pub fn render(&self) -> String {
        match self {
            Event::Text(e) => format!("TEXT:{}", escape_text(&e.content)),
            Event::ToolCall(e) => {
                let mut out = format!(
                    "TOOL_CALL:{}\t{}\t{}",
                    e.name,
                    e.id,
                    escape_text(&e.input_json.to_string())
                );
                for key in &e.order {
                    out.push('\t');
                    out.push_str(key);
                    out.push('\t');
                    out.push_str(&escape_text(
                        e.fields.get(key).map(String::as_str).unwrap_or(""),
                    ));
                }
                out
            }
            Event::Usage(e) => format!(
                "USAGE:{}\t{}\t{}",
                e.input_tokens, e.output_tokens, e.cache_input_tokens
            ),
            Event::Stop(e) => format!("STOP:{}", e.reason),
            Event::Error(e) => format!("ERROR:{}", e.message),
        }
    }
}

#[derive(Debug, Clone)]
pub struct TextEvent {
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct StopEvent {
    pub reason: String,
}

#[derive(Debug, Clone)]
pub struct ErrorEvent {
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct UsageEvent {
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_input_tokens: i64,
}

#[derive(Debug, Clone)]
pub struct ToolCallEvent {
    pub name: String,
    pub id: String,
    pub input_json: Value,
    pub fields: BTreeMap<String, String>,
    pub order: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolResultContent {
    #[serde(rename = "type")]
    pub kind: String,
    pub tool_use_id: String,
    pub content: String,
}

pub fn escape_text(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
        .replace('\t', "\\t")
}

pub fn unescape_text(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some('\\') => out.push('\\'),
            Some(other) => {
                out.push('\\');
                out.push(other);
            }
            None => out.push('\\'),
        }
    }
    out
}

pub fn parse_tool_call_payload(payload: &str) -> Result<ToolCallEvent> {
    let parts: Vec<&str> = payload.split('\t').collect();
    if parts.len() < 3 {
        bail!("invalid tool call payload")
    }
    let input: Value = serde_json::from_str(&unescape_text(parts[2]))?;
    let mut fields = BTreeMap::new();
    let mut order = Vec::new();
    let mut i = 3;
    while i + 1 < parts.len() {
        let key = parts[i].to_string();
        let value = unescape_text(parts[i + 1]);
        fields.insert(key.clone(), value);
        order.push(key);
        i += 2;
    }
    Ok(ToolCallEvent {
        name: parts[0].to_string(),
        id: parts[1].to_string(),
        input_json: input,
        fields,
        order,
    })
}

pub fn parse_usage_payload(payload: &str) -> Result<UsageEvent> {
    let parts: Vec<&str> = payload.split('\t').collect();
    if parts.len() != 3 {
        bail!("invalid usage payload")
    }
    Ok(UsageEvent {
        input_tokens: parts[0].parse()?,
        output_tokens: parts[1].parse()?,
        cache_input_tokens: parts[2].parse()?,
    })
}
