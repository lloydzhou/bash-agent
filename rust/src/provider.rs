use crate::config::Config;
use anyhow::Result;
use serde_json::{Value, json};

/// Build a Claude Messages API request body.
/// Always produces Claude-format JSON; the transport layer handles provider conversion.
pub fn build_claude_request(
    cfg: &Config,
    messages: &[Value],
    tools: &[Value],
    system_prompt: &str,
    max_tokens: i32,
    thinking_budget: i32,
) -> Result<Vec<u8>> {
    let mut body = json!({
        "model": cfg.model,
        "max_tokens": max_tokens,
        "stream": true,
        "messages": messages,
    });
    if thinking_budget > 0 {
        body["thinking"] = json!({
            "type": "enabled",
            "budget_tokens": thinking_budget,
        });
    }
    if !system_prompt.is_empty() {
        body["system"] = Value::String(system_prompt.to_string());
    }
    if !tools.is_empty() {
        body["tools"] = Value::Array(tools.to_vec());
    }
    Ok(serde_json::to_vec(&body)?)
}
