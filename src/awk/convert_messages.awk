# convert_messages.awk — Convert Claude-format messages to OpenAI Chat Completions format
# Input: JSON array of messages (Claude format) on stdin
# Output: JSON array of messages (OpenAI format) on stdout
# Requires: awk -f common.awk -f convert_messages.awk


# Parse content array from an assistant message and convert to OpenAI format.
# Claude: {"role":"assistant","content":[{"type":"text","text":"..."},{"type":"tool_use","id":"...","name":"...","input":{...}}]}
# OpenAI: {"role":"assistant","content":"...","tool_calls":[{"id":"...","type":"function","function":{"name":"...","arguments":"..."}}]}
function convert_assistant_msg(json,    role, content_val, text_parts, tool_parts, n, i, block, btype, t, tid, tname, tinput, reasoning) {
    role = extract_str(json, "role")
    content_val = extract_value(json, "content")

    text_parts = ""
    tool_parts = ""
    reasoning = ""
    n = 0

    # Parse content array: [{...},{...}]
    if (substr(content_val, 1, 1) == "[") {
        # Split content array into blocks
        n = split_top_level_objects(content_val, blocks)
        for (i = 1; i <= n; i++) {
            block = blocks[i]
            btype = extract_str(block, "type")
            if (btype == "thinking") {
                t = extract_value(block, "thinking")
                if (substr(t, 1, 1) == "\"") t = substr(t, 2, length(t) - 2)
                reasoning = unescape_json_string(t)
            } else if (btype == "text") {
                t = extract_value(block, "text")
                # Strip surrounding quotes
                if (substr(t, 1, 1) == "\"") t = substr(t, 2, length(t) - 2)
                text_parts = text_parts unescape_json_string(t)
            } else if (btype == "tool_use") {
                tid = extract_str(block, "id")
                tname = extract_str(block, "name")
                tinput = extract_value(block, "input")
                # OpenAI wants arguments as a string
                tool_parts = tool_parts "{\"id\":\"" tid "\",\"type\":\"function\",\"function\":{\"name\":\"" tname "\",\"arguments\":\"" escape_json_string(tinput) "\"}},"
            }
        }
    } else {
        # Simple string content
        if (substr(content_val, 1, 1) == "\"") {
            text_parts = unescape_json_string(substr(content_val, 2, length(content_val) - 2))
        } else {
            text_parts = content_val
        }
    }

    # Build OpenAI message
    result_msg = "{\"role\":\"assistant\""
    result_msg = result_msg ",\"reasoning_content\":\"" escape_json_string(reasoning) "\""

    result_msg = result_msg ",\"content\":\"" escape_json_string(text_parts) "\""
    if (tool_parts != "") {
        # Remove trailing comma
        tool_parts = substr(tool_parts, 1, length(tool_parts) - 1)
        result_msg = result_msg ",\"tool_calls\":[" tool_parts "]"
    }
    result_msg = result_msg "}"
    return result_msg
}

# Convert a user message with tool_result content to OpenAI role:tool messages
# Claude: {"role":"user","content":[{"type":"tool_result","tool_use_id":"...","content":"..."}]}
# OpenAI: {"role":"tool","tool_call_id":"...","content":"..."}
function convert_tool_result_msg(json,    content_val, n, i, block, tid, result_content, msgs) {
    content_val = extract_value(json, "content")
    msgs = ""
    if (substr(content_val, 1, 1) == "[") {
        n = split_top_level_objects(content_val, blocks)
        for (i = 1; i <= n; i++) {
            block = blocks[i]
            if (extract_str(block, "type") == "tool_result") {
                tid = extract_str(block, "tool_use_id")
                result_content = extract_value(block, "content")
                # Strip quotes if string
                if (substr(result_content, 1, 1) == "\"") {
                    result_content = unescape_json_string(substr(result_content, 2, length(result_content) - 2))
                }
                if (msgs != "") msgs = msgs ","
                msgs = msgs "{\"role\":\"tool\",\"tool_call_id\":\"" tid "\",\"content\":\"" escape_json_string(result_content) "\"}"
            }
        }
    }
    return msgs
}

# Check whether content is a JSON array.
function is_content_array(json,    content_val) {
    content_val = extract_value(json, "content")
    return (substr(content_val, 1, 1) == "[")
}

function content_has_block_type(content_val, want_type,    n, i, block) {
    if (substr(content_val, 1, 1) != "[") return 0
    n = split_top_level_objects(content_val, blocks)
    for (i = 1; i <= n; i++) {
        block = blocks[i]
        if (extract_str(block, "type") == want_type) return 1
    }
    return 0
}

# Accumulate all lines into one string
{ line = line $0 }

# Parse the JSON array of messages
END {
    inner = line
    gsub(/^\[/, "", inner)
    gsub(/\]$/, "", inner)

    n = split_top_level_objects("[" inner "]", msgs)

    result = "["
    for (i = 1; i <= n; i++) {
        msg = msgs[i]

        # Detect message type
        role = extract_str(msg, "role")
        has_tool_result = 0

        if (role == "user" && is_content_array(msg)) {
            content_val = extract_value(msg, "content")
            if (content_has_block_type(content_val, "tool_result")) has_tool_result = 1
        }

        if (i > 1) result = result ","
        if (role == "assistant") {
            result = result convert_assistant_msg(msg)
        } else if (has_tool_result) {
            result = result convert_tool_result_msg(msg)
        } else {
            # Pass through as-is
            result = result msg
        }
    }
    result = result "]"
    printf "%s", result
}
