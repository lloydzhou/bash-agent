use crate::protocol::{
    ErrorEvent, Event, RetryEvent, StopEvent, TextEvent, ThinkingEvent, UsageEvent,
};
use crate::sse::toolcall::build_tool_call_event;
use anyhow::Result;
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read};

#[derive(Default, Clone)]
struct PendingCall {
    id: String,
    name: String,
    arguments: String,
}

pub fn parse<R: Read>(reader: R, mut emit: impl FnMut(Event) -> Result<()>) -> Result<()> {
    let mut br = BufReader::new(reader);
    let mut line = String::new();
    let mut stop_reason = String::new();
    let mut input_tokens = 0i64;
    let mut output_tokens = 0i64;
    let mut cache_read_input_tokens = 0i64;
    let mut saw_text = false;
    let mut pending_calls: BTreeMap<i64, PendingCall> = BTreeMap::new();
    let mut pending_usage: Option<UsageEvent> = None;
    let mut pending_stop: Option<String> = None;

    loop {
        line.clear();
        let n = br.read_line(&mut line)?;
        if n == 0 {
            break;
        }
        let l = line.trim_end_matches(['\n', '\r']);

        // RETRY: reset all parser state
        if l == "RETRY:" {
            stop_reason.clear();
            input_tokens = 0;
            output_tokens = 0;
            cache_read_input_tokens = 0;
            saw_text = false;
            pending_calls.clear();
            pending_usage = None;
            pending_stop = None;
            emit(Event::Retry(RetryEvent {}))?;
            continue;
        }

        if l.is_empty() || !l.starts_with("data: ") {
            continue;
        }
        let payload = &l[6..];
        if payload == "[DONE]" {
            emit_pending(&mut pending_calls, &mut emit)?;
            if stop_reason.is_empty() {
                stop_reason = "done".to_string();
            }
            pending_usage = Some(UsageEvent {
                input_tokens,
                output_tokens,
                cache_read_input_tokens,
                cache_creation_input_tokens: 0,
            });
            pending_stop = Some(stop_reason.clone());
            break;
        }

        let body: Value = serde_json::from_str(payload)?;
        if let Some(msg) = body
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(Value::as_str)
        {
            emit(Event::Error(ErrorEvent {
                message: msg.to_string(),
            }))?;
            continue;
        }

        let usage = body.get("usage").cloned().unwrap_or(Value::Null);
        if let Some(v) = usage.get("prompt_tokens").and_then(Value::as_i64) {
            input_tokens = v;
        }
        if let Some(v) = usage.get("completion_tokens").and_then(Value::as_i64) {
            output_tokens = v;
        }
        if let Some(v) = usage.get("cached_tokens").and_then(Value::as_i64) {
            cache_read_input_tokens = v;
        }

        let choice = body
            .get("choices")
            .and_then(Value::as_array)
            .and_then(|arr| arr.first())
            .cloned()
            .unwrap_or(Value::Null);

        if let Some(r) = choice.get("finish_reason").and_then(Value::as_str) {
            if !r.is_empty() && r != "null" {
                stop_reason = r.to_string();
            }
        }

        let delta = choice.get("delta").cloned().unwrap_or(Value::Null);
        if let Some(content) = delta.get("content").and_then(Value::as_str) {
            let c = if !saw_text {
                content.trim_start_matches(['\n', '\r']).to_string()
            } else {
                content.to_string()
            };
            if !c.is_empty() {
                saw_text = true;
                emit(Event::Text(TextEvent { content: c }))?;
            }
        }

        // Reasoning / thinking content (e.g. o-series, deepseek)
        if let Some(reasoning) = delta
            .get("reasoning_content")
            .or_else(|| delta.get("reasoning"))
            .and_then(Value::as_str)
        {
            if !reasoning.is_empty() {
                emit(Event::Thinking(ThinkingEvent {
                    content: reasoning.to_string(),
                }))?;
            }
        }

        if let Some(tool_calls) = delta.get("tool_calls").and_then(Value::as_array) {
            for tc in tool_calls {
                let idx = tc.get("index").and_then(Value::as_i64).unwrap_or(0);
                let entry = pending_calls.entry(idx).or_default();
                if let Some(v) = tc.get("id").and_then(Value::as_str) {
                    entry.id = v.to_string();
                }
                if let Some(v) = tc
                    .get("function")
                    .and_then(|f| f.get("name"))
                    .and_then(Value::as_str)
                {
                    entry.name = v.to_string();
                }
                if let Some(v) = tc
                    .get("function")
                    .and_then(|f| f.get("arguments"))
                    .and_then(Value::as_str)
                {
                    entry.arguments.push_str(v);
                }
            }
        }

        if choice.get("finish_reason").and_then(Value::as_str) == Some("tool_calls") {
            emit_pending(&mut pending_calls, &mut emit)?;
        }
    }

    if let Some(usage) = pending_usage {
        emit(Event::Usage(usage))?;
    }
    if let Some(reason) = pending_stop {
        emit(Event::Stop(StopEvent { reason }))?;
    }

    Ok(())
}

fn emit_pending(
    pending_calls: &mut BTreeMap<i64, PendingCall>,
    emit: &mut impl FnMut(Event) -> Result<()>,
) -> Result<()> {
    for call in pending_calls.values_mut() {
        if call.arguments.is_empty() {
            continue;
        }
        let evt = build_tool_call_event(&call.name, &call.id, &call.arguments)?;
        emit(Event::ToolCall(evt))?;
        call.arguments.clear();
    }
    Ok(())
}
