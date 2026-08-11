# transport_openai_body.awk — Convert Claude Messages API request to OpenAI Chat Completions request
# Input:  Claude request JSON on stdin
# Output: OpenAI request JSON on stdout
# Requires: awk -f json.awk -f transport_openai_body.awk

{ line = line $0 }

END {
    # Extract top-level fields from Claude request body
    model      = extract_str(line, "model")
    max_tokens = extract_num(line, "max_tokens")
    system_val = extract_value(line, "system")
    thinking_val = extract_value(line, "thinking")
    output_config_val = extract_value(line, "output_config")
    messages_raw = extract_value(line, "messages")
    tools_raw  = extract_value(line, "tools")

    # 1. Convert messages
    openai_msgs = convert_messages(messages_raw)

    # 2. System prompt -> system message (prepend to messages array)
    if (system_val != "" && system_val != "null") {
        sys_msg = "{\"role\":\"system\",\"content\":" system_val "}"
        if (openai_msgs == "[]") {
            openai_msgs = "[" sys_msg "]"
        } else {
            openai_msgs = "[" sys_msg "," substr(openai_msgs, 2)
        }
    }

    # 3. Convert tools
    openai_tools = ""
    if (tools_raw != "" && tools_raw != "null" && tools_raw != "[]") {
        openai_tools = convert_tools(tools_raw)
    }

    # 4. Build output JSON
    result = "{\"model\":\"" model "\",\"max_tokens\":" max_tokens ",\"stream\":true,\"stream_options\":{\"include_usage\":true}"

    # thinking adaptive/enabled -> OpenAI enabled + reasoning_effort
    thinking_type = ""
    if (thinking_val != "" && thinking_val != "null" && thinking_val != "{}") {
        thinking_type = extract_str(thinking_val, "type")
    }
    if (thinking_type == "adaptive" || thinking_type == "enabled") {
        result = result ",\"thinking\":{\"type\":\"enabled\"}"
        effort_val = ""
        if (output_config_val != "" && output_config_val != "null" && output_config_val != "{}") {
            effort_val = extract_str(output_config_val, "effort")
        }
        if (effort_val != "" && effort_val != "null") {
            result = result ",\"reasoning_effort\":\"" effort_val "\""
        } else {
            result = result ",\"reasoning_effort\":\"high\""
        }
    }

    if (openai_tools != "" && openai_tools != "[]") {
        result = result ",\"tools\":" openai_tools
    }

    result = result ",\"messages\":" openai_msgs "}"

    printf "%s", result
}

# --- Message conversion ---

function convert_messages(msgs_json,    inner, n, msgs, result, i, msg, role, content_val, has_tr) {
    if (msgs_json == "" || msgs_json == "null" || msgs_json == "[]") return "[]"
    n = split_top_level_objects(msgs_json, msgs)
    result = "["
    for (i = 1; i <= n; i++) {
        msg = msgs[i]
        role = extract_str(msg, "role")
        has_tr = 0

        if (role == "user") {
            content_val = extract_value(msg, "content")
            if (substr(content_val, 1, 1) == "[") {
                has_tr = _content_has_tool_result(content_val)
            }
        }

        if (i > 1) result = result ","
        if (role == "assistant") {
            result = result _convert_assistant_msg(msg)
        } else if (has_tr) {
            result = result _convert_tool_result_msg(msg)
        } else {
            result = result msg
        }
    }
    result = result "]"
    return result
}

function _convert_assistant_msg(json,    content_val, text_parts, reasoning, tool_parts, n, i, block, btype, t, tid, tname, tinput, result_msg) {
    content_val = extract_value(json, "content")
    text_parts = ""
    tool_parts = ""
    reasoning = ""

    if (substr(content_val, 1, 1) == "[") {
        n = split_top_level_objects(content_val, _BODY_BLKS)
        for (i = 1; i <= n; i++) {
            block = _BODY_BLKS[i]
            btype = extract_str(block, "type")
            if (btype == "thinking") {
                t = extract_value(block, "thinking")
                if (substr(t, 1, 1) == "\"") t = substr(t, 2, length(t) - 2)
                reasoning = unescape_json_string(t)
            } else if (btype == "text") {
                t = extract_value(block, "text")
                if (substr(t, 1, 1) == "\"") t = substr(t, 2, length(t) - 2)
                text_parts = text_parts unescape_json_string(t)
            } else if (btype == "tool_use") {
                tid = extract_str(block, "id")
                tname = extract_str(block, "name")
                tinput = extract_value(block, "input")
                tool_parts = tool_parts "{\"id\":\"" tid "\",\"type\":\"function\",\"function\":{\"name\":\"" tname "\",\"arguments\":\"" escape_json_string(tinput) "\"}},"
            }
        }
    } else {
        if (substr(content_val, 1, 1) == "\"") {
            text_parts = unescape_json_string(substr(content_val, 2, length(content_val) - 2))
        } else {
            text_parts = content_val
        }
    }

    result_msg = "{\"role\":\"assistant\""
    result_msg = result_msg ",\"reasoning_content\":\"" escape_json_string(reasoning) "\""
    result_msg = result_msg ",\"content\":\"" escape_json_string(text_parts) "\""
    if (tool_parts != "") {
        tool_parts = substr(tool_parts, 1, length(tool_parts) - 1)
        result_msg = result_msg ",\"tool_calls\":[" tool_parts "]"
    }
    result_msg = result_msg "}"
    return result_msg
}

function _convert_tool_result_msg(json,    content_val, n, i, block, tid, rc, msgs) {
    content_val = extract_value(json, "content")
    msgs = ""
    if (substr(content_val, 1, 1) == "[") {
        n = split_top_level_objects(content_val, _BODY_BLKS)
        for (i = 1; i <= n; i++) {
            block = _BODY_BLKS[i]
            if (extract_str(block, "type") == "tool_result") {
                tid = extract_str(block, "tool_use_id")
                rc = extract_value(block, "content")
                if (substr(rc, 1, 1) == "\"") {
                    rc = unescape_json_string(substr(rc, 2, length(rc) - 2))
                }
                if (msgs != "") msgs = msgs ","
                msgs = msgs "{\"role\":\"tool\",\"tool_call_id\":\"" tid "\",\"content\":\"" escape_json_string(rc) "\"}"
            }
        }
    }
    return msgs
}

function _content_has_tool_result(content_val,    n, i) {
    if (substr(content_val, 1, 1) != "[") return 0
    n = split_top_level_objects(content_val, _BODY_BLKS)
    for (i = 1; i <= n; i++) {
        if (extract_str(_BODY_BLKS[i], "type") == "tool_result") return 1
    }
    return 0
}

# --- Tool conversion ---

function convert_tools(tools_json,    n, tdefs, result, i, td, name, desc, params) {
    if (tools_json == "" || tools_json == "null" || tools_json == "[]") return "[]"
    n = split_top_level_objects(tools_json, tdefs)
    result = "["
    for (i = 1; i <= n; i++) {
        td = tdefs[i]
        # Already in OpenAI format?
        if (td ~ /"type" *: *"function"/ || td ~ /"type":"function"/) {
            if (i > 1) result = result ","
            result = result td
            continue
        }
        name = extract_str(td, "name")
        desc = extract_str(td, "description")
        params = extract_value(td, "input_schema")
        if (params == "") params = extract_value(td, "parameters")
        if (params == "") params = "{}"
        if (i > 1) result = result ","
        result = result "{\"type\":\"function\",\"function\":{\"name\":\"" escape_json_string(name) "\",\"description\":\"" escape_json_string(desc) "\",\"parameters\":" params "}}"
    }
    result = result "]"
    return result
}
