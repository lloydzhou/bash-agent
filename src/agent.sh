#!/usr/bin/env bash
# bash-agent — AI Agent in pure bash/awk
# Supports: Anthropic Claude, OpenAI Chat
# No dependencies beyond: bash, curl, awk

set -uo pipefail

# ============================================================================
# Section 1: User Options
# ============================================================================
PROVIDER="claude"
MODEL=""
MAX_TOKENS=4096
SUMMARY_MAX_TOKENS=1024
TOOL_TIMEOUT_SECS=600
TOOL_RESULT_MAX_BYTES=50000
FILE_WRITE_MAX_BYTES=1048576
OUTPUT_FORMAT="human"
VERBOSE=false
API_KEY=""
BASE_URL=""
PROMPT=""
MAX_TURNS=20
MAX_CONTEXT_BYTES=200000
MAX_CONTEXT_KEEP_PCT=25
declare -a SKILL_NAMES=()

# ============================================================================
# Section 2: Runtime Mode & Session State
# ============================================================================
INTERACTIVE=false
COMMAND="chat"
SESSION_MODE=false
SESSION_ID=""
CONTINUE_SESSION=false
SESSION_EVENT_FILE=""
CONTEXT_SUMMARY_FILE=""
TODO_FILE=""

# ============================================================================
# Section 3: Internal Runtime State
# ============================================================================
CONV_FILE=""
TOOL_DEF_FILE=""
AGENT_TMPDIR=""
API_URL=""
AWK_DIR=""
EXEC_TOOL_RESULTS=""
INTERRUPT_REQUESTED=false
ESC_LISTENER_PID=""
ESC_LISTENER_FLAG=""

# ============================================================================
# Section 4: Environment Defaults
# ============================================================================
: "${ANTHROPIC_API_KEY:=}"
: "${OPENAI_API_KEY:=}"
: "${ANTHROPIC_BASE_URL:=}"
: "${OPENAI_BASE_URL:=}"

# ============================================================================
# Section 5: Utility Functions
# ============================================================================

log_error() {
    printf '\033[31mError: %s\033[0m\n' "$*" >&2
}

log_info() {
    printf '\033[36m%s\033[0m\n' "$*" >&2
}

log_tool() {
    printf '\033[33m[tool] %s\033[0m\n' "$*"
}

log_verbose() {
    $VERBOSE && printf '\033[90m[verbose] %s\033[0m\n' "$*" >&2
}

deny_bash_command_reason() {
    local cmd="$1"
    local device_write_re='(^|[[:space:]])(of=|>|1>|>>|1>>)[[:space:]]*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)([[:space:]]|$)'

    [[ -z "$cmd" ]] && return 1

    case "$cmd" in
        sudo\ *|shutdown*|reboot*|halt*|poweroff*|mkfs*|fdisk*)
            printf 'blocked dangerous command prefix'
            return 0
            ;;
    esac

    [[ "$cmd" == *'rm -rf /'* || "$cmd" == *'rm -fr /'* ]] && {
        printf 'blocked destructive root deletion pattern'
        return 0
    }
    [[ "$cmd" =~ $device_write_re ]] && {
        printf 'blocked device write pattern'
        return 0
    }
    [[ "$cmd" == *'find '* && "$cmd" == *' -delete'* ]] && {
        printf 'blocked destructive find -delete pattern'
        return 0
    }
    [[ "$cmd" == *':(){:|:&};:'* ]] && {
        printf 'blocked fork bomb pattern'
        return 0
    }

    return 1
}

tool_call_arg() {
    local payload="$1" key="$2" __outvar="$3"
    local fields=() i field_name field_value
    IFS=$'\t' read -r -a fields <<< "$payload"
    for (( i = 0; i + 1 < ${#fields[@]}; i += 2 )); do
        field_name="${fields[i]}"
        field_value="${fields[i+1]}"
        if [[ "$field_name" == "$key" ]]; then
            unescape_protocol_to_var field_value "$field_value"
            printf -v "$__outvar" '%s' "$field_value"
            return 0
        fi
    done
    printf -v "$__outvar" '%s' ""
    return 1
}

tool_metadata() {
    local name="$1" __keys_outvar="$2" __summary_outvar="$3" meta_keys="" meta_summary_key=""
    case "$name" in
        Read)
            meta_keys="path"
            meta_summary_key="path"
            ;;
        Write)
            meta_keys="path content"
            meta_summary_key="path"
            ;;
        Edit)
            meta_keys="path old_string new_string"
            meta_summary_key="path"
            ;;
        Bash)
            meta_keys="command"
            meta_summary_key="command"
            ;;
        Glob)
            meta_keys="pattern path"
            meta_summary_key="pattern"
            ;;
        Grep)
            meta_keys="pattern path glob"
            meta_summary_key="pattern"
            ;;
        TodoWrite)
            meta_keys="checklist summary"
            meta_summary_key="summary"
            ;;
    esac
    printf -v "$__keys_outvar" '%s' "$meta_keys"
    printf -v "$__summary_outvar" '%s' "$meta_summary_key"
}

tool_call_summary() {
    local name="$1" payload="${2:-}" label="" value="" summary_key="" _
    tool_metadata "$name" _ summary_key
    if [[ "$name" == "Bash" && -n "$summary_key" ]]; then
        tool_call_arg "$payload" "$summary_key" value || true
        if [[ -n "$value" ]]; then
            value="${value//$'\n'/ }"
            if (( ${#value} > 80 )); then
                value="${value:0:77}..."
            fi
            label="$value"
        fi
    fi
    if [[ -n "$summary_key" && -z "$label" ]]; then
        tool_call_arg "$payload" "$summary_key" value || true
        [[ -n "$value" ]] && label="$value"
    fi
    if [[ -n "$label" ]]; then
        printf '%s(%s)' "$name" "$label"
    else
        printf '%s' "$name"
    fi
}

escape_protocol_text() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '%s' "$value"
}

parse_tool_call_record() {
    local payload="$1" __namevar="$2" __idvar="$3" __inputvar="$4" __kvvar="$5"
    local name="" id="" input_value="" kv_value=""
    IFS=$'\t' read -r name id input_value kv_value <<< "$payload"
    unescape_protocol_to_var input_value "$input_value"
    printf -v "$__namevar" '%s' "$name"
    printf -v "$__idvar" '%s' "$id"
    printf -v "$__inputvar" '%s' "$input_value"
    printf -v "$__kvvar" '%s' "$kv_value"
}

parse_usage_fields() {
    local payload="$1" __inputvar="$2" __outputvar="$3" __cachevar="$4"
    local input_value="" output_value="" cache_value=""
    IFS=$'\t' read -r input_value output_value cache_value <<< "$payload"
    printf -v "$__inputvar" '%s' "${input_value:-0}"
    printf -v "$__outputvar" '%s' "${output_value:-0}"
    printf -v "$__cachevar" '%s' "${cache_value:-0}"
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

die() {
    log_error "$@"
    exit 1
}

parse_size_bytes() {
    local raw="${1:-}" lower num
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *k)
            num="${lower%k}"
            [[ "$num" =~ ^[0-9]+$ ]] || return 1
            printf '%s' $(( num * 1000 ))
            ;;
        *m)
            num="${lower%m}"
            [[ "$num" =~ ^[0-9]+$ ]] || return 1
            printf '%s' $(( num * 1000 * 1000 ))
            ;;
        *g)
            num="${lower%g}"
            [[ "$num" =~ ^[0-9]+$ ]] || return 1
            printf '%s' $(( num * 1000 * 1000 * 1000 ))
            ;;
        *)
            [[ "$lower" =~ ^[0-9]+$ ]] || return 1
            printf '%s' "$lower"
            ;;
    esac
}

json_escape() {
    local input="${1:-}"
    printf '%s' "$input" | awk \
        -v json_mode="escape_string" \
        -f "$AWK_DIR/json.awk" \
        -f "$AWK_DIR/json_cli.awk"
}

strip_ansi() {
    local input="$1"
    printf '%s' "$input" | awk '
    {
        gsub(/\033\[[0-9;]*[[:alpha:]]/, "", $0)
        print
    }'
}

format_tool_result() {
    local output="$1"
    local size marker marker_bytes available head_chars tail_chars

    size=$(printf '%s' "$output" | wc -c)
    size=${size//[[:space:]]/}
    if (( size <= TOOL_RESULT_MAX_BYTES )); then
        printf '%s' "$output"
        return 0
    fi

    marker=$'\n[... omitted, original result was '"$size"$' bytes ...]\n'
    marker_bytes=$(printf '%s' "$marker" | wc -c)
    marker_bytes=${marker_bytes//[[:space:]]/}
    available=$(( TOOL_RESULT_MAX_BYTES - marker_bytes ))
    if (( available < 2 )); then
        printf '%s' "${output:0:TOOL_RESULT_MAX_BYTES}"
        return 0
    fi

    head_chars=$(( available / 2 ))
    tail_chars=$(( available - head_chars ))
    printf '%s' "${output:0:head_chars}"
    printf '%s' "$marker"
    printf '%s' "${output: -tail_chars}"
}

is_stream_json_mode() {
    [[ "$OUTPUT_FORMAT" == "stream-json" ]]
}

wrap_section() {
    local tag="$1" content="$2" name="${3:-}"
    if [[ -z "$content" ]]; then
        printf ''
        return 0
    fi
    if [[ -n "$name" ]]; then
        printf '<%s name="%s">\n%s\n</%s>' "$tag" "$(json_escape "$name")" "$content" "$tag"
    else
        printf '<%s>\n%s\n</%s>' "$tag" "$content" "$tag"
    fi
}

append_section() {
    local __outvar="$1" tag="$2" content="$3" name="${4:-}"
    [[ -n "$content" ]] || return 0
    printf -v "$__outvar" '%s%s%s\n' "${!__outvar}" "$(wrap_section "$tag" "$content" "$name")" ""
}

session_append_line() {
    [[ "$SESSION_MODE" == true && -n "${SESSION_EVENT_FILE:-}" ]] || return 0
    printf '%s\n' "$1" >> "$SESSION_EVENT_FILE"
}

emit_stream_event() {
    printf '%s\n' "$1"
}

build_system_prompt() {
    local output=""
    local agent_identity core_rules todo_guidance instruction_files skill_index selected_skills stable_context todo
    agent_identity='You are bash-agent, a lightweight coding agent that works in a terminal.'
    core_rules=$'- Be concise and concrete.\n- Use tools when needed.\n- Prefer safe, exact edits.\n- For Edit, Read first and copy old_string exactly (including whitespace/indent/newlines).\n- Report failures clearly.'
    todo_guidance=$'- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.'

    instruction_files=$(build_instruction_files_section)
    skill_index=$(build_skill_index_section)
    selected_skills=$(build_selected_skills_section)
    stable_context=$(build_stable_context_section)
    todo=$(build_todo_section)

    append_section output "agent-identity" "$agent_identity"
    append_section output "rules" "$core_rules"
    append_section output "todo-guidance" "$todo_guidance"
    append_section output "instruction-files" "$instruction_files"
    append_section output "skill-index" "$skill_index"
    append_section output "selected-skills" "$selected_skills"
    append_section output "context-summary" "$stable_context"
    append_section output "current-todo" "$todo"

    printf '%s' "${output%$'\n'}"
}

read_optional_file() {
    local path="$1"
    if [[ -n "$path" && -s "$path" ]]; then
        printf '%s' "$(<"$path")"
        return 0
    fi
    printf ''
}

find_skill_base_dirs() {
    local cwd home
    cwd="${PWD:-$(pwd)}"
    home="${HOME:-}"
    if [[ -d "$cwd/.claude/skills" ]]; then
        printf '%s\n' "$cwd/.claude/skills"
    fi
    if [[ -n "$home" && -d "$home/.claude/skills" ]]; then
        printf '%s\n' "$home/.claude/skills"
    fi
}

load_skill_content() {
    local skill_name="$1" base skill_file skill_dir content
    while IFS= read -r base; do
        [[ -n "$base" ]] || continue
        skill_file="$base/$skill_name/SKILL.md"
        [[ -f "$skill_file" ]] || continue
        skill_dir=$(dirname "$skill_file")
        content=$(<"$skill_file") || return 1
        content="${content//\$\{BASH_AGENT_SKILL_DIR\}/$skill_dir}"
        printf 'Base directory for this skill: %s\n\n%s' "$skill_dir" "$content"
        return 0
    done < <(find_skill_base_dirs)
    return 1
}

build_skill_index_section() {
    local base skill_file skill_name summary output="" seen=$'\n'
    while IFS= read -r base; do
        [[ -n "$base" ]] || continue
        for skill_file in "$base"/*/SKILL.md; do
            [[ -f "$skill_file" ]] || continue
            skill_name=$(basename "$(dirname "$skill_file")")
            if [[ "$seen" == *$'\n'"$skill_name"$'\n'* ]]; then
                continue
            fi
            seen+="$skill_name"$'\n'
            summary=$(awk -f "$AWK_DIR/skill_summary.awk" "$skill_file")
            output+="- ${skill_name}"
            [[ -n "$summary" ]] && output+=": ${summary}"
            output+=$'\n'
        done
    done < <(find_skill_base_dirs)

    printf '%s' "${output%$'\n'}"
}

build_selected_skills_section() {
    local output="" skill_name skill_content

    if [[ ${#SKILL_NAMES[@]} -eq 0 ]]; then
        printf ''
        return 0
    fi

    for skill_name in "${SKILL_NAMES[@]}"; do
        skill_content=$(load_skill_content "$skill_name") || die "Skill not found: $skill_name (expected .claude/skills/$skill_name/SKILL.md or ~/.claude/skills/$skill_name/SKILL.md)"
        append_section output "skill" "$skill_content" "$skill_name"
    done
    printf '%s' "${output%$'\n'}"
}

find_instruction_file_in_dir() {
    local dir="$1" candidate
    [[ -n "$dir" && -d "$dir" ]] || return 1
    for candidate in \
        "$dir/AGENTS.md" \
        "$dir/AGENT.md" \
        "$dir/CLAUDE.md" \
        "$dir/.claude/CLAUDE.md"
    do
        if [[ -f "$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

build_instruction_files_section() {
    local output="" global_file project_file global_content project_content
    global_file=$(find_instruction_file_in_dir "${HOME}/.bash-agent" 2>/dev/null || true)
    project_file=$(find_instruction_file_in_dir "${PWD:-$(pwd)}" 2>/dev/null || true)

    if [[ -n "$global_file" ]]; then
        global_content=$(<"$global_file") || return 1
        append_section output "instruction-file" "$global_content" "global"
    fi

    if [[ -n "$project_file" ]]; then
        project_content=$(<"$project_file") || return 1
        append_section output "instruction-file" "$project_content" "project"
    fi

    printf '%s' "${output%$'\n'}"
}

build_compact_summary_system_prompt() {
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

# Unescape the single-line protocol escaping used between awk and bash.
unescape_protocol_to_var() {
    local __outvar="$1" value="$2" backslash_placeholder=$'\001'
    value="${value//\\\\/$backslash_placeholder}"
    value="${value//\\n/$'\n'}"
    value="${value//\\r/$'\r'}"
    value="${value//\\t/$'\t'}"
    value="${value//\\\"/\"}"
    value="${value//$backslash_placeholder/\\}"
    printf -v "$__outvar" '%s' "$value"
}

build_tool_call_json_object() {
    local name="$1" id="$2" input_escaped="$3" type="${4:-tool_use}"
    local input
    unescape_protocol_to_var input "$input_escaped"
    if [[ "$type" == "tool_use" ]]; then
        printf '{"type":"tool_use","id":"%s","name":"%s","input":%s}' \
            "$(json_escape "$id")" \
            "$(json_escape "$name")" \
            "$input"
    else
        printf '{"name":"%s","id":"%s","input":%s}' \
            "$(json_escape "$name")" \
            "$(json_escape "$id")" \
            "$input"
    fi
}

build_tool_result_json_object() {
    local tid="$1" result="$2" type="${3:-tool_result}"
    printf '{"type":"%s","tool_use_id":"%s","content":"%s"}' \
        "$(json_escape "$type")" \
        "$(json_escape "$tid")" \
        "$result"
}

build_tool_calls_json() {
    local calls="$1"
    local tool_json="[" first=true
    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local name id input_escaped
        IFS=$'\t' read -r name id input_escaped _ <<< "$tc"
        $first || tool_json+=","
        first=false
        tool_json+="$(build_tool_call_json_object "$name" "$id" "$input_escaped" "tool_call")"
    done <<< "$calls"
    tool_json+="]"
    printf '%s' "$tool_json"
}

build_assistant_content_json() {
    local text="$1" calls="$2"
    local content="[" first=true

    if [[ -n "$text" ]]; then
        content+="{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}"
        first=false
    fi

    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local name id input_escaped
        IFS=$'\t' read -r name id input_escaped _ <<< "$tc"
        $first || content+=","
        first=false
        content+="$(build_tool_call_json_object "$name" "$id" "$input_escaped")"
    done <<< "$calls"

    content+="]"
    printf '%s' "$content"
}

build_tool_results_content_json() {
    local results="$1"
    local content="[" first=true

    while IFS= read -r tr; do
        [[ -z "$tr" ]] && continue
        local tid result
        IFS=$'\t' read -r tid result <<< "$tr"
        $first || content+=","
        first=false
        content+="$(build_tool_result_json_object "$tid" "$result")"
    done <<< "$results"

    content+="]"
    printf '%s' "$content"
}

build_tool_result_event_json() {
    local tid="$1" result="$2"
    build_tool_result_json_object "$tid" "$result"
}

build_todo_event_json() {
    local checklist="$1"
    printf '{"type":"todo_update","content":"%s"}' "$(json_escape "$checklist")"
}

cleanup() {
    stop_esc_interrupt_listener
    # Only clean tmpdir, not session files
    [[ -n "${AGENT_TMPDIR:-}" && -d "${AGENT_TMPDIR:-}" ]] && rm -rf "$AGENT_TMPDIR"
}
trap cleanup EXIT
trap 'INTERRUPT_REQUESTED=true' USR1

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
    printf '%s' "$cwd" | awk '
    {
        sub(/^\/+/, "", $0)
        gsub(/\//, "-", $0)
        gsub(/[^A-Za-z0-9._-]/, "-", $0)
        gsub(/-+/, "-", $0)
        sub(/^-+/, "", $0)
        sub(/-+$/, "", $0)
        print "-" $0
    }'
}

# ============================================================================
# Section 3: Conversation Management (temp file, one JSON message per line)
# ============================================================================

conv_init() {
    if [[ "$SESSION_MODE" == true ]]; then
        local session_dir
        session_dir="${HOME}/.bash-agent/projects/$(get_project_key)"
        mkdir -p "$session_dir"

        local session_base=""
        if [[ -n "$SESSION_ID" ]]; then
            # Named session
            session_base="$SESSION_ID"
        elif [[ "$CONTINUE_SESSION" == true ]]; then
            # Continue most recent session
            CONV_FILE=$(ls -t "${session_dir}"/*.jsonl 2>/dev/null | grep -Ev '\.(events\.jsonl|summary\.txt)$' | head -1)
            if [[ -n "$CONV_FILE" ]]; then
                session_base="$(basename "$CONV_FILE" .jsonl)"
            elif [[ "$COMMAND" == "compact" ]]; then
                die "No existing session found to compact. Use --session NAME or run a session first."
            else
                session_base="$(date +%Y%m%d-%H%M%S)"
            fi
        else
            # New unnamed session
            session_base="$(date +%Y%m%d-%H%M%S)"
        fi

        [[ -z "$session_base" ]] && session_base="$(date +%Y%m%d-%H%M%S)"
        CONV_FILE="${session_dir}/${session_base}.jsonl"
        SESSION_EVENT_FILE="${session_dir}/${session_base}.events.jsonl"
        CONTEXT_SUMMARY_FILE="${session_dir}/${session_base}.summary.txt"
        TODO_FILE="${session_dir}/${session_base}.todo.md"
        local new_session=false
        [[ ! -s "$SESSION_EVENT_FILE" ]] && new_session=true
        touch "$CONV_FILE"
        touch "$SESSION_EVENT_FILE"
        touch "$CONTEXT_SUMMARY_FILE"
        touch "$TODO_FILE"
        if [[ "$new_session" == true ]]; then
            session_append_line "{\"type\":\"session_start\",\"session_id\":\"$(json_escape "$session_base")\"}"
        fi
    else
        # Ephemeral: use tmpdir (cleaned on exit)
        CONV_FILE=$(mktemp "${AGENT_TMPDIR}/conv.XXXXXX")
        CONTEXT_SUMMARY_FILE=$(mktemp "${AGENT_TMPDIR}/summary.XXXXXX")
        TODO_FILE=$(mktemp "${AGENT_TMPDIR}/todo.XXXXXX")
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
    local content
    content=$(build_assistant_content_json "$text" "$calls")
    printf '{"role":"assistant","content":%s}\n' "$content" >> "$CONV_FILE"
    session_log_assistant "$text" "$calls"
}

conv_add_tool_results() {
    local results="$1"
    local content
    content=$(build_tool_results_content_json "$results")
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

context_append_summary() {
    local text="$1"
    [[ -n "${CONTEXT_SUMMARY_FILE:-}" ]] || return 0
    [[ -n "$text" ]] || return 0
    printf '%s\n' "$text" > "$CONTEXT_SUMMARY_FILE"
}

build_stable_context_section() {
    read_optional_file "${CONTEXT_SUMMARY_FILE:-}"
}

build_todo_section() {
    read_optional_file "${TODO_FILE:-}"
}

build_compact_summary_user_prompt() {
    local current_summary="$1" dropped_messages="$2" summary_section dropped_section
    summary_section=$(wrap_section "current-summary" "$current_summary")
    dropped_section=$(wrap_section "dropped-messages" "$dropped_messages")
    cat <<EOF
${summary_section}

${dropped_section}
EOF
}

compact_keep_lines() {
    local target_keep_bytes="$1"
    awk -v target_bytes="$target_keep_bytes" '
        {
            sizes[NR] = length($0) + 1
            turn_start[NR] = ($0 ~ /^\{"role":"user","content":"/)
        }
        END {
            keep = 0
            bytes = 0
            for (i = NR; i >= 1; i--) {
                if (keep > 0 && bytes + sizes[i] > target_bytes) break
                bytes += sizes[i]
                keep++
            }
            if (keep == 0 && NR > 0) keep = 1

            start = NR - keep + 1
            adjusted = start
            while (adjusted <= NR && !turn_start[adjusted]) {
                adjusted++
            }

            if (adjusted <= NR) {
                start = adjusted
            } else {
                while (start > 1 && !turn_start[start]) {
                    start--
                }
            }

            print NR - start + 1
        }
    ' "$CONV_FILE"
}

compact_context_window() {
    local trigger="$1" force="${2:-false}" total_bytes total_lines keep_lines drop tmp_dropped dropped_messages current_summary prompt summary_request summary_response
    local threshold=$MAX_CONTEXT_BYTES
    local target_keep_bytes=$(( MAX_CONTEXT_BYTES * MAX_CONTEXT_KEEP_PCT / 100 ))

    total_bytes=$(wc -c < "$CONV_FILE" 2>/dev/null || echo 0)
    total_lines=$(wc -l < "$CONV_FILE" 2>/dev/null || echo 0)
    (( target_keep_bytes < 1 )) && target_keep_bytes=1

    if ! $force && (( total_bytes <= threshold )); then
        return 1
    fi

    keep_lines=$(compact_keep_lines "$target_keep_bytes")
    [[ -n "$keep_lines" ]] || keep_lines=0
    (( total_lines > keep_lines )) || keep_lines=$total_lines
    drop=$(( total_lines - keep_lines ))
    [[ $drop -gt 0 ]] || return 1

    tmp_dropped=$(mktemp "${AGENT_TMPDIR}/dropped.XXXXXX")
    head -n "$drop" "$CONV_FILE" > "$tmp_dropped"
    dropped_messages=$(<"$tmp_dropped")
    current_summary=""
    if [[ -n "${CONTEXT_SUMMARY_FILE:-}" && -s "$CONTEXT_SUMMARY_FILE" ]]; then
        current_summary=$(<"$CONTEXT_SUMMARY_FILE")
    fi

    prompt=$(build_compact_summary_user_prompt "$current_summary" "$dropped_messages")
    if [[ "$trigger" == "manual" && -z "${API_URL:-}" ]]; then
        validate_config
        setup_api_url
    fi
    summary_request="[{\"role\":\"user\",\"content\":\"$(json_escape "$prompt")\"}]"
    summary_response=$(run_summary_call "$summary_request")
    context_append_summary "$summary_response"

    if (( keep_lines < total_lines )); then
        tmp=$(mktemp "${AGENT_TMPDIR}/conv_trim.XXXXXX")
        tail -n "$keep_lines" "$CONV_FILE" > "$tmp"
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
    local tool_json
    tool_json=$(build_tool_calls_json "$calls")
    payload+=",\"tool_calls\":${tool_json}}"
    session_append_line "$payload"
}

session_log_tool_results() {
    local results="$1"
    while IFS= read -r tr; do
        [[ -z "$tr" ]] && continue
        local tid result
        IFS=$'\t' read -r tid result <<< "$tr"
        session_append_line "$(build_tool_result_event_json "$tid" "$result")"
    done <<< "$results"
}

# ============================================================================
# Section 6: Tool Definitions (auto-generated JSON)
# ============================================================================

get_tool_defs_file() {
    local tools_file script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    tools_file="$script_dir/tools.json"
    [[ -f "$tools_file" ]] || die "Cannot find tools.json: $tools_file"
    printf '%s' "$tools_file"
}

# ============================================================================
# Section 7: Tool Implementations
# ============================================================================

tool_read() {
    local path="$1"

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    [[ ! -r "$path" ]] && { echo "Error: permission denied: $path"; return 1; }

    cat "$path"
}

tool_write() {
    local path="$1" content="$2" content_size

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    content_size=$(printf '%s' "$content" | wc -c)
    content_size=${content_size//[[:space:]]/}
    if (( content_size > FILE_WRITE_MAX_BYTES )); then
        echo "Error: content too large for write_file (${content_size} bytes > ${FILE_WRITE_MAX_BYTES} bytes)"
        return 1
    fi

    mkdir -p "$(dirname "$path")" 2>/dev/null
    printf '%s' "$content" > "$path"
    echo "OK: wrote $(wc -c < "$path" 2>/dev/null || echo '?') bytes to $path"
}

tool_edit() {
    local path="$1" old_string="$2" new_string="$3"
    local input tmp meta
    input=$(printf '{"path":"%s","old_string":"%s","new_string":"%s"}' \
        "$(json_escape "$path")" \
        "$(json_escape "$old_string")" \
        "$(json_escape "$new_string")")
    tmp=$(mktemp "${AGENT_TMPDIR}/edit.XXXXXX")
    meta=$(mktemp "${AGENT_TMPDIR}/edit.meta.XXXXXX")
    if ! run_edit_file_awk "$input" "$FILE_WRITE_MAX_BYTES" "$meta" > "$tmp"; then
        rm -f "$tmp"
        rm -f "$meta"
        return 1
    fi
    path=$(<"$meta")
    rm -f "$meta"
    [[ -n "$path" ]] || { rm -f "$tmp"; echo "Error: no path provided"; return 1; }

    if (( $(wc -c < "$tmp") > 0 )); then
        mv "$tmp" "$path"
        echo "OK: edited $path"
    else
        rm -f "$tmp"
        echo "Error: edit produced empty result, reverted"
        return 1
    fi
}

tool_bash() {
    local cmd="$1" script_file
    local reason

    [[ -z "$cmd" ]] && { echo "Error: no command provided"; return 1; }
    reason=$(deny_bash_command_reason "$cmd") || reason=""
    if [[ -n "$reason" ]]; then
        echo "Error: command blocked by bash safety policy ($reason)"
        return 1
    fi

    local output
    script_file=$(mktemp "${AGENT_TMPDIR}/bash.XXXXXX.sh")
    printf '%s\n' "$cmd" > "$script_file"
    chmod 700 "$script_file" 2>/dev/null || true
    output=$(run_with_timeout "$TOOL_TIMEOUT_SECS" bash "$script_file") || true
    rm -f "$script_file"
    printf '%s' "$output"
}

tool_glob() {
    local pattern="$1" path="$2"

    [[ -z "$pattern" ]] && { echo "Error: no pattern provided"; return 1; }
    [[ -n "$path" ]] || path="."
    [[ -d "$path" ]] || { echo "Error: directory not found: $path"; return 1; }
    command -v rg >/dev/null 2>&1 || { echo "Error: rg is required for glob"; return 1; }
    rg --files "$path" -g "$pattern" 2>/dev/null || true
}

tool_grep() {
    local pattern="$1" path="$2" glob="$3"

    [[ -z "$pattern" ]] && { echo "Error: no pattern provided"; return 1; }
    [[ -n "$path" ]] || path="."
    [[ -e "$path" ]] || { echo "Error: path not found: $path"; return 1; }
    command -v rg >/dev/null 2>&1 || { echo "Error: rg is required for grep"; return 1; }
    if [[ -n "$glob" ]]; then
        rg -n --color never --glob "$glob" -- "$pattern" "$path" 2>/dev/null || true
    else
        rg -n --color never -- "$pattern" "$path" 2>/dev/null || true
    fi
}

tool_todo() {
    local checklist="$1"
    printf '%s\n' "$checklist" > "$TODO_FILE"
    session_append_line "$(build_todo_event_json "$checklist")"
    printf '%s' "$checklist"
}

dispatch_tool() {
    local name="$1" arg1="${2:-}" arg2="${3:-}" arg3="${4:-}"
    case "$name" in
        Read)      tool_read "$arg1" ;;
        Write)     tool_write "$arg1" "$arg2" ;;
        Edit)      tool_edit "$arg1" "$arg2" "$arg3" ;;
        Bash)      tool_bash "$arg1" ;;
        Glob)      tool_glob "$arg1" "$arg2" ;;
        Grep)      tool_grep "$arg1" "$arg2" "$arg3" ;;
        TodoWrite) tool_todo "$arg1" ;;
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

build_request() {
    local messages="$1" tools="$2" system_prompt="${3:-}" max_tokens="${4:-$MAX_TOKENS}"
    case "$PROVIDER" in
        claude)            build_claude_request "$messages" "$tools" "$system_prompt" "$max_tokens" ;;
        openai)            build_openai_request "$messages" "$tools" "$system_prompt" "$max_tokens" ;;
    esac
}

# ============================================================================
# Section 8: SSE Parsers (call awk/*.awk)
# ============================================================================

parse_http_stream() {
    awk -f "$AWK_DIR/http_stream.awk"
}

run_edit_file_awk() {
    local input="$1" max_bytes="$2" meta_file="$3"
    printf '%s' "$input" | awk \
        -v max_bytes="$max_bytes" \
        -v meta_file="$meta_file" \
        -f "$AWK_DIR/json.awk" \
        -f "$AWK_DIR/edit_file.awk"
}

parse_sse() {
    case "$PROVIDER" in
        claude) awk -v verbose="${VERBOSE:-false}" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" ;;
        openai) awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/openai_sse.awk" ;;
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
        "$API_URL" 2>&1 | parse_http_stream
}

call_api() {
    local body="$1"
    case "$PROVIDER" in
        claude)
            _stream_curl "$body" \
                -H "Content-Type: application/json" \
                -H "x-api-key: ${API_KEY}" \
                -H "anthropic-version: 2023-06-01"
            ;;
        openai)
            _stream_curl "$body" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${API_KEY}"
            ;;
    esac
}

# ============================================================================
# Section 11: LLM Call (internal)
# ============================================================================

llm_call() {
    local messages="$1"
    local tools
    tools=$(<"$TOOL_DEF_FILE")

    local body
    body=$(build_request "$messages" "$tools")
    log_verbose "Request body ($((${#body} / 1024))KB): ${body:0:200}..."

    call_api "$body" | parse_sse
}

run_summary_call() {
    local messages="$1"
    local body text line
    body=$(build_request "$messages" "" "$(build_compact_summary_system_prompt)" "$SUMMARY_MAX_TOKENS")
    log_verbose "Summary request body ($((${#body} / 1024))KB): ${body:0:200}..."

    text=""
    while IFS= read -r line; do
        case "$line" in
            TEXT:*)
                local t="${line#TEXT:}"
                local d="$t"
                unescape_protocol_to_var d "$d"
                text+="$d"
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
    INTERRUPT_REQUESTED=false
    start_esc_interrupt_listener
    conv_add_user "$user_input"

    local turn=0
    local human_last_char=""

    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true

        local text="" tool_calls="" stop=""
        local cur_tool_name="" cur_tool_id="" input=""
        local loop_error=""

        [[ "$VERBOSE" == true ]] && printf '[debug] messages: %.500s...\n' "$(conv_get_messages)" >&2
        while IFS= read -r line; do
            if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                stop="interrupted"
                break
            fi
            [[ "$VERBOSE" == true ]] && printf '[debug] <%s>\n' "$line" >&2
            case "$line" in
                TEXT:*)
                    t="${line#TEXT:}"
                    local d="$t"
                    unescape_protocol_to_var d "$d"
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"text\",\"content\":\"$(json_escape "$d")\"}"
                    else
                        printf '%s' "$d"
                        if [[ -n "$d" ]]; then
                            human_last_char="${d: -1}"
                        fi
                    fi
                    text+="$d"
                    ;;
                TOOL_CALL:*)
                    if ! is_stream_json_mode; then
                        if [[ "$human_last_char" != $'\n' ]]; then
                            printf '\n'
                        fi
                        human_last_char=$'\n'
                    fi
                    local tool_call_payload="${line#TOOL_CALL:}"
                    local tool_kv=""
                    parse_tool_call_record "$tool_call_payload" cur_tool_name cur_tool_id input tool_kv
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"tool_call\",\"name\":\"$(json_escape "$cur_tool_name")\",\"id\":\"$(json_escape "$cur_tool_id")\",\"input\":$input}"
                    else
                        log_tool "$(tool_call_summary "$cur_tool_name" "$tool_kv")"
                    fi
                    tool_calls+="${cur_tool_name}"$'\t'"${cur_tool_id}"$'\t'"$(escape_protocol_text "$input")"$'\t'"${tool_kv}"$'\n'
                    ;;
                USAGE:*)
                    if is_stream_json_mode; then
                        local input_tokens output_tokens cache_input_tokens
                        parse_usage_fields "${line#USAGE:}" input_tokens output_tokens cache_input_tokens
                        emit_stream_event "{\"type\":\"usage\",\"input_tokens\":${input_tokens:-0},\"output_tokens\":${output_tokens:-0},\"cache_input_tokens\":${cache_input_tokens:-0}}"
                    fi
                    ;;
                STOP:*)
                    stop="${line#STOP:}"
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"stop\",\"reason\":\"$(json_escape "$stop")\"}"
                    else
                        if [[ "$human_last_char" != $'\n' ]]; then
                            printf '\n'
                        fi
                        human_last_char=$'\n'
                    fi
                    ;;
                ERROR:*)
                    if is_stream_json_mode; then
                        emit_stream_event "{\"type\":\"error\",\"message\":\"$(json_escape "${line#ERROR:}")\"}"
                    fi
                    loop_error="${line#ERROR:}"
                    stop="error"
                    break
                    ;;
            esac
        done < <(llm_call "$(conv_get_messages)")

        # Record assistant response
        conv_add_assistant "$text" "$tool_calls"

        case "$stop" in
            error)
                log_error "$loop_error"
                stop_esc_interrupt_listener
                return 1
                ;;
            end_turn|stop|done)
                compact_context_window "auto" false || true
                break
                ;;
            interrupted)
                stop_esc_interrupt_listener
                if [[ "$OUTPUT_FORMAT" == "human" ]]; then
                    if [[ "$human_last_char" != $'\n' ]]; then
                        printf '\n'
                        human_last_char=$'\n'
                    fi
                    log_info "Interrupted."
                fi
                break
                ;;
            tool_use|tool_calls)
                if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                    stop_esc_interrupt_listener
                    if [[ "$OUTPUT_FORMAT" == "human" ]]; then
                        if [[ "$human_last_char" != $'\n' ]]; then
                            printf '\n'
                            human_last_char=$'\n'
                        fi
                        log_info "Interrupted."
                    fi
                    break
                fi
                # Execute tools and continue
                local results=""
                execute_tool_calls "$tool_calls"
                results="$EXEC_TOOL_RESULTS"
                if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                    stop_esc_interrupt_listener
                    if [[ "$OUTPUT_FORMAT" == "human" ]]; then
                        if [[ "$human_last_char" != $'\n' ]]; then
                            printf '\n'
                            human_last_char=$'\n'
                        fi
                        log_info "Interrupted."
                    fi
                    break
                fi
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
    stop_esc_interrupt_listener
}

execute_tool_calls() {
    local calls="$1"
    EXEC_TOOL_RESULTS=""
    while IFS= read -r tc; do
        [[ "$INTERRUPT_REQUESTED" == true ]] && break
        [[ -z "$tc" ]] && continue
        local name id input_escaped kv_escaped input kv arg1="" arg2="" arg3=""
        IFS=$'\t' read -r name id input_escaped kv_escaped <<< "$tc"
        unescape_protocol_to_var input "$input_escaped"
        kv="$kv_escaped"
        local param_key_string="" summary_key="" param_keys=() idx param_value=""
        tool_metadata "$name" param_key_string summary_key
        if [[ -n "$param_key_string" ]]; then
            IFS=' ' read -r -a param_keys <<< "$param_key_string"
            for idx in "${!param_keys[@]}"; do
                param_value=""
                tool_call_arg "$kv" "${param_keys[idx]}" param_value || true
                case "$idx" in
                    0) arg1="$param_value" ;;
                    1) arg2="$param_value" ;;
                    2) arg3="$param_value" ;;
                esac
            done
        fi
        local output
        output=$(dispatch_tool "$name" "$arg1" "$arg2" "$arg3" 2>&1)
        local tool_rc=$?
        [[ "$INTERRUPT_REQUESTED" == true ]] && break
        output=$(strip_ansi "$output")
        if (( tool_rc != 0 )); then
            output="Error: tool execution failed: $output"
        fi
        output=$(format_tool_result "$output")
        # json_escape so newlines in output don't break the line-based format
        local escaped
        escaped=$(json_escape "$output")
        EXEC_TOOL_RESULTS+="${id}"$'\t'"${escaped}"$'\n'

        # Print tool_result event in stream-json mode
        if is_stream_json_mode; then
            if [[ "$name" == "TodoWrite" ]] && (( tool_rc == 0 )) && [[ -s "$TODO_FILE" ]]; then
                emit_stream_event "$(build_todo_event_json "$(<"$TODO_FILE")")"
            fi
            emit_stream_event "{\"type\":\"tool_result\",\"tool_use_id\":\"$(json_escape "$id")\",\"content\":\"$escaped\"}"
        else
            if [[ -n "$output" ]]; then
                printf '%s\n' "$output"
            fi
        fi
    done <<< "$calls"
}

# ============================================================================
# Section 13: CLI
# ============================================================================

usage() {
    cat <<'EOF'
Usage: agent.sh [options] [prompt]
       agent.sh compact [options]

Options:
  -p, --provider PROV     LLM provider: claude | openai (default: claude)
  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)
  --max-tokens N          Max output tokens (default: 4096)
  --tool-timeout N        Tool execution timeout in seconds (default: 600)
  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)
  --max-turns N           Max agent turns (default: 20)
  --max-context N         Max stored context bytes before compact (default: 200000; supports k/m/g)
  --api-key KEY           API key (default from env)
  --base-url URL          Override API base URL (for Ollama, DeepSeek, etc.)
  --output-format FMT     Output format: human | stream-json
  --print                 Alias for --output-format stream-json
  --session [NAME]        Use named session (persist conversation)
  --continue              Continue most recent session
  --list-sessions         List all saved sessions
  -v, --verbose           Verbose mode
  -i, --interactive       Interactive mode (REPL)
  -h, --help              Show this help

Environment:
  ANTHROPIC_API_KEY       API key for Claude
  OPENAI_API_KEY          API key for OpenAI
  ANTHROPIC_BASE_URL      Claude API base URL
  OPENAI_BASE_URL         OpenAI API base URL

Examples:
  ./agent.sh "Read /etc/hostname and tell me what it says"
  ./agent.sh -m claude-sonnet-4-20250514 "List files in /tmp"
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
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--provider)   PROVIDER="$2"; shift 2 ;;
            -m|--model)      MODEL="$2"; shift 2 ;;
            --max-tokens)    MAX_TOKENS="$2"; shift 2 ;;
            --tool-timeout)  TOOL_TIMEOUT_SECS="$2"; shift 2 ;;
            --skill)         SKILL_NAMES+=("$2"); shift 2 ;;
            --max-turns)     MAX_TURNS="$2"; shift 2 ;;
            --max-context)
                MAX_CONTEXT_BYTES=$(parse_size_bytes "$2") || die "Invalid --max-context value: $2"
                shift 2
                ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            --output-format)  OUTPUT_FORMAT="$2"; shift 2 ;;
            --print)         OUTPUT_FORMAT="stream-json"; shift ;;
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
    files=$(ls -t "$dir"/*.jsonl 2>/dev/null | grep -Ev '\.(events\.jsonl|summary\.txt)$')
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
    case "$PROVIDER" in
        claude)
            : "${API_KEY:=$ANTHROPIC_API_KEY}"
            : "${BASE_URL:=${ANTHROPIC_BASE_URL:-}}"
            : "${MODEL:=claude-sonnet-4-20250514}"
            ;;
        openai)
            : "${API_KEY:=$OPENAI_API_KEY}"
            : "${BASE_URL:=${OPENAI_BASE_URL:-}}"
            : "${MODEL:=gpt-4o}"
            ;;
        *)
            die "Unknown provider: $PROVIDER (use claude|openai)"
            ;;
    esac

    if [[ -z "$API_KEY" && -z "$BASE_URL" ]]; then
        case "$PROVIDER" in
            claude) die "No API key. Set ANTHROPIC_API_KEY or use --api-key" ;;
            openai) die "No API key. Set OPENAI_API_KEY or use --api-key" ;;
        esac
    fi
}

setup_api_url() {
    case "$PROVIDER" in
        claude)            API_URL="${BASE_URL:-https://api.anthropic.com/v1}/messages" ;;
        openai)            API_URL="${BASE_URL:-https://api.openai.com/v1}/chat/completions" ;;
    esac
}

interactive_mode() {
    log_info "bash-agent interactive mode (type 'exit' or Ctrl+D to quit)"
    while true; do
        stty echo 2>/dev/null || true
        IFS= read -e -r -p $'\033[32m> \033[0m' user_input || break
        [[ "$user_input" == "exit" || "$user_input" == "quit" ]] && break
        [[ -z "$user_input" ]] && continue
        agent_loop "$user_input"
    done
    log_info "Goodbye!"
}

start_esc_interrupt_listener() {
    [[ "$INTERACTIVE" == true ]] || return 0
    [[ -r /dev/tty ]] || return 0
    stop_esc_interrupt_listener
    ESC_LISTENER_FLAG=$(mktemp "${TMPDIR:-/tmp}/agent-esc.XXXXXX")
    (
        local c
        while [[ -f "$ESC_LISTENER_FLAG" ]]; do
            if IFS= read -r -s -n 1 -t 1 c < /dev/tty; then
                [[ "$c" == $'\e' ]] && kill -USR1 "$$" 2>/dev/null || true
            fi
        done
    ) &
    ESC_LISTENER_PID=$!
}

stop_esc_interrupt_listener() {
    if [[ -n "${ESC_LISTENER_FLAG:-}" ]]; then
        rm -f "$ESC_LISTENER_FLAG" 2>/dev/null || true
        ESC_LISTENER_FLAG=""
    fi
    if [[ -n "${ESC_LISTENER_PID:-}" ]]; then
        wait "$ESC_LISTENER_PID" 2>/dev/null || true
        ESC_LISTENER_PID=""
    fi
}

main() {
    parse_args "$@"

    if [[ "$COMMAND" == "compact" && "$SESSION_MODE" != true && "$CONTINUE_SESSION" != true && -z "$SESSION_ID" ]]; then
        SESSION_MODE=true
        CONTINUE_SESSION=true
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
    else
        validate_config
        setup_api_url
    fi

    if [[ "$COMMAND" == "compact" ]]; then
        :
    elif [[ "$INTERACTIVE" == true ]]; then
        TOOL_DEF_FILE=$(get_tool_defs_file)
        interactive_mode
    elif [[ -n "$PROMPT" ]]; then
        TOOL_DEF_FILE=$(get_tool_defs_file)
        agent_loop "$PROMPT"
    elif [[ ! -t 0 ]]; then
        TOOL_DEF_FILE=$(get_tool_defs_file)
        local input
        input=$(cat)
        agent_loop "$input"
    else
        TOOL_DEF_FILE=$(get_tool_defs_file)
        INTERACTIVE=true
        interactive_mode
    fi
}

main "$@"
