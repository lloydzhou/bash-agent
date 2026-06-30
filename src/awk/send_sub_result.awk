# send_sub_result.awk — Extract sub-agent result and send AGENT_RESULT via RESP
# Usage: awk -v session_id=... -v status=ok -v stats_file=... -v conv_file=... \
#            -f json.awk -f send_sub_result.awk
# Reads the last assistant message from conv_file, stats from stats_file,
# outputs RESP-formatted AGENT_RESULT message to stdout.
#
# RESP format: *N\r\n$len\r\ndata\r\n...
# Fields: AGENT_RESULT <session_id> <status> <thinking> <text> <in> <out> <cr> <cc> <reqs>

BEGIN {
    thinking = ""
    text = ""

    # 1. Read conversation.jsonl — only for successful runs
    #    When status != "ok" (e.g. fork child failed before producing output),
    #    skip reading to avoid leaking stale assistant content inherited from parent.
    if (status == "ok") {
        while ((getline line < conv_file) > 0) {
            if (line ~ /"role":"assistant"/) last_assistant = line
        }
        close(conv_file)

        if (last_assistant != "") {
            content_raw = extract_value(last_assistant, "content")
            if (content_raw != "") {
                content_raw = json_trim(content_raw)
                n = split_top_level_objects(content_raw, blocks)
                for (i = 1; i <= n; i++) {
                    t = extract_str(blocks[i], "type")
                    if (t == "thinking") {
                        txt = extract_str(blocks[i], "thinking")
                        if (txt != "") thinking = txt
                    } else if (t == "text") {
                        txt = extract_str(blocks[i], "text")
                        if (txt != "") text = txt
                    }
                }
            }
        }
    }

    # 2. Read stats.json — extract token counters + request_count
    _in = 0; _out = 0; _cr = 0; _cc = 0; _reqs = 0
    if ((getline stats_line < stats_file) > 0) {
        close(stats_file)
        v = extract_num(stats_line, "total_input_tokens")
        if (v != "") _in = v + 0
        v = extract_num(stats_line, "total_output_tokens")
        if (v != "") _out = v + 0
        v = extract_num(stats_line, "total_cache_read_tokens")
        if (v != "") _cr = v + 0
        v = extract_num(stats_line, "total_cache_creation_tokens")
        if (v != "") _cc = v + 0
        v = extract_num(stats_line, "agent_request_count")
        if (v != "") _reqs = v + 0
    } else {
        close(stats_file)
    }

    # 3. Build RESP message: AGENT_RESULT session_id status thinking text in out cr cc reqs
    _resp_field("AGENT_RESULT")
    _resp_field(session_id)
    _resp_field(status)
    _resp_field(thinking)
    _resp_field(text)
    _resp_field(_in "")
    _resp_field(_out "")
    _resp_field(_cr "")
    _resp_field(_cc "")
    _resp_field(_reqs "")
    printf "*10\r\n%s", _resp_buf
}

function _resp_field(data,    byte_len, seg, i, c, len) {
    # Compute byte length under LC_ALL=C (each char = 1 byte for ASCII)
    len = length(data)
    _resp_buf = _resp_buf "$" len "\r\n" data "\r\n"
}
