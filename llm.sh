#!/usr/bin/env bash
# bash-llm — Universal LLM CLI in pure bash/awk
# Supports: Anthropic Claude, OpenAI Chat, OpenAI Responses
# No dependencies beyond: bash, curl, awk

set -uo pipefail

# ============================================================================
# Section 1: Configuration & Defaults
# ============================================================================

PROVIDER=""
MODEL=""
MAX_TOKENS=4096
SYSTEM_PROMPT=""
TOOLS_JSON=""
MESSAGES_FILE=""
RAW_MODE=false
NO_STREAM=false
API_KEY=""
BASE_URL=""
VERBOSE=false
PROMPT=""

TMPDIR_WORK=""
API_URL=""

# Env defaults
: "${ANTHROPIC_API_KEY:=}"
: "${OPENAI_API_KEY:=}"
: "${LLM_BASE_URL:=}"
: "${ANTHROPIC_BASE_URL:=}"
: "${OPENAI_BASE_URL:=}"

# ============================================================================
# Section 2: Utility Functions
# ============================================================================

log_error() {
    printf '\033[31mError: %s\033[0m\n' "$*" >&2
}

die() {
    log_error "$@"
    exit 1
}

log_verbose() {
    $VERBOSE && printf '\033[90m[verbose] %s\033[0m\n' "$*" >&2
}

json_escape() {
    local input="$1"
    # Process each character to escape special JSON chars
    local output=""
    local i=0 len=${#input}
    while (( i < len )); do
        local c="${input:i:1}"
        case "$c" in
            '"')  output+='\"' ;;
            '\')  output+='\\' ;;
            $'\n') output+='\n' ;;
            $'\r') output+='\r' ;;
            $'\t') output+='\t' ;;
            # Handle literal backslash-n etc that might appear
            *)    output+="$c" ;;
        esac
        (( i++ )) || true
    done
    printf '%s' "$output"
}

# JSON escape that preserves existing escape sequences (for passing through content)
json_escape_preserve() {
    local input="$1"
    local output=""
    local i=0 len=${#input}
    while (( i < len )); do
        local c="${input:i:1}"
        case "$c" in
            '"')  output+='\"' ;;
            '\')
                # If next char is already an escape target, pass through
                if (( i + 1 < len )); then
                    local nc="${input:i+1:1}"
                    case "$nc" in
                        '"'|'\'|'n'|'r'|'t'|'u') output+="$c$nc"; (( i++ )) ;;
                        *) output+='\\' ;;
                    esac
                else
                    output+='\\'
                fi
                ;;
            $'\n') output+='\n' ;;
            $'\r') output+='\r' ;;
            $'\t') output+='\t' ;;
            *)    output+="$c" ;;
        esac
        (( i++ )) || true
    done
    printf '%s' "$output"
}

cleanup() {
    [[ -n "${TMPDIR_WORK:-}" && -d "${TMPDIR_WORK:-}" ]] && rm -rf "$TMPDIR_WORK"
}
trap cleanup EXIT

setup_tempdir() {
    TMPDIR_WORK=$(mktemp -d "${TMPDIR:-/tmp}/llm.XXXXXX")
}

usage() {
    cat <<'EOF'
Usage: llm.sh [options] [prompt]

Options:
  -p, --provider PROV     Provider: claude | openai | openai-responses
  -m, --model MODEL       Model name (e.g. claude-sonnet-4-20250514, gpt-4o)
  --max-tokens N          Max output tokens (default: 4096)
  --system PROMPT         System prompt
  --tools FILE            Tool definitions JSON file
  --messages FILE         Messages JSON file (or stdin)
  --raw                   Raw text output (no protocol prefixes)
  --no-stream             Disable streaming
  --api-key KEY           API key (default from env)
  --base-url URL          Override API base URL (for Ollama, DeepSeek, Groq, etc.)
  -v, --verbose           Verbose mode: show API URL, request body, curl errors
  -h, --help              Show this help

Environment:
  ANTHROPIC_API_KEY       API key for Claude
  OPENAI_API_KEY          API key for OpenAI
  LLM_BASE_URL            Default base URL override

Examples:
  ./llm.sh -p claude -m claude-sonnet-4-20250514 "Say hello"
  echo '[{"role":"user","content":"hello"}]' | ./llm.sh -p openai -m gpt-4o
  ./llm.sh -p claude --tools tools.json "What's the weather?"
  ./llm.sh -p openai --base-url http://localhost:11434 -m llama3 "Hello"
  ./llm.sh -p openai --base-url https://api.deepseek.com -m deepseek-chat "Hi"
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--provider)   PROVIDER="$2"; shift 2 ;;
            -m|--model)      MODEL="$2"; shift 2 ;;
            --max-tokens)    MAX_TOKENS="$2"; shift 2 ;;
            --system)        SYSTEM_PROMPT="$2"; shift 2 ;;
            --tools)         TOOLS_JSON="$2"; shift 2 ;;
            --messages)      MESSAGES_FILE="$2"; shift 2 ;;
            --raw)           RAW_MODE=true; shift ;;
            --no-stream)     NO_STREAM=true; shift ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            -h|--help)       usage ;;
            -*)              die "Unknown option: $1" ;;
            *)               PROMPT="$1"; shift ;;
        esac
    done
}

# ============================================================================
# Section 3: Message Reading
# ============================================================================

read_messages() {
    local messages=""

    if [[ -n "$MESSAGES_FILE" ]]; then
        # Read from file
        messages=$(cat "$MESSAGES_FILE")
    elif [[ ! -t 0 ]]; then
        # Read from stdin (piped)
        messages=$(cat)
    fi

    # If we got a prompt from CLI, wrap it as a user message
    if [[ -n "$PROMPT" && -z "$messages" ]]; then
        local escaped
        escaped=$(json_escape "$PROMPT")
        messages="[{\"role\":\"user\",\"content\":\"$escaped\"}]"
    elif [[ -n "$PROMPT" ]]; then
        # Both messages and prompt: append prompt as last user message
        local escaped
        escaped=$(json_escape "$PROMPT")
        # Remove trailing ] and append
        messages="${messages%]}"
        messages+=",{\"role\":\"user\",\"content\":\"$escaped\"}]"
    fi

    [[ -z "$messages" ]] && die "No input. Provide a prompt or pipe messages JSON."
    printf '%s' "$messages"
}

# ============================================================================
# Section 4: Message Format Conversion
# ============================================================================

# Convert Claude-format messages to OpenAI Chat Completions format.
# Handles two key differences:
#   1. Assistant tool_use blocks → OpenAI tool_calls format
#   2. User tool_result messages → OpenAI role:tool messages
# Input/output: JSON array of messages on stdin/stdout
convert_messages_to_openai() {
    awk '
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

    function extract_num(json, key,    pos, rest, i, c, result) {
        pos = find_key(json, key)
        if (pos == 0) return ""
        rest = substr(json, pos)
        result = ""
        for (i = 1; i <= length(rest); i++) {
            c = substr(rest, i, 1)
            if (c == "-" || c == "." || (c >= "0" && c <= "9")) {
                result = result c
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
            # String value
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
        # Non-string: number, object, array, bool, null
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
        # Primitive
        result = ""
        for (i = 1; i <= length(rest); i++) {
            c = substr(rest, i, 1)
            if (c == "," || c == "}" || c == "]") return result
            result = result c
        }
        return result
    }

    # Parse content array from an assistant message and convert to OpenAI format.
    # Claude: {"role":"assistant","content":[{"type":"text","text":"..."},{"type":"tool_use","id":"...","name":"...","input":{...}}]}
    # OpenAI: {"role":"assistant","content":"...","tool_calls":[{"id":"...","type":"function","function":{"name":"...","arguments":"..."}}]}
    function convert_assistant_msg(json,    role, content_val, text_parts, tool_parts, n, i, block, btype, t, tid, tname, tinput) {
        role = extract_str(json, "role")
        content_val = extract_value(json, "content")

        text_parts = ""
        tool_parts = ""
        n = 0

        # Parse content array: [{...},{...}]
        if (substr(content_val, 1, 1) == "[") {
            # Split content array into blocks
            n = split_content_blocks(content_val, blocks)
            for (i = 1; i <= n; i++) {
                block = blocks[i]
                if (block ~ /"type" *: *"text"/ || block ~ /"type":"text"/) {
                    t = extract_value(block, "text")
                    # Strip surrounding quotes
                    if (substr(t, 1, 1) == "\"") t = substr(t, 2, length(t) - 2)
                    text_parts = text_parts unescape_json(t)
                } else if (block ~ /"type" *: *"tool_use"/ || block ~ /"type":"tool_use"/) {
                    tid = extract_str(block, "id")
                    tname = extract_str(block, "name")
                    tinput = extract_value(block, "input")
                    # OpenAI wants arguments as a string
                    tool_parts = tool_parts "{\"id\":\"" tid "\",\"type\":\"function\",\"function\":{\"name\":\"" tname "\",\"arguments\":\"" escape_for_json_string(tinput) "\"}},"
                }
            }
        } else {
            # Simple string content
            if (substr(content_val, 1, 1) == "\"") {
                text_parts = substr(content_val, 2, length(content_val) - 2)
                gsub(/\\n/, "\n", text_parts)
                gsub(/\\t/, "\t", text_parts)
                gsub(/\\\"/, "\"", text_parts)
            } else {
                text_parts = content_val
            }
        }

        # Build OpenAI message
        result_msg = "{\"role\":\"assistant\""
        if (text_parts != "") {
            result_msg = result_msg ",\"content\":\"" escape_for_json_string(text_parts) "\""
        } else {
            result_msg = result_msg ",\"content\":null"
        }
        if (tool_parts != "") {
            # Remove trailing comma
            tool_parts = substr(tool_parts, 1, length(tool_parts) - 1)
            result_msg = result_msg ",\"tool_calls\":[" tool_parts "]"
        }
        result_msg = result_msg "}"
        return result_msg
    }

    # Convert a user message with tool_result content to OpenAI role:tool messages
    # Claude: {"role":"user","content":[{"type":"tool_result","tool_use_id":"...","content":"..."}]}
    # OpenAI: {"role":"tool","tool_call_id":"...","content":"..."}
    function convert_tool_result_msg(json,    content_val, n, i, block, tid, result_content, msgs) {
        content_val = extract_value(json, "content")
        msgs = ""
        if (substr(content_val, 1, 1) == "[") {
            n = split_content_blocks(content_val, blocks)
            for (i = 1; i <= n; i++) {
                block = blocks[i]
                if (block ~ /"type" *: *"tool_result"/ || block ~ /"type":"tool_result"/) {
                    tid = extract_str(block, "tool_use_id")
                    result_content = extract_value(block, "content")
                    # Strip quotes if string
                    if (substr(result_content, 1, 1) == "\"") {
                        result_content = substr(result_content, 2, length(result_content) - 2)
                        result_content = unescape_json(result_content)
                    }
                    if (msgs != "") msgs = msgs ","
                    msgs = msgs "{\"role\":\"tool\",\"tool_call_id\":\"" tid "\",\"content\":\"" escape_for_json_string(result_content) "\"}"
                }
            }
        }
        return msgs
    }

    # Check if a string has balanced braces/brackets (for content array detection)
    function is_content_array(json,    pos, content_val) {
        pos = find_key(json, "content")
        if (pos == 0) return 0
        content_val = substr(json, pos)
        # Check if content starts with [
        if (substr(content_val, 1, 1) == "[") return 1
        return 0
    }

    # Split a JSON array into its top-level elements
    function split_content_blocks(arr, blocks,    depth, in_str, i, c, count, start) {
        count = 0
        depth = 0
        in_str = 0
        start = 0
        for (i = 1; i <= length(arr); i++) {
            c = substr(arr, i, 1)
            if (c == "\\" && in_str) { i++; continue }
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

    function unescape_json(s,    t) {
        t = s
        gsub(/\\n/, "\n", t)
        gsub(/\\t/, "\t", t)
        gsub(/\\r/, "\r", t)
        gsub(/\\\"/, "\"", t)
        gsub(/\\\\/, "\\", t)
        return t
    }

    function escape_for_json_string(s,    t, i, c) {
        t = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\"") t = t "\\\""
            else if (c == "\\") t = t "\\\\"
            else if (c == "\n") t = t "\\n"
            else if (c == "\t") t = t "\\t"
            else if (c == "\r") t = t "\\r"
            else t = t c
        }
        return t
    }

    # Accumulate all lines into one string
    { line = line $0 }

    # Parse the JSON array of messages
    END {
        inner = line
        gsub(/^\[/, "", inner)
        gsub(/\]$/, "", inner)

        n = split_content_blocks("[" inner "]", msgs)

        result = "["
        for (i = 1; i <= n; i++) {
            msg = msgs[i]

            # Detect message type
            role = extract_str(msg, "role")
            has_tool_content = 0
            has_tool_result = 0

            if (role == "assistant" && is_content_array(msg)) {
                content_val = extract_value(msg, "content")
                if (content_val ~ /"tool_use"/) has_tool_content = 1
            }
            if (role == "user" && is_content_array(msg)) {
                content_val = extract_value(msg, "content")
                if (content_val ~ /"tool_result"/) has_tool_result = 1
            }

            if (i > 1) result = result ","
            if (has_tool_content) {
                result = result convert_assistant_msg(msg)
            } else if (has_tool_result) {
                result = result convert_tool_result_msg(msg)
            } else {
                # Pass through as-is
                result = result msg
            }
        }
        result = result "]"
        printf "%s", result
    }
    '
}

# Convert Claude-format tools to OpenAI function calling format.
# Claude: {"name":"x","description":"y","input_schema":{...}}
# OpenAI: {"type":"function","function":{"name":"x","description":"y","parameters":{...}}}
convert_tools_to_openai() {
    awk '
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
            if (c == "\\" && i < length(rest)) { result = result substr(rest, i, 2); i += 2 }
            else if (c == "\"") break
            else { result = result c; i++ }
        }
        return result
    }
    function extract_value(json, key,    pos, rest, c, result, depth, in_str, i) {
        pos = find_key(json, key)
        if (pos == 0) return ""
        rest = substr(json, pos)
        if (substr(rest, 1, 1) == "\"") {
            result = "\""; i = 2
            while (i <= length(rest)) {
                c = substr(rest, i, 1)
                if (c == "\\" && i < length(rest)) { result = result substr(rest, i, 2); i += 2 }
                else if (c == "\"") { result = result "\""; return result }
                else { result = result c; i++ }
            }
            return result
        }
        if (substr(rest, 1, 1) == "{" || substr(rest, 1, 1) == "[") {
            depth = 0; in_str = 0; result = ""
            for (i = 1; i <= length(rest); i++) {
                c = substr(rest, i, 1)
                if (c == "\\" && in_str) { result = result substr(rest, i, 2); i++; continue }
                if (c == "\"") in_str = !in_str
                if (!in_str) {
                    if (c == "{" || c == "[") depth++
                    if (c == "}" || c == "]") { depth--; if (depth == 0) { result = result c; return result } }
                }
                result = result c
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
    '
}

# ============================================================================
# Section 5: API Request Builders
# ============================================================================

build_claude_request() {
    local messages="$1" tools="$2"
    local body
    body="{\"model\":\"${MODEL}\",\"max_tokens\":${MAX_TOKENS},\"stream\":true"

    [[ -n "$SYSTEM_PROMPT" ]] && body+=",\"system\":\"$(json_escape "$SYSTEM_PROMPT")\""
    [[ -n "$tools" ]] && body+=",\"tools\":${tools}"

    body+=",\"messages\":${messages}}"
    printf '%s' "$body"
}

build_openai_request() {
    local messages="$1" tools="$2"
    local msgs
    # Convert Claude-format messages to OpenAI format
    msgs=$(printf '%s' "$messages" | convert_messages_to_openai)

    # OpenAI: system prompt goes as first message in array
    if [[ -n "$SYSTEM_PROMPT" ]]; then
        local sys_msg="{\"role\":\"system\",\"content\":\"$(json_escape "$SYSTEM_PROMPT")\"}"
        msgs="${msgs%]}"
        msgs="[${sys_msg},${msgs#\[}"
    fi

    local body
    body="{\"model\":\"${MODEL}\",\"max_tokens\":${MAX_TOKENS},\"stream\":true"

    if [[ -n "$tools" ]]; then
        local openai_tools
        openai_tools=$(printf '%s' "$tools" | convert_tools_to_openai)
        body+=",\"tools\":${openai_tools}"
    fi

    body+=",\"messages\":${msgs}}"
    printf '%s' "$body"
}

build_openai_responses_request() {
    local messages="$1" tools="$2"
    # Convert Claude-format messages to OpenAI format
    local msgs
    msgs=$(printf '%s' "$messages" | convert_messages_to_openai)

    local body
    body="{\"model\":\"${MODEL}\",\"max_output_tokens\":${MAX_TOKENS},\"stream\":true"

    [[ -n "$SYSTEM_PROMPT" ]] && body+=",\"instructions\":\"$(json_escape "$SYSTEM_PROMPT")\""

    if [[ -n "$tools" ]]; then
        local openai_tools
        openai_tools=$(printf '%s' "$tools" | convert_tools_to_openai)
        body+=",\"tools\":${openai_tools}"
    fi

    body+=",\"input\":${msgs}}"
    printf '%s' "$body"
}

# ============================================================================
# Section 5: SSE Parsers (awk — the core)
# ============================================================================

parse_claude_sse() {
    awk -v verbose="${VERBOSE:-false}" '
    BEGIN {
        event = ""
        block_type = ""
        tool_name = ""
        tool_id = ""
        partial_json = ""
        stop_reason = ""
        input_tokens = 0
        output_tokens = 0
    }

    /^:/ { next }

    /^event: / {
        event = substr($0, 8)
        next
    }

    /^data: / {
        json = substr($0, 7)
        if (verbose == "true") printf "[sse-debug] event=[%s] data=[%.200s]\n", event, json > "/dev/stderr"

        if (event == "content_block_start") {
            if (json ~ /"type" *: *"text"/ || json ~ /"type":"text"/) {
                block_type = "text"
            } else if (json ~ /"type" *: *"tool_use"/ || json ~ /"type":"tool_use"/) {
                block_type = "tool"
                tool_name = extract_str(json, "name")
                tool_id = extract_str(json, "id")
                partial_json = ""
                printf "TOOL_START:%s:%s\n", tool_name, tool_id
                fflush()
            }
        }
        else if (event == "content_block_delta") {
            if (block_type == "text") {
                text = extract_escaped(json, "text")
                if (text != "") {
                    printf "TEXT:%s\n", text
                    fflush()
                }
            }
            else if (block_type == "tool") {
                partial_json = partial_json extract_escaped(json, "partial_json")
            }
        }
        else if (event == "content_block_stop") {
            if (block_type == "tool") {
                # Decode JSON string escapes so TOOL_INPUT is valid JSON
                gsub(/\\["]/, "\"", partial_json)
                printf "TOOL_INPUT:%s\n", partial_json
                fflush()
            }
            block_type = ""
        }
        else if (event == "message_delta") {
            sr = extract_str(json, "stop_reason")
            if (sr != "") stop_reason = sr
            # Extract usage (both input and output tokens may appear here)
            it = extract_num(json, "input_tokens")
            if (it != "") input_tokens = it
            ot = extract_num(json, "output_tokens")
            if (ot != "") output_tokens = ot
        }
        else if (event == "message_start") {
            it = extract_num_from_nested(json, "input_tokens")
            if (it != "") input_tokens = it
        }
        else if (event == "message_stop") {
            printf "USAGE:in=%d,out=%d\n", input_tokens, output_tokens
            fflush()
            printf "STOP:%s\n", stop_reason
            fflush()
        }
        else if (event == "error") {
            msg = extract_str(json, "message")
            printf "ERROR:%s\n", msg
            fflush()
        }

        next
    }

    # Find "key": in json, return position after colon+optional spaces, or 0
    function find_key(json, key,    prefix, pos, rest, j) {
        prefix = "\"" key "\":"
        pos = index(json, prefix)
        if (pos == 0) return 0
        rest = substr(json, pos + length(prefix))
        # Skip optional spaces after colon
        j = 1
        while (j <= length(rest) && substr(rest, j, 1) == " ") j++
        if (j > length(rest)) return 0
        # Return absolute position of first non-space char after "key":
        return pos + length(prefix) + j - 1
    }

    # Extract simple string value: "key":"value" or "key": "value"
    function extract_str(json, key,    pos, rest, i, c, result) {
        pos = find_key(json, key)
        if (pos == 0) return ""
        rest = substr(json, pos)
        # Must start with opening quote
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

    # Extract string value preserving escapes (same logic)
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

    # Extract number from nested JSON (same as extract_num, kept for clarity)
    function extract_num_from_nested(json, key,    pos, rest, i, c, result) {
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
    '
}

parse_openai_sse() {
    awk '
    BEGIN {
        stop_reason = ""
        # Track tool calls: index -> {id, name, arguments}
        tc_count = 0
        input_tokens = 0
        output_tokens = 0
    }

    /^:/ { next }

    /^data: \[DONE\]/ {
        if (stop_reason == "") stop_reason = "done"
        printf "USAGE:in=%d,out=%d\n", input_tokens, output_tokens
        fflush()
        printf "STOP:%s\n", stop_reason
        fflush()
        next
    }

    /^data: / {
        json = substr($0, 7)

        # Extract finish_reason
        fr = extract_str(json, "finish_reason")
        if (fr != "" && fr != "null") stop_reason = fr

        # Extract text content from delta
        content = extract_escaped_nested(json, "content")
        if (content != "") {
            printf "TEXT:%s\n", content
            fflush()
        }

        # Extract tool calls from delta
        # Format: "tool_calls":[{"index":0,"id":"call_xxx","type":"function","function":{"name":"func","arguments":"{...}"}}]
        if (json ~ /"tool_calls"/) {
            parse_tool_calls(json)
        }

        # Extract usage if present
        pt = extract_num(json, "prompt_tokens")
        if (pt != "") input_tokens = pt
        ct = extract_num(json, "completion_tokens")
        if (ct != "") output_tokens = ct

        next
    }

    function parse_tool_calls(json,    pos, end, tc_json) {
        # Find "tool_calls":[ and extract the array content
        pos = index(json, "\"tool_calls\":[")
        if (pos == 0) return

        # Simple extraction: find each tool call object
        # We look for "index" markers
        gsub(/\},\{/, "}\n{", json)
        split(json, parts, "\n")

        for (p = 1; p <= length(parts); p++) {
            tc = parts[p]

            if (tc !~ /"index"/) continue

            idx = extract_num(tc, "index")
            tc_id = extract_str(tc, "id")
            name = extract_str(tc, "name")
            args = extract_escaped(tc, "arguments")

            # If this is a new tool call (has id and name)
            if (tc_id != "" && name != "") {
                printf "TOOL_START:%s:%s\n", name, tc_id
                fflush()
                tool_args[idx] = args
            } else if (args != "") {
                # Continuation of arguments
                if (idx in tool_args) {
                    tool_args[idx] = tool_args[idx] args
                } else {
                    tool_args[idx] = args
                }
            }

            # Check if arguments are complete (finish_reason = tool_calls or block end)
            if (fr != "" || tc ~ /\}\]/) {
                if (idx in tool_args && tool_args[idx] != "") {
                    gsub(/\\["]/, "\"", tool_args[idx])
                    printf "TOOL_INPUT:%s\n", tool_args[idx]
                    fflush()
                    tool_args[idx] = ""
                }
            }
        }
    }

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

    # For OpenAI, content is nested in delta: {"choices":[{"delta":{"content":"..."}}]}
    function extract_escaped_nested(json, key,    pos, rest, i, c, result) {
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
    '
}

parse_openai_responses_sse() {
    awk '
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
    '
}

# ============================================================================
# Section 6: API Calls (curl)
# ============================================================================

# Simple streaming curl: outputs body directly to stdout for real-time SSE parsing.
# HTTP errors are detected by checking if body starts with non-SSE content.
_stream_curl() {
    local body="$1"
    shift
    local header_args=("$@")

    $VERBOSE && log_verbose "POST $API_URL ($((${#body}/1024))KB body)"

    # Write response to temp file so we can check HTTP status, then stream it out
    # We use -w to capture HTTP code separately, and stream body through
    curl -sS --no-buffer \
        "${header_args[@]}" \
        -d "$body" \
        -w '\n__LLM_HTTP__%{http_code}' \
        "$API_URL" 2>"$TMPDIR_WORK/curl.err" | {
        # Filter: pass through all lines except the __LLM_HTTP__ marker
        # Also detect non-200 status from error responses
        local http_code=""
        while IFS= read -r line; do
            line="${line%$'\r'}"
            if [[ "$line" == __LLM_HTTP__* ]]; then
                http_code="${line#__LLM_HTTP__}"
                continue
            fi
            printf '%s\n' "$line"
        done
        if [[ "$http_code" =~ ^[45] ]]; then
            printf 'ERROR:HTTP %s\n' "$http_code" >&2
            return 1
        fi
    }
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        local err_msg
        err_msg=$(cat "$TMPDIR_WORK/curl.err" 2>/dev/null)
        [[ -n "$err_msg" ]] && log_verbose "curl stderr: $err_msg"
        return 1
    fi
}

call_claude_api() {
    local body="$1"
    _stream_curl "$body" \
        -H "Content-Type: application/json" \
        -H "x-api-key: ${API_KEY}" \
        -H "anthropic-version: 2023-06-01"
}

call_openai_api() {
    local body="$1"
    _stream_curl "$body" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}"
}

call_openai_responses_api() {
    local body="$1"
    _stream_curl "$body" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${API_KEY}"
}

# ============================================================================
# Section 7: Output Formatting (raw mode filter)
# ============================================================================

format_output() {
    if [[ "$RAW_MODE" == true ]]; then
        awk '
        /^TEXT:/ {
            text = substr($0, 6)
            # Decode common escape sequences for display
            gsub(/\\n/, "\n", text)
            gsub(/\\t/, "\t", text)
            gsub(/\\\"/, "\"", text)
            gsub(/\\\\/, "\\", text)
            printf "%s", text
            fflush()
        }
        /^STOP:/ { printf "\n"; fflush() }
        /^ERROR:/ {
            msg = substr($0, 7)
            printf "Error: %s\n", msg > "/dev/stderr"
        }
        '
    else
        cat
    fi
}

# ============================================================================
# Section 8: Main
# ============================================================================

validate_config() {
    [[ -z "$PROVIDER" ]] && die "No provider specified. Use -p claude|openai|openai-responses"

    case "$PROVIDER" in
        claude)
            : "${API_KEY:=$ANTHROPIC_API_KEY}"
            # Base URL: --base-url > LLM_BASE_URL > ANTHROPIC_BASE_URL > default
            : "${BASE_URL:=${LLM_BASE_URL:-${ANTHROPIC_BASE_URL:-}}}"
            : "${MODEL:=claude-sonnet-4-20250514}"
            ;;
        openai)
            : "${API_KEY:=$OPENAI_API_KEY}"
            : "${BASE_URL:=${LLM_BASE_URL:-${OPENAI_BASE_URL:-}}}"
            : "${MODEL:=gpt-4o}"
            ;;
        openai-responses)
            : "${API_KEY:=$OPENAI_API_KEY}"
            : "${BASE_URL:=${LLM_BASE_URL:-${OPENAI_BASE_URL:-}}}"
            : "${MODEL:=gpt-4o}"
            ;;
        *)
            die "Unknown provider: $PROVIDER (use claude|openai|openai-responses)"
            ;;
    esac

    # For providers that don't require an API key (e.g. local Ollama), allow empty key
    if [[ -z "$API_KEY" && -z "$BASE_URL" ]]; then
        case "$PROVIDER" in
            claude) die "No API key. Set ANTHROPIC_API_KEY or use --api-key" ;;
            openai|openai-responses) die "No API key. Set OPENAI_API_KEY or use --api-key" ;;
        esac
    fi
}

main() {
    parse_args "$@"
    validate_config
    setup_tempdir

    local messages tools
    messages=$(read_messages)

    if [[ -n "$TOOLS_JSON" ]]; then
        tools=$(cat "$TOOLS_JSON")
    else
        tools=""
    fi

    local body
    case "$PROVIDER" in
        claude)
            API_URL="${BASE_URL:-https://api.anthropic.com/v1}/messages"
            body=$(build_claude_request "$messages" "$tools")
            log_verbose "Provider: claude | Model: $MODEL | URL: $API_URL"
            log_verbose "Request body ($((${#body} / 1024))KB): ${body:0:200}..."
            call_claude_api "$body" | parse_claude_sse | format_output
            ;;
        openai)
            API_URL="${BASE_URL:-https://api.openai.com/v1}/chat/completions"
            body=$(build_openai_request "$messages" "$tools")
            log_verbose "Provider: openai | Model: $MODEL | URL: $API_URL"
            log_verbose "Request body ($((${#body} / 1024))KB): ${body:0:200}..."
            call_openai_api "$body" | parse_openai_sse | format_output
            ;;
        openai-responses)
            API_URL="${BASE_URL:-https://api.openai.com/v1}/responses"
            body=$(build_openai_responses_request "$messages" "$tools")
            log_verbose "Provider: openai-responses | Model: $MODEL | URL: $API_URL"
            log_verbose "Request body ($((${#body} / 1024))KB): ${body:0:200}..."
            call_openai_responses_api "$body" | parse_openai_responses_sse | format_output
            ;;
    esac
}

main "$@"
