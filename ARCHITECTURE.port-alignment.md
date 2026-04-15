# Go/Rust Port Alignment — Completed

All three ports (Bash, Go, Rust) now use the **inline dispatch** pattern for tool execution during SSE streaming.

---

## 1. Architecture: Inline Dispatch (All Ports Aligned)

All three ports execute tools **during** the LLM stream parse loop, not after it:

```
TOOL_CALL event → parse → dispatch tool immediately → display result → collect for conv → continue parsing
After stream ends:
  1. Check fatal stop (error/max_tokens/length) → return immediately, no conv write
  2. Check interrupt → if interrupted, skip conv write, emit stop, break
  3. conv_add_assistant / AddAssistant / add_assistant (text + tool_calls)
  4. conv_add_tool_results / AddToolResults / add_tool_results (batch)
  5. compact_context_window
  6. tool_use/tool_calls → continue loop; else break
```

---

## 2. Cross-Port Alignment Matrix

### 2.1 Stop Reason Handling

| Aspect | Bash | Go | Rust |
|--------|------|------|------|
| Fatal exits | `error\|max_tokens\|length` → `return 1` before conv write | Same — `return nil` before conv write | Same — `return Ok(())` before conv write |
| Interrupt check | `interrupt_requested` → skip conv write, emit `STOP:interrupted` | `rt.interrupted.Load()` → skip conv write, print "Interrupted." | `self.interrupted.load()` → skip conv write, print "Interrupted." |
| Continue condition | `tool_use\|tool_calls` → continue; else break | Same | Same |
| Max turns | `ERROR:Max turns reached`, continue loop check | `rt.error(...)`, return nil | `self.error(...)`, return Ok(()) |

### 2.2 Tool Execution

| Aspect | Bash | Go | Rust |
|--------|------|------|------|
| When tools run | Inside stream loop on `TOOL_CALL:` | Inside `llmCall` callback on `ToolCallEvent` | Inside `llm_call` closure on `Event::ToolCall` |
| Error handling | `Error: tool execution failed: $output` | `Error: tool execution failed: ` + outputOrErr | `Error: tool execution failed: {e}` |
| Format truncation | `format_tool_result` | `tools.FormatToolResult` | `tools::format_tool_result` |
| Edit special case | `tool_result_first_line` for conv, full for display | `edit_diff_summary` for conv, full diff for display | `edit_diff_summary` for conv, full diff for display |
| TodoWrite event | `TODO_UPDATE:` emitted inline after dispatch | `appendEvent` + `emitStream` inline | `append_event` + `emit_stream` inline |

### 2.3 Conversation Persistence

| Aspect | Bash | Go | Rust |
|--------|------|------|------|
| Assistant write | `conv_add_assistant "$text" "$tool_calls"` | `rt.conv.AddAssistant(text, calls)` | `self.conv.add_assistant(&text, &calls)` |
| Tool result write | `conv_add_tool_results "$tool_conv_results"` (batch) | `rt.conv.AddToolResults(toolResults)` (batch) | `self.conv.add_tool_results(&tool_results)` (batch) |
| Removed methods | `conv_add_single_tool_result` (removed) | `executeToolCalls` (removed) | `execute_tool_calls` (removed) |

### 2.4 Display Architecture

| Aspect | Bash | Go | Rust |
|--------|------|------|------|
| Layer model | Two-layer: `agent_loop_stream` emits protocol lines → `agent_loop` + `display_event` consumes | Single-layer: callback directly calls `displayEvent` | Same single-layer |
| Protocol lines | `TEXT:`, `TOOL_CALL:`, `TOOL_RESULT:`, `STOP:`, `ERROR:`, `USAGE:`, `TODO_UPDATE:` | N/A (uses typed events) | N/A (uses typed events) |
| Stream-JSON mode | `is_stream_json_mode` → emit JSON per protocol line | `isStreamJSONMode` → emit JSON per event | `is_stream_json_mode` → emit JSON per event |

---

## 3. Files Changed (Completed)

### Bash
| File | Change |
|------|--------|
| `src/agent.sh` | Replaced `conv_add_single_tool_result` loop with batch `conv_add_tool_results`; removed per-result function |

### Go
| File | Change |
|------|--------|
| `go/internal/app/app.go` | Inlined tool dispatch into SSE callback; removed `executeToolCalls` (~48 lines); batch `AddToolResults` |

### Rust
| File | Change |
|------|--------|
| `rust/src/app.rs` | Inlined tool dispatch into SSE callback; removed `execute_tool_calls` (~56 lines); batch `add_tool_results` |

---

## 4. Minor Remaining Differences (Acceptable)

| # | Aspect | Bash | Go/Rust | Notes |
|---|--------|------|---------|-------|
| 1 | Two-layer vs single-layer display | Protocol line based | Callback based | Design difference — both correct |
| 2 | Session event placement | Integrated into conv functions | Explicit in loop | Functionally equivalent |
| 3 | `max_turns` reached output | `ERROR:` protocol line | `self.error()` + return | Functionally equivalent |

---

## 5. Verification

- `bash -n src/agent.sh` ✅
- `go build ./...` ✅ (Go)
- `cargo check` ✅ (Rust)
- Zero references to removed functions (`executeToolCalls`, `execute_tool_calls`, `conv_add_single_tool_result`) in source code ✅
- Stop-reason logic aligned across all three: fatal → interrupt → conv write → compact → continue/break ✅
