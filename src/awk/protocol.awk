# protocol.awk — Shared protocol formatting helpers for SSE parsers.
# Wire format (RESP-like, CRLF):
#   *N\r\n          — array marker + field count + CRLF
#   $len\r\n        — per-field: $ + byte length + CRLF
#   data_bytes\r\n  — exact len bytes (may contain internal \n) + CRLF
# Binary-safe: no escaping needed. Length-prefix for every field.
# First field is always the event type.

# emit1(type) — start a message with type as first field
function emit1(type) {
    _EM_N = 1
    _EM_V[1] = type
}

# emit(field) — append a positional field
function emit(field) {
    _EM_V[++_EM_N] = field
}

# emit_flush() — write the message to stdout in RESP-like format
function emit_flush(    i) {
    printf "*%d\r\n", _EM_N
    for (i = 1; i <= _EM_N; i++)
        printf "$%d\r\n%s\r\n", length(_EM_V[i]), _EM_V[i]
    fflush()
}

# --- JSON helpers ---

function decode_json_scalar(raw) {
    if (substr(raw, 1, 1) == "\"" && substr(raw, length(raw), 1) == "\"") {
        return unescape_json_string(substr(raw, 2, length(raw) - 2))
    }
    gsub(/^[ \t]+|[ \t]+$/, "", raw)
    return raw
}

# protocol_emit_tool_call_record — emit TOOL_CALL with flattened JSON fields
function protocol_emit_tool_call_record(name, id, input_json,    count, keys, raw_vals, i) {
    count = split_top_level_members(input_json, keys, raw_vals)
    emit1("TOOL_CALL")
    emit(name)
    emit(id)
    emit(input_json)
    for (i = 1; i <= count; i++) {
        emit(keys[i])
        emit(decode_json_scalar(raw_vals[i]))
    }
    emit_flush()
}
