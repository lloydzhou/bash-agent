pub mod toolcall {
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
        let obj: Value =
            serde_json::from_str(trimmed).map_err(|e| anyhow!("parse tool input: {e}"))?;
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
                    lines.push(format!("- [ ] {content}"));
                }
                "completed" => {
                    completed += 1;
                    lines.push(format!("- [x] {content}"));
                }
                _ => bail!("Error: invalid todo status: {status}"),
            }
        }
        Ok((lines.join("\n"), format!("{completed}/{total}")))
    }
}

pub mod claude {
    use crate::protocol::{
        ErrorEvent, Event, RetryEvent, StopEvent, TextEvent, ThinkingEvent, UsageEvent,
    };
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
            if l == "RETRY:" {
                if !cur.event.is_empty() || !cur.data.is_empty() {
                    emit(cur)?;
                }
                emit(SseEvent {
                    event: "RETRY".to_string(),
                    data: String::new(),
                })?;
                cur = SseEvent::default();
                continue;
            }
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
        let mut cache_read_input_tokens = 0i64;
        let mut cache_creation_input_tokens = 0i64;
        let mut pending_usage: Option<UsageEvent> = None;
        let mut pending_stop: Option<String> = None;

        read_sse(reader, |evt| {
            if evt.event == "RETRY" {
                block_type.clear();
                tool_name.clear();
                tool_id.clear();
                partial_json.clear();
                stop_reason.clear();
                input_tokens = 0;
                output_tokens = 0;
                cache_read_input_tokens = 0;
                cache_creation_input_tokens = 0;
                pending_usage = None;
                pending_stop = None;
                emit(Event::Retry(RetryEvent {}))?;
                return Ok(());
            }

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
                    } else if t == "thinking" {
                        block_type = "thinking".to_string();
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
                    } else if block_type == "thinking" {
                        let text = delta.get("thinking").and_then(Value::as_str).unwrap_or("");
                        if !text.is_empty() {
                            emit(Event::Thinking(ThinkingEvent {
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
                    // message_delta.usage.output_tokens: 总是取
                    // message_delta.usage.input_tokens/cache_*: 仅在 message_start 未提供时取
                    // （OpenAI 路径无 message_start，通过 transport 合成 message_delta）
                    if let Some(v) = usage.get("output_tokens").and_then(Value::as_i64) {
                        output_tokens = v;
                    }
                    if input_tokens == 0 {
                        if let Some(v) = usage.get("input_tokens").and_then(Value::as_i64) {
                            input_tokens = v;
                        }
                    }
                    if cache_read_input_tokens == 0 {
                        if let Some(v) =
                            usage.get("cache_read_input_tokens").and_then(Value::as_i64)
                        {
                            cache_read_input_tokens = v;
                        }
                    }
                    if cache_creation_input_tokens == 0 {
                        if let Some(v) = usage
                            .get("cache_creation_input_tokens")
                            .and_then(Value::as_i64)
                        {
                            cache_creation_input_tokens = v;
                        }
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
                    if let Some(v) = usage.get("cache_read_input_tokens").and_then(Value::as_i64) {
                        cache_read_input_tokens = v;
                    }
                    if let Some(v) = usage
                        .get("cache_creation_input_tokens")
                        .and_then(Value::as_i64)
                    {
                        cache_creation_input_tokens = v;
                    }
                }
                "message_stop" => {
                    pending_usage = Some(UsageEvent {
                        input_tokens,
                        output_tokens,
                        cache_read_input_tokens,
                        cache_creation_input_tokens,
                    });
                    pending_stop = Some(stop_reason.clone());
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

        if let Some(usage) = pending_usage {
            emit(Event::Usage(usage))?;
        }
        if let Some(reason) = pending_stop {
            emit(Event::Stop(StopEvent { reason }))?;
        } else {
            emit(Event::Error(ErrorEvent {
                message: "Stream interrupted (no message_stop received)".to_string(),
            }))?;
            emit(Event::Stop(StopEvent {
                reason: "error".to_string(),
            }))?;
        }

        Ok(())
    }
}

pub mod openai {
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
            if let Some(v) = usage.get("completion_tokens").and_then(Value::as_i64) {
                output_tokens = v;
            }
            if let Some(v) = usage.get("cached_tokens").and_then(Value::as_i64) {
                cache_read_input_tokens = v;
            }
            if let Some(v) = usage.get("prompt_tokens").and_then(Value::as_i64) {
                if cache_read_input_tokens > 0 {
                    input_tokens = v - cache_read_input_tokens;
                } else {
                    input_tokens = v;
                }
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
                    /* 非标准 API（如 sensenova）在后续 chunk 发送空字符串 "" 而非省略字段 */
                    if let Some(v) = tc.get("id").and_then(Value::as_str) {
                        if !v.is_empty() {
                            entry.id = v.to_string();
                        }
                    }
                    if let Some(v) = tc
                        .get("function")
                        .and_then(|f| f.get("name"))
                        .and_then(Value::as_str)
                    {
                        if !v.is_empty() {
                            entry.name = v.to_string();
                        }
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
        } else {
            emit(Event::Error(ErrorEvent {
                message: "Stream interrupted (no message_stop received)".to_string(),
            }))?;
            emit(Event::Stop(StopEvent {
                reason: "error".to_string(),
            }))?;
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
}

pub mod responses {
    use crate::protocol::{
        ErrorEvent, Event, RetryEvent, StopEvent, TextEvent, ThinkingEvent, UsageEvent,
    };
    use crate::sse::toolcall::build_tool_call_event;
    use anyhow::Result;
    use serde_json::Value;
    use std::collections::BTreeMap;
    use std::io::{BufRead, BufReader, Read};

    #[derive(Default)]
    struct PendingCall {
        id: String,
        name: String,
        arguments: String,
    }

    pub fn parse<R: Read>(reader: R, mut emit: impl FnMut(Event) -> Result<()>) -> Result<()> {
        let mut br = BufReader::new(reader);
        let mut line = String::new();
        let mut event = String::new();
        let mut saw_text = false;
        let mut input_tokens = 0i64;
        let mut output_tokens = 0i64;
        let mut cache_read_input_tokens = 0i64;
        let mut calls: BTreeMap<i64, PendingCall> = BTreeMap::new();
        let mut item_indexes: BTreeMap<String, i64> = BTreeMap::new();
        let mut completed = false;
        while {
            line.clear();
            br.read_line(&mut line)? != 0
        } {
            let l = line.trim_end_matches(['\n', '\r']);
            if l == "RETRY:" {
                event.clear();
                saw_text = false;
                input_tokens = 0;
                output_tokens = 0;
                cache_read_input_tokens = 0;
                calls.clear();
                item_indexes.clear();
                completed = false;
                emit(Event::Retry(RetryEvent {}))?;
                continue;
            }
            if let Some(v) = l.strip_prefix("event: ") {
                event = v.to_string();
                continue;
            }
            let Some(payload) = l.strip_prefix("data: ") else {
                continue;
            };
            let body: Value = match serde_json::from_str(payload) {
                Ok(v) => v,
                Err(_) => continue,
            };
            match event.as_str() {
                "response.reasoning_text.delta" => {
                    if let Some(delta) = body.get("delta").and_then(Value::as_str) {
                        if !delta.is_empty() {
                            emit(Event::Thinking(ThinkingEvent {
                                content: delta.to_string(),
                            }))?;
                        }
                    }
                }
                "response.output_text.delta" => {
                    if let Some(delta) = body.get("delta").and_then(Value::as_str) {
                        let text = if saw_text {
                            delta
                        } else {
                            delta.trim_start_matches(['\n', '\r'])
                        };
                        if !text.is_empty() {
                            saw_text = true;
                            emit(Event::Text(TextEvent {
                                content: text.to_string(),
                            }))?;
                        }
                    }
                }
                "response.output_item.added" | "response.output_item.done" => {
                    record_item(&body, &mut calls, &mut item_indexes)
                }
                "response.function_call_arguments.delta" => {
                    if let Some(idx) = tool_index(&body, &mut item_indexes) {
                        let call = calls.entry(idx).or_default();
                        if let Some(delta) = body.get("delta").and_then(Value::as_str) {
                            call.arguments.push_str(delta);
                        }
                    }
                }
                "response.completed" => {
                    let response = body.get("response").unwrap_or(&body);
                    record_usage(
                        response,
                        &mut input_tokens,
                        &mut output_tokens,
                        &mut cache_read_input_tokens,
                    );
                    let has_tools = !calls.is_empty();
                    emit_calls(&mut calls, &mut emit)?;
                    emit(Event::Usage(UsageEvent {
                        input_tokens,
                        output_tokens,
                        cache_read_input_tokens,
                        cache_creation_input_tokens: 0,
                    }))?;
                    emit(Event::Stop(StopEvent {
                        reason: if has_tools { "tool_use" } else { "end_turn" }.to_string(),
                    }))?;
                    completed = true;
                }
                "response.failed" | "response.incomplete" | "error" => {
                    let response = body.get("response").unwrap_or(&body);
                    record_usage(
                        response,
                        &mut input_tokens,
                        &mut output_tokens,
                        &mut cache_read_input_tokens,
                    );
                    let message = response
                        .get("error")
                        .and_then(|v| v.get("message"))
                        .and_then(Value::as_str)
                        .or_else(|| response.get("message").and_then(Value::as_str))
                        .or_else(|| response.get("reason").and_then(Value::as_str))
                        .unwrap_or(if event == "response.incomplete" {
                            "Response incomplete"
                        } else if event == "error" {
                            "Stream error"
                        } else {
                            "Response failed"
                        });
                    emit(Event::Error(ErrorEvent {
                        message: message.to_string(),
                    }))?;
                    emit(Event::Usage(UsageEvent {
                        input_tokens,
                        output_tokens,
                        cache_read_input_tokens,
                        cache_creation_input_tokens: 0,
                    }))?;
                    emit(Event::Stop(StopEvent {
                        reason: "error".to_string(),
                    }))?;
                    completed = true;
                }
                _ => {}
            }
        }
        if !completed {
            emit(Event::Error(ErrorEvent {
                message: "Stream interrupted (no response.completed received)".to_string(),
            }))?;
            emit(Event::Stop(StopEvent {
                reason: "error".to_string(),
            }))?;
        }
        Ok(())
    }

    fn tool_index(body: &Value, item_indexes: &mut BTreeMap<String, i64>) -> Option<i64> {
        let item = body.get("item");
        let id = body
            .get("item_id")
            .and_then(Value::as_str)
            .or_else(|| item.and_then(|v| v.get("id")).and_then(Value::as_str));
        let idx = body
            .get("output_index")
            .and_then(Value::as_i64)
            .or_else(|| id.and_then(|id| item_indexes.get(id).copied()));
        if let (Some(id), Some(idx)) = (id, idx) {
            item_indexes.insert(id.to_string(), idx);
        }
        idx
    }

    fn record_item(
        body: &Value,
        calls: &mut BTreeMap<i64, PendingCall>,
        item_indexes: &mut BTreeMap<String, i64>,
    ) {
        let Some(item) = body.get("item") else { return };
        if item.get("type").and_then(Value::as_str) != Some("function_call") {
            return;
        }
        let Some(idx) = tool_index(body, item_indexes) else {
            return;
        };
        let call = calls.entry(idx).or_default();
        if let Some(v) = item.get("call_id").and_then(Value::as_str) {
            call.id = v.to_string();
        }
        if let Some(v) = item.get("name").and_then(Value::as_str) {
            call.name = v.to_string();
        }
        if let Some(v) = item.get("arguments").and_then(Value::as_str) {
            call.arguments = v.to_string();
        }
    }

    fn record_usage(response: &Value, input: &mut i64, output: &mut i64, cached: &mut i64) {
        let usage = response.get("usage").unwrap_or(response);
        *output = usage
            .get("output_tokens")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        *cached = usage
            .get("input_tokens_details")
            .and_then(|v| v.get("cached_tokens"))
            .and_then(Value::as_i64)
            .filter(|v| *v != 0)
            .or_else(|| usage.get("cached_tokens").and_then(Value::as_i64))
            .unwrap_or(0);
        *input = (usage
            .get("input_tokens")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            - *cached)
            .max(0);
    }

    fn emit_calls(
        calls: &mut BTreeMap<i64, PendingCall>,
        emit: &mut impl FnMut(Event) -> Result<()>,
    ) -> Result<()> {
        for call in calls.values() {
            let args = if call.arguments.is_empty() {
                "{}"
            } else {
                &call.arguments
            };
            emit(Event::ToolCall(build_tool_call_event(
                &call.name, &call.id, args,
            )?))?;
        }
        calls.clear();
        Ok(())
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::io::Cursor;

        #[test]
        fn responses_parses_nested_cache_and_error_event() {
            let stream = concat!(
                "event: response.output_item.added\n",
                "data: {\"output_index\":2,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"Read\"}}\n\n",
                "event: response.function_call_arguments.delta\n",
                "data: {\"item_id\":\"item_1\",\"delta\":\"{\\\"path\\\":\\\"/tmp/a\\\"}\"}\n\n",
                "event: response.completed\n",
                "data: {\"response\":{\"usage\":{\"input_tokens\":15,\"output_tokens\":8,\"cached_tokens\":4,\"input_tokens_details\":{\"cached_tokens\":6}}}}\n"
            );
            let mut events = Vec::new();
            parse(Cursor::new(stream), |event| {
                events.push(event);
                Ok(())
            })
            .unwrap();
            assert!(
                matches!(&events[0], Event::ToolCall(call) if call.name == "Read" && call.id == "call_1" && call.input_json == serde_json::json!({"path":"/tmp/a"}))
            );
            assert!(
                matches!(&events[1], Event::Usage(usage) if usage.input_tokens == 9 && usage.output_tokens == 8 && usage.cache_read_input_tokens == 6)
            );
            assert!(matches!(&events[2], Event::Stop(stop) if stop.reason == "tool_use"));

            let mut errors = Vec::new();
            parse(
                Cursor::new("event: error\ndata: {\"reason\":\"upstream failed\"}\n"),
                |event| {
                    errors.push(event);
                    Ok(())
                },
            )
            .unwrap();
            assert!(
                matches!(&errors[0], Event::Error(error) if error.message == "upstream failed")
            );
            assert!(matches!(&errors[1], Event::Usage(_)));
            assert!(matches!(&errors[2], Event::Stop(stop) if stop.reason == "error"));

            let mut bare = Vec::new();
            parse(Cursor::new("event: error\ndata: {}\n"), |event| {
                bare.push(event);
                Ok(())
            })
            .unwrap();
            assert!(
                matches!(&bare[0], Event::Error(error) if error.message == "Stream error")
            );
            assert!(matches!(&bare[1], Event::Usage(_)));
            assert!(matches!(&bare[2], Event::Stop(stop) if stop.reason == "error"));
        }

        #[test]
        fn responses_reports_interrupted_stream() {
            let mut events = Vec::new();
            parse(
                Cursor::new("event: response.output_text.delta\ndata: {\"delta\":\"partial\"}\n"),
                |event| {
                    events.push(event);
                    Ok(())
                },
            )
            .unwrap();
            assert!(matches!(&events[0], Event::Text(text) if text.content == "partial"));
            assert!(
                matches!(&events[1], Event::Error(error) if error.message == "Stream interrupted (no response.completed received)")
            );
            assert!(matches!(&events[2], Event::Stop(stop) if stop.reason == "error"));
        }
    }
}
