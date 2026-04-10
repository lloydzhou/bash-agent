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
    return unescape_json_string(extract_json_string(json, key))
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

function flatten_object_fields(obj,    out, i, c, key, raw, depth, in_str, bs) {
    out = ""
    i = 2
    while (i < length(obj)) {
        while (i < length(obj)) {
            c = substr(obj, i, 1)
            if (c == " " || c == "\t" || c == "\n" || c == "\r" || c == ",") i++
            else break
        }
        if (i >= length(obj) || substr(obj, i, 1) != "\"") break

        key = ""
        bs = 0
        i++
        while (i <= length(obj)) {
            c = substr(obj, i, 1)
            if (c == "\"" && !bs) break
            key = key c
            if (c == "\\" && !bs) bs = 1
            else bs = 0
            i++
        }
        key = unescape_json_string(key)
        i++

        while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t\r\n]/) i++
        if (substr(obj, i, 1) != ":") break
        i++
        while (i <= length(obj) && substr(obj, i, 1) ~ /[ \t\r\n]/) i++

        raw = ""
        c = substr(obj, i, 1)
        if (c == "\"") {
            raw = "\""
            i++
            bs = 0
            while (i <= length(obj)) {
                c = substr(obj, i, 1)
                raw = raw c
                if (c == "\"" && !bs) break
                if (c == "\\" && !bs) bs = 1
                else bs = 0
                i++
            }
        } else if (c == "{" || c == "[") {
            depth = 0
            in_str = 0
            bs = 0
            while (i <= length(obj)) {
                c = substr(obj, i, 1)
                raw = raw c
                if (in_str) {
                    if (c == "\\" && !bs) bs = 1
                    else {
                        if (c == "\"" && !bs) in_str = 0
                        bs = 0
                    }
                } else {
                    if (c == "\"") in_str = 1
                    else if (c == "{" || c == "[") depth++
                    else if (c == "}" || c == "]") {
                        depth--
                        if (depth == 0) break
                    }
                }
                i++
            }
        } else {
            while (i <= length(obj)) {
                c = substr(obj, i, 1)
                if (c == "," || c == "}") {
                    i--
                    break
                }
                raw = raw c
                i++
            }
        }

        out = append_protocol_kv(out, key, decode_json_scalar(raw))
        i++
    }
    return out
}

function protocol_emit_tool_call_record(name, id, input_json,    out) {
    out = flatten_object_fields(input_json)
    printf "TOOL_CALL:%s\t%s\t%s%s\n", name, id, escape_protocol_text(input_json), out
}
