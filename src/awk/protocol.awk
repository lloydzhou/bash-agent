# protocol.awk — Shared line-protocol formatting helpers for SSE parsers.

function escape_protocol_text(s,    out, i, c) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else if (c == "\t") out = out "\\t"
        else out = out c
    }
    return out
}

function extract_input_string(json, key) {
    return extract_str(json, key)
}

function decode_json_scalar(raw) {
    if (substr(raw, 1, 1) == "\"" && substr(raw, length(raw), 1) == "\"") {
        return unescape_json_string(substr(raw, 2, length(raw) - 2))
    }
    gsub(/^[ \t]+|[ \t]+$/, "", raw)
    return raw
}

function append_protocol_kv(out, key, value) {
    return out "\t" escape_protocol_text(key) "\t" escape_protocol_text(value)
}

function flatten_object_fields(obj,    out, count, i) {
    out = ""
    count = split_top_level_members(obj, PROTOCOL_KEYS, PROTOCOL_RAW_VALUES)
    for (i = 1; i <= count; i++) {
        out = append_protocol_kv(out, PROTOCOL_KEYS[i], decode_json_scalar(PROTOCOL_RAW_VALUES[i]))
    }
    return out
}

function protocol_emit_tool_call_record(name, id, input_json,    out) {
    out = flatten_object_fields(input_json)
    printf "TOOL_CALL:%s\t%s\t%s%s\n", name, id, escape_protocol_text(input_json), out
}
