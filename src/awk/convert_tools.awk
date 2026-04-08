# convert_tools.awk — Convert Claude-format tools to OpenAI function calling format
# Claude: {"name":"x","description":"y","input_schema":{...}}
# OpenAI: {"type":"function","function":{"name":"x","description":"y","parameters":{...}}}
# Input: JSON array of tool definitions (Claude format) on stdin
# Output: JSON array of tool definitions (OpenAI format) on stdout
# Requires: awk -f common.awk -f convert_tools.awk

function split_objects(arr, blocks,    depth, in_str, i, c, count, start) {
    count = 0; depth = 0; in_str = 0; start = 0
    for (i = 1; i <= length(arr); i++) {
        c = substr(arr, i, 1)
        if (c == "\\" && in_str) { i++; continue }
        if (c == "\"") in_str = !in_str
        if (in_str) continue
        if (c == "{") { if (depth == 0) start = i; depth++ }
        if (c == "}") { depth--; if (depth == 0 && start > 0) { count++; blocks[count] = substr(arr, start, i - start + 1); start = 0 } }
    }
    return count
}

# Accumulate all lines into one string
{ line = line $0 }

END {
    inner = line
    gsub(/^\[/, "", inner)
    gsub(/\]$/, "", inner)
    n = split_objects(inner, tool_defs)
    result = "["
    for (i = 1; i <= n; i++) {
        td = tool_defs[i]
        # Already in OpenAI format? (has "type":"function")
        if (td ~ /"type" *: *"function"/ || td ~ /"type":"function"/) {
            if (i > 1) result = result ","
            result = result td
            continue
        }
        name = extract_str(td, "name")
        desc = extract_str(td, "description")
        params = extract_value(td, "input_schema")
        # If no input_schema, try parameters
        if (params == "") params = extract_value(td, "parameters")
        if (params == "") params = "{}"
        if (i > 1) result = result ","
        result = result "{\"type\":\"function\",\"function\":{\"name\":\"" name "\",\"description\":\"" desc "\",\"parameters\":" params "}}"
    }
    result = result "]"
    printf "%s", result
}
