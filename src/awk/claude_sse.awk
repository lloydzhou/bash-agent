# claude_sse.awk — Anthropic Claude SSE stream parser
# Input: SSE lines (event:, data:)
# Output: Unified protocol (TEXT:, TOOL_CALL:, USAGE:, STOP:, ERROR:)
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
    cache_input_tokens = 0
}

/^:/ { next }

# Pass through ERROR lines from _stream_curl
/^ERROR:/ { print; fflush(); next }

/^event: / {
    event = substr($0, 8)
    next
}

/^data: / {
    json = substr($0, 7)
    if (verbose == "true") printf "[sse-debug] event=[%s] data=[%.200s]\n", event, json > "/dev/stderr"

    if (event == "content_block_start") {
        if (json ~ /"type" *: *"text"/ || json ~ /"type":"text"/) {
            block_type = "text"
        } else if (json ~ /"type" *: *"tool_use"/ || json ~ /"type":"tool_use"/) {
            block_type = "tool"
            tool_name = extract_str(json, "name", 1)
            tool_id = extract_str(json, "id", 1)
            partial_json = ""
        }
    }
    else if (event == "content_block_delta") {
        if (block_type == "text") {
            text = extract_str(json, "text", 1)
            if (text != "") {
                printf "TEXT:%s\n", escape_protocol_text(text)
                fflush()
            }
        }
        else if (block_type == "tool") {
            # Claude streams tool input as partial_json, which is itself a JSON string
            # embedded inside the outer SSE JSON payload. Accumulate the escaped string
            # fragments here and decode that outer string exactly once at block stop.
            partial_json = partial_json extract_json_string(json, "partial_json", 1)
        }
    }
    else if (event == "content_block_stop") {
        if (block_type == "tool") {
            emit_tool_call_record(tool_name, tool_id, unescape_json_string(partial_json))
            fflush()
        }
        block_type = ""
    }
    else if (event == "message_delta") {
        sr = extract_str(json, "stop_reason", 1)
        if (sr != "") stop_reason = sr
        # Extract usage (both input and output tokens may appear here)
        it = extract_num(json, "input_tokens", 1)
        if (it != "") input_tokens = it
        ot = extract_num(json, "output_tokens", 1)
        if (ot != "") output_tokens = ot
        crt = extract_num(json, "cache_read_input_tokens", 1)
        if (crt == "") crt = extract_num(json, "cache_creation_input_tokens", 1)
        if (crt != "") cache_input_tokens = crt
    }
    else if (event == "message_start") {
        it = extract_num_from_nested(json, "input_tokens")
        if (it != "") input_tokens = it
        crt = extract_num_from_nested(json, "cache_read_input_tokens")
        if (crt == "") crt = extract_num_from_nested(json, "cache_creation_input_tokens")
        if (crt != "") cache_input_tokens = crt
    }
    else if (event == "message_stop") {
        printf "USAGE:%d\t%d\t%d\n", input_tokens, output_tokens, cache_input_tokens
        fflush()
        printf "STOP:%s\n", stop_reason
        fflush()
    }
    else if (event == "error") {
        msg = extract_str(json, "message", 1)
        printf "ERROR:%s\n", msg
        fflush()
    }

    next
}

# Extract number from nested JSON (kept for call-site clarity)
function extract_num_from_nested(json, key) {
    return extract_num(json, key, 1)
}
