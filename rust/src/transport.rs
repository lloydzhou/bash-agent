use crate::config::Config;
use crate::protocol::Event;
use crate::sse;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::io::Read;

/// Transport abstracts the per-provider body conversion and SSE parsing.
/// Mirrors bash's unified pipeline: build_claude_request | body_convert | _stream_curl | sse_convert | sse_parse
/// - convert_body: Claude-format body → provider body (identity for Claude)
/// - parse_sse:    provider SSE stream → Event (always emits Claude semantics)
pub trait Transport: Send + Sync {
    fn convert_body(&self, claude_body: &[u8]) -> Result<Vec<u8>>;
    fn parse_sse(
        &self,
        reader: Box<dyn Read + Send>,
        emit: &mut dyn FnMut(Event) -> Result<()>,
    ) -> Result<()>;
}

/// Return the appropriate Transport for the configured provider.
pub fn new_transport(cfg: &Config) -> Box<dyn Transport> {
    match cfg.provider.as_str() {
        "openai" => Box::new(OpenAITransport),
        _ => Box::new(ClaudeTransport),
    }
}

struct ClaudeTransport;

impl Transport for ClaudeTransport {
    fn convert_body(&self, body: &[u8]) -> Result<Vec<u8>> {
        Ok(body.to_vec())
    }

    fn parse_sse(
        &self,
        reader: Box<dyn Read + Send>,
        emit: &mut dyn FnMut(Event) -> Result<()>,
    ) -> Result<()> {
        sse::claude::parse(reader, emit)
    }
}

impl crate::traits::Transport for ClaudeTransport {
    fn convert_body(&self, claude_body: &[u8]) -> Result<Vec<u8>> {
        <Self as Transport>::convert_body(self, claude_body)
    }

    fn parse_sse(
        &self,
        reader: Box<dyn Read + Send>,
        emit: &mut dyn FnMut(Event) -> Result<()>,
    ) -> Result<()> {
        <Self as Transport>::parse_sse(self, reader, emit)
    }
}

struct OpenAITransport;

impl Transport for OpenAITransport {
    fn convert_body(&self, claude_body: &[u8]) -> Result<Vec<u8>> {
        let raw: Value = serde_json::from_slice(claude_body)
            .map_err(|e| anyhow!("transport_openai_body: {e}"))?;

        let model = raw
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let max_tokens = raw.get("max_tokens").and_then(Value::as_i64).unwrap_or(0);
        let system_val = raw.get("system").cloned();
        let thinking_val = raw.get("thinking").cloned();
        let output_config_val = raw.get("output_config").cloned();
        let messages_val = raw.get("messages").cloned().unwrap_or(Value::Array(vec![]));
        let tools_val = raw.get("tools").cloned();

        let messages = messages_val.as_array().cloned().unwrap_or_default();
        let converted = convert_messages_to_openai(&messages)?;

        let mut openai_messages: Vec<Value> = vec![];

        if let Some(sys) = &system_val {
            if !sys.is_null() {
                if let Some(s) = sys.as_str() {
                    if !s.is_empty() {
                        openai_messages.push(json!({"role":"system","content":s}));
                    }
                } else {
                    openai_messages.push(json!({"role":"system","content":sys}));
                }
            }
        }
        openai_messages.extend(converted);

        let mut body = json!({
            "model": model,
            "max_tokens": max_tokens,
            "stream": true,
            "messages": openai_messages,
        });

        let thinking_type = thinking_val
            .as_ref()
            .and_then(Value::as_object)
            .and_then(|o| o.get("type"))
            .and_then(Value::as_str)
            .unwrap_or("");
        if thinking_type == "adaptive" || thinking_type == "enabled" {
            body["thinking"] = json!({"type":"enabled"});
            let effort = output_config_val
                .as_ref()
                .and_then(Value::as_object)
                .and_then(|o| o.get("effort"))
                .and_then(Value::as_str)
                .unwrap_or("high");
            body["reasoning_effort"] = Value::String(effort.to_string());
        }

        if let Some(tools) = &tools_val {
            if !tools.is_null() {
                if let Some(arr) = tools.as_array() {
                    if !arr.is_empty() {
                        body["tools"] = Value::Array(convert_tools_to_openai(arr));
                    }
                }
            }
        }

        Ok(serde_json::to_vec(&body)?)
    }

    fn parse_sse(
        &self,
        reader: Box<dyn Read + Send>,
        emit: &mut dyn FnMut(Event) -> Result<()>,
    ) -> Result<()> {
        sse::openai::parse(reader, &mut |evt: Event| -> Result<()> {
            let mapped = match &evt {
                Event::Stop(s) => {
                    let reason = match s.reason.as_str() {
                        "stop" => "end_turn",
                        "tool_calls" => "tool_use",
                        "length" => "max_tokens",
                        other => other,
                    };
                    Event::Stop(crate::protocol::StopEvent {
                        reason: reason.to_string(),
                    })
                }
                other => other.clone(),
            };
            emit(mapped)
        })
    }
}

impl crate::traits::Transport for OpenAITransport {
    fn convert_body(&self, claude_body: &[u8]) -> Result<Vec<u8>> {
        <Self as Transport>::convert_body(self, claude_body)
    }

    fn parse_sse(
        &self,
        reader: Box<dyn Read + Send>,
        emit: &mut dyn FnMut(Event) -> Result<()>,
    ) -> Result<()> {
        <Self as Transport>::parse_sse(self, reader, emit)
    }
}

fn convert_messages_to_openai(messages: &[Value]) -> Result<Vec<Value>> {
    let mut result = Vec::new();
    for msg in messages {
        let role = msg.get("role").and_then(Value::as_str).unwrap_or("");
        let content = msg.get("content").cloned().unwrap_or(Value::Null);
        if content.is_array() && role == "assistant" {
            result.push(convert_assistant_message(&content)?);
            continue;
        }
        if content.is_array() && role == "user" {
            let tool_msgs = convert_tool_result_messages(&content)?;
            if !tool_msgs.is_empty() {
                result.extend(tool_msgs);
                continue;
            }
        }
        result.push(msg.clone());
    }
    Ok(result)
}

fn convert_assistant_message(content: &Value) -> Result<Value> {
    let blocks = content.as_array().cloned().unwrap_or_default();
    let mut text = String::new();
    let mut reasoning = String::new();
    let mut tool_calls = Vec::new();
    for block in blocks {
        match block.get("type").and_then(Value::as_str).unwrap_or("") {
            "thinking" => {
                reasoning.push_str(block.get("thinking").and_then(Value::as_str).unwrap_or(""))
            }
            "text" => text.push_str(block.get("text").and_then(Value::as_str).unwrap_or("")),
            "tool_use" => {
                let args = block
                    .get("input")
                    .cloned()
                    .unwrap_or(Value::Object(Default::default()));
                tool_calls.push(json!({
                    "id": block.get("id").and_then(Value::as_str).unwrap_or(""),
                    "type": "function",
                    "function": {
                        "name": block.get("name").and_then(Value::as_str).unwrap_or(""),
                        "arguments": args.to_string(),
                    }
                }));
            }
            _ => {}
        }
    }
    let mut msg = json!({
        "role": "assistant",
        "reasoning_content": reasoning,
        "content": text,
    });
    if !tool_calls.is_empty() {
        msg["tool_calls"] = Value::Array(tool_calls);
    }
    Ok(msg)
}

fn convert_tool_result_messages(content: &Value) -> Result<Vec<Value>> {
    let blocks = content.as_array().cloned().unwrap_or_default();
    let mut out = Vec::new();
    for b in blocks {
        if b.get("type").and_then(Value::as_str) != Some("tool_result") {
            continue;
        }
        out.push(json!({
            "role":"tool",
            "tool_call_id": b.get("tool_use_id").and_then(Value::as_str).unwrap_or(""),
            "content": b.get("content").and_then(Value::as_str).unwrap_or(""),
        }));
    }
    Ok(out)
}

fn convert_tools_to_openai(tools: &[Value]) -> Vec<Value> {
    tools
            .iter()
            .map(|tool| {
                if tool.get("type").and_then(Value::as_str) == Some("function") {
                    return tool.clone();
                }
                json!({
                    "type":"function",
                    "function":{
                        "name": tool.get("name").cloned().unwrap_or(Value::String(String::new())),
                        "description": tool.get("description").cloned().unwrap_or(Value::String(String::new())),
                        "parameters": tool.get("input_schema").cloned().or_else(|| tool.get("parameters").cloned()).unwrap_or_else(|| json!({})),
                    }
                })
            })
            .collect()
}
