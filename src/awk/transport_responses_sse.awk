# transport_responses_sse.awk — Convert Responses API SSE to Claude Messages SSE
# Input: Responses API SSE lines from http_stream.awk
# Output: Claude-compatible SSE event/data pairs
# Requires: awk -f json.awk -f transport_responses_sse.awk

BEGIN {
    event = ""
    state = "idle"
    block_idx = 0
    saw_text = 0
    completed = 0
    input_tokens = 0
    output_tokens = 0
    cache_read_input_tokens = 0
    cache_creation_input_tokens = 0
    tool_count = 0
    split("", tool_order)
    split("", tool_name)
    split("", tool_call_id)
    split("", tool_args)
    split("", tool_emitted)
    split("", item_to_index)
}

/^:/ { next }
/^ERROR:/ { print; fflush(); next }
/^RETRY:/ { _reset(); print; fflush(); next }
/^event: / { event = substr($0, 8); next }

/^data: / {
    json = substr($0, 7)
    if (event == "response.reasoning_text.delta") {
        delta = extract_str(json, "delta")
        if (delta != "") {
            _switch_block("thinking")
            _emit_thinking_delta(block_idx, delta)
        }
    }
    else if (event == "response.output_text.delta") {
        delta = extract_str(json, "delta")
        if (delta != "") {
            if (!saw_text) {
                sub(/^\n+/, "", delta)
                sub(/^\r+/, "", delta)
            }
            if (delta != "") {
                saw_text = 1
                _switch_block("text")
                _emit_text_delta(block_idx, delta)
            }
        }
    }
    else if (event == "response.output_item.added") {
        _record_tool_item(json)
    }
    else if (event == "response.function_call_arguments.delta") {
        _record_tool_arguments(json)
    }
    else if (event == "response.output_item.done") {
        _record_tool_item(json)
    }
    else if (event == "response.completed") {
        response = extract_value(json, "response")
        if (response == "") response = json
        _record_usage(response)
        _close_block()
        _emit_pending_tools()
        _emit_terminal("end_turn")
        completed = 1
    }
    else if (event == "response.incomplete" || event == "response.failed" || event == "error") {
        response = extract_value(json, "response")
        if (response == "") response = json
        _record_usage(response)
        error_obj = extract_value(response, "error")
        message = extract_str(error_obj, "message", 1)
        if (message == "") message = extract_str(response, "message", 1)
        if (message == "") message = extract_str(response, "reason", 1)
        if (message == "") message = (event == "response.incomplete" ? "Response incomplete" : (event == "error" ? "Stream error" : "Response failed"))
        _close_block()
        printf "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"%s\"}}\n\n", escape_json_string(message)
        _emit_terminal("error")
        completed = 1
    }
    next
}

END {
    if (!completed) {
        _close_block()
        printf "event: error\ndata: {\"type\":\"error\",\"error\":{\"message\":\"Stream interrupted (no response.completed received)\"}}\n\n"
        _emit_terminal("error")
    }
}

function _reset() {
    event = ""
    state = "idle"
    block_idx = 0
    saw_text = 0
    completed = 0
    input_tokens = 0
    output_tokens = 0
    cache_read_input_tokens = 0
    cache_creation_input_tokens = 0
    tool_count = 0
    split("", tool_order)
    split("", tool_name)
    split("", tool_call_id)
    split("", tool_args)
    split("", tool_emitted)
    split("", item_to_index)
}

function _tool_index(json,    idx, item_id, item) {
    idx = extract_num(json, "output_index")
    item = extract_value(json, "item")
    item_id = extract_str(json, "item_id")
    if (item_id == "" && item != "") item_id = extract_str(item, "id")
    if (idx == "" && item_id != "" && item_id in item_to_index) idx = item_to_index[item_id]
    if (idx == "") return ""
    if (item_id != "") item_to_index[item_id] = idx
    return idx
}

function _record_tool_item(json,    item, idx, typ, name, call_id, args, item_id) {
    item = extract_value(json, "item")
    if (item == "") return
    typ = extract_str(item, "type")
    if (typ != "function_call") return
    idx = _tool_index(json)
    if (idx == "") return
    if (!(idx in tool_order)) {
        tool_order[tool_count] = idx
        tool_count++
    }
    name = extract_str(item, "name")
    call_id = extract_str(item, "call_id")
    args = extract_json_string(item, "arguments")
    if (name != "") tool_name[idx] = name
    if (call_id != "") tool_call_id[idx] = call_id
    if (args != "" && args != "null") tool_args[idx] = args
}

function _record_tool_arguments(json,    idx, delta, item_id) {
    idx = _tool_index(json)
    if (idx == "") return
    if (!(idx in tool_order)) {
        tool_order[tool_count] = idx
        tool_count++
    }
    delta = extract_json_string(json, "delta")
    if (delta != "" && delta != "null") tool_args[idx] = tool_args[idx] delta
}

function _record_usage(response,    usage, total_input, cached, input_details, nested_cached) {
    usage = extract_value(response, "usage")
    if (usage == "") usage = response
    total_input = extract_num(usage, "input_tokens")
    output_tokens = extract_num(usage, "output_tokens")
    cached = extract_num(usage, "cached_tokens")
    input_details = extract_value(usage, "input_tokens_details")
    if (input_details != "") {
        nested_cached = extract_num(input_details, "cached_tokens")
        if (nested_cached != "" && nested_cached != 0) cached = nested_cached
    }
    if (cached == "") cached = 0
    cache_read_input_tokens = cached
    if (total_input != "") input_tokens = total_input - cached
    if (input_tokens < 0) input_tokens = 0
    if (output_tokens == "") output_tokens = 0
}

function _switch_block(kind) {
    if (state == kind) return
    _close_block()
    printf "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":%d,\"content_block\":{\"type\":\"%s\",\"%s\":\"\"}}\n\n", block_idx, kind, kind
    state = kind
    fflush()
}

function _close_block() {
    if (state == "text" || state == "thinking") {
        printf "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":%d}\n\n", block_idx
        block_idx++
        state = "idle"
        fflush()
    }
}

function _emit_text_delta(idx, text) {
    printf "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":%d,\"delta\":{\"type\":\"text_delta\",\"text\":\"%s\"}}\n\n", idx, escape_json_string(text)
    fflush()
}

function _emit_thinking_delta(idx, text) {
    printf "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":%d,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"%s\"}}\n\n", idx, escape_json_string(text)
    fflush()
}

function _emit_pending_tools(    pos, idx, args, encoded_args) {
    for (pos = 0; pos < tool_count; pos++) {
        idx = tool_order[pos]
        if (tool_emitted[idx]) continue
        if (tool_name[idx] == "" || tool_call_id[idx] == "") continue
        args = tool_args[idx]
        if (args == "") args = "{}"
        # args 是 Responses 转义的 JSON 字符串表示；先还原原始 JSON，
        # 再为合成 SSE 重新编码。
        encoded_args = escape_json_string(unescape_json_string(args))
        printf "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":%d,\"content_block\":{\"type\":\"tool_use\",\"id\":\"%s\",\"name\":\"%s\",\"input\":{}}}\n\n", block_idx, escape_json_string(tool_call_id[idx]), escape_json_string(tool_name[idx])
        printf "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":%d,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"%s\"}}\n\n", block_idx, encoded_args
        printf "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":%d}\n\n", block_idx
        tool_emitted[idx] = 1
        block_idx++
    }
    fflush()
}

function _emit_terminal(default_stop,    stop) {
    stop = default_stop
    if (default_stop == "end_turn" && tool_count > 0) stop = "tool_use"
    printf "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"%s\"},\"usage\":{\"output_tokens\":%d,\"input_tokens\":%d,\"cache_read_input_tokens\":%d,\"cache_creation_input_tokens\":%d}}\n\n", stop, output_tokens + 0, input_tokens + 0, cache_read_input_tokens + 0, cache_creation_input_tokens + 0
    printf "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
    fflush()
}
