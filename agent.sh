#!/usr/bin/env bash
# bash-agent — AI Agent in pure bash, powered by bash-llm
# Implements agent loop with tools: read_file, write_file, edit_file, bash
# No dependencies beyond: bash, curl, awk, llm.sh

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

LLM_SH=""       # Path to llm.sh (auto-detected or set via --llm)
PROVIDER=""
MODEL=""
SYSTEM_PROMPT=""
MAX_TURNS=20
RAW_MODE=false
VERBOSE=false
API_KEY=""
BASE_URL=""
PROMPT=""

CONV_FILE=""
TOOL_DEF_FILE=""
AGENT_TMPDIR=""

# ============================================================================
# Utility Functions
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
    # Decode in order: \\ last to avoid double-decoding
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
        # Skip whitespace
        gsub(/^[ \t]+/, "", rest)
        if (substr(rest, 1, 1) == "\"") {
            # String value — extract with escape handling
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
            # Non-string (number, bool, null, object, array) — grab until comma or brace
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
    [[ -n "${AGENT_TMPDIR:-}" && -d "${AGENT_TMPDIR:-}" ]] && rm -rf "$AGENT_TMPDIR"
}
trap cleanup EXIT

# ============================================================================
# Conversation Management (temp file, one JSON message per line)
# ============================================================================

conv_init() {
    CONV_FILE=$(mktemp "${AGENT_TMPDIR}/conv.XXXXXX")
    # Add system prompt if provided
    if [[ -n "$SYSTEM_PROMPT" ]]; then
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
    # Build content array
    local content="[" first=true

    if [[ -n "$text" ]]; then
        content+="{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}"
        first=false
    fi

    # Process tool calls: format is name:id:input per line
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

    # Format: tool_use_id:result per line
    while IFS= read -r tr; do
        [[ -z "$tr" ]] && continue
        local tid result
        tid=$(echo "$tr" | cut -d: -f1)
        result=$(echo "$tr" | cut -d: -f2-)
        $first || content+=","
        first=false
        content+="{\"type\":\"tool_result\",\"tool_use_id\":\"${tid}\",\"content\":\"$(json_escape "$result")\"}"
    done <<< "$results"

    content+="]"
    printf '{"role":"user","content":%s}\n' "$content" >> "$CONV_FILE"
}

conv_get_messages() {
    # Join lines with commas into a JSON array
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
# Tool Definitions (auto-generated JSON)
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
# Tool Implementations
# ============================================================================

tool_read_file() {
    local input="$1"
    local path
    path=$(extract_json_field "$input" "path")
    # Remove surrounding quotes if any
    path="${path#\"}" ; path="${path%\"}"

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    [[ ! -r "$path" ]] && { echo "Error: permission denied: $path"; return 1; }

    # Limit to 100KB
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

    # Check if old_string exists in file
    if ! grep -qF "$old_str" "$path" 2>/dev/null; then
        echo "Error: old_string not found in $path"
        return 1
    fi

    # Use awk for safe replacement via ENVIRON (avoids quoting issues)
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

    # Run with timeout, capture output, truncate to 50KB
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
# LLM Call
# ============================================================================

llm_call() {
    local messages="$1"

    # Build llm.sh arguments
    local llm_args=()
    llm_args+=("-p" "$PROVIDER")
    llm_args+=("-m" "$MODEL")
    llm_args+=("--max-tokens" "4096")
    [[ -n "$API_KEY" ]] && llm_args+=("--api-key" "$API_KEY")
    [[ -n "$BASE_URL" ]] && llm_args+=("--base-url" "$BASE_URL")
    llm_args+=("--tools" "$TOOL_DEF_FILE")

    # Write messages to temp file
    local msg_file
    msg_file=$(mktemp "${AGENT_TMPDIR}/msg.XXXXXX")
    printf '%s' "$messages" > "$msg_file"

    "$LLM_SH" "${llm_args[@]}" --messages "$msg_file"
}

# ============================================================================
# Agent Loop
# ============================================================================

agent_loop() {
    local user_input="$1"
    conv_add_user "$user_input"

    local turn=0

    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true

        local text="" tool_calls="" stop=""
        local cur_tool_name="" cur_tool_id=""

        while IFS= read -r line; do
            [[ "$VERBOSE" == true ]] && printf '[debug] <%s>\n' "$line" >&2
            case "$line" in
                TEXT:*)
                    t="${line#TEXT:}"
                    printf '%s' "$(unescape_display "$t")"
                    text+="$t"
                    ;;
                TOOL_START:*)
                    printf '\n'
                    # Parse TOOL_START:name:id
                    local rest="${line#TOOL_START:}"
                    cur_tool_name="${rest%%:*}"
                    cur_tool_id="${rest#*:}"
                    log_tool "$cur_tool_name"
                    ;;
                TOOL_INPUT:*)
                    input="${line#TOOL_INPUT:}"
                    tool_calls+="${cur_tool_name}:${cur_tool_id}:${input}"$'\n'
                    ;;
                USAGE:*)
                    # Token usage info — could log
                    ;;
                STOP:*)
                    stop="${line#STOP:}"
                    printf '\n'
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
        results+="${id}:${output}"$'\n'
    done <<< "$calls"
    printf '%s' "$results"
}

# ============================================================================
# CLI
# ============================================================================

usage() {
    cat <<'EOF'
Usage: agent.sh [options] [prompt]

Options:
  -p, --provider PROV     LLM provider: claude | openai (default: claude)
  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)
  --llm PATH              Path to llm.sh (auto-detected if not set)
  --system PROMPT         System prompt for the agent
  --max-turns N           Max agent turns (default: 20)
  --api-key KEY           API key (default from env)
  -i, --interactive       Interactive mode (REPL)
  -h, --help              Show this help

Environment:
  ANTHROPIC_API_KEY       API key for Claude
  OPENAI_API_KEY          API key for OpenAI

Examples:
  ./agent.sh "Read /etc/hostname and tell me what it says"
  ./agent.sh -p openai -m gpt-4o "List files in /tmp"
  echo "What day is it?" | ./agent.sh
  ./agent.sh -i
EOF
    exit 0
}

INTERACTIVE=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--provider)   PROVIDER="$2"; shift 2 ;;
            -m|--model)      MODEL="$2"; shift 2 ;;
            --llm)           LLM_SH="$2"; shift 2 ;;
            --system)        SYSTEM_PROMPT="$2"; shift 2 ;;
            --max-turns)     MAX_TURNS="$2"; shift 2 ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            -i|--interactive) INTERACTIVE=true; shift ;;
            -h|--help)       usage ;;
            -*)              die "Unknown option: $1" ;;
            *)               PROMPT="$1"; shift ;;
        esac
    done
}

find_llm_sh() {
    # If already set, validate
    if [[ -n "$LLM_SH" ]]; then
        [[ -x "$LLM_SH" ]] && return
        die "Specified llm.sh not found or not executable: $LLM_SH"
    fi

    # Try same directory as agent.sh
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -x "$script_dir/llm.sh" ]]; then
        LLM_SH="$script_dir/llm.sh"
        return
    fi

    # Try PATH
    if command -v llm.sh &>/dev/null; then
        LLM_SH="$(command -v llm.sh)"
        return
    fi

    die "Cannot find llm.sh. Use --llm PATH or ensure bash-llm/llm.sh exists"
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

    # Set defaults
    : "${PROVIDER:=claude}"
    : "${MODEL:=claude-sonnet-4-20250514}"

    # Find llm.sh
    find_llm_sh

    # Setup
    AGENT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/agent.XXXXXX")
    conv_init

    # Generate tool definitions
    TOOL_DEF_FILE=$(generate_tool_defs)

    if [[ "$INTERACTIVE" == true ]]; then
        interactive_mode
    elif [[ -n "$PROMPT" ]]; then
        agent_loop "$PROMPT"
    elif [[ ! -t 0 ]]; then
        # Read from stdin
        local input
        input=$(cat)
        agent_loop "$input"
    else
        usage
    fi
}

main "$@"
