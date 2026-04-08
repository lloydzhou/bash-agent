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
