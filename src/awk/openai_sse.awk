# openai_sse.awk — OpenAI Chat Completions SSE stream parser
# Input: SSE lines (data:)
# Output: Unified protocol (TEXT:, TOOL_START:, TOOL_INPUT:, USAGE:, STOP:, ERROR:)
# Requires: awk -f common.awk -f openai_sse.awk

BEGIN {
    stop_reason = ""
    # Track tool calls: index -> {id, name, arguments}
    tc_count = 0
    input_tokens = 0
    output_tokens = 0
}

/^:/ { next }

# Pass through ERROR lines from _stream_curl
/^ERROR:/ { print; fflush(); next }

/^data: \[DONE\]/ {
    if (stop_reason == "") stop_reason = "done"
    printf "USAGE:in=%d,out=%d\n", input_tokens, output_tokens
    fflush()
    printf "STOP:%s\n", stop_reason
    fflush()
    next
}

/^data: / {
    json = substr($0, 7)

    # Extract finish_reason
    fr = extract_str(json, "finish_reason")
    if (fr != "" && fr != "null") stop_reason = fr

    # Extract text content from delta
    content = extract_json_string(json, "content")
    if (content != "") {
        printf "TEXT:%s\n", content
        fflush()
    }

    # Extract tool calls from delta
    # Format: "tool_calls":[{"index":0,"id":"call_xxx","type":"function","function":{"name":"func","arguments":"{...}"}}]
    if (json ~ /"tool_calls"/) {
        parse_tool_calls(json)
    }

    # Extract usage if present
    pt = extract_num(json, "prompt_tokens")
    if (pt != "") input_tokens = pt
    ct = extract_num(json, "completion_tokens")
    if (ct != "") output_tokens = ct

    next
}

function parse_tool_calls(json,    pos, end, tc_json) {
    # Find "tool_calls":[ and extract the array content
    pos = index(json, "\"tool_calls\":[")
    if (pos == 0) return

    # Simple extraction: find each tool call object
    # We look for "index" markers
    gsub(/\},\{/, "}\n{", json)
    split(json, parts, "\n")

    for (p = 1; p <= length(parts); p++) {
        tc = parts[p]

        if (tc !~ /"index"/) continue

        idx = extract_num(tc, "index")
        tc_id = extract_str(tc, "id")
        name = extract_str(tc, "name")
        args = extract_json_string(tc, "arguments")

        # If this is a new tool call (has id and name)
        if (tc_id != "" && name != "") {
            printf "TOOL_START:%s:%s\n", name, tc_id
            fflush()
            tool_args[idx] = args
        } else if (args != "") {
            # Continuation of arguments
            if (idx in tool_args) {
                tool_args[idx] = tool_args[idx] args
            } else {
                tool_args[idx] = args
            }
        }

        # OpenAI streams function.arguments as an escaped JSON string. Accumulate the
        # string fragments first, then decode that outer string once before emitting
        # TOOL_INPUT as JSON object text.
        # Check if arguments are complete (finish_reason = tool_calls or block end)
        if (fr != "" || tc ~ /\}\]/) {
            if (idx in tool_args && tool_args[idx] != "") {
                printf "TOOL_INPUT:%s\n", unescape_json_string(tool_args[idx])
                fflush()
                tool_args[idx] = ""
            }
        }
    }
}
