use crate::protocol::{ErrorEvent, Event, StopEvent, TextEvent, UsageEvent};
use crate::sse::toolcall::build_tool_call_event;
use anyhow::{Result, anyhow};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read};

#[derive(Default)]
struct SseEvent {
    event: String,
    data: String,
}

fn read_sse<R: Read>(reader: R, mut emit: impl FnMut(SseEvent) -> Result<()>) -> Result<()> {
    let mut br = BufReader::new(reader);
    let mut line = String::new();
    let mut cur = SseEvent::default();
    loop {
        line.clear();
        let n = br.read_line(&mut line)?;
        if n == 0 {
            if !cur.event.is_empty() || !cur.data.is_empty() {
                emit(cur)?;
            }
            break;
        }
        let l = line.trim_end_matches(['\n', '\r']);
        if l.is_empty() {
            if !cur.event.is_empty() || !cur.data.is_empty() {
                emit(cur)?;
            }
            cur = SseEvent::default();
            continue;
        }
        if let Some(v) = l.strip_prefix("event: ") {
            cur.event = v.to_string();
        } else if let Some(v) = l.strip_prefix("data: ") {
            cur.data.push_str(v);
        }
    }
    Ok(())
}

pub fn parse<R: Read>(reader: R, mut emit: impl FnMut(Event) -> Result<()>) -> Result<()> {
    let mut block_type = String::new();
    let mut tool_name = String::new();
    let mut tool_id = String::new();
    let mut partial_json = String::new();
    let mut stop_reason = String::new();
    let mut input_tokens = 0i64;
    let mut output_tokens = 0i64;
    let mut cache_input_tokens = 0i64;

    read_sse(reader, |evt| {
        if evt.data.is_empty() {
            return Ok(());
        }
        let body: Value = serde_json::from_str(&evt.data)?;
        match evt.event.as_str() {
            "content_block_start" => {
                let cb = body.get("content_block").cloned().unwrap_or(Value::Null);
                let t = cb.get("type").and_then(Value::as_str).unwrap_or("");
                if t == "text" {
                    block_type = "text".to_string();
                } else if t == "tool_use" {
                    block_type = "tool".to_string();
                    tool_name = cb
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    tool_id = cb
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    partial_json.clear();
                }
            }
            "content_block_delta" => {
                let delta = body.get("delta").cloned().unwrap_or(Value::Null);
                if block_type == "text" {
                    let text = delta.get("text").and_then(Value::as_str).unwrap_or("");
                    if !text.is_empty() {
                        emit(Event::Text(TextEvent {
                            content: text.to_string(),
                        }))?;
                    }
                } else if block_type == "tool" {
                    partial_json.push_str(
                        delta
                            .get("partial_json")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                    );
                }
            }
            "content_block_stop" => {
                if block_type == "tool" {
                    let call = build_tool_call_event(&tool_name, &tool_id, &partial_json)?;
                    emit(Event::ToolCall(call))?;
                }
                block_type.clear();
            }
            "message_delta" => {
                if let Some(r) = body
                    .get("delta")
                    .and_then(|v| v.get("stop_reason"))
                    .and_then(Value::as_str)
                {
                    if !r.is_empty() {
                        stop_reason = r.to_string();
                    }
                }
                let usage = body.get("usage").cloned().unwrap_or(Value::Null);
                if let Some(v) = usage.get("input_tokens").and_then(Value::as_i64) {
                    input_tokens = v;
                }
                if let Some(v) = usage.get("output_tokens").and_then(Value::as_i64) {
                    output_tokens = v;
                }
                if let Some(v) = usage
                    .get("cache_read_input_tokens")
                    .and_then(Value::as_i64)
                    .or_else(|| {
                        usage
                            .get("cache_creation_input_tokens")
                            .and_then(Value::as_i64)
                    })
                {
                    cache_input_tokens = v;
                }
            }
            "message_start" => {
                let usage = body
                    .get("message")
                    .and_then(|m| m.get("usage"))
                    .cloned()
                    .unwrap_or(Value::Null);
                if let Some(v) = usage.get("input_tokens").and_then(Value::as_i64) {
                    input_tokens = v;
                }
                if let Some(v) = usage
                    .get("cache_read_input_tokens")
                    .and_then(Value::as_i64)
                    .or_else(|| {
                        usage
                            .get("cache_creation_input_tokens")
                            .and_then(Value::as_i64)
                    })
                {
                    cache_input_tokens = v;
                }
            }
            "message_stop" => {
                emit(Event::Usage(UsageEvent {
                    input_tokens,
                    output_tokens,
                    cache_input_tokens,
                }))?;
                emit(Event::Stop(StopEvent {
                    reason: stop_reason.clone(),
                }))?;
            }
            "error" => {
                let msg = body
                    .get("message")
                    .and_then(Value::as_str)
                    .or_else(|| {
                        body.get("error")
                            .and_then(|e| e.get("message"))
                            .and_then(Value::as_str)
                    })
                    .unwrap_or("unknown error");
                emit(Event::Error(ErrorEvent {
                    message: msg.to_string(),
                }))?;
            }
            _ => {}
        }
        Ok(())
    })
    .map_err(|e| anyhow!("parse claude sse: {e}"))?;

    Ok(())
}
