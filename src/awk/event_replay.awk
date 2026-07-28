# event_replay.awk — Convert events.jsonl lines to RESP wire format
# Usage: awk -f json.awk -f protocol.awk -f event_replay.awk events.jsonl
# Input: one JSON object per line (events.jsonl format)
# Output: RESP wire format messages (consumable by read_message + display_event)
#
# Supports both new format (per-token text/thinking/tool_call/tool_result/stop)
# and legacy format (user_message/assistant_message).

BEGIN {
}

{
    # Extract event type
    _type = extract_str($0, "type")

    # Skip session_start and usage
    if (_type == "session_start" || _type == "usage") next

    # --- New format: per-token events ---

    # user_input → USER_MESSAGE
    if (_type == "user_input") {
        _content = extract_str($0, "content")
        if (_content != "") {
            emit1("USER_MESSAGE")
            emit(_content)
            emit_flush()
        }
        next
    }

    # text (per token) — 直接输出，不累积
    if (_type == "text") {
        _t = extract_str($0, "content")
        if (_t != "") {
            emit1("TEXT")
            emit(_t)
            emit_flush()
        }
        next
    }

    # thinking (per token) — 直接输出，不累积
    if (_type == "thinking") {
        _t = extract_str($0, "content")
        if (_t != "") {
            emit1("THINKING")
            emit(_t)
            emit_flush()
        }
        next
    }

    # tool_call
    if (_type == "tool_call") {
        _tc_name = extract_str($0, "name")
        _tc_id = extract_str($0, "id")
        _tc_input = extract_value($0, "input")
        if (_tc_input == "") _tc_input = "{}"
        protocol_emit_tool_call_record(_tc_name, _tc_id, _tc_input)
        next
    }

    # tool_result
    if (_type == "tool_result") {
        _tr_id = extract_str($0, "tool_use_id")
        _tr_name = extract_str($0, "name")
        _tr_content = extract_str($0, "content")

        # Truncate content to 200 chars for replay to avoid flooding terminal
        if (length(_tr_content) > 200) {
            _tr_content = substr(_tr_content, 1, 200) "..."
        }

        emit1("TOOL_RESULT")
        emit(_tr_id)
        emit(_tr_name)
        emit(_tr_content)
        emit_flush()
        next
    }

    # sub_agent_result
    if (_type == "sub_agent_result") {
        _sid = extract_str($0, "session_id")
        _status = extract_str($0, "status")
        _in = extract_value($0, "input_tokens")
        _out = extract_value($0, "output_tokens")
        _thinking = extract_str($0, "thinking")
        _text = extract_str($0, "text")
        # Escape backslashes and newlines for RESP wire format
        emit1("AGENT_RESULT")
        emit(_sid)
        emit(_status)
        emit(_in)
        emit(_out)
        emit(_thinking)
        emit(_text)
        emit_flush()
        next
    }

    # stop
    if (_type == "stop") {
        # Don't emit STOP for replay — display_event just ensures newline
        next
    }

    # retry
    if (_type == "retry") {
        next
    }

    # error
    if (_type == "error") {
        _msg = extract_str($0, "message")
        emit1("ERROR")
        emit(_msg)
        emit_flush()
        next
    }

    # --- Legacy format ---

    # user_message → USER_MESSAGE
    if (_type == "user_message") {
        _content = extract_str($0, "content")
        emit1("USER_MESSAGE")
        emit(_content)
        emit_flush()
        next
    }

    # assistant_message → TEXT + TOOL_CALL per tool_call
    if (_type == "assistant_message") {
        _text = extract_str($0, "text")
        if (_text != "") {
            emit1("TEXT")
            emit(_text)
            emit_flush()
        }

        # Extract tool_calls array
        _tc_raw = extract_value($0, "tool_calls")
        if (_tc_raw != "" && substr(_tc_raw, 1, 1) == "[") {
            _tc_count = split_top_level_objects(_tc_raw, _tc_blocks)
            for (_i = 1; _i <= _tc_count; _i++) {
                _tc_name = extract_str(_tc_blocks[_i], "name")
                _tc_id = extract_str(_tc_blocks[_i], "id")
                _tc_input = extract_value(_tc_blocks[_i], "input")
                if (_tc_input == "") _tc_input = "{}"
                protocol_emit_tool_call_record(_tc_name, _tc_id, _tc_input)
            }
        }
        next
    }
}

END {
}
