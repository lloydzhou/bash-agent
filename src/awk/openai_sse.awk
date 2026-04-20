# openai_sse.awk — OpenAI Chat Completions SSE stream parser
# Input: SSE lines (data:)
# Output: Unified protocol via emit1/emit/emit_flush
# Requires: awk -f json.awk -f protocol.awk -f todo_protocol.awk -f openai_sse.awk

BEGIN {
    stop_reason = ""
    tc_count = 0
    tc_max_index = -1
    input_tokens = 0
    output_tokens = 0
    cache_input_tokens = 0
    saw_text = 0
    pending_stop_reason = ""
}

/^:/ { next }

# Pass through ERROR lines from http_stream.awk
/^ERROR:/ { emit1("ERROR"); emit(substr($0, 7)); emit_flush(); next }

# Handle curl retry: reset all parser state for new response
/^RETRY:/ {
    stop_reason = ""
    tc_count = 0
    tc_max_index = -1
    input_tokens = 0
    output_tokens = 0
    cache_input_tokens = 0
    saw_text = 0
    pending_stop_reason = ""
    for (idx in tool_name) delete tool_name[idx]
    for (idx in tool_id) delete tool_id[idx]
    for (idx in tool_args) delete tool_args[idx]
    emit1("RETRY"); emit_flush()
    next
}

/^data: \[DONE\]/ {
    emit_pending_tool_calls()
    if (stop_reason == "") stop_reason = "done"
    pending_input_tokens = input_tokens
    pending_output_tokens = output_tokens
    pending_cache_tokens = cache_input_tokens
    pending_stop_reason = stop_reason
    next
}

/^data: / {
    json = substr($0, 7)

    fr = extract_str(json, "finish_reason", 1)
    if (fr != "" && fr != "null") stop_reason = fr

    content = extract_json_string(json, "content", 1)
    if (content != "") {
        content = unescape_json_string(content)
        if (!saw_text) {
            sub(/^\n+/, "", content)
            sub(/^\r+/, "", content)
        }
        if (content != "") {
            saw_text = 1
            emit1("TEXT"); emit(content); emit_flush()
        }
    }

    reasoning = extract_json_string(json, "reasoning_content", 1)
    if (reasoning == "") reasoning = extract_json_string(json, "reasoning", 1)
    if (reasoning != "") {
        reasoning = unescape_json_string(reasoning)
        if (reasoning != "") {
            emit1("THINKING"); emit(reasoning); emit_flush()
        }
    }

    if (extract_value(json, "tool_calls", 1) != "") {
        parse_tool_calls(json)
    }
    if (fr == "tool_calls") emit_pending_tool_calls()

    pt = extract_num(json, "prompt_tokens", 1)
    if (pt != "") input_tokens = pt
    ct = extract_num(json, "completion_tokens", 1)
    if (ct != "") output_tokens = ct
    crt = extract_num(json, "cached_tokens", 1)
    if (crt == "") crt = extract_num(json, "cache_read_input_tokens", 1)
    if (crt != "") cache_input_tokens = crt

    next
}

function parse_tool_calls(json,    arr, count, p, tc, idx, tc_id, func_raw, name, args) {
    arr = extract_value(json, "tool_calls", 1)
    if (arr == "" || substr(arr, 1, 1) != "[") return
    count = split_top_level_objects(arr, OPENAI_TOOL_CALLS)
    for (p = 1; p <= count; p++) {
        tc = OPENAI_TOOL_CALLS[p]
        idx = extract_num(tc, "index")
        if (idx == "") continue
        if ((idx + 0) > tc_max_index) tc_max_index = idx + 0
        tc_id = extract_str(tc, "id")
        func_raw = extract_value(tc, "function")
        name = extract_str(func_raw, "name")
        args = extract_json_string(func_raw, "arguments")

        if (tc_id != "" && name != "") {
            tool_name[idx] = name
            tool_id[idx] = tc_id
            tool_args[idx] = args
        } else if (args != "") {
            if (idx in tool_args) {
                tool_args[idx] = tool_args[idx] args
            } else {
                tool_args[idx] = args
            }
        }
    }
}

function emit_pending_tool_calls(    idx) {
    for (idx = 0; idx <= tc_max_index; idx++) {
        if (tool_args[idx] == "") continue
        emit_tool_call_record(tool_name[idx], tool_id[idx], unescape_json_string(tool_args[idx]))
        tool_args[idx] = ""
    }
}

END {
    if (pending_stop_reason != "") {
        emit1("USAGE"); emit(pending_input_tokens + 0); emit(pending_output_tokens + 0); emit(pending_cache_tokens + 0); emit_flush()
        emit1("STOP"); emit(pending_stop_reason); emit_flush()
    }
}
