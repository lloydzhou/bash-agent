# claude_sse.awk — Anthropic Claude SSE stream parser
# Input: SSE lines (event:, data:)
# Output: Unified protocol (TEXT:, TOOL_START:, TOOL_INPUT:, USAGE:, STOP:, ERROR:)
# Requires: awk -v verbose=true/false -f common.awk -f claude_sse.awk

BEGIN {
    event = ""
    block_type = ""
    tool_name = ""
    tool_id = ""
    partial_json = ""
    stop_reason = ""
    input_tokens = 0
    output_tokens = 0
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
            tool_name = extract_str(json, "name")
            tool_id = extract_str(json, "id")
            partial_json = ""
            printf "TOOL_START:%s:%s\n", tool_name, tool_id
            fflush()
        }
    }
    else if (event == "content_block_delta") {
        if (block_type == "text") {
            text = extract_escaped(json, "text")
            if (text != "") {
                printf "TEXT:%s\n", text
                fflush()
            }
        }
        else if (block_type == "tool") {
            partial_json = partial_json extract_escaped(json, "partial_json")
        }
    }
    else if (event == "content_block_stop") {
        if (block_type == "tool") {
            # Decode JSON string escapes so TOOL_INPUT is valid JSON
            gsub(/\\["]/, "\"", partial_json)
            printf "TOOL_INPUT:%s\n", partial_json
            fflush()
        }
        block_type = ""
    }
    else if (event == "message_delta") {
        sr = extract_str(json, "stop_reason")
        if (sr != "") stop_reason = sr
        # Extract usage (both input and output tokens may appear here)
        it = extract_num(json, "input_tokens")
        if (it != "") input_tokens = it
        ot = extract_num(json, "output_tokens")
        if (ot != "") output_tokens = ot
    }
    else if (event == "message_start") {
        it = extract_num_from_nested(json, "input_tokens")
        if (it != "") input_tokens = it
    }
    else if (event == "message_stop") {
        printf "USAGE:in=%d,out=%d\n", input_tokens, output_tokens
        fflush()
        printf "STOP:%s\n", stop_reason
        fflush()
    }
    else if (event == "error") {
        msg = extract_str(json, "message")
        printf "ERROR:%s\n", msg
        fflush()
    }

    next
}

# Extract number from nested JSON (same as extract_num, kept for clarity)
function extract_num_from_nested(json, key,    pos, rest, i, c, result) {
    pos = find_key(json, key)
    if (pos == 0) return ""
    rest = substr(json, pos)
    result = ""
    i = 1
    while (i <= length(rest)) {
        c = substr(rest, i, 1)
        if (c >= "0" && c <= "9") {
            result = result c
            i++
        } else {
            break
        }
    }
    return result
}
