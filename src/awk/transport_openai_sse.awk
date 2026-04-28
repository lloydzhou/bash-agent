# transport_openai_sse.awk — Convert OpenAI Chat Completions SSE to Claude Messages SSE
# Input:  SSE lines from http_stream.awk (OpenAI format)
# Output: SSE lines in Claude Messages API format (event: / data: pairs)
# Requires: awk -f json.awk -f transport_openai_sse.awk
#
# This sits between http_stream.awk and claude_sse.awk, allowing claude_sse.awk
# to be the single unified SSE parser for all providers.

BEGIN {
    state = "idle"       # idle | text | thinking
    block_idx = 0
    pending_stop = ""
    saw_text = 0
    input_tokens = 0
    output_tokens = 0
    cache_input_tokens = 0

    # Tool call accumulation
    tc_max = -1
    split("", tc_name)
    split("", tc_id)
    split("", tc_args)
}

# Skip SSE comments
/^:/ { next }

# Pass through ERROR lines from http_stream.awk
/^ERROR:/ { print; fflush(); next }

# Handle curl retry: reset all state
/^RETRY:/ {
    _sse_reset()
    print; fflush(); next
}

# [DONE] — finalize and emit Claude message events
/^data: \[DONE\]/ {
    _close_block()

    # Emit accumulated tool calls as Claude content blocks
    _emit_tools()

    if (pending_stop != "") {
        # Map OpenAI finish reasons to Claude stop reasons
        sr = pending_stop
        if (sr == "stop") sr = "end_turn"
        else if (sr == "tool_calls") sr = "tool_use"
        else if (sr == "length") sr = "max_tokens"

        printf "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"%s\"},\"usage\":{\"output_tokens\":%d,\"input_tokens\":%d,\"cache_read_input_tokens\":%d}}\n\n", sr, output_tokens + 0, input_tokens + 0, cache_input_tokens + 0
        printf "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
        fflush()
    }
    next
}

# OpenAI data chunk
/^data: / {
    json = substr($0, 7)

    # Finish reason
    fr = extract_str(json, "finish_reason", 1)
    if (fr != "" && fr != "null") pending_stop = fr

    # --- Text content ---
    content = extract_json_string(json, "content", 1)
    if (content != "" && content != "null") {
        content = unescape_json_string(content)
        if (!saw_text) {
            sub(/^\n+/, "", content)
            sub(/^\r+/, "", content)
        }
        if (content != "") {
            saw_text = 1
            if (state != "text") {
                _close_block()
                _emit_block_start("text", block_idx)
                state = "text"
            }
            _emit_text_delta(block_idx, content)
        }
    }

    # --- Reasoning / thinking ---
    reasoning = extract_json_string(json, "reasoning_content", 1)
    if (reasoning == "" || reasoning == "null") reasoning = extract_json_string(json, "reasoning", 1)
    if (reasoning != "" && reasoning != "null") {
        reasoning = unescape_json_string(reasoning)
        if (reasoning != "") {
            if (state != "thinking") {
                _close_block()
                _emit_block_start("thinking", block_idx)
                state = "thinking"
            }
            _emit_thinking_delta(block_idx, reasoning)
        }
    }

    # --- Tool calls ---
    tc_val = extract_value(json, "tool_calls", 1)
    if (tc_val != "" && tc_val != "null") {
        if (state != "idle") _close_block()
        state = "idle"
        _parse_tool_calls(tc_val)
    }
    # If finish_reason is tool_calls, emit pending tools early (otherwise [DONE] handles it)
    if (fr == "tool_calls") {
        _close_block()
        _emit_tools()
    }

    # --- Usage ---
    pt = extract_num(json, "prompt_tokens", 1)
    if (pt != "") input_tokens = pt
    ct = extract_num(json, "completion_tokens", 1)
    if (ct != "") output_tokens = ct
    crt = extract_num(json, "cached_tokens", 1)
    if (crt == "") crt = extract_num(json, "cache_read_input_tokens", 1)
    if (crt != "") cache_input_tokens = crt

    next
}

# --- Internal functions ---

function _sse_reset() {
    state = "idle"
    block_idx = 0
    pending_stop = ""
    saw_text = 0
    input_tokens = 0
    output_tokens = 0
    cache_input_tokens = 0
    tc_max = -1
    split("", tc_name)
    split("", tc_id)
    split("", tc_args)
}

function _close_block() {
    if (state == "text" || state == "thinking") {
        printf "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":%d}\n\n", block_idx
        fflush()
        block_idx++
        state = "idle"
    }
}

function _emit_block_start(kind, idx) {
    printf "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":%d,\"content_block\":{\"type\":\"%s\",\"%s\":\"\"}}\n\n", idx, kind, kind
    fflush()
}

function _emit_text_delta(idx, text,    escaped) {
    escaped = escape_json_string(text)
    printf "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":%d,\"delta\":{\"type\":\"text_delta\",\"text\":\"%s\"}}\n\n", idx, escaped
    fflush()
}

function _emit_thinking_delta(idx, text,    escaped) {
    escaped = escape_json_string(text)
    printf "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":%d,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"%s\"}}\n\n", idx, escaped
    fflush()
}

function _parse_tool_calls(tc_json,    count, p, tc, idx, tc_id_val, func_raw, name, args) {
    if (substr(tc_json, 1, 1) != "[") return
    count = split_top_level_objects(tc_json, _TC_CHUNKS)
    for (p = 1; p <= count; p++) {
        tc = _TC_CHUNKS[p]
        idx = extract_num(tc, "index")
        if (idx == "") continue
        idx = idx + 0
        if (idx > tc_max) tc_max = idx

        tc_id_val = extract_str(tc, "id")
        func_raw = extract_value(tc, "function")
        name = extract_str(func_raw, "name")
        args = extract_json_string(func_raw, "arguments")

        if (tc_id_val != "" && name != "") {
            tc_name[idx] = name
            tc_id[idx] = tc_id_val
        }
        if (args != "" && args != "null") {
            if (idx in tc_args) tc_args[idx] = tc_args[idx] args
            else tc_args[idx] = args
        }
    }
}

function _emit_tools(    idx, escaped_args) {
    for (idx = 0; idx <= tc_max; idx++) {
        if (!(idx in tc_args) || tc_args[idx] == "") continue

        # content_block_start
        printf "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":%d,\"content_block\":{\"type\":\"tool_use\",\"id\":\"%s\",\"name\":\"%s\",\"input\":{}}}\n\n", block_idx, tc_id[idx], tc_name[idx]

        # content_block_delta — arguments are already JSON-escaped from extract_json_string
        printf "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":%d,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"%s\"}}\n\n", block_idx, tc_args[idx]

        # content_block_stop
        printf "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":%d}\n\n", block_idx

        block_idx++
        tc_args[idx] = ""
    }
    fflush()
}
