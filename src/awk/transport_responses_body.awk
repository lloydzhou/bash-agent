# transport_responses_body.awk — Convert Claude Messages request to DeepSeek Responses request
# Input: Claude request JSON on stdin
# Output: Responses API request JSON on stdout
# Requires: awk -f json.awk -f transport_responses_body.awk

{ line = line $0 }

END {
    model = extract_str(line, "model")
    max_tokens = extract_num(line, "max_tokens")
    system_val = extract_value(line, "system")
    thinking_val = extract_value(line, "thinking")
    output_config_val = extract_value(line, "output_config")
    messages_raw = extract_value(line, "messages")
    tools_raw = extract_value(line, "tools")

    input = convert_messages(messages_raw)
    tools = convert_tools(tools_raw)

    result = "{\"model\":\"" escape_json_string(model) "\",\"input\":" input
    if (max_tokens != "") result = result ",\"max_output_tokens\":" max_tokens
    result = result ",\"stream\":true"
    if (system_val != "" && system_val != "null") result = result ",\"instructions\":" system_val

    thinking_type = ""
    if (thinking_val != "" && thinking_val != "null" && thinking_val != "{}") thinking_type = extract_str(thinking_val, "type")
    if (thinking_type == "adaptive" || thinking_type == "enabled") {
        effort = "high"
        if (output_config_val != "" && output_config_val != "null" && output_config_val != "{}") {
            configured_effort = extract_str(output_config_val, "effort")
            if (configured_effort != "") effort = configured_effort
        }
        result = result ",\"reasoning\":{\"effort\":\"" escape_json_string(effort) "\"}"
    }
    if (tools != "[]") result = result ",\"tools\":" tools
    result = result "}"
    printf "%s", result
}

# Convert stored Claude conversation to the heterogeneous Responses input array.
function convert_messages(msgs_json,    n, msgs, i, converted, result) {
    if (msgs_json == "" || msgs_json == "null" || msgs_json == "[]") return "[]"
    n = split_top_level_objects(msgs_json, msgs)
    result = "["
    for (i = 1; i <= n; i++) {
        converted = convert_message(msgs[i])
        if (converted == "") continue
        if (result != "[") result = result ","
        result = result converted
    }
    return result "]"
}

function convert_message(msg,    role, content) {
    role = extract_str(msg, "role")
    content = extract_value(msg, "content")
    if (role == "assistant") return convert_assistant(content)
    if (role == "user") return convert_user(content)
    return "{\"role\":\"" escape_json_string(role) "\",\"content\":" content "}"
}

function convert_user(content,    n, blocks, i, block, result, type, value, call_id) {
    if (substr(content, 1, 1) != "[") return "{\"role\":\"user\",\"content\":" content "}"
    n = split_top_level_objects(content, blocks)
    result = ""
    for (i = 1; i <= n; i++) {
        block = blocks[i]
        type = extract_str(block, "type")
        if (type == "tool_result") {
            call_id = extract_str(block, "tool_use_id")
            value = extract_value(block, "content")
            if (substr(value, 1, 1) == "\"") value = unescape_json_string(substr(value, 2, length(value) - 2))
            if (result != "") result = result ","
            result = result "{\"type\":\"function_call_output\",\"call_id\":\"" escape_json_string(call_id) "\",\"output\":\"" escape_json_string(value) "\"}"
        } else if (type == "text") {
            value = extract_value(block, "text")
            if (result != "") result = result ","
            result = result "{\"role\":\"user\",\"content\":" value "}"
        }
    }
    return result
}

function convert_assistant(content,    n, blocks, i, block, type, value, text, calls, call_id, name, args, result) {
    if (substr(content, 1, 1) != "[") return "{\"role\":\"assistant\",\"content\":" content "}"
    n = split_top_level_objects(content, blocks)
    text = ""
    calls = ""
    for (i = 1; i <= n; i++) {
        block = blocks[i]
        type = extract_str(block, "type")
        if (type == "text") {
            value = extract_value(block, "text")
            if (substr(value, 1, 1) == "\"") value = unescape_json_string(substr(value, 2, length(value) - 2))
            text = text value
        } else if (type == "tool_use") {
            call_id = extract_str(block, "id")
            name = extract_str(block, "name")
            args = extract_value(block, "input")
            if (calls != "") calls = calls ","
            calls = calls "{\"type\":\"function_call\",\"call_id\":\"" escape_json_string(call_id) "\",\"name\":\"" escape_json_string(name) "\",\"arguments\":\"" escape_json_string(args) "\"}"
        }
        # Reasoning blocks are intentionally not replayed: DeepSeek Responses does not
        # accept arbitrary historical reasoning text as an input item.
    }
    result = ""
    if (text != "") result = "{\"role\":\"assistant\",\"content\":\"" escape_json_string(text) "\"}"
    if (calls != "") {
        if (result != "") result = result ","
        result = result calls
    }
    return result
}

function convert_tools(tools_json,    n, defs, i, td, name, desc, params, result) {
    if (tools_json == "" || tools_json == "null" || tools_json == "[]") return "[]"
    n = split_top_level_objects(tools_json, defs)
    result = "["
    for (i = 1; i <= n; i++) {
        td = defs[i]
        name = extract_str(td, "name")
        if (name == "") continue
        desc = extract_str(td, "description")
        params = extract_value(td, "input_schema")
        if (params == "") params = extract_value(td, "parameters")
        if (params == "") params = "{}"
        if (result != "[") result = result ","
        result = result "{\"type\":\"function\",\"name\":\"" escape_json_string(name) "\",\"description\":\"" escape_json_string(desc) "\",\"parameters\":" params "}"
    }
    return result "]"
}
