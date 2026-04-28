# claude_sse.awk — Anthropic Claude SSE stream parser
# Input: SSE lines (event:, data:)
# Output: Unified protocol via emit1/emit/emit_flush
# Requires: awk -v verbose=true/false -f json.awk -f protocol.awk -f todo_protocol.awk -f claude_sse.awk

BEGIN {
    event = ""
    block_type = ""
    tool_name = ""
    tool_id = ""
    partial_json = ""
    stop_reason = ""
    input_tokens = 0
    output_tokens = 0
    cache_read_input_tokens = 0
    cache_creation_input_tokens = 0
    pending_stop_reason = ""
}

/^:/ { next }

# Pass through ERROR lines from http_stream.awk
/^ERROR:/ { emit1("ERROR"); emit(substr($0, 7)); emit_flush(); next }

# Handle curl retry: reset all parser state for new response
/^RETRY:/ {
    event = ""
    block_type = ""
    tool_name = ""
    tool_id = ""
    partial_json = ""
    stop_reason = ""
    input_tokens = 0
    output_tokens = 0
    cache_read_input_tokens = 0
    cache_creation_input_tokens = 0
    pending_stop_reason = ""
    emit1("RETRY"); emit_flush()
    next
}

/^event: / {
    event = substr($0, 8)
    next
}

/^data: / {
    json = substr($0, 7)
    if (verbose == "true") printf "[sse-debug] event=[%s] data=[%.200s]\n", event, json > "/dev/stderr"

    if (event == "content_block_start") {
        block_json = extract_value(json, "content_block")
        block_kind = extract_str(block_json, "type")
        if (block_kind == "text") {
            block_type = "text"
        } else if (block_kind == "thinking") {
            block_type = "thinking"
        } else if (block_kind == "tool_use") {
            block_type = "tool"
            tool_name = extract_str(block_json, "name")
            tool_id = extract_str(block_json, "id")
            partial_json = ""
        }
    }
    else if (event == "content_block_delta") {
        if (block_type == "text") {
            text = extract_str(json, "text", 1)
            if (text != "") {
                emit1("TEXT"); emit(text); emit_flush()
            }
        }
        else if (block_type == "thinking") {
            text = extract_str(json, "thinking", 1)
            if (text != "") {
                emit1("THINKING"); emit(text); emit_flush()
            }
        }
        else if (block_type == "tool") {
            partial_json = partial_json extract_json_string(json, "partial_json", 1)
        }
    }
    else if (event == "content_block_stop") {
        if (block_type == "tool") {
            emit_tool_call_record(tool_name, tool_id, unescape_json_string(partial_json))
        }
        block_type = ""
    }
    else if (event == "message_delta") {
        sr = extract_str(json, "stop_reason", 1)
        if (sr != "") stop_reason = sr
        it = extract_num(json, "input_tokens", 1)
        if (it != "") input_tokens = it
        ot = extract_num(json, "output_tokens", 1)
        if (ot != "") output_tokens = ot
        crt = extract_num(json, "cache_read_input_tokens", 1)
        if (crt != "") cache_read_input_tokens = crt
        cct = extract_num(json, "cache_creation_input_tokens", 1)
        if (cct != "") cache_creation_input_tokens = cct
    }
    else if (event == "message_start") {
        it = extract_num(json, "input_tokens", 1)
        if (it != "") input_tokens = it
        crt = extract_num(json, "cache_read_input_tokens", 1)
        if (crt != "") cache_read_input_tokens = crt
        cct = extract_num(json, "cache_creation_input_tokens", 1)
        if (cct != "") cache_creation_input_tokens = cct
    }
    else if (event == "message_stop") {
        pending_input_tokens = input_tokens
        pending_output_tokens = output_tokens
        pending_cache_read_tokens = cache_read_input_tokens
        pending_cache_creation_tokens = cache_creation_input_tokens
        pending_stop_reason = stop_reason
    }
    else if (event == "error") {
        msg = extract_str(json, "message", 1)
        emit1("ERROR"); emit(msg); emit_flush()
    }

    next
}

END {
    if (pending_stop_reason != "") {
        emit1("USAGE"); emit(pending_input_tokens + 0); emit(pending_output_tokens + 0); emit(pending_cache_read_tokens + 0); emit(pending_cache_creation_tokens + 0); emit_flush()
        emit1("STOP"); emit(pending_stop_reason); emit_flush()
    }
}

