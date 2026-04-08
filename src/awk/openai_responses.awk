# openai_responses.awk — OpenAI Responses API SSE stream parser
# Input: SSE lines (data:)
# Output: Unified protocol (TEXT:, TOOL_START:, TOOL_INPUT:, USAGE:, STOP:, ERROR:)
# Requires: awk -f common.awk -f openai_responses.awk

BEGIN {
    stop_reason = ""
    block_type = ""
    tool_name = ""
    tool_id = ""
    partial_args = ""
    input_tokens = 0
    output_tokens = 0
}

/^:/ { next }

# Pass through ERROR lines from _stream_curl
/^ERROR:/ { print; fflush(); next }

/^data: / {
    json = substr($0, 7)

    # Detect event type from the JSON type field
    if (json ~ /"type":"response.output_item.added"/ || json ~ /"type\":\"response.output_item.added\"/) {
        # New content block starting
        if (json ~ /"type":"function_call"/ || json ~ /"type\":\"function_call\"/) {
            block_type = "tool"
            tool_name = extract_str(json, "name")
            tool_id = extract_str(json, "call_id")
            if (tool_id == "") tool_id = extract_str(json, "id")
            partial_args = ""
            printf "TOOL_START:%s:%s\n", tool_name, tool_id
            fflush()
        } else {
            block_type = "text"
        }
    }
    else if (json ~ /"type":"response.content_part.added"/ || json ~ /"type\":\"response.content_part.added\"/) {
        block_type = "text"
    }
    else if (json ~ /"type":"response.output_text.delta"/ || json ~ /"type\":\"response.output_text.delta\"/) {
        text = extract_escaped(json, "delta")
        if (text != "") {
            printf "TEXT:%s\n", text
            fflush()
        }
    }
    else if (json ~ /"type":"response.function_call_arguments.delta"/ || json ~ /"type\":\"response.function_call_arguments.delta\"/) {
        partial_args = partial_args extract_escaped(json, "delta")
    }
    else if (json ~ /"type":"response.function_call_arguments.done"/ || json ~ /"type\":\"response.function_call_arguments.done\"/) {
        args = extract_str(json, "arguments")
        if (args == "") args = partial_args
        args = unescape_json_string(args)
        printf "TOOL_INPUT:%s\n", args
        fflush()
        partial_args = ""
        block_type = ""
    }
    else if (json ~ /"type":"response.completed"/ || json ~ /"type\":\"response.completed\"/) {
        sr = extract_str(json, "status")
        if (sr == "completed") stop_reason = "end_turn"
        else stop_reason = sr

        # Extract usage
        it = extract_num(json, "input_tokens")
        if (it != "") input_tokens = it
        ot = extract_num(json, "output_tokens")
        if (ot != "") output_tokens = ot

        printf "USAGE:in=%d,out=%d\n", input_tokens, output_tokens
        fflush()
        printf "STOP:%s\n", stop_reason
        fflush()
    }
    else if (json ~ /"type":"error"/ || json ~ /"type\":\"error\"/) {
        msg = extract_str(json, "message")
        printf "ERROR:%s\n", msg
        fflush()
    }

    next
}

