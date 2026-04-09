# common.awk — Shared JSON parsing functions for SSE parsers and format converters
# This file is meant to be included via: awk -f common.awk -f <specific>.awk
# Not used directly.

# Find "key": in json, return position after colon+optional spaces, or 0
function find_key(json, key,    prefix, pos, rest, j) {
    prefix = "\"" key "\":"
    pos = index(json, prefix)
    if (pos == 0) return 0
    rest = substr(json, pos + length(prefix))
    j = 1
    while (j <= length(rest) && substr(rest, j, 1) == " ") j++
    if (j > length(rest)) return 0
    return pos + length(prefix) + j - 1
}

# Extract string value: "key":"value" or "key": "value"
function extract_str(json, key,    pos, rest, i, c, result) {
    pos = find_key(json, key)
    if (pos == 0) return ""
    rest = substr(json, pos)
    if (substr(rest, 1, 1) != "\"") return ""
    rest = substr(rest, 2)
    result = ""
    i = 1
    while (i <= length(rest)) {
        c = substr(rest, i, 1)
        if (c == "\\" && i < length(rest)) {
            result = result substr(rest, i, 2)
            i += 2
        } else if (c == "\"") {
            break
        } else {
            result = result c
            i++
        }
    }
    return result
}

# Extract string value preserving escape sequences
function extract_escaped(json, key,    pos, rest, i, c, result) {
    pos = find_key(json, key)
    if (pos == 0) return ""
    rest = substr(json, pos)
    if (substr(rest, 1, 1) != "\"") return ""
    rest = substr(rest, 2)
    result = ""
    i = 1
    while (i <= length(rest)) {
        c = substr(rest, i, 1)
        if (c == "\\" && i < length(rest)) {
            result = result substr(rest, i, 2)
            i += 2
        } else if (c == "\"") {
            break
        } else {
            result = result c
            i++
        }
    }
    return result
}

# Extract numeric value: "key":123 or "key": 123
function extract_num(json, key,    pos, rest, i, c, result) {
    pos = find_key(json, key)
    if (pos == 0) return ""
    rest = substr(json, pos)
    result = ""
    i = 1
    while (i <= length(rest)) {
        c = substr(rest, i, 1)
        if (c >= "0" && c <= "9") {
            result = result c
            i++
        } else {
            break
        }
    }
    return result
}

# Extract a JSON value (string, number, object, array) after "key":
function extract_value(json, key,    pos, rest, c, result, depth, in_str, i) {
    pos = find_key(json, key)
    if (pos == 0) return ""
    rest = substr(json, pos)
    if (substr(rest, 1, 1) == "\"") {
        result = "\""
        i = 2
        while (i <= length(rest)) {
            c = substr(rest, i, 1)
            if (c == "\\" && i < length(rest)) {
                result = result substr(rest, i, 2)
                i += 2
            } else if (c == "\"") {
                result = result "\""
                return result
            } else {
                result = result c
                i++
            }
        }
        return result
    }
    if (substr(rest, 1, 1) == "{" || substr(rest, 1, 1) == "[") {
        depth = 0; in_str = 0; result = ""
        for (i = 1; i <= length(rest); i++) {
            c = substr(rest, i, 1)
            if (c == "\\" && in_str) {
                result = result substr(rest, i, 2)
                i++
                continue
            }
            if (c == "\"") in_str = !in_str
            if (!in_str) {
                if (c == "{" || c == "[") depth++
                if (c == "}" || c == "]") depth--
            }
            result = result c
            if (depth == 0) return result
        }
        return result
    }
    result = ""
    for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "," || c == "}" || c == "]") return result
        result = result c
    }
    return result
}

# Decode a JSON string value that already has surrounding quotes removed.
# Handles common escapes used by tool inputs/arguments.
function unescape_json_string(s,    out, i, c, esc) {
    out = ""
    esc = 0
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (esc) {
            if (c == "b") out = out "\b"
            else if (c == "f") out = out "\f"
            else if (c == "n") out = out "\n"
            else if (c == "r") out = out "\r"
            else if (c == "t") out = out "\t"
            else if (c == "\"") out = out "\""
            else if (c == "\\") out = out "\\"
            else if (c == "/") out = out "/"
            else out = out c
            esc = 0
        } else if (c == "\\") {
            esc = 1
        } else {
            out = out c
        }
    }
    if (esc) out = out "\\"
    return out
}

# Extract a JSON string value while preserving escape sequences.
# Unlike extract_escaped(), this correctly handles sequences such as \\\".
function extract_json_string(json, key,    pos, rest, i, c, result, bs) {
    pos = find_key(json, key)
    if (pos == 0) return ""
    rest = substr(json, pos)
    if (substr(rest, 1, 1) != "\"") return ""
    rest = substr(rest, 2)
    result = ""
    bs = 0
    for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "\"") {
            if ((bs % 2) == 0) return result
            result = result c
            bs = 0
        } else {
            result = result c
            if (c == "\\") bs++
            else bs = 0
        }
    }
    return result
}

# Extract a field value and strip surrounding quotes if it is a JSON string.
BEGIN {
    if (json_mode == "extract_field") {
        raw = extract_value(json_input, json_field_key)
        if (raw == "") {
            print ""
            exit 0
        }
        if (substr(raw, 1, 1) == "\"" && substr(raw, length(raw), 1) == "\"") {
            print extract_json_string(json_input, json_field_key)
        } else {
            gsub(/^[ \t]+|[ \t]+$/, "", raw)
            print raw
        }
        exit 0
    }
}
