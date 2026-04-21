# common.awk — Shared JSON parsing functions for SSE parsers and format converters
# This file is meant to be included via: awk -f common.awk -f <specific>.awk
# Not used directly.

# Trim leading/trailing JSON whitespace from a scalar token.
function json_trim(s) {
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
    return s
}

function json_skip_ws(text, pos,    c) {
    while (pos <= length(text)) {
        c = substr(text, pos, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") pos++
        else break
    }
    return pos
}

# Read one complete JSON string token starting at `pos`, including quotes.
# Sets JSON_VALUE_END to the position of the closing quote.
function json_read_string_token(text, pos,    c, i, bs, raw) {
    raw = "\""
    bs = 0
    for (i = pos + 1; i <= length(text); i++) {
        c = substr(text, i, 1)
        raw = raw c
        if (c == "\"" && !bs) {
            JSON_VALUE_END = i
            return raw
        }
        if (c == "\\" && !bs) bs = 1
        else bs = 0
    }
    JSON_VALUE_END = length(text)
    return raw
}

# Read one complete JSON value starting at `pos`.
# Sets JSON_VALUE_END to the position of the last character of the value.
function json_read_raw_value(text, pos,    c, i, depth, in_str, bs, raw) {
    raw = ""
    c = substr(text, pos, 1)
    if (c == "\"") {
        return json_read_string_token(text, pos)
    }

    if (c == "{" || c == "[") {
        depth = 0
        in_str = 0
        bs = 0
        for (i = pos; i <= length(text); i++) {
            c = substr(text, i, 1)
            raw = raw c
            if (in_str) {
                if (c == "\\" && !bs) {
                    bs = 1
                } else {
                    if (c == "\"" && !bs) in_str = 0
                    bs = 0
                }
                continue
            }
            if (c == "\"") {
                in_str = 1
                continue
            }
            if (c == "{" || c == "[") depth++
            else if (c == "}" || c == "]") {
                depth--
                if (depth == 0) {
                    JSON_VALUE_END = i
                    return raw
                }
            }
        }
        JSON_VALUE_END = length(text)
        return raw
    }

    for (i = pos; i <= length(text); i++) {
        c = substr(text, i, 1)
        if (c == "," || c == "}" || c == "]") {
            JSON_VALUE_END = i - 1
            return json_trim(raw)
        }
        raw = raw c
    }
    JSON_VALUE_END = length(text)
    return json_trim(raw)
}

# Find the raw JSON value for an object member named `key`.
# When nested=0, only match top-level object members.
# When nested=1, match the first member at any object depth.
function json_scan_member_raw(json, key, nested,    i, c, raw_key, raw_value, key_pos, j, depth) {
    depth = 0
    for (i = 1; i <= length(json); i++) {
        c = substr(json, i, 1)
        if (c == "{" || c == "[") {
            depth++
            continue
        }
        if (c == "}" || c == "]") {
            depth--
            continue
        }
        if (c != "\"") continue

        raw_key = json_read_string_token(json, i)
        key_pos = JSON_VALUE_END
        if (key_pos > length(json)) return ""

        j = json_skip_ws(json, key_pos + 1)
        if (substr(json, j, 1) != ":") {
            i = key_pos
            continue
        }
        if ((!nested && depth != 1) || (nested && depth < 1) || unescape_json_string(substr(raw_key, 2, length(raw_key) - 2)) != key) {
            i = key_pos
            continue
        }

        j = json_skip_ws(json, j + 1)
        raw_value = json_read_raw_value(json, j)
        return raw_value
    }
    return ""
}

function json_get_raw(json, key, nested) {
    return json_scan_member_raw(json, key, nested)
}

# Extract a JSON string value while preserving escape sequences.
function extract_json_string(json, key, nested,    raw) {
    raw = json_get_raw(json, key, nested)
    if (raw == "" || substr(raw, 1, 1) != "\"" || substr(raw, length(raw), 1) != "\"") return ""
    return substr(raw, 2, length(raw) - 2)
}

function extract_str(json, key, nested) {
    return unescape_json_string(extract_json_string(json, key, nested))
}

function extract_num(json, key, nested,    raw) {
    raw = json_trim(json_get_raw(json, key, nested))
    if (raw ~ /^-?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) return raw
    return ""
}

function extract_value(json, key, nested) {
    return json_get_raw(json, key, nested)
}

# Decode a JSON string value that already has surrounding quotes removed.
# Handles common escapes used by tool inputs/arguments.
function hex_digit_value(c,    lc) {
    lc = tolower(c)
    if (lc >= "0" && lc <= "9") return lc + 0
    if (lc == "a") return 10
    if (lc == "b") return 11
    if (lc == "c") return 12
    if (lc == "d") return 13
    if (lc == "e") return 14
    if (lc == "f") return 15
    return -1
}

function hex_to_int(hex,    i, c, d, value) {
    value = 0
    for (i = 1; i <= length(hex); i++) {
        c = substr(hex, i, 1)
        d = hex_digit_value(c)
        if (d < 0) return -1
        value = value * 16 + d
    }
    return value
}

function utf8_from_codepoint(cp,    b1, b2, b3, b4, out) {
    # Protocol/JSON decoding runs under LC_ALL=C so sprintf("%c") emits raw bytes.
    # Build UTF-8 bytes manually to avoid locale-dependent codepoint handling.
    out = ""
    if (cp <= 127) {
        out = sprintf("%c", cp)
    } else if (cp <= 2047) {
        b1 = 192 + int(cp / 64)
        b2 = 128 + (cp % 64)
        out = sprintf("%c%c", b1, b2)
    } else if (cp <= 65535) {
        b1 = 224 + int(cp / 4096)
        b2 = 128 + int((cp % 4096) / 64)
        b3 = 128 + (cp % 64)
        out = sprintf("%c%c%c", b1, b2, b3)
    } else {
        b1 = 240 + int(cp / 262144)
        b2 = 128 + int((cp % 262144) / 4096)
        b3 = 128 + int((cp % 4096) / 64)
        b4 = 128 + (cp % 64)
        out = sprintf("%c%c%c%c", b1, b2, b3, b4)
    }
    return out
}

function json_control_code(c,    i) {
    if (JSON_CTRL_CHARS == "") {
        for (i = 1; i <= 31; i++) JSON_CTRL_CHARS = JSON_CTRL_CHARS sprintf("%c", i)
    }
    return index(JSON_CTRL_CHARS, c)
}

function unescape_json_string(s,    out, i, c, esc, hex, cp, nexthex, lo) {
    out = ""
    esc = 0
    i = 1
    while (i <= length(s)) {
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
            else if (c == "u") {
                if (i + 4 <= length(s)) {
                    hex = substr(s, i + 1, 4)
                    cp = hex_to_int(hex)
                    if (cp >= 0) {
                        if (cp >= 55296 && cp <= 56319 && i + 10 <= length(s) && substr(s, i + 5, 1) == "\\" && substr(s, i + 6, 1) == "u") {
                            nexthex = substr(s, i + 7, 4)
                            lo = hex_to_int(nexthex)
                            if (lo >= 56320 && lo <= 57343) {
                                out = out utf8_from_codepoint(65536 + ((cp - 55296) * 1024) + (lo - 56320))
                                i += 11
                                esc = 0
                                continue
                            }
                        }
                        if (cp >= 55296 && cp <= 57343) {
                            out = out "\\" "u" hex
                        } else {
                            out = out utf8_from_codepoint(cp)
                        }
                        i += 5
                        esc = 0
                        continue
                    }
                }
                out = out "\\" "u"
            } else out = out c
            esc = 0
        } else if (c == "\\") {
            esc = 1
        } else {
            out = out c
        }
        i++
    }
    if (esc) out = out "\\"
    return out
}

function escape_json_string(s,    out, i, c, code, hex) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\"") out = out "\\\""
        else if (c == "\\") out = out "\\\\"
        else if (c == "\b") out = out "\\b"
        else if (c == "\f") out = out "\\f"
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else if (c == "\t") out = out "\\t"
        else if ((code = json_control_code(c)) > 0) {
            hex = sprintf("%04x", code)
            out = out "\\u" hex
        } else out = out c
    }
    return out
}

# Split a JSON array into its top-level object elements.
function split_top_level_objects(arr, blocks,    i, c, count, raw) {
    count = 0
    if (substr(arr, 1, 1) != "[") return 0
    i = 2
    while (i < length(arr)) {
        i = json_skip_ws(arr, i)
        while (i < length(arr) && substr(arr, i, 1) == ",") i = json_skip_ws(arr, i + 1)
        if (i >= length(arr) || substr(arr, i, 1) == "]") break
        raw = json_read_raw_value(arr, i)
        if (substr(raw, 1, 1) == "{") {
            count++
            blocks[count] = raw
        }
        i = JSON_VALUE_END + 1
    }
    return count
}

# Split a JSON object into its top-level members.
# Populates keys[count] and raw_values[count] with the decoded member name
# and raw JSON value text respectively.
function split_top_level_members(obj, keys, raw_values,    count, i, raw_key, key_pos, raw) {
    count = 0
    if (substr(obj, 1, 1) != "{") return 0
    i = 2
    while (i < length(obj)) {
        i = json_skip_ws(obj, i)
        while (i < length(obj) && substr(obj, i, 1) == ",") i = json_skip_ws(obj, i + 1)
        if (i >= length(obj) || substr(obj, i, 1) == "}") break
        if (substr(obj, i, 1) != "\"") break
        raw_key = json_read_string_token(obj, i)
        key_pos = JSON_VALUE_END
        i = json_skip_ws(obj, key_pos + 1)
        if (substr(obj, i, 1) != ":") break
        i = json_skip_ws(obj, i + 1)
        raw = json_read_raw_value(obj, i)
        count++
        keys[count] = unescape_json_string(substr(raw_key, 2, length(raw_key) - 2))
        raw_values[count] = raw
        i = JSON_VALUE_END + 1
    }
    return count
}
