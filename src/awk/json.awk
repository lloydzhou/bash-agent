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
        else {
            code = index(sprintf("%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c",
                0, 1, 2, 3, 4, 5, 6, 7,
                8, 9, 10, 11, 12, 13, 14, 15,
                16, 17, 18, 19, 20, 21, 22, 23,
                24, 25, 26, 27, 28, 29, 30, 31), c) - 1
            if (code >= 0) {
                hex = sprintf("%04x", code)
                out = out "\\u" hex
            } else {
                out = out c
            }
        }
    }
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

# Split a JSON array into its top-level object elements.
function split_top_level_objects(arr, blocks,    depth, in_str, i, c, count, start) {
    count = 0
    depth = 0
    in_str = 0
    start = 0
    for (i = 1; i <= length(arr); i++) {
        c = substr(arr, i, 1)
        if (c == "\\" && in_str) {
            i++
            continue
        }
        if (c == "\"") in_str = !in_str
        if (in_str) continue
        if (c == "{") {
            if (depth == 0) start = i
            depth++
        }
        if (c == "}") {
            depth--
            if (depth == 0 && start > 0) {
                count++
                blocks[count] = substr(arr, start, i - start + 1)
                start = 0
            }
        }
    }
    return count
}

# Extract a field value and strip surrounding quotes if it is a JSON string.
BEGIN {
    if (json_mode == "escape_string") {
        if (json_input == "") {
            if ((getline json_input) < 0) {
                json_input = ""
            } else {
                while ((getline _line) > 0) {
                    json_input = json_input "\n" _line
                }
            }
        }
        print escape_json_string(json_input)
        exit 0
    }
    if (json_mode == "extract_field") {
        if (json_input == "") {
            if ((getline json_input) < 0) json_input = ""
        }
        raw = extract_value(json_input, json_field_key)
        if (raw == "") {
            print ""
            exit 0
        }
        if (substr(raw, 1, 1) == "\"" && substr(raw, length(raw), 1) == "\"") {
            print unescape_json_string(extract_json_string(json_input, json_field_key))
        } else {
            gsub(/^[ \t]+|[ \t]+$/, "", raw)
            print raw
        }
        exit 0
    }
    if (json_mode == "extract_field_raw") {
        if (json_input == "") {
            if ((getline json_input) < 0) json_input = ""
        }
        raw = extract_value(json_input, json_field_key)
        if (raw == "") {
            print ""
            exit 0
        }
        gsub(/^[ \t]+|[ \t]+$/, "", raw)
        print raw
        exit 0
    }
}
