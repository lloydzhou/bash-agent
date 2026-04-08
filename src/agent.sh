#!/usr/bin/env bash
# bash-agent — AI Agent in pure bash/awk
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
RAW_MODE=false
NO_STREAM=false
PRINT_MODE=false
VERBOSE=false
API_KEY=""
BASE_URL=""
PROMPT=""
MAX_TURNS=20
INTERACTIVE=false

# Session
SESSION_MODE=false
SESSION_ID=""
CONTINUE_SESSION=false
SESSION_DIR=""

# Internal
CONV_FILE=""
TOOL_DEF_FILE=""
AGENT_TMPDIR=""
API_URL=""
AWK_DIR=""

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

log_info() {
    printf '\033[36m%s\033[0m\n' "$*" >&2
}

log_tool() {
    printf '\033[33m[tool] %s\033[0m\n' "$*" >&2
}

log_verbose() {
    $VERBOSE && printf '\033[90m[verbose] %s\033[0m\n' "$*" >&2
}

die() {
    log_error "$@"
    exit 1
}

json_escape() {
    local input="${1:-}" output="" i=0 len c
    len=${#input}
    while (( i < len )); do
        c="${input:i:1}"
        case "$c" in
            '"')  output+='\"' ;;
            '\')  output+='\\' ;;
            $'\n') output+='\n' ;;
            $'\r') output+='\r' ;;
            $'\t') output+='\t' ;;
            *)    output+="$c" ;;
        esac
        (( i++ )) || true
    done
    printf '%s' "$output"
}

# Unescape JSON escape sequences for display
unescape_display() {
    local input="$1"
    input="${input//\\n/$'\n'}"
    input="${input//\\t/$'\t'}"
    input="${input//\\\"/\"}"
    input="${input//\\\\/\\}"
    printf '%s' "$input"
}

# Extract a field value from JSON using awk
extract_json_field() {
    local json="$1" key="$2"
    printf '%s' "$json" | awk -v key="\"$2\":" '
    BEGIN { found = 0 }
    {
        idx = index($0, key)
        if (idx == 0) { print ""; exit }
        rest = substr($0, idx + length(key))
        gsub(/^[ \t]+/, "", rest)
        if (substr(rest, 1, 1) == "\"") {
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
            printf "%s", result
        } else {
            result = ""
            i = 1
            while (i <= length(rest)) {
                c = substr(rest, i, 1)
                if (c == "," || c == "}" || c == "]" || c == "\n") break
                result = result c
                i++
            }
            gsub(/^[ \t]+|[ \t]+$/, "", result)
            printf "%s", result
        }
        exit
    }'
}

cleanup() {
    # Only clean tmpdir, not session files
    [[ -n "${AGENT_TMPDIR:-}" && -d "${AGENT_TMPDIR:-}" ]] && rm -rf "$AGENT_TMPDIR"
}
trap cleanup EXIT

find_awk_dir() {
    # If already set via env, use it
    if [[ -n "${AWK_DIR:-}" ]]; then
        [[ -d "$AWK_DIR" ]] && return
        die "AWK_DIR not found: $AWK_DIR"
    fi
    # Try same directory as agent.sh
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/awk" ]]; then
        AWK_DIR="$script_dir/awk"
        return
    fi
    die "Cannot find awk/ directory. Set AWK_DIR or ensure awk/ exists alongside agent.sh"
}

# ============================================================================
# Section 3: Conversation Management (temp file, one JSON message per line)
# ============================================================================

conv_init() {
    if [[ "$SESSION_MODE" == true ]]; then
        SESSION_DIR="${HOME}/.bash-agent/sessions"
        mkdir -p "$SESSION_DIR"

        if [[ -n "$SESSION_ID" ]]; then
            # Named session
            CONV_FILE="${SESSION_DIR}/${SESSION_ID}.jsonl"
        elif [[ "$CONTINUE_SESSION" == true ]]; then
            # Continue most recent session
            CONV_FILE=$(ls -t "${SESSION_DIR}"/*.jsonl 2>/dev/null | head -1)
            [[ -z "$CONV_FILE" ]] && CONV_FILE="${SESSION_DIR}/$(date +%Y%m%d-%H%M%S).jsonl"
        else
            # New unnamed session
            CONV_FILE="${SESSION_DIR}/$(date +%Y%m%d-%H%M%S).jsonl"
        fi
        # Touch to create if not exists
        touch "$CONV_FILE"
    else
        # Ephemeral: use tmpdir (cleaned on exit)
        CONV_FILE=$(mktemp "${AGENT_TMPDIR}/conv.XXXXXX")
    fi

    # Add system prompt if provided (only for empty conversation)
    if [[ -n "$SYSTEM_PROMPT" && ! -s "$CONV_FILE" ]]; then
        local escaped
        escaped=$(json_escape "$SYSTEM_PROMPT")
        printf '{"role":"user","content":"%s"}\n' "$escaped" >> "$CONV_FILE"
        printf '{"role":"assistant","content":"Understood. I will follow these instructions."}\n' >> "$CONV_FILE"
    fi
}

conv_add_user() {
    local content
    content=$(json_escape "$1")
    printf '{"role":"user","content":"%s"}\n' "$content" >> "$CONV_FILE"
}

conv_add_assistant() {
    local text="$1" calls="$2"
    local content="[" first=true

    if [[ -n "$text" ]]; then
        content+="{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}"
        first=false
    fi

    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local name id input
        name=$(echo "$tc" | cut -d: -f1)
        id=$(echo "$tc" | cut -d: -f2)
        input=$(echo "$tc" | cut -d: -f3-)
        $first || content+=","
        first=false
        content+="{\"type\":\"tool_use\",\"id\":\"${id}\",\"name\":\"${name}\",\"input\":${input}}"
    done <<< "$calls"

    content+="]"
    printf '{"role":"assistant","content":%s}\n' "$content" >> "$CONV_FILE"
}

conv_add_tool_results() {
    local results="$1"
    local content="["
    local first=true

    while IFS= read -r tr; do
        [[ -z "$tr" ]] && continue
        local tid result
        tid=$(echo "$tr" | cut -d: -f1)
        result=$(echo "$tr" | cut -d: -f2-)
        $first || content+=","
        first=false
        content+="{\"type\":\"tool_result\",\"tool_use_id\":\"${tid}\",\"content\":\"${result}\"}"
    done <<< "$results"

    content+="]"
    printf '{"role":"user","content":%s}\n' "$content" >> "$CONV_FILE"
}

conv_get_messages() {
    local result="[" first=true
    while IFS= read -r msg; do
        [[ -z "$msg" ]] && continue
        $first || result+=","
        first=false
        result+="$msg"
    done < "$CONV_FILE"
    printf '%s]' "$result"
}

# ============================================================================
# Section 4: Tool Definitions (auto-generated JSON)
# ============================================================================

generate_tool_defs() {
    local tmp
    tmp=$(mktemp "${AGENT_TMPDIR}/tools.XXXXXX")
    cat > "$tmp" <<'TOOLDEFS'
[
  {
    "name": "read_file",
    "description": "Read the contents of a file. Returns the file content as text.",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Path to the file to read"
        }
      },
      "required": ["path"]
    }
  },
  {
    "name": "write_file",
    "description": "Write content to a file. Creates parent directories if needed.",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Path to the file to write"
        },
        "content": {
          "type": "string",
          "description": "Content to write to the file"
        }
      },
      "required": ["path", "content"]
    }
  },
  {
    "name": "edit_file",
    "description": "Edit a file by replacing an exact string match with a new string.",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": {
          "type": "string",
          "description": "Path to the file to edit"
        },
        "old_string": {
          "type": "string",
          "description": "The exact text to find and replace"
        },
        "new_string": {
          "type": "string",
          "description": "The replacement text"
        }
      },
      "required": ["path", "old_string", "new_string"]
    }
  },
  {
    "name": "bash",
    "description": "Execute a bash command. Returns stdout and stderr.",
    "input_schema": {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "The bash command to execute"
        }
      },
      "required": ["command"]
    }
  }
]
TOOLDEFS
    printf '%s' "$tmp"
}

# ============================================================================
# Section 5: Tool Implementations
# ============================================================================

tool_read_file() {
    local input="$1"
    local path
    path=$(extract_json_field "$input" "path")
    path="${path#\"}" ; path="${path%\"}"

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    [[ ! -r "$path" ]] && { echo "Error: permission denied: $path"; return 1; }

    head -c 100000 "$path"
    local size
    size=$(wc -c < "$path" 2>/dev/null || echo "0")
    if (( size > 100000 )); then
        printf '\n[... truncated, file is %s bytes ...]' "$size"
    fi
}

tool_write_file() {
    local input="$1"
    local path content
    path=$(extract_json_field "$input" "path")
    content=$(extract_json_field "$input" "content")
    path="${path#\"}" ; path="${path%\"}"

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }

    mkdir -p "$(dirname "$path")" 2>/dev/null
    printf '%s' "$content" > "$path"
    echo "OK: wrote $(wc -c < "$path" 2>/dev/null || echo '?') bytes to $path"
}

tool_edit_file() {
    local input="$1"
    local path old_str new_str
    path=$(extract_json_field "$input" "path")
    old_str=$(extract_json_field "$input" "old_string")
    new_str=$(extract_json_field "$input" "new_string")
    path="${path#\"}" ; path="${path%\"}"

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    [[ -z "$old_str" ]] && { echo "Error: empty old_string"; return 1; }

    if ! grep -qF "$old_str" "$path" 2>/dev/null; then
        echo "Error: old_string not found in $path"
        return 1
    fi

    export _AGENT_OLD="$old_str" _AGENT_NEW="$new_str"
    local tmp
    tmp=$(mktemp "${AGENT_TMPDIR}/edit.XXXXXX")
    awk 'BEGIN{RS="\0"; ORS=""}
         { old=ENVIRON["_AGENT_OLD"]; new=ENVIRON["_AGENT_NEW"]
           i=index($0,old)
           if(i==0){print; exit}
           printf "%s%s%s", substr($0,1,i-1), new, substr($0,i+length(old))
         }' "$path" > "$tmp"

    if (( $(wc -c < "$tmp") > 0 )); then
        mv "$tmp" "$path"
        echo "OK: edited $path"
    else
        rm -f "$tmp"
        echo "Error: edit produced empty result, reverted"
        return 1
    fi

    unset _AGENT_OLD _AGENT_NEW
}

tool_bash_exec() {
    local input="$1"
    local cmd
    cmd=$(extract_json_field "$input" "command")

    [[ -z "$cmd" ]] && { echo "Error: no command provided"; return 1; }

    local output
    output=$(timeout 30 bash -c "$cmd" 2>&1) || true
    local outlen=${#output}
    if (( outlen > 50000 )); then
        output="${output:0:50000}"
        output+=$'\n[... truncated, output was '"$outlen"' bytes ...]'
    fi
    printf '%s' "$output"
}

dispatch_tool() {
    local name="$1" input="$2"
    case "$name" in
        read_file)  tool_read_file "$input" ;;
        write_file) tool_write_file "$input" ;;
        edit_file)  tool_edit_file "$input" ;;
        bash)       tool_bash_exec "$input" ;;
        *)
            echo "Error: unknown tool: $name"
            return 1
            ;;
    esac
}

# ============================================================================
# Section 6: Format Conversion (call awk/*.awk)
# ============================================================================

convert_messages_to_openai() {
    awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/convert_messages.awk"
}

convert_tools_to_openai() {
    awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/convert_tools.awk"
}

# ============================================================================
# Section 7: API Request Builders
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
    msgs=$(printf '%s' "$messages" | convert_messages_to_openai)

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

build_request() {
    local messages="$1" tools="$2"
    case "$PROVIDER" in
        claude)            build_claude_request "$messages" "$tools" ;;
        openai)            build_openai_request "$messages" "$tools" ;;
        openai-responses)  build_openai_responses_request "$messages" "$tools" ;;
    esac
}

# ============================================================================
# Section 8: SSE Parsers (call awk/*.awk)
# ============================================================================

parse_claude_sse() {
    awk -v verbose="${VERBOSE:-false}" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/claude_sse.awk"
}

parse_openai_sse() {
    awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/openai_sse.awk"
}

parse_openai_responses_sse() {
    awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/openai_responses.awk"
}

parse_sse() {
    case "$PROVIDER" in
        claude)            parse_claude_sse ;;
        openai)            parse_openai_sse ;;
        openai-responses)  parse_openai_responses_sse ;;
    esac
}

# ============================================================================
# Section 9: API Calls (curl)
# ============================================================================

_stream_curl() {
    local body="$1"
    shift
    local header_args=("$@")

    $VERBOSE && log_verbose "POST $API_URL ($((${#body}/1024))KB body)"

    # Merge stderr to stdout: curl errors come through same pipe
    # Handles: network errors, HTTP errors, and API JSON errors in body
    curl -sS --no-buffer -D - \
        "${header_args[@]}" \
        -d "$body" \
        "$API_URL" 2>&1 | awk '
    BEGIN { http_code = ""; in_body = 0 }
    {
        # Strip trailing \r from each line (HTTP headers use \r\n)
        sub(/\r$/, "")
    }
    /^curl: / {
        printf "ERROR:%s\n", $0
        exit 1
    }
    /^HTTP\// {
        http_code = $2
        next
    }
    /^[ \t]*$/ && !in_body {
        if (http_code >= 400) {
            printf "ERROR:HTTP %s\n", http_code
            exit 1
        }
        in_body = 1
        next
    }
    !in_body { next }
    # Handle non-SSE JSON error responses (e.g., {"code":500,"msg":"..."})
    in_body && /^{/ && /"code"/ && /"msg"/ {
        # Simple extraction without gawk-specific match()
        line = $0
        # Extract code (number)
        code = ""
        if (match(line, /"code"[ \t]*:[ \t]*[0-9]+/)) {
            s = substr(line, RSTART, RLENGTH)
            sub(/.*:[ \t]*/, "", s)
            code = s
        }
        # Extract msg (string)
        msg = ""
        if (match(line, /"msg"[ \t]*:[ \t]*"[^"]*"/)) {
            s = substr(line, RSTART, RLENGTH)
            sub(/.*:[ \t]*"/, "", s)
            sub(/"$/, "", s)
            msg = s
        }
        printf "ERROR:API error (code %s): %s\n", code, msg
        exit 1
    }
    { print; fflush() }
    '
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

call_api() {
    local body="$1"
    case "$PROVIDER" in
        claude)            call_claude_api "$body" ;;
        openai)            call_openai_api "$body" ;;
        openai-responses)  call_openai_responses_api "$body" ;;
    esac
}

# ============================================================================
# Section 10: Output Formatting
# ============================================================================

format_output() {
    if [[ "$RAW_MODE" == true ]]; then
        awk '
        /^TEXT:/ {
            text = substr($0, 6)
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
# Section 11: LLM Call (internal)
# ============================================================================

llm_call() {
    local messages="$1"
    local tools
    tools=$(cat "$TOOL_DEF_FILE")

    local body
    body=$(build_request "$messages" "$tools")
    log_verbose "Request body ($((${#body} / 1024))KB): ${body:0:200}..."

    call_api "$body" | parse_sse | format_output
}

# ============================================================================
# Section 12: Agent Loop
# ============================================================================

agent_loop() {
    local user_input="$1"
    conv_add_user "$user_input"

    local turn=0

    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true

        local text="" tool_calls="" stop=""
        local cur_tool_name="" cur_tool_id=""

        [[ "$VERBOSE" == true ]] && printf '[debug] messages: %.500s...\n' "$(conv_get_messages)" >&2
        while IFS= read -r line; do
            [[ "$VERBOSE" == true ]] && printf '[debug] <%s>\n' "$line" >&2
            case "$line" in
                TEXT:*)
                    t="${line#TEXT:}"
                    if [[ "$PRINT_MODE" == true ]]; then
                        printf '{"type":"text","content":"%s"}\n' "$(json_escape "$t")"
                    else
                        local d="$t"
                        d="${d//\\n/$'\n'}"
                        d="${d//\\t/$'\t'}"
                        d="${d//\\\"/\"}"
                        d="${d//\\\\/\\}"
                        printf '%s' "$d"
                    fi
                    text+="$t"
                    ;;
                TOOL_START:*)
                    if [[ "$PRINT_MODE" != true ]]; then
                        printf '\n'
                    fi
                    local rest="${line#TOOL_START:}"
                    cur_tool_name="${rest%%:*}"
                    cur_tool_id="${rest#*:}"
                    if [[ "$PRINT_MODE" == true ]]; then
                        printf '{"type":"tool_start","name":"%s","id":"%s"}\n' "$cur_tool_name" "$cur_tool_id"
                    else
                        log_tool "$cur_tool_name"
                    fi
                    ;;
                TOOL_INPUT:*)
                    input="${line#TOOL_INPUT:}"
                    tool_calls+="${cur_tool_name}:${cur_tool_id}:${input}"$'\n'
                    ;;
                USAGE:*)
                    # Token usage info
                    ;;
                STOP:*)
                    stop="${line#STOP:}"
                    if [[ "$PRINT_MODE" == true ]]; then
                        printf '{"type":"stop","reason":"%s"}\n' "$stop"
                    else
                        printf '\n'
                    fi
                    ;;
                ERROR:*)
                    log_error "${line#ERROR:}"
                    return 1
                    ;;
            esac
        done < <(llm_call "$(conv_get_messages)")

        # Record assistant response
        conv_add_assistant "$text" "$tool_calls"

        case "$stop" in
            end_turn|stop|done)
                break
                ;;
            tool_use|tool_calls)
                # Execute tools and continue
                local results=""
                results=$(execute_tool_calls "$tool_calls")
                conv_add_tool_results "$results"
                ;;
            max_tokens|length)
                log_error "Response truncated (max_tokens reached)"
                break
                ;;
            *)
                log_error "Unknown stop reason: $stop"
                break
                ;;
        esac
    done

    if (( turn >= MAX_TURNS )); then
        log_error "Max turns ($MAX_TURNS) reached"
    fi
}

execute_tool_calls() {
    local calls="$1" results=""
    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local name id input
        name=$(echo "$tc" | cut -d: -f1)
        id=$(echo "$tc" | cut -d: -f2)
        input=$(echo "$tc" | cut -d: -f3-)
        local output
        output=$(dispatch_tool "$name" "$input" 2>&1) || output="Error: tool execution failed"
        # json_escape so newlines in output don't break the line-based format
        local escaped
        escaped=$(json_escape "$output")
        results+="${id}:${escaped}"$'\n'

        # Print tool_result event in --print mode
        if [[ "$PRINT_MODE" == true ]]; then
            printf '{"type":"tool_result","tool_use_id":"%s","content":"%s"}\n' "$id" "$escaped"
        fi
    done <<< "$calls"
    printf '%s' "$results"
}

# ============================================================================
# Section 13: CLI
# ============================================================================

usage() {
    cat <<'EOF'
Usage: agent.sh [options] [prompt]

Options:
  -p, --provider PROV     LLM provider: claude | openai | openai-responses
  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)
  --max-tokens N          Max output tokens (default: 4096)
  --system PROMPT         System prompt for the agent
  --max-turns N           Max agent turns (default: 20)
  --api-key KEY           API key (default from env)
  --base-url URL          Override API base URL (for Ollama, DeepSeek, etc.)
  --print                 Stream JSON events to stdout (for programmatic use)
  --raw                   Raw text output (no protocol prefixes)
  --no-stream             Disable streaming
  --session [NAME]        Use named session (persist conversation)
  --continue              Continue most recent session
  --list-sessions         List all saved sessions
  -v, --verbose           Verbose mode
  -i, --interactive       Interactive mode (REPL)
  -h, --help              Show this help

Environment:
  ANTHROPIC_API_KEY       API key for Claude
  OPENAI_API_KEY          API key for OpenAI
  LLM_BASE_URL            Default base URL override
  ANTHROPIC_BASE_URL      Claude API base URL
  OPENAI_BASE_URL         OpenAI API base URL

Examples:
  ./agent.sh "Read /etc/hostname and tell me what it says"
  ./agent.sh -p openai -m gpt-4o "List files in /tmp"
  ./agent.sh --session code-review "Analyze this code"
  ./agent.sh --continue "What did we discuss?"
  ./agent.sh --print "Hello" | jq -r 'select(.type=="text") .content'
  echo "prompt" | ./agent.sh --print
  ./agent.sh -i
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
            --max-turns)     MAX_TURNS="$2"; shift 2 ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            --print)         PRINT_MODE=true; shift ;;
            --raw)           RAW_MODE=true; shift ;;
            --no-stream)     NO_STREAM=true; shift ;;
            --session)
                SESSION_MODE=true
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    SESSION_ID="$2"; shift 2
                else
                    shift
                fi
                ;;
            --continue)      SESSION_MODE=true; CONTINUE_SESSION=true; shift ;;
            --list-sessions)
                list_sessions
                exit 0
                ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            -i|--interactive) INTERACTIVE=true; shift ;;
            -h|--help)       usage ;;
            -*)              die "Unknown option: $1" ;;
            *)               PROMPT="$1"; shift ;;
        esac
    done
}

list_sessions() {
    local dir="${HOME}/.bash-agent/sessions"
    if [[ ! -d "$dir" ]]; then
        echo "No sessions found."
        return
    fi
    local files
    files=$(ls -t "$dir"/*.jsonl 2>/dev/null)
    if [[ -z "$files" ]]; then
        echo "No sessions found."
        return
    fi
    printf "%-40s %s\n" "NAME" "MODIFIED"
    while IFS= read -r f; do
        local name mod
        name=$(basename "$f" .jsonl)
        mod=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$f" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d. -f1)
        printf "%-40s %s\n" "$name" "$mod"
    done <<< "$files"
}

validate_config() {
    [[ -z "$PROVIDER" ]] && die "No provider specified. Use -p claude|openai|openai-responses"

    case "$PROVIDER" in
        claude)
            : "${API_KEY:=$ANTHROPIC_API_KEY}"
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

    if [[ -z "$API_KEY" && -z "$BASE_URL" ]]; then
        case "$PROVIDER" in
            claude) die "No API key. Set ANTHROPIC_API_KEY or use --api-key" ;;
            openai|openai-responses) die "No API key. Set OPENAI_API_KEY or use --api-key" ;;
        esac
    fi
}

setup_api_url() {
    case "$PROVIDER" in
        claude)            API_URL="${BASE_URL:-https://api.anthropic.com/v1}/messages" ;;
        openai)            API_URL="${BASE_URL:-https://api.openai.com/v1}/chat/completions" ;;
        openai-responses)  API_URL="${BASE_URL:-https://api.openai.com/v1}/responses" ;;
    esac
}

interactive_mode() {
    log_info "bash-agent interactive mode (type 'exit' or Ctrl+D to quit)"
    while true; do
        printf '\n\033[32m> \033[0m'
        IFS= read -r user_input || break
        [[ "$user_input" == "exit" || "$user_input" == "quit" ]] && break
        [[ -z "$user_input" ]] && continue
        agent_loop "$user_input"
    done
    log_info "Goodbye!"
}

main() {
    parse_args "$@"
    validate_config
    setup_api_url

    AGENT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/agent.XXXXXX")
    find_awk_dir
    conv_init

    TOOL_DEF_FILE=$(generate_tool_defs)

    if [[ "$INTERACTIVE" == true ]]; then
        interactive_mode
    elif [[ -n "$PROMPT" ]]; then
        agent_loop "$PROMPT"
    elif [[ ! -t 0 ]]; then
        local input
        input=$(cat)
        agent_loop "$input"
    else
        usage
    fi
}

main "$@"
