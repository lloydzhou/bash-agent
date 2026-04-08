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
SUMMARY_MAX_TOKENS=1024
TOOL_TIMEOUT_SECS=600
SYSTEM_PROMPT=""
BASE_SYSTEM_PROMPT=""
OUTPUT_FORMAT="human"
NO_STREAM=false
VERBOSE=false
API_KEY=""
BASE_URL=""
PROMPT=""
MAX_TURNS=20
MAX_CONTEXT_MESSAGES=40
MAX_CONTEXT_BUFFER_MESSAGES=4
INTERACTIVE=false
COMMAND="chat"
COMPACT_MODE=false
declare -a SKILL_NAMES=()

# Session
SESSION_MODE=false
SESSION_ID=""
CONTINUE_SESSION=false
SESSION_DIR=""
PROJECT_KEY=""
SESSION_EVENT_FILE=""
CONTEXT_SUMMARY_FILE=""

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

log_tool_result() {
    local name="$1" output="$2"
    printf '\033[33m[tool] %s result\033[0m\n' "$name" >&2
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" >&2
    fi
}

run_with_timeout() {
    local timeout_secs="$1"
    shift

    local tmp_out pid rc elapsed=0 use_process_group=false
    tmp_out=$(mktemp "${AGENT_TMPDIR}/tool.XXXXXX")

    if command -v setsid >/dev/null 2>&1; then
        setsid "$@" >"$tmp_out" 2>&1 &
        pid=$!
        use_process_group=true
    else
        ( "$@" ) >"$tmp_out" 2>&1 &
        pid=$!
    fi

    while kill -0 "$pid" 2>/dev/null; do
        if (( elapsed >= timeout_secs )); then
            if $use_process_group; then
                kill -TERM -- "-$pid" 2>/dev/null || true
            else
                kill -TERM "$pid" 2>/dev/null || true
            fi
            sleep 1
            if kill -0 "$pid" 2>/dev/null; then
                if $use_process_group; then
                    kill -KILL -- "-$pid" 2>/dev/null || true
                else
                    kill -KILL "$pid" 2>/dev/null || true
                fi
            fi
            wait "$pid" 2>/dev/null || true
            cat "$tmp_out"
            rm -f "$tmp_out"
            printf '\n[... truncated, command timed out after %s seconds ...]' "$timeout_secs"
            return 124
        fi
        sleep 1
        ((elapsed++))
    done

    wait "$pid"
    rc=$?
    cat "$tmp_out"
    rm -f "$tmp_out"
    return "$rc"
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

json_unescape() {
    local input="${1:-}" output="" i=0 len c esc=0
    len=${#input}
    while (( i < len )); do
        c="${input:i:1}"
        if (( esc )); then
            case "$c" in
                '"') output+='"' ;;
                '\') output+='\' ;;
                /) output+='/' ;;
                b) output+=$'\b' ;;
                f) output+=$'\f' ;;
                n) output+=$'\n' ;;
                r) output+=$'\r' ;;
                t) output+=$'\t' ;;
                u)
                    # Keep unknown unicode escapes literal; they are rare in tool inputs.
                    output+='u'
                    ;;
                *) output+="$c" ;;
            esac
            esc=0
        elif [[ "$c" == '\' ]]; then
            esc=1
        else
            output+="$c"
        fi
        (( i++ )) || true
    done
    if (( esc )); then
        output+='\\'
    fi
    printf '%s' "$output"
}

strip_ansi() {
    local input="$1"
    printf '%s' "$input" | awk '
    {
        gsub(/\033\[[0-9;]*[[:alpha:]]/, "", $0)
        print
    }'
}

is_stream_json_mode() {
    [[ "$OUTPUT_FORMAT" == "stream-json" ]]
}

render_template() {
    local template="$1"
    shift
    local key value
    while [[ $# -gt 0 ]]; do
        key="$1"
        value="$2"
        shift 2
        template="${template//\{\{$key\}\}/$value}"
    done
    printf '%s' "$template"
}

wrap_section() {
    local tag="$1" content="$2"
    if [[ -z "$content" ]]; then
        printf ''
        return 0
    fi
    printf '<%s>\n%s\n</%s>' "$tag" "$content" "$tag"
}

wrap_named_section() {
    local tag="$1" name="$2" content="$3"
    if [[ -z "$content" ]]; then
        printf ''
        return 0
    fi
    printf '<%s name="%s">\n%s\n</%s>' "$tag" "$(json_escape "$name")" "$content" "$tag"
}

prompt_template_default() {
    cat <<'EOF'
{{agent_identity_section}}
{{core_rules_section}}
{{skills_section}}
{{stable_context_section}}
{{recent_context_section}}
{{task_instructions_section}}
EOF
}

session_append_line() {
    [[ "$SESSION_MODE" == true && -n "${SESSION_EVENT_FILE:-}" ]] || return 0
    printf '%s\n' "$1" >> "$SESSION_EVENT_FILE"
}

emit_stream_event() {
    local line="$1"
    printf '%s\n' "$line"
    session_append_line "$line"
}

build_system_prompt() {
    local template agent_identity core_rules skills stable_context recent_context task_instructions agent_identity_section core_rules_section skills_section stable_context_section recent_context_section task_instructions_section
    template=$(prompt_template_default)
    BASE_SYSTEM_PROMPT="$template"
    agent_identity='You are bash-agent, a lightweight coding agent that works in a terminal.'
    core_rules=$'- Be concise and concrete.\n- Use tools when needed.\n- Prefer safe, exact edits.\n- Report failures clearly.'
    skills=$(build_skills_section)
    stable_context=$(build_stable_context_section)
    recent_context=$(build_recent_context_section)
    task_instructions=$(build_task_instructions_section)
    agent_identity_section=$(wrap_section "agent-identity" "$agent_identity")
    core_rules_section=$(wrap_section "rules" "$core_rules")
    skills_section=$(wrap_section "skills" "$skills")
    stable_context_section=$(wrap_section "context-summary" "$stable_context")
    recent_context_section=$(wrap_section "recent-messages" "$recent_context")
    task_instructions_section=$(wrap_section "instructions" "$task_instructions")
    render_template "$template" \
        "agent_identity_section" "$agent_identity_section" \
        "core_rules_section" "$core_rules_section" \
        "skills_section" "$skills_section" \
        "stable_context_section" "$stable_context_section" \
        "recent_context_section" "$recent_context_section" \
        "task_instructions_section" "$task_instructions_section"
}

find_skill_file() {
    local skill_name="$1" cwd base candidate
    cwd="${PWD:-$(pwd)}"
    for base in "$cwd/.claude/skills" "$cwd/skills"; do
        candidate="$base/$skill_name/SKILL.md"
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

load_skill_content() {
    local skill_name="$1" skill_file="" skill_dir="" content=""
    skill_file=$(find_skill_file "$skill_name") || return 1
    skill_dir=$(dirname "$skill_file")
    content=$(cat "$skill_file") || return 1
    content="${content//\$\{BASH_AGENT_SKILL_DIR\}/$skill_dir}"
    printf 'Base directory for this skill: %s\n\n%s' "$skill_dir" "$content"
}

build_skills_section() {
    local section="" skill_name skill_content

    if [[ ${#SKILL_NAMES[@]} -eq 0 ]]; then
        printf ''
        return 0
    fi

    for skill_name in "${SKILL_NAMES[@]}"; do
        skill_content=$(load_skill_content "$skill_name") || die "Skill not found: $skill_name (expected .claude/skills/$skill_name/SKILL.md or skills/$skill_name/SKILL.md)"
        section+="$(wrap_named_section "skill" "$skill_name" "$skill_content")"$'\n'
    done
    section="${section%$'\n'}"
    printf '%s' "$section"
}

build_compact_system_prompt() {
    cat <<'EOF'
You are compressing conversation context for a lightweight coding agent.

Return only plain text.
Do not include analysis, markdown fences, or extra commentary.
Update the existing summary snapshot using the dropped messages.
Keep the output concise and specific.

Use exactly these fields:
Task focus:
Latest request:
Progress:
Tool evidence:
EOF
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

get_project_key() {
    local cwd="${PWD:-$(pwd)}"
    cwd="$(cd "$cwd" && pwd -P)"
    cwd="${cwd#/}"
    cwd="${cwd//\//-}"
    cwd="$(printf '%s' "$cwd" | awk '{ gsub(/[^A-Za-z0-9._-]/, "-"); gsub(/-+/, "-", $0); sub(/^-+/, "", $0); sub(/-+$/, "", $0); print }')"
    printf -- '-%s' "$cwd"
}

# ============================================================================
# Section 3: Conversation Management (temp file, one JSON message per line)
# ============================================================================

conv_init() {
    if [[ "$SESSION_MODE" == true ]]; then
        PROJECT_KEY="$(get_project_key)"
        SESSION_DIR="${HOME}/.bash-agent/projects/${PROJECT_KEY}"
        mkdir -p "$SESSION_DIR"

        local session_base=""
        if [[ -n "$SESSION_ID" ]]; then
            # Named session
            session_base="$SESSION_ID"
        elif [[ "$CONTINUE_SESSION" == true ]]; then
            # Continue most recent session
            CONV_FILE=$(ls -t "${SESSION_DIR}"/*.jsonl 2>/dev/null | grep -v '\.events\.jsonl$' | grep -v '\.summary\.txt$' | head -1)
            if [[ -n "$CONV_FILE" ]]; then
                session_base="$(basename "$CONV_FILE" .jsonl)"
            elif [[ "$COMPACT_MODE" == true ]]; then
                die "No existing session found to compact. Use --session NAME or run a session first."
            else
                session_base="$(date +%Y%m%d-%H%M%S)"
            fi
        else
            # New unnamed session
            session_base="$(date +%Y%m%d-%H%M%S)"
        fi

        [[ -z "$session_base" ]] && session_base="$(date +%Y%m%d-%H%M%S)"
        CONV_FILE="${SESSION_DIR}/${session_base}.jsonl"
        SESSION_EVENT_FILE="${SESSION_DIR}/${session_base}.events.jsonl"
        CONTEXT_SUMMARY_FILE="${SESSION_DIR}/${session_base}.summary.txt"
        touch "$CONV_FILE"
        touch "$SESSION_EVENT_FILE"
        touch "$CONTEXT_SUMMARY_FILE"
        session_append_line "{\"type\":\"session_start\",\"session_id\":\"$(json_escape "$session_base")\"}"
    else
        # Ephemeral: use tmpdir (cleaned on exit)
        CONV_FILE=$(mktemp "${AGENT_TMPDIR}/conv.XXXXXX")
        CONTEXT_SUMMARY_FILE=$(mktemp "${AGENT_TMPDIR}/summary.XXXXXX")
    fi
}

conv_add_user() {
    local content
    content=$(json_escape "$1")
    printf '{"role":"user","content":"%s"}\n' "$content" >> "$CONV_FILE"
    session_append_line "{\"type\":\"user_message\",\"content\":\"$content\"}"
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
        IFS=$'\t' read -r name id input <<< "$tc"
        $first || content+=","
        first=false
        content+="{\"type\":\"tool_use\",\"id\":\"$(json_escape "$id")\",\"name\":\"$(json_escape "$name")\",\"input\":${input}}"
    done <<< "$calls"

    content+="]"
    printf '{"role":"assistant","content":%s}\n' "$content" >> "$CONV_FILE"
    session_log_assistant "$text" "$calls"
}

conv_add_tool_results() {
    local results="$1"
    local content="["
    local first=true

    while IFS= read -r tr; do
        [[ -z "$tr" ]] && continue
        local tid result
        IFS=$'\t' read -r tid result <<< "$tr"
        $first || content+=","
        first=false
        content+="{\"type\":\"tool_result\",\"tool_use_id\":\"$(json_escape "$tid")\",\"content\":\"${result}\"}"
    done <<< "$results"

    content+="]"
    printf '{"role":"user","content":%s}\n' "$content" >> "$CONV_FILE"
    session_log_tool_results "$results"
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

conv_trim() {
    compact_context_window "auto" false
}

context_append_summary() {
    local text="$1"
    [[ -n "${CONTEXT_SUMMARY_FILE:-}" ]] || return 0
    [[ -n "$text" ]] || return 0
    printf '%s\n' "$text" > "$CONTEXT_SUMMARY_FILE"
}

build_stable_context_section() {
    local section=""
    if [[ -n "${CONTEXT_SUMMARY_FILE:-}" && -s "$CONTEXT_SUMMARY_FILE" ]]; then
        section="$(cat "$CONTEXT_SUMMARY_FILE")"
    fi
    printf '%s' "$section"
}

build_recent_context_section() {
    local section=""
    if [[ -s "$CONV_FILE" ]]; then
        section+="$(tail -n "$MAX_CONTEXT_MESSAGES" "$CONV_FILE")"
    fi
    printf '%s' "$section"
}

build_task_instructions_section() {
    local section=""
    if [[ -n "$SYSTEM_PROMPT" ]]; then
        section="$SYSTEM_PROMPT"
    fi
    printf '%s' "$section"
}

build_compact_summary_prompt() {
    local current_summary="$1" dropped_messages="$2" summary_section dropped_section
    summary_section=$(wrap_section "current-summary" "$current_summary")
    dropped_section=$(wrap_section "dropped-messages" "$dropped_messages")
    cat <<EOF
${summary_section}

${dropped_section}
EOF
}

compact_context_window() {
    local trigger="$1" force="${2:-false}" total keep drop tmp_dropped dropped_messages current_summary prompt summary_request summary_response summary_text

    total=$(wc -l < "$CONV_FILE" 2>/dev/null || echo 0)
    local threshold=$MAX_CONTEXT_MESSAGES
    local target_keep=$MAX_CONTEXT_BUFFER_MESSAGES
    (( target_keep < 1 )) && target_keep=1

    if ! $force && (( total <= threshold )); then
        return 1
    fi

    keep=$target_keep
    (( total > keep )) || keep=$total
    drop=$(( total - keep ))
    [[ $drop -gt 0 ]] || return 1

    tmp_dropped=$(mktemp "${AGENT_TMPDIR}/dropped.XXXXXX")
    head -n "$drop" "$CONV_FILE" > "$tmp_dropped"
    dropped_messages=$(cat "$tmp_dropped")
    current_summary=""
    if [[ -n "${CONTEXT_SUMMARY_FILE:-}" && -s "$CONTEXT_SUMMARY_FILE" ]]; then
        current_summary=$(cat "$CONTEXT_SUMMARY_FILE")
    fi

    prompt=$(build_compact_summary_prompt "$current_summary" "$dropped_messages")
    summary_request="[{\"role\":\"user\",\"content\":\"$(json_escape "$prompt")\"}]"
    summary_response=$(run_summary_call "$summary_request")
    context_append_summary "$summary_response"

    if (( keep < total )); then
        tmp=$(mktemp "${AGENT_TMPDIR}/conv_trim.XXXXXX")
        tail -n "$keep" "$CONV_FILE" > "$tmp"
        mv "$tmp" "$CONV_FILE"
    fi

    rm -f "$tmp_dropped"
    if is_stream_json_mode; then
        emit_stream_event "{\"type\":\"context_update\",\"kind\":\"compact\",\"trigger\":\"$(json_escape "$trigger")\"}"
    elif [[ "$trigger" == "auto" ]]; then
        log_info "Context compacted automatically."
    fi
    return 0
}

session_log_assistant() {
    local text="$1" calls="$2"
    local payload="{\"type\":\"assistant_message\",\"text\":\"$(json_escape "$text")\""
    local tool_json="[" first=true
    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local name id input
        IFS=$'\t' read -r name id input <<< "$tc"
        $first || tool_json+=","
        first=false
        tool_json+="{\"name\":\"$(json_escape "$name")\",\"id\":\"$(json_escape "$id")\",\"input\":$input}"
    done <<< "$calls"
    tool_json+="]"
    payload+=",\"tool_calls\":${tool_json}}"
    session_append_line "$payload"
}

session_log_tool_results() {
    local results="$1"
    while IFS= read -r tr; do
        [[ -z "$tr" ]] && continue
        local tid result
        IFS=$'\t' read -r tid result <<< "$tr"
        session_append_line "{\"type\":\"tool_result\",\"tool_use_id\":\"$(json_escape "$tid")\",\"content\":\"${result}\"}"
    done <<< "$results"
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
    path=$(json_unescape "$path")

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
    path=$(json_unescape "$path")
    content=$(json_unescape "$content")

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
    path=$(json_unescape "$path")
    old_str=$(json_unescape "$old_str")
    new_str=$(json_unescape "$new_str")

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
    local cmd script_file
    cmd=$(extract_json_field "$input" "command")
    cmd=$(json_unescape "$cmd")

    [[ -z "$cmd" ]] && { echo "Error: no command provided"; return 1; }

    local output
    script_file=$(mktemp "${AGENT_TMPDIR}/bash.XXXXXX.sh")
    printf '%s\n' "$cmd" > "$script_file"
    chmod 700 "$script_file" 2>/dev/null || true
    output=$(run_with_timeout "$TOOL_TIMEOUT_SECS" bash "$script_file") || true
    rm -f "$script_file"
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
    local messages="$1" tools="$2" system_prompt="${3:-}" max_tokens="${4:-$MAX_TOKENS}"
    local body
    if [[ -z "$system_prompt" ]]; then
        system_prompt=$(build_system_prompt)
    fi
    body="{\"model\":\"${MODEL}\",\"max_tokens\":${max_tokens},\"stream\":true"

    [[ -n "$system_prompt" ]] && body+=",\"system\":\"$(json_escape "$system_prompt")\""
    [[ -n "$tools" ]] && body+=",\"tools\":${tools}"

    body+=",\"messages\":${messages}}"
    printf '%s' "$body"
}

build_openai_request() {
    local messages="$1" tools="$2" system_prompt="${3:-}" max_tokens="${4:-$MAX_TOKENS}"
    local msgs
    msgs=$(printf '%s' "$messages" | convert_messages_to_openai)
    if [[ -z "$system_prompt" ]]; then
        system_prompt=$(build_system_prompt)
    fi

    if [[ -n "$system_prompt" ]]; then
        local sys_msg="{\"role\":\"system\",\"content\":\"$(json_escape "$system_prompt")\"}"
        msgs="${msgs%]}"
        msgs="[${sys_msg},${msgs#\[}]"
    fi

    local body
    body="{\"model\":\"${MODEL}\",\"max_tokens\":${max_tokens},\"stream\":true"

    if [[ -n "$tools" ]]; then
        local openai_tools
        openai_tools=$(printf '%s' "$tools" | convert_tools_to_openai)
        body+=",\"tools\":${openai_tools}"
    fi

    body+=",\"messages\":${msgs}}"
    printf '%s' "$body"
}

build_openai_responses_request() {
    local messages="$1" tools="$2" system_prompt="${3:-}" max_tokens="${4:-$MAX_TOKENS}"
    local msgs
    msgs=$(printf '%s' "$messages" | convert_messages_to_openai)
    if [[ -z "$system_prompt" ]]; then
        system_prompt=$(build_system_prompt)
    fi

    local body
    body="{\"model\":\"${MODEL}\",\"max_output_tokens\":${max_tokens},\"stream\":true"

    [[ -n "$system_prompt" ]] && body+=",\"instructions\":\"$(json_escape "$system_prompt")\""

    if [[ -n "$tools" ]]; then
        local openai_tools
        openai_tools=$(printf '%s' "$tools" | convert_tools_to_openai)
        body+=",\"tools\":${openai_tools}"
    fi

    body+=",\"input\":${msgs}}"
    printf '%s' "$body"
}

build_request() {
    local messages="$1" tools="$2" system_prompt="${3:-}" max_tokens="${4:-$MAX_TOKENS}"
    case "$PROVIDER" in
        claude)            build_claude_request "$messages" "$tools" "$system_prompt" "$max_tokens" ;;
        openai)            build_openai_request "$messages" "$tools" "$system_prompt" "$max_tokens" ;;
        openai-responses)  build_openai_responses_request "$messages" "$tools" "$system_prompt" "$max_tokens" ;;
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
        printf "ERROR:API response body received\n"
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
# Section 11: LLM Call (internal)
# ============================================================================

llm_call() {
    local messages="$1"
    local tools
    tools=$(cat "$TOOL_DEF_FILE")

    local body
    body=$(build_request "$messages" "$tools")
    log_verbose "Request body ($((${#body} / 1024))KB): ${body:0:200}..."

    call_api "$body" | parse_sse
}

run_summary_call() {
    local messages="$1"
    local body text line
    body=$(build_request "$messages" "" "$(build_compact_system_prompt)" "$SUMMARY_MAX_TOKENS")
    log_verbose "Summary request body ($((${#body} / 1024))KB): ${body:0:200}..."

    text=""
    while IFS= read -r line; do
        case "$line" in
            TEXT:*)
                text+="${line#TEXT:}"
                ;;
            ERROR:*)
                die "${line#ERROR:}"
                ;;
        esac
    done < <(call_api "$body" | parse_sse)

    [[ -n "$text" ]] || die "Failed to generate context summary"
    printf '%s' "$text"
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
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"text\",\"content\":\"$(json_escape "$t")\"}"
                    else
                        local d="$t"
                        printf '%s' "$(unescape_display "$d")"
                    fi
                    text+="$t"
                    ;;
                TOOL_START:*)
                    if ! is_stream_json_mode; then
                        printf '\n'
                    fi
                    local rest="${line#TOOL_START:}"
                    cur_tool_name="${rest%%:*}"
                    cur_tool_id="${rest#*:}"
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"tool_start\",\"name\":\"$(json_escape "$cur_tool_name")\",\"id\":\"$(json_escape "$cur_tool_id")\"}"
                    else
                        log_tool "$cur_tool_name"
                    fi
                    ;;
                TOOL_INPUT:*)
                    input="${line#TOOL_INPUT:}"
                    tool_calls+="${cur_tool_name}"$'\t'"${cur_tool_id}"$'\t'"${input}"$'\n'
                    ;;
                USAGE:*)
                    if is_stream_json_mode; then
                        local usage="${line#USAGE:}"
                        local input_tokens output_tokens
                        input_tokens="${usage#in=}"
                        input_tokens="${input_tokens%%,*}"
                        output_tokens="${usage##*,out=}"
                        emit_stream_event "{\"type\":\"usage\",\"input_tokens\":${input_tokens:-0},\"output_tokens\":${output_tokens:-0}}"
                    fi
                    ;;
                STOP:*)
                    stop="${line#STOP:}"
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"stop\",\"reason\":\"$(json_escape "$stop")\"}"
                    else
                        printf '\n'
                    fi
                    ;;
                ERROR:*)
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"error\",\"message\":\"$(json_escape "${line#ERROR:}")\"}"
                    fi
                    log_error "${line#ERROR:}"
                    return 1
                    ;;
            esac
        done < <(llm_call "$(conv_get_messages)")

        # Record assistant response
        conv_add_assistant "$text" "$tool_calls"

        case "$stop" in
            end_turn|stop|done)
                compact_context_window "auto" false || true
                break
                ;;
            tool_use|tool_calls)
                # Execute tools and continue
                local results=""
                results=$(execute_tool_calls "$tool_calls")
                conv_add_tool_results "$results"
                compact_context_window "auto" false || true
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
        IFS=$'\t' read -r name id input <<< "$tc"
        local output
        output=$(dispatch_tool "$name" "$input" 2>&1)
        local tool_rc=$?
        output=$(strip_ansi "$output")
        if (( tool_rc != 0 )); then
            output="Error: tool execution failed: $output"
        fi
        # json_escape so newlines in output don't break the line-based format
        local escaped
        escaped=$(json_escape "$output")
        results+="${id}"$'\t'"${escaped}"$'\n'

        # Print tool_result event in stream-json mode
        if is_stream_json_mode; then
            emit_stream_event "{\"type\":\"tool_result\",\"tool_use_id\":\"$(json_escape "$id")\",\"content\":\"$escaped\"}"
        else
            log_tool_result "$name" "$output"
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
       agent.sh compact [options]

Options:
  -p, --provider PROV     LLM provider: claude | openai | openai-responses
  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)
  --max-tokens N          Max output tokens (default: 4096)
  --tool-timeout N        Tool execution timeout in seconds (default: 600)
  --system PROMPT         System prompt for the agent
  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md
  --max-turns N           Max agent turns (default: 20)
  --max-context N         Max stored context messages (default: 40)
  --api-key KEY           API key (default from env)
  --base-url URL          Override API base URL (for Ollama, DeepSeek, etc.)
  --output-format FMT     Output format: human | stream-json
  --print                 Alias for --output-format stream-json
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
  ./agent.sh --skill shell-safety "List files in /tmp"
  ./agent.sh --continue "What did we discuss?"
  ./agent.sh --output-format stream-json "Hello" | jq -r 'select(.type=="text") .content'
  echo "prompt" | ./agent.sh --print
  ./agent.sh compact --session code-review
  ./agent.sh -i
EOF
    exit 0
}

parse_args() {
    if [[ $# -gt 0 && "$1" == "compact" ]]; then
        COMMAND="compact"
        COMPACT_MODE=true
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--provider)   PROVIDER="$2"; shift 2 ;;
            -m|--model)      MODEL="$2"; shift 2 ;;
            --max-tokens)    MAX_TOKENS="$2"; shift 2 ;;
            --tool-timeout)  TOOL_TIMEOUT_SECS="$2"; shift 2 ;;
            --system)        SYSTEM_PROMPT="$2"; shift 2 ;;
            --skill)         SKILL_NAMES+=("$2"); shift 2 ;;
            --max-turns)     MAX_TURNS="$2"; shift 2 ;;
            --max-context)   MAX_CONTEXT_MESSAGES="$2"; shift 2 ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            --output-format)  OUTPUT_FORMAT="$2"; shift 2 ;;
            --print)         OUTPUT_FORMAT="stream-json"; shift ;;
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

    case "$OUTPUT_FORMAT" in
        human|stream-json) ;;
        *)
            die "Unknown output format: $OUTPUT_FORMAT (use human|stream-json)"
            ;;
    esac
}

list_sessions() {
    local dir
    dir="${HOME}/.bash-agent/projects/$(get_project_key)"
    if [[ ! -d "$dir" ]]; then
        echo "No sessions found."
        return
    fi
    local files
    files=$(ls -t "$dir"/*.jsonl 2>/dev/null | grep -v '\.events\.jsonl$' | grep -v '\.summary\.txt$')
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

    if [[ "$COMMAND" == "compact" && "$SESSION_MODE" != true && "$CONTINUE_SESSION" != true && -z "$SESSION_ID" ]]; then
        SESSION_MODE=true
        CONTINUE_SESSION=true
        COMPACT_MODE=true
    fi

    AGENT_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/agent.XXXXXX")
    find_awk_dir
    conv_init

    if [[ "$COMMAND" == "compact" ]]; then
        if compact_context_window "manual" true; then
            if [[ "$OUTPUT_FORMAT" == "human" ]]; then
                log_info "Context compacted."
            fi
        else
            if [[ "$OUTPUT_FORMAT" == "human" ]]; then
                log_info "Context is within budget; no compaction needed."
            fi
        fi
    elif [[ "$INTERACTIVE" == true ]]; then
        TOOL_DEF_FILE=$(generate_tool_defs)
        interactive_mode
    elif [[ -n "$PROMPT" ]]; then
        TOOL_DEF_FILE=$(generate_tool_defs)
        agent_loop "$PROMPT"
    elif [[ ! -t 0 ]]; then
        TOOL_DEF_FILE=$(generate_tool_defs)
        local input
        input=$(cat)
        agent_loop "$input"
    else
        usage
    fi
}

main "$@"
