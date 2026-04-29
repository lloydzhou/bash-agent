#!/usr/bin/env bash
# bash-agent — AI Agent in pure bash/awk
# Supports: Anthropic Claude, OpenAI Chat
# No dependencies beyond: bash, curl, awk

set -uo pipefail

# --- User Options ---
PROVIDER="claude"
MODEL=""
MAX_TOKENS=4096
SUMMARY_MAX_TOKENS=1024
TOOL_TIMEOUT_SECS=600
: "${TOOL_RESULT_MAX_BYTES:=50000}"
FILE_WRITE_MAX_BYTES=1048576
OUTPUT_FORMAT="human"
VERBOSE=false
API_KEY=""
BASE_URL=""
USER_INPUT=""
MAX_TURNS=40
MAX_CONTEXT_TOKENS=200000
# --- Dynamic Planning Compact (DP) ---
: "${DP_P_INPUT:=3.0}"          # $/MTok，未命中缓存的输入价格
: "${DP_P_CACHE:=0.30}"        # $/MTok，命中缓存的输入价格
: "${DP_P_OUT:=15.0}"          # $/MTok，输出价格
: "${DP_V:=5000}"              # 固定前缀 token 数（system prompt + tools + summary）
: "${DP_S:=500}"               # 固定摘要长度 token 数
: "${DP_L:=5}"                 # 每轮用户输入平均 LLM 调用次数（0=从 stats 自动计算，默认≈5）
: "${DP_BASELINE_E:=8}"        # 预期剩余用户输入轮数（0=使用E_FIXED或2）
: "${DP_E_FIXED:=0}"           # 固定预期剩余步数（0=使用 DP_BASELINE_E）
: "${DP_R:=0.8}"               # 单次摘要信息保留率（递归摘要的指数衰减）
: "${DP_BETA:=0.03}"           # 信息损失惩罚系数（典型值 0.03）
: "${DP_MIN_KEEP_RATIO:=0.12}" # 最少保留消息比例（防止过度压缩）
declare -a SKILL_NAMES=()
: "${THINKING_BUDGET:=2048}"

# --- Runtime Mode & Session State ---
INTERACTIVE=false
SESSION_ID=""
SESSION_EVENT_FILE=""
CONTEXT_SUMMARY_FILE=""
TODO_FILE=""
PLAN_FILE=""
STATS_FILE=""
LOG_EVENTS=true

# --- Internal Runtime State ---
CONV_FILE=""
TOOL_DEF_JSON=""
API_URL=""
AWK_DIR=""
declare -a HEADER_ARGS=()
INTERRUPT_REQUESTED=false
ESC_LISTENER_PID=""
ESC_LISTENER_FLAG=""
DISPLAY_LAST_CHAR=$'\n'
PREV_WAS_THINKING=false

# --- Stats Cache (in-memory) --- Indexes match stats.awk _init_fields() order:
#   0:current_turn_count  1:agent_request_count  2:compact_request_count 3:total_input_tokens  4:total_output_tokens
#   5:total_cache_read_tokens 6:total_cache_creation_tokens  7:current_context_tokens  8:last_updated
STATS_CACHE=()

# --- Environment Defaults ---
: "${ANTHROPIC_API_KEY:=}"
: "${OPENAI_API_KEY:=}"
: "${ANTHROPIC_BASE_URL:=}"
: "${OPENAI_BASE_URL:=}"

# --- Utility Functions ---
awk_run() {
    LC_ALL=C LANG=C awk "$@"
}

write_message() {
    # Args: field0 field1 field2 ...
    # Wire format (RESP-like, CRLF): *N\r\n$len0\r\ndata0\r\n$len1\r\ndata1\r\n...
    local nfields=$# field byte_len
    printf '*%s\r\n' "$nfields"
    for field in "$@"; do
        byte_len=$(LC_ALL=C printf '%s' "$field" | wc -c)
        byte_len=${byte_len//[[:space:]]/}
        printf '$%s\r\n%s\r\n' "$byte_len" "$field"
    done
}

read_message() {
    # Reads RESP-like CRLF format: *N\r\n$len0\r\ndata0\r\n...
    REPLY_MESSAGE=()
    local nfields i _hdr _len _field

    IFS= LC_ALL=C read -r _hdr || [[ -n "$_hdr" ]]
    _hdr="${_hdr%$'\r'}"
    [[ -n "$_hdr" && "$_hdr" == \** ]] || return 1
    nfields="${_hdr:1}"

    for ((i = 0; i < nfields; i++)); do
        IFS= LC_ALL=C read -r _hdr || [[ -n "$_hdr" ]]
        _hdr="${_hdr%$'\r'}"
        [[ -n "$_hdr" && "$_hdr" == \$* ]] || return 1
        _len="${_hdr:1}"
        _field=""
        if (( _len > 0 )); then
            _field=$(dd bs=1 count="$((_len + 2))" 2>/dev/null)
            _field="${_field%$'\r'}"
        else
            IFS= LC_ALL=C read -r -n 2 _crlf 2>/dev/null || true
        fi
        REPLY_MESSAGE+=("$_field")
    done
    return 0
}

new_session_id() {
    printf '%s-%04x' "$(date +%Y%m%d-%H%M%S)" "$(( RANDOM << 1 | (RANDOM & 1) ))"
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

tool_param_keys() {
    case "$1" in
        Read) printf 'path offset limit' ;;
        Write) printf 'path content' ;;
        Edit) printf 'path old_string new_string' ;;
        Bash) printf 'command timeout' ;;
        Glob) printf 'pattern path' ;;
        Grep) printf 'pattern path glob context' ;;
        TodoWrite) printf 'checklist' ;;
        Skill) printf 'name' ;;
        WebSearch) printf 'query' ;;
        WebFetch) printf 'url' ;;
        *) printf '' ;;
    esac
}

tool_args_from_msg() {
    local name="$1"
    # Extract known params from flattened KV pairs at REPLY_MESSAGE[4..]
    local param_key_string="" param_keys=() idx param_value=""
    local -a _outvars=("$2" "$3" "$4" "$5")
    local _n=${#REPLY_MESSAGE[@]}

    param_key_string=$(tool_param_keys "$name")
    if [[ -n "$param_key_string" ]]; then
        IFS=' ' read -r -a param_keys <<< "$param_key_string"
        for idx in "${!param_keys[@]}"; do
            local _pkey="${param_keys[idx]}" i
            param_value=""
            for (( i = 4; i + 1 < _n; i += 2 )); do
                if [[ "${REPLY_MESSAGE[i]}" == "$_pkey" ]]; then
                    param_value="${REPLY_MESSAGE[i+1]}"
                    break
                fi
            done
            printf -v "${_outvars[idx]}" '%s' "$param_value"
        done
    fi
}

tool_call_summary() {
    local name="$1" label="" key=""
    shift
    case "$name" in
        Read|Write|Edit) key="path" ;;
        Bash) key="command" ;;
        Glob|Grep) key="pattern" ;;
        TodoWrite) key="summary" ;;
        Skill) key="name" ;;
        WebSearch) key="query" ;;
        WebFetch) key="url" ;;
    esac
    if [[ -n "$key" && $# -gt 0 ]]; then
        local i value=""
        for (( i = 1; i + 1 <= $#; i += 2 )); do
            if [[ "${!i}" == "$key" ]]; then
                local _vi=$(( i + 1 ))
                value="${!_vi}"
                break
            fi
        done
        if [[ "$name" == "Bash" && -n "$value" ]]; then
            value="${value//$'\n'/ }"
            (( ${#value} > 80 )) && value="${value:0:77}..."
        fi
        [[ -n "$value" ]] && label="$value"
    fi
    if [[ -n "$label" ]]; then
        printf '%s(%s)' "$name" "$label"
    else
        printf '%s' "$name"
    fi
}

clear_interrupt_state() {
    INTERRUPT_REQUESTED=false
    if [[ -n "${ESC_LISTENER_FLAG:-}" && -f "${ESC_LISTENER_FLAG:-}" ]]; then
        : > "$ESC_LISTENER_FLAG"
    fi
}

interrupt_requested() {
    [[ "$INTERRUPT_REQUESTED" == true ]] && return 0
    [[ -n "${ESC_LISTENER_FLAG:-}" && -s "${ESC_LISTENER_FLAG:-}" ]] && return 0
    return 1
}

run_with_timeout() {
    local timeout_secs="$1"
    shift
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${timeout_secs}s" "$@" 2>&1
    elif command -v timeout >/dev/null 2>&1; then
        timeout "${timeout_secs}s" "$@" 2>&1
    else
        # pure shell fallback (no timeout/gtimeout available)
        "$@" 2>&1 & local pid=$!
        ( sleep "$timeout_secs" && kill -TERM $pid 2>/dev/null ) & local watcher=$!
        wait $pid 2>/dev/null; local rc=$?; kill $watcher 2>/dev/null; return $(( rc == 143 ? 124 : rc ))
    fi
}

die() {
    printf '\033[31mError: %s\033[0m\n' "$*" >&2
    exit 1
}

parse_size_bytes() {
    local raw="${1:-}" lower num
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *k) num="${lower%k}";  [[ "$num" =~ ^[0-9]+$ ]] || return 1; printf '%s' $(( num * 1000 )) ;;
        *m) num="${lower%m}";  [[ "$num" =~ ^[0-9]+$ ]] || return 1; printf '%s' $(( num * 1000 * 1000 )) ;;
        *g) num="${lower%g}";  [[ "$num" =~ ^[0-9]+$ ]] || return 1; printf '%s' $(( num * 1000 * 1000 * 1000 )) ;;
        *)  [[ "$lower" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$lower" ;;
    esac
}

json_escape() {
    local input="${1:-}"
    printf '%s' "$input" | awk_run \
        -v json_mode="escape_string" \
        -f "$AWK_DIR/json.awk" \
        -f "$AWK_DIR/json_cli.awk"
}

format_tool_result() {
    local output="$1"
    if (( ${#output} <= TOOL_RESULT_MAX_BYTES )); then
        printf '%s' "$output"
        return 0
    fi

    local size=${#output}
    local marker=$'\n\n[... truncated: showing first/last portions of %d bytes ...]\n\n'
    local marker_len=$(( ${#marker} + 20 ))
    local tail_lines=5
    local tail_text
    tail_text=$(printf '%s' "$output" | tail -n "$tail_lines")
    local tail_len=${#tail_text}
    local head_len=$(( TOOL_RESULT_MAX_BYTES - marker_len - tail_len ))
    (( head_len > 0 )) || head_len=$(( TOOL_RESULT_MAX_BYTES / 2 ))

    printf '%s' "${output:0:$head_len}"
    printf "$marker" "$size"
    printf '%s' "$tail_text"
}

tool_file_summary() {
    local kind="$1" path="$2" bytes lines
    [[ -n "$path" && -f "$path" ]] || { printf '%s(%s)' "$kind" "$path"; return 0; }
    bytes=$(wc -c < "$path" 2>/dev/null || echo 0)
    bytes=${bytes//[[:space:]]/}
    lines=$(awk_run 'END { print NR }' "$path" 2>/dev/null || echo 0)
    lines=${lines//[[:space:]]/}
    printf '%s(%s) [%s lines, %s bytes]' "$kind" "$path" "$lines" "$bytes"
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
    printf -v "$__outvar" '%s%s\n' "${!__outvar}" "$(wrap_section "$tag" "$content" "$name")"
}

session_append_line() {
    [[ -n "${SESSION_EVENT_FILE:-}" ]] || return 0
    printf '%s\n' "$1" >> "$SESSION_EVENT_FILE"
}

display_ensure_newline() {
    if [[ "$DISPLAY_LAST_CHAR" != $'\n' ]]; then
        printf '\n'
        DISPLAY_LAST_CHAR=$'\n'
    fi
}

display_human_text() {
    local s="$1"
    [[ -z "$s" ]] && return 0
    printf '%s' "$s"
    if [[ "$s" == *$'\n' ]]; then
        DISPLAY_LAST_CHAR=$'\n'
    else
        DISPLAY_LAST_CHAR="${s: -1}"
    fi
}

# Convert REPLY_MESSAGE to a stream event JSON string (for events.jsonl and stream-json output).
# Prints JSON to stdout; returns 1 if type has no event representation.
msg_to_stream_event() {
    local _type="${REPLY_MESSAGE[0]}"
    case "$_type" in
        TEXT)        printf '{"type":"text","content":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" ;;
        THINKING)    printf '{"type":"thinking","content":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" ;;
        TOOL_CALL)
            printf '{"type":"tool_call","name":"%s","id":"%s","input":%s}' \
                "$(json_escape "${REPLY_MESSAGE[1]}")" \
                "$(json_escape "${REPLY_MESSAGE[2]}")" \
                "${REPLY_MESSAGE[3]}"
            ;;
        TOOL_RESULT)
            printf '{"type":"tool_result","tool_use_id":"%s","name":"%s","content":"%s"}' \
                "$(json_escape "${REPLY_MESSAGE[1]}")" \
                "$(json_escape "${REPLY_MESSAGE[2]}")" \
                "$(json_escape "${REPLY_MESSAGE[3]}")"
            ;;
        USAGE)       printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}' "${REPLY_MESSAGE[1]:-0}" "${REPLY_MESSAGE[2]:-0}" "${REPLY_MESSAGE[3]:-0}" "${REPLY_MESSAGE[4]:-0}" ;;
        STOP)        printf '{"type":"stop","reason":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" ;;
        TODO_UPDATE) build_todo_event_json "${REPLY_MESSAGE[1]}" ;;
        ERROR)       printf '{"type":"error","message":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" ;;
        RETRY)       printf '{"type":"retry"}' ;;
        *)           return 1 ;;
    esac
    return 0
}

display_event() {
    # REPLY_MESSAGE[0]=type, rest varies by type
    # Pure human-text rendering only. JSON event construction is in msg_to_stream_event().
    local _type="${REPLY_MESSAGE[0]}"

    case "$_type" in
        TEXT)
            # Insert newline when transitioning from thinking to text
            if [[ "$PREV_WAS_THINKING" == true && "$DISPLAY_LAST_CHAR" != $'\n' ]]; then
                printf '\n'
                DISPLAY_LAST_CHAR=$'\n'
            fi
            PREV_WAS_THINKING=false
            [[ -n "${REPLY_MESSAGE[1]}" ]] && display_human_text "${REPLY_MESSAGE[1]}"
            ;;
        THINKING)
            [[ -n "${REPLY_MESSAGE[1]}" ]] && printf '\033[90m%s\033[0m' "${REPLY_MESSAGE[1]}"
            if [[ "${REPLY_MESSAGE[1]}" == *$'\n' ]]; then
                DISPLAY_LAST_CHAR=$'\n'
            else
                DISPLAY_LAST_CHAR="${REPLY_MESSAGE[1]: -1}"
            fi
            PREV_WAS_THINKING=true
            ;;
        TOOL_CALL)
            local _tc_kv=() i _n=${#REPLY_MESSAGE[@]} _tc_summary=""
            for (( i = 4; i + 1 < _n; i += 2 )); do
                _tc_kv+=("${REPLY_MESSAGE[i]}" "${REPLY_MESSAGE[i+1]}")
            done
            if (( ${#_tc_kv[@]} > 0 )); then
                _tc_summary="$(tool_call_summary "${REPLY_MESSAGE[1]}" "${_tc_kv[@]}")"
            else
                _tc_summary="$(tool_call_summary "${REPLY_MESSAGE[1]}")"
            fi
            display_ensure_newline
            printf '\033[33m[tool] %s\033[0m\n' "$_tc_summary"
            DISPLAY_LAST_CHAR=$'\n'
            ;;
        TOOL_RESULT)
            local _tr_name="${REPLY_MESSAGE[2]}" _tr_text=""
            if [[ "$_tr_name" == "Edit" ]]; then
                _tr_text="${REPLY_MESSAGE[3]}"$'\n'
            elif [[ "$_tr_name" == "Read" || "$_tr_name" == "Write" ]]; then
                # Summary is already prepended to content (by agent_loop_stream)
                _tr_text="${REPLY_MESSAGE[3]%%$'\n'*}"$'\n'
            else
                _tr_text="${REPLY_MESSAGE[3]}"$'\n'
            fi
            # Insert newline when transitioning from thinking to text
            if [[ "$PREV_WAS_THINKING" == true && "$DISPLAY_LAST_CHAR" != $'\n' ]]; then
                printf '\n'
                DISPLAY_LAST_CHAR=$'\n'
            fi
            PREV_WAS_THINKING=false
            [[ -n "$_tr_text" ]] && display_human_text "$_tr_text"
            ;;
        USER_MESSAGE)
            display_ensure_newline
            local _um_text="${REPLY_MESSAGE[1]%%$'\n'*}"
            (( ${#_um_text} > 80 )) && _um_text="${_um_text:0:77}..."
            printf '\033[32m> %s\033[0m\n' "$_um_text"
            DISPLAY_LAST_CHAR=$'\n'
            ;;
        STOP)  display_ensure_newline ;;
        ERROR) display_ensure_newline; printf '\033[31mError: %s\033[0m\n' "${REPLY_MESSAGE[1]}" >&2 ;;
        *)     return 0 ;;
    esac
}

build_system_prompt() {
    local output=""
    local agent_identity core_rules tool_guidance todo_guidance plan_lifecycle_guidance instruction_files skill_index selected_skills plan stable_context todo
    agent_identity='You are bash-agent, a lightweight coding agent that works in a terminal.'
    core_rules=$'- Be concise and concrete.\n- Prefer safe, exact edits.\n- Report failures clearly.\n- No pleasantries. No explanations unless asked. Raw results only.'
    tool_guidance=$'- Use Read for a single file. If you need multiple files, call Read multiple times.\n- For large files, use Read with offset/limit instead of reading the whole file.\n- Use Glob and Grep for one pattern at a time.\n- Use multiple tool calls in one response when they are independent.\n- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n- For Edit, Read first and copy old_string exactly (including whitespace/indent/newlines).\n- For skills, first check the skill-index section, then use Skill(name) for the matching skill.'
    todo_guidance=$'- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.'
    plan_lifecycle_guidance=$'- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n- **Step-by-step**:\n  1. Write plan to PLAN_FILE using Edit (markdown: goal, analysis, steps, notes)\n  2. Ask user to confirm the plan before execution\n  3. After user confirms, create TodoWrite checklist based on plan\n  4. Execute tasks following todo checklist (update progress in TodoWrite)\n  5. When all tasks complete, clear plan: Bash ": > PLAN_FILE"\n- **Plan vs Todo separation**:\n  - PLAN_FILE: planning document for analysis and strategy\n  - TodoWrite: execution checklist for real-time progress tracking\n  - Do NOT mix todo checkboxes into plan file\n- **PLAN_FILE**: '${PLAN_FILE:-<not set>}

    instruction_files=$(build_instruction_files_section)
    skill_index=$(build_skill_index_section)
    selected_skills=$(build_selected_skills_section)
    plan=$(read_optional_file "${PLAN_FILE:-}")
    stable_context=$(read_optional_file "${CONTEXT_SUMMARY_FILE:-}")
    todo=$(read_optional_file "${TODO_FILE:-}")

    append_section output "agent-identity" "$agent_identity"
    append_section output "rules" "$core_rules"
    append_section output "using-your-tools" "$tool_guidance"
    append_section output "todo-guidance" "$todo_guidance"
    append_section output "plan-lifecycle-guidance" "$plan_lifecycle_guidance"
    append_section output "instruction-files" "$instruction_files"
    append_section output "skill-index" "$skill_index"
    append_section output "selected-skills" "$selected_skills"
    append_section output "current-plan" "$plan" "${PLAN_FILE:-}"
    append_section output "context-summary" "$stable_context"
    append_section output "current-todo" "$todo"

    printf '%s' "${output%$'\n'}"
}

read_optional_file() {
    local path="$1"
    if [[ -n "$path" && -s "$path" ]]; then
        printf '%s' "$(<"$path")"
    fi
}

find_skill_base_dirs() {
    local cwd home
    cwd="${PWD:-$(pwd)}"
    home="${HOME:-}"
    if [[ -d "$cwd/.claude/skills" ]]; then
        printf '%s\n' "$cwd/.claude/skills"
    fi
    if [[ -d "$cwd/skills" ]]; then
        printf '%s\n' "$cwd/skills"
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
        printf 'Base directory: %s\n\n%s' "$skill_dir" "$content"
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
            summary=$(awk_run -f "$AWK_DIR/skill_summary.awk" "$skill_file")
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

build_tool_call_json_object() {
    local name="$1" id="$2" input="$3" type="${4:-tool_use}"
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

build_assistant_content_json() {
    local text="$1" thinking="$2" calls="$3"
    local content="["
    content+="{\"type\":\"thinking\",\"thinking\":\"$(json_escape "$thinking")\"}"
    content+=",{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}"

    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        local name id input
        IFS=$'\t' read -r name id input _ <<< "$tc"
        content+=",$(build_tool_call_json_object "$name" "$id" "$input")"
    done <<< "$calls"

    content+="]"
    printf '%s' "$content"
}

build_todo_event_json() {
    local checklist="$1"
    printf '{"type":"todo_update","content":"%s"}' "$(json_escape "$checklist")"
}

cleanup() {
    stop_esc_interrupt_listener
    clear_interrupt_state
}
trap cleanup EXIT
trap 'INTERRUPT_REQUESTED=true; [[ -n "${ESC_LISTENER_FLAG:-}" ]] && printf 1 > "$ESC_LISTENER_FLAG"' USR1

find_awk_dir() {
    if [[ -n "${AWK_DIR:-}" ]]; then
        [[ -d "$AWK_DIR" ]] && return
        die "AWK_DIR not found: $AWK_DIR"
    fi
    # Fallback: awk/ alongside agent.sh
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/awk" ]]; then
        AWK_DIR="$script_dir/awk"
        return
    fi
    die "Cannot find awk/ directory. Set AWK_DIR or ensure awk/ exists alongside agent.sh"
}
get_session_dir() {
    local cwd="${PWD:-$(pwd)}"
    local project_key base="${BASH_AGENT_HOME:-${HOME}}"
    cwd="$(cd "$cwd" && pwd -P)"
    project_key="$(printf '%s' "$cwd" | awk_run '
    {
        sub(/^\/+/, "", $0)
        gsub(/\//, "-", $0)
        gsub(/[^A-Za-z0-9._-]/, "-", $0)
        gsub(/-+/, "-", $0)
        sub(/^-+/, "", $0)
        sub(/-+$/, "", $0)
        print "-" $0
    }')"
    printf '%s/.bash-agent/projects/%s' "$base" "$project_key"
}

get_latest_session_dir() {
    local project_dir
    project_dir="$(get_session_dir)"
    [[ -d "$project_dir" ]] || return 1
    local latest="" latest_ts=0 dir ts
    for dir in "$project_dir"/*/; do
        [[ -d "$dir" ]] || continue
        ts=$(stat -f "%m" "$dir/events.jsonl" 2>/dev/null || stat -f "%m" "$dir" 2>/dev/null || echo 0)
        (( ts > latest_ts )) && { latest_ts=$ts; latest="$dir"; }
    done
    [[ -n "$latest" ]] && basename "$latest" || return 1
}

resolve_continue_session_id() {
    local latest_id=""
    latest_id="$(get_latest_session_dir || true)"
    if [[ -n "$latest_id" ]]; then
        SESSION_ID="$latest_id"
    else
        SESSION_ID="$(new_session_id)"
    fi
}

# --- Conversation Management (temp file, one JSON message per line) ---

conv_init() {
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="$(new_session_id)"
    fi
    local project_dir session_dir
    project_dir="$(get_session_dir)"
    session_dir="${project_dir}/${SESSION_ID}"
    mkdir -p "$session_dir"

    CONV_FILE="${session_dir}/conversation.jsonl"
    SESSION_EVENT_FILE="${session_dir}/events.jsonl"
    CONTEXT_SUMMARY_FILE="${session_dir}/summary.txt"
    TODO_FILE="${session_dir}/todo.md"
    PLAN_FILE="${session_dir}/plan.md"
    STATS_FILE="${session_dir}/stats.json"
    local new_session=false
    [[ ! -s "$SESSION_EVENT_FILE" ]] && new_session=true
    touch "$CONV_FILE"
    touch "$SESSION_EVENT_FILE"
    touch "$CONTEXT_SUMMARY_FILE"
    touch "$TODO_FILE"
    touch "$PLAN_FILE"
    if [[ "$new_session" == true ]]; then
        session_append_line "{\"type\":\"session_start\",\"session_id\":\"$(json_escape "$SESSION_ID")\"}"
    fi
    stats_load
    stats_show_osc
}

conv_add_user() {
    local content
    content=$(json_escape "$1")
    printf '{"role":"user","content":"%s"}\n' "$content" >> "$CONV_FILE"
}

conv_add_assistant() {
    local text="$1" thinking="$2" calls="$3" content
    content=$(build_assistant_content_json "$text" "$thinking" "$calls")
    printf '{"role":"assistant","content":%s}\n' "$content" >> "$CONV_FILE"
}

conv_add_tool_results() {
    # $1: newline-separated list of id<TAB>json_escaped_result
    local results="$1" content="[" first=true tid="" result=""
    while IFS=$'\t' read -r tid result; do
        [[ -z "$tid" ]] && continue
        $first || content+=","
        first=false
        content+=$(build_tool_result_json_object "$tid" "$result")
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
    done <<< "$1"
    printf '%s]' "$result"
}

context_append_summary() {
    local text="$1"
    [[ -n "${CONTEXT_SUMMARY_FILE:-}" ]] || return 0
    [[ -n "$text" ]] || return 0
    printf '%s\n' "$text" > "$CONTEXT_SUMMARY_FILE"
}

stats_load() {
    local idx=0
    while IFS=$'\t' read -r key val; do
        [[ -z "$key" ]] && continue
        STATS_CACHE[idx]="$val"
        idx=$(( idx + 1 ))
    done < <(awk_run -v action=dump -f "$AWK_DIR/stats.awk" "$STATS_FILE" 2>/dev/null)
}

_stats_sync() {
    printf '%s\n' "${STATS_CACHE[@]}" | awk_run -v action=sync -f "$AWK_DIR/stats.awk" "$STATS_FILE"
}

stats_inc() {
    for entry in "$@"; do
        local idx="${entry%%=*}" val="${entry#*=}"
        STATS_CACHE[idx]=$(( STATS_CACHE[idx] + val ))
    done
    _stats_sync
}

stats_set() {
    for entry in "$@"; do
        local idx="${entry%%=*}" val="${entry#*=}"
        STATS_CACHE[idx]="$val"
    done
    _stats_sync
}

stats_get() {
    echo "${STATS_CACHE[$1]:-0}"
}

record_usage() {
    # Args: kind counter_idx
    # Reads REPLY_MESSAGE[1..4], logs event, updates stats.
    # Returns context token count (input+output+cache_read+cache_creation).
    local kind="$1" counter_idx="$2"
    local _in="${REPLY_MESSAGE[1]:-0}" _out="${REPLY_MESSAGE[2]:-0}" _cr="${REPLY_MESSAGE[3]:-0}" _cc="${REPLY_MESSAGE[4]:-0}" _event
    if [[ -n "$kind" ]]; then
        _event=$(printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"kind":"%s"}' "$_in" "$_out" "$_cr" "$_cc" "$kind")
    else
        _event=$(printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s}' "$_in" "$_out" "$_cr" "$_cc")
    fi
    [[ "$LOG_EVENTS" != "false" ]] && session_append_line "$_event"
    stats_inc ${counter_idx}=1 3=${_in} 4=${_out} 5=${_cr} 6=${_cc}
    echo $(( _in + _out + _cr + _cc ))
}

stats_show_osc() {
    printf '\033]0;T:%s R:%s I:%s O:%s C:%s\007' \
        "${STATS_CACHE[0]:-0}" "${STATS_CACHE[1]:-0}" \
        "${STATS_CACHE[3]:-0}" "${STATS_CACHE[4]:-0}" "${STATS_CACHE[7]:-0}"
}

# --- Dynamic Planning Compact Decision ---
# DP compact decision: find optimal k via cache-aware economics.
# Cache-Aligned Summarization: the summary call reuses the main agent's
# prefix (system prompt + tools + cache-control markers) for cache hits.
# Formula: NetBenefit(k) = ①savings - ②cache_miss - ③compact_cost - ④info_loss
# Returns: number of lines to keep (turn-aligned), or "0" if no compact beneficial.
compact_dp_decision() {
    local current_turn=$(stats_get 0)
    # E: expected remaining user-input rounds
    # DP_E_FIXED > (DP_BASELINE_E - current_turn) > baseline/2
    local baseline=${DP_BASELINE_E:-8} E
    if (( DP_E_FIXED > 0 )); then
        E=$DP_E_FIXED
    elif (( baseline > 0 )); then
        local remaining=$(( baseline - current_turn ))
        local floor=$(( baseline > 1 ? baseline / 2 : 2 ))
        E=$(( remaining > floor ? remaining : floor ))
    else
        E=2
    fi

    # L: avg LLM calls per user input (default 5, auto from stats if DP_L=0)
    local L=$DP_L
    local L_raw=0
    if (( L <= 0 )); then
        L_raw=$(stats_get 1)
    fi

    # avg: average input tokens per LLM request (for info loss N_remain)
    local avg_per_request=4000
    local total_input_tokens=$(stats_get 3)
    local total_requests=$(stats_get 1)
    if (( total_requests > 0 )); then
        avg_per_request=$(( total_input_tokens / total_requests ))
    fi

    local prev_compactions=$(stats_get 2)

    awk_run -v E="$E" -v L="$L" -v L_raw="$L_raw" -v t="$current_turn" \
            -v avg="$avg_per_request" -v V="$DP_V" \
            -v p_input="$DP_P_INPUT" -v p_cache="$DP_P_CACHE" -v p_out="$DP_P_OUT" \
            -v S="$DP_S" -v min_keep_ratio="$DP_MIN_KEEP_RATIO" \
            -v c="$prev_compactions" -v r="$DP_R" -v beta="$DP_BETA" \
            -f "$AWK_DIR/compact_dp.awk" "$CONV_FILE"
}

compact_context_window() {
    local total_lines keep_lines drop tmp_dropped dropped_messages summary_response

    keep_lines=$(compact_dp_decision) || true
    [[ -n "$keep_lines" ]] || keep_lines=0
    if (( keep_lines == 0 )); then
        # Safety valve: DP says no, but check context size
        local ct=$(stats_get 7)
        if (( ct > 0 && ct > MAX_CONTEXT_TOKENS * 90 / 100 )); then
            total_lines=$(wc -l < "$CONV_FILE" 2>/dev/null || echo 0)
            keep_lines=$(awk -v lines="$total_lines" -v r="$DP_MIN_KEEP_RATIO" 'BEGIN { k=int(lines*r+0.5); print k>3?k:3 }')
        else
            return 1
        fi
    fi

    total_lines=$(wc -l < "$CONV_FILE" 2>/dev/null || echo 0)
    (( keep_lines < total_lines )) || return 1
    drop=$(( total_lines - keep_lines ))

    tmp_dropped=$(mktemp "${TMPDIR:-/tmp}/dropped.XXXXXX")
    head -n "$drop" "$CONV_FILE" > "$tmp_dropped"
    dropped_messages=$(<"$tmp_dropped")

    summary_response=$(run_summary_call "$dropped_messages")
    context_append_summary "$summary_response"

    if (( keep_lines < total_lines )); then
        tmp=$(mktemp "${TMPDIR:-/tmp}/conv_trim.XXXXXX")
        tail -n "$keep_lines" "$CONV_FILE" > "$tmp"
        mv "$tmp" "$CONV_FILE"
    fi

    rm -f "$tmp_dropped"
    local remaining_turns
    remaining_turns=$(grep -c '"role":"user","content":"' "$CONV_FILE" 2>/dev/null || echo 0)
    stats_set 0=$remaining_turns
    if is_stream_json_mode; then
        printf '%s\n' '{"type":"context_update","kind":"compact","trigger":"auto"}'
    else
        printf '\033[36mContext compacted automatically.\033[0m\n'
    fi
    return 0
}

# --- Tool Definitions (auto-generated JSON) ---

load_tool_defs() {
    local tools_file script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    tools_file="$script_dir/tools.json"
    [[ -f "$tools_file" ]] || die "Cannot find tools.json: $tools_file"
    TOOL_DEF_JSON=$(<"$tools_file")
}

# --- Tool Implementations ---

tool_read() {
    local path="$1" offset="${2:-1}" limit="${3:-0}"

    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    [[ ! -r "$path" ]] && { echo "Error: permission denied: $path"; return 1; }

    if (( limit > 0 )); then
        sed -n "${offset},$((offset + limit - 1))p" "$path"
    else
        sed -n "${offset},\$p" "$path"
    fi
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
    local tmp diff_output added removed
    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/edit.XXXXXX")
    if ! printf '{"path":"%s","old_string":"%s","new_string":"%s"}' \
            "$(json_escape "$path")" "$(json_escape "$old_string")" "$(json_escape "$new_string")" \
         | awk_run -v max_bytes="$FILE_WRITE_MAX_BYTES" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/edit_file.awk" > "$tmp" 2>&1; then
        cat "$tmp"; rm -f "$tmp"; return 1
    fi
    (( $(wc -c < "$tmp") > 0 )) || { echo "Error: edit produced empty result"; rm -f "$tmp"; return 1; }
    local label="${path#/}"
    diff_output=$(diff -u --color=always --label "a/$label" --label "b/$label" "$path" "$tmp" 2>&1) || true
    [[ "$diff_output" == *"unsupported --color"* || "$diff_output" == *"unrecognized option '--color'"* ]] \
        && diff_output=$(diff -u --label "a/$label" --label "b/$label" "$path" "$tmp" 2>&1) || true
    added=$(printf '%s\n' "$diff_output" | grep -cE $'^(\033\[[0-9;]*m)?\+[^+]') || added=0
    removed=$(printf '%s\n' "$diff_output" | grep -cE $'^(\033\[[0-9;]*m)?-[^-]') || removed=0
    cat "$tmp" > "$path"
    rm -f "$tmp"
    printf 'Edit(%s) [+%s -%s lines]\n' "$path" "$added" "$removed"
    [[ -n "$diff_output" ]] && printf '%s\n' "$diff_output"
}

tool_bash() {
    local cmd="$1" timeout_secs="${2:-$TOOL_TIMEOUT_SECS}"
    local reason output tool_rc

    [[ -z "$cmd" ]] && { echo "Error: no command provided"; return 1; }
    reason=$(deny_bash_command_reason "$cmd") || reason=""
    if [[ -n "$reason" ]]; then
        echo "Error: command blocked by bash safety policy ($reason)"
        return 1
    fi

    local tmpout
    tmpout=$(mktemp)

    if [[ -n "$timeout_secs" && "$timeout_secs" =~ ^[0-9]+$ && "$timeout_secs" -gt 0 ]]; then
        run_with_timeout "$timeout_secs" bash -lc "$cmd" > "$tmpout" 2>&1
        tool_rc=$?
        if (( tool_rc == 124 )); then
            printf '\n[... command timed out after %s seconds ...]' "$timeout_secs" >> "$tmpout"
        fi
    else
        bash -lc "$cmd" > "$tmpout" 2>&1
        tool_rc=$?
    fi
    cat "$tmpout"
    rm -f "$tmpout"
    return "$tool_rc"
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
    local pattern="$1" path="$2" glob="$3" context="$4"

    [[ -z "$pattern" ]] && { echo "Error: no pattern provided"; return 1; }
    [[ -n "$path" ]] || path="."
    [[ -e "$path" ]] || { echo "Error: path not found: $path"; return 1; }
    command -v rg >/dev/null 2>&1 || { echo "Error: rg is required for grep"; return 1; }

    local args=(-n --color never)
    [[ -n "$context" && "$context" =~ ^[0-9]+$ ]] && args+=(-C "$context")
    [[ -n "$glob" ]] && args+=(--glob "$glob")
    args+=("--" "$pattern" "$path")

    rg "${args[@]}" 2>/dev/null || true
}

tool_todo() {
    printf '%s\n' "$1" > "$TODO_FILE"
    printf '%s' "$1"
}

tool_skill() {
    local skill_name="$1" skill_content=""
    skill_name="${skill_name#"${skill_name%%[![:space:]]*}"}"
    skill_name="${skill_name%"${skill_name##*[![:space:]]}"}"
    [[ -n "$skill_name" ]] || { echo "Error: no skill name provided"; return 1; }
    skill_content=$(load_skill_content "$skill_name") || { echo "Error: skill not found: $skill_name"; return 1; }
    printf 'Skill: %s\n%s' "$skill_name" "$skill_content"
}

tool_web_search() { curl -sS --connect-timeout 10 --max-time 30 -G --data-urlencode "q=$1" -H "Authorization: Bearer ${JINA_API_KEY:-}" -H "X-Respond-With: no-content" "https://s.jina.ai/" 2>&1; }

tool_web_fetch() { curl -sS --connect-timeout 10 --max-time 60 -G --data-urlencode "url=$1" -H "Authorization: Bearer ${JINA_API_KEY:-}" "https://r.jina.ai/" 2>&1; }

dispatch_tool() {
    local name="$1" arg1="${2:-}" arg2="${3:-}" arg3="${4:-}" arg4="${5:-}"
    case "$name" in
        Read)      tool_read "$arg1" "$arg2" "$arg3" ;;
        Write)     tool_write "$arg1" "$arg2" ;;
        Edit)      tool_edit "$arg1" "$arg2" "$arg3" ;;
        Bash)      tool_bash "$arg1" "$arg2" ;;
        Glob)      tool_glob "$arg1" "$arg2" ;;
        Grep)      tool_grep "$arg1" "$arg2" "$arg3" "$arg4" ;;
        TodoWrite) tool_todo "$arg1" ;;
        Skill)     tool_skill "$arg1" ;;
        WebSearch) tool_web_search "$arg1" ;;
        WebFetch)  tool_web_fetch "$arg1" ;;
        *)
            echo "Error: unknown tool: $name"
            return 1
            ;;
    esac
}

# --- API Calls (curl) ---

_stream_curl() {
    curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 --connect-timeout 5 --speed-limit 1 --speed-time 60 "${HEADER_ARGS[@]}" -d @- "$API_URL" 2>&1 | awk_run -f "$AWK_DIR/http_stream.awk"
}

# --- LLM Call (internal) ---

llm_call() {
    local messages="$1" max_tokens="${2:-$MAX_TOKENS}" thinking_budget="${3:-$THINKING_BUDGET}" body system_prompt
    system_prompt=$(build_system_prompt)

    body="{\"model\":\"${MODEL}\",\"max_tokens\":${max_tokens},\"stream\":true"

    if (( thinking_budget > 0 )); then
        body+=",\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":${thinking_budget}}"
    fi

    [[ -n "$system_prompt" ]] && body+=",\"system\":\"$(json_escape "$system_prompt")\""
    [[ -n "$TOOL_DEF_JSON" ]] && body+=",\"tools\":${TOOL_DEF_JSON}"

    body+=",\"messages\":${messages}}"

    $VERBOSE && printf '\033[90m[verbose] Request body (%dKB): %.200s...\033[0m\n' "$((${#body} / 1024))" "$body" >&2

    printf '%s' "$body" | body_convert | _stream_curl | sse_convert | sse_parse
}

run_summary_call() {
    local dropped_messages="$1" text="" messages summary_instruction=$'The conversation context above needs to be compacted. Summarize the key information from the messages above into a concise context summary. Update the existing summary snapshot using the messages above. Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:'
    messages=$(conv_get_messages "${dropped_messages}"$'\n'"{\"role\":\"user\",\"content\":\"$(json_escape "$summary_instruction")\"}")

    while read_message; do
        case "${REPLY_MESSAGE[0]}" in
            TEXT)  text+="${REPLY_MESSAGE[1]}" ;;
            THINKING) ;;
            USAGE) record_usage "compact" 2 >/dev/null ;;
            ERROR) die "${REPLY_MESSAGE[1]}" ;;
        esac
    done < <(llm_call "$messages" "$SUMMARY_MAX_TOKENS" "$THINKING_BUDGET")

    [[ -n "$text" ]] || die "Failed to generate context summary"
    printf '%s' "$text"
}

# --- Agent Loop ---

agent_loop_stream() {
    local user_input="$1"
    conv_add_user "$user_input"

    local turn=0
    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true
        stats_set 9=$turn

        local text="" thinking="" tool_calls="" stop="" loop_error="" tool_conv_results="" _ctx_tokens=""
        [[ "$VERBOSE" == true ]] && printf '[debug] messages: %.500s...\n' "$(conv_get_messages "$(<"$CONV_FILE")")" >&2
        while read_message; do
            if interrupt_requested; then
                stop="interrupted"
                break
            fi
            [[ "$VERBOSE" == true ]] && printf '[debug] type=<%s> nfields=%d\n' "${REPLY_MESSAGE[0]}" "${#REPLY_MESSAGE[@]}" >&2
            # Forward to display
            write_message "${REPLY_MESSAGE[@]}"

            case "${REPLY_MESSAGE[0]}" in
                RETRY)    text="" thinking="" tool_calls="" tool_conv_results="" _ctx_tokens="" ;;
                TEXT)     text+="${REPLY_MESSAGE[1]}" ;;
                THINKING) thinking+="${REPLY_MESSAGE[1]}" ;;
                TOOL_CALL)
                    local cur_tool_name cur_tool_id input
                    cur_tool_name="${REPLY_MESSAGE[1]}"
                    cur_tool_id="${REPLY_MESSAGE[2]}"
                    input="${REPLY_MESSAGE[3]}"

                    tool_calls+="${cur_tool_name}"$'\t'"${cur_tool_id}"$'\t'"${input}"$'\n'

                    # Execute tool immediately, output result
                    local arg1="" arg2="" arg3="" arg4=""
                    tool_args_from_msg "$cur_tool_name" arg1 arg2 arg3 arg4

                    local output
                    output=$(dispatch_tool "$cur_tool_name" "$arg1" "$arg2" "$arg3" "$arg4" 2>&1)
                    local tool_rc=$?

                    if (( tool_rc != 0 )); then
                        output="Error: tool execution failed: $output"
                    fi
                    output=$(format_tool_result "$output")

                    if [[ "$cur_tool_name" == "TodoWrite" ]] && (( tool_rc == 0 )) && [[ -s "$TODO_FILE" ]]; then
                        write_message "TODO_UPDATE" "$(<"$TODO_FILE")"
                    fi
                    local result_for_conv="$output"
                    if [[ "$cur_tool_name" == "Edit" ]]; then
                        result_for_conv="$(printf '%s' "$output" | sed -n '1p')"
                    fi
                    tool_conv_results+="${cur_tool_id}"$'\t'"$(json_escape "$result_for_conv")"$'\n'

                    # Prepend file summary header for Read/Write so events.jsonl captures it
                    if [[ "$cur_tool_name" == "Read" || "$cur_tool_name" == "Write" ]]; then
                        output="$(tool_file_summary "$cur_tool_name" "$arg1")"$'\n'"$output"
                    fi

                    # TOOL_RESULT: [0]=type [1]=id [2]=name [3]=output [4..]=checklist/summary
                    local _tr_args=("TOOL_RESULT" "$cur_tool_id" "$cur_tool_name" "$output")
                    [[ -n "$arg1" ]] && _tr_args+=("$arg1")
                    [[ -n "$arg2" ]] && _tr_args+=("$arg2")
                    # Search for checklist/summary in TOOL_CALL flattened KV pairs
                    local i _n=${#REPLY_MESSAGE[@]}
                    for (( i = 4; i + 1 < _n; i += 2 )); do
                        if [[ "${REPLY_MESSAGE[i]}" == "checklist" ]]; then _tr_args+=("checklist" "${REPLY_MESSAGE[i+1]}"); fi
                        if [[ "${REPLY_MESSAGE[i]}" == "summary" ]]; then _tr_args+=("summary" "${REPLY_MESSAGE[i+1]}"); fi
                    done
                    write_message "${_tr_args[@]}"
                    ;;
                STOP)  stop="${REPLY_MESSAGE[1]}" ;;
                ERROR) loop_error="${REPLY_MESSAGE[1]}"; stop="error"; break ;;
                USAGE)
                    _ctx_tokens=$(record_usage "agent" 1)
                    ;;
            esac
        done < <(llm_call "$(conv_get_messages "$(<"$CONV_FILE")")")

        # Fatal stop reasons exit immediately
        case "$stop" in
            error|max_tokens|length)
                [[ "$stop" != "error" ]] && { write_message "ERROR" "Response truncated (max_tokens reached)"; }
                return 1
                ;;
        esac

        # Tools already executed inline; persist unless interrupted
        if ! interrupt_requested; then
            conv_add_assistant "$text" "$thinking" "$tool_calls"
            if [[ -n "$tool_conv_results" ]]; then
                conv_add_tool_results "$tool_conv_results"
            fi
            # Update context tokens and trigger compact if needed
            if [[ -n "$_ctx_tokens" && "$_ctx_tokens" -gt 0 ]]; then
                stats_set 7=${_ctx_tokens}
                compact_context_window || true
            else
                # No usage data (e.g. retry) — skip compact
                :
            fi
            # tool_use/tool_calls → loop continues; anything else → break
            [[ "$stop" == "tool_use" || "$stop" == "tool_calls" ]] || break
        else
            write_message "STOP" "interrupted"
            break
        fi
    done

    if (( turn >= MAX_TURNS )); then
        write_message "ERROR" "Max turns ($MAX_TURNS) reached"
    fi
}

agent_loop() {
    local user_input="$1" had_error=false
    DISPLAY_LAST_CHAR=$'\n'
    PREV_WAS_THINKING=false
    start_esc_interrupt_listener  # stop/clear before start

    # Record user input event
    [[ "$LOG_EVENTS" != "false" ]] && \
        session_append_line "{\"type\":\"user_input\",\"content\":\"$(json_escape "$user_input")\"}"
    # Increment turn count
    stats_inc 0=1

    local _se=""
    while read_message; do
        [[ "${REPLY_MESSAGE[0]}" == "ERROR" ]] && had_error=true

        # Layer 1: Always convert and write to events.jsonl
        _se=$(msg_to_stream_event) && [[ -n "$_se" ]] && {
            [[ "$LOG_EVENTS" != "false" ]] && session_append_line "$_se"
        }

        # Layer 2: stdout — stream-json or human display
        if [[ "${REPLY_MESSAGE[0]}" == "STOP" && "${REPLY_MESSAGE[1]}" == "interrupted" ]]; then
            if is_stream_json_mode; then
                [[ -n "$_se" ]] && printf '%s\n' "$_se"
            else
                display_event
                printf '\033[36mInterrupted.\033[0m\n'
            fi
            break
        fi
        if is_stream_json_mode; then
            [[ -n "$_se" ]] && printf '%s\n' "$_se"
        else
            display_event
        fi
    done < <(agent_loop_stream "$user_input")

    stop_esc_interrupt_listener
    stats_show_osc
    $had_error && return 1
    return 0
}

# --- CLI ---

usage() {
    cat <<'EOF'
Usage: agent.sh [options] [prompt]

Options:
  -p, --provider PROV     LLM provider: claude | openai (default: claude)
  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)
  --max-tokens N          Max output tokens (default: 4096)
  --tool-timeout N        Tool execution timeout in seconds (default: 600)
  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)
  --max-turns N           Max agent turns (default: 40)
  --max-context N         Max context tokens before compact (default: 200000; supports k/m)
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
  BASH_AGENT_HOME         Override base directory for session storage (default: $HOME)

Examples:
  ./agent.sh "Read /etc/hostname and tell me what it says"
  ./agent.sh -m claude-sonnet-4-20250514 "List files in /tmp"
  ./agent.sh --session code-review "Analyze this code"
  ./agent.sh --skill shell-safety "List files in /tmp"
  ./agent.sh --continue "What did we discuss?"
  ./agent.sh --output-format stream-json "Hello" | jq -r 'select(.type=="text") .content'
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
            --max-tokens)    MAX_TOKENS=$(parse_size_bytes "$2") || { die "Invalid --max-tokens: $2"; }; shift 2 ;;
            --tool-timeout)  TOOL_TIMEOUT_SECS="$2"; shift 2 ;;
            --skill)         SKILL_NAMES+=("$2"); shift 2 ;;
            --max-turns)     MAX_TURNS="$2"; shift 2 ;;
            --max-context)
                MAX_CONTEXT_TOKENS=$(parse_size_bytes "$2") || die "Invalid --max-context: $2"
                shift 2
                ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            --output-format)  OUTPUT_FORMAT="$2"; shift 2 ;;
            --print)         OUTPUT_FORMAT="stream-json"; shift ;;
            --session)
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    SESSION_ID="$2"; shift 2
                else
                    SESSION_ID="$(new_session_id)"
                    shift
                fi
                ;;
            --continue)
                if [[ -z "$SESSION_ID" ]]; then
                    resolve_continue_session_id
                fi
                shift
                ;;
            --list-sessions)
                list_sessions
                exit 0
                ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            -i|--interactive) INTERACTIVE=true; shift ;;
            -h|--help)       usage ;;
            -*)              die "Unknown option: $1" ;;
            *)               USER_INPUT="$1"; shift ;;
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
    dir="$(get_session_dir)"
    if [[ ! -d "$dir" ]]; then
        echo "No sessions found."
        return
    fi
    printf "%-40s %-16s %s\n" "NAME" "MODIFIED" "PREVIEW"
    local session_dir name mod preview summary_file
    for session_dir in "$dir"/*/; do
        [[ -d "$session_dir" ]] || continue
        name=$(basename "$session_dir")
        mod=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$session_dir" 2>/dev/null || stat -c "%y" "$session_dir" 2>/dev/null | cut -d. -f1)
        summary_file="${session_dir}/summary.txt"
        preview=""
        if [[ -s "$summary_file" ]]; then
            preview=$(grep -m1 -v '^[[:space:]]*$' "$summary_file" 2>/dev/null || true)
        fi
        [[ ${#preview} -gt 60 ]] && preview="${preview:0:57}..."
        printf "%-40s %-16s %s\n" "$name" "$mod" "$preview"
    done
}

validate_config() {
    case "$PROVIDER" in
        claude)
            : "${API_KEY:=$ANTHROPIC_API_KEY}"
            : "${BASE_URL:=${ANTHROPIC_BASE_URL:-}}"
            : "${MODEL:=claude-sonnet-4-20250514}"
            API_URL="${BASE_URL:-https://api.anthropic.com/v1}/messages"
            HEADER_ARGS=(
                -H "Content-Type: application/json"
                -H "x-api-key: ${API_KEY}"
                -H "anthropic-version: 2023-06-01"
                -H "User-Agent: claude-cli/1.0.33 (max, cli)"
                -H "x-app: cli"
            )
            body_convert() { cat; }
            sse_convert()  { cat; }
            ;;
        openai)
            : "${API_KEY:=$OPENAI_API_KEY}"
            : "${BASE_URL:=${OPENAI_BASE_URL:-}}"
            : "${MODEL:=gpt-4o}"
            API_URL="${BASE_URL:-https://api.openai.com/v1}/chat/completions"
            HEADER_ARGS=(
                -H "Content-Type: application/json"
                -H "Authorization: Bearer ${API_KEY}"
                -H "User-Agent: claude-cli/1.0.33 (max, cli)"
            )
            body_convert() { awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_body.awk"; }
            sse_convert()  { awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk"; }
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

    # Unified SSE parser — same for all providers (sse_convert normalizes to Claude format)
    sse_parse() { awk_run -v verbose="${VERBOSE:-false}" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk"; }
}

interactive_mode() {
    local history_file="${BASH_AGENT_HOME:-${HOME}}/.bash-agent/history"

    mkdir -p "$(dirname "$history_file")" 2>/dev/null || true
    touch "$history_file" 2>/dev/null || true

    history -r "$history_file" 2>/dev/null || true
    trap 'history -w "$history_file" 2>/dev/null || true' INT TERM

    printf '\033[36mbash-agent interactive mode (type '\''exit'\'' or Ctrl+D to quit)\033[0m\n'
    # Replay recent 10 turns for resumed sessions (inlined turn-aware replay)
    if [[ -s "${SESSION_EVENT_FILE:-}" ]]; then
        local _saved_log_events="${LOG_EVENTS:-true}"
        LOG_EVENTS=false
        local _efile="${SESSION_EVENT_FILE:-}" _match _from_line
        _match=$(grep -n '"type":"user_input"' "$_efile" 2>/dev/null | tail -n 10 | head -n 1) || true
        _from_line="${_match%%:*}"
        [[ -n "$_from_line" && "$_from_line" -ge 1 ]] || _from_line=1
        tail -n +"$_from_line" "$_efile" \
            | awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/event_replay.awk" \
            | while read_message; do
                display_event
            done
        LOG_EVENTS="$_saved_log_events"
        [[ -n "$_match" ]] && printf "\n"
    fi
    while true; do
        stty echo 2>/dev/null || true
        IFS= read -e -r -p $'\001\033[32m\002> \001\033[0m\002' user_input || break
        [[ "$user_input" == "exit" || "$user_input" == "quit" ]] && break
        [[ -z "$user_input" ]] && continue
        history -s -- "$user_input" 2>/dev/null || true
        history -a "$history_file" 2>/dev/null || true
        agent_loop "$user_input"
    done
    history -w "$history_file" 2>/dev/null || true
    printf '\033[36mGoodbye!\033[0m\n'
    if [[ -n "${SESSION_ID:-}" ]]; then
        printf '\033[90mResume with: --session %s  or  --continue\033[0m\n' "$SESSION_ID"
    fi
}

start_esc_interrupt_listener() {
    [[ "$INTERACTIVE" == true ]] || return 0
    [[ -r /dev/tty ]] || return 0
    clear_interrupt_state
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

    find_awk_dir
    conv_init
    load_tool_defs

    validate_config

    if [[ "$INTERACTIVE" == true ]]; then
        interactive_mode
    elif [[ -n "$USER_INPUT" ]]; then
        agent_loop "$USER_INPUT"
    elif [[ ! -t 0 ]]; then
        local input
        input=$(cat)
        agent_loop "$input"
    else
        INTERACTIVE=true
        interactive_mode
    fi
}

main "$@"
