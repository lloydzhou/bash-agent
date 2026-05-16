#!/usr/bin/env bash
# bash-agent — AI Agent in pure bash/awk
# Supports: Anthropic Claude, OpenAI Chat
# No dependencies beyond: bash, curl, awk

set -uo pipefail

# --- User Options ---
PROVIDER="claude"
MODEL=""
MAX_TOKENS=4096
TOOL_TIMEOUT_SECS=600
: "${TOOL_RESULT_MAX_BYTES:=100000}"
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
: "${EFFORT:=high}"
: "${THINKING:=adaptive}"

# --- Runtime Mode & Session State ---
INTERACTIVE=false
SESSION_ID=""
SESSION_EVENT_FILE=""
CONTEXT_SUMMARY_FILE=""
PLAN_FILE=""
PLAN_DRAFT_FILE=""
STATS_FILE=""
INPUT_FIFO=""
LOG_EVENTS=true

# --- Internal Runtime State ---
CONV_FILE=""
TOOL_DEF_JSON=""
API_URL=""
AWK_DIR=""
declare -a HEADER_ARGS=()
INTERRUPT_REQUESTED=false
DISPLAY_LAST_CHAR=$'\n'
PREV_WAS_THINKING=false
ACTIVE_SUB_COUNT=0

# --- Environment Defaults ---
: "${ANTHROPIC_API_KEY:=}"
: "${OPENAI_API_KEY:=}"
: "${ANTHROPIC_BASE_URL:=}"
: "${OPENAI_BASE_URL:=}"

# --- Utility Functions ---
awk_run() { LC_ALL=C LANG=C awk "$@"; }

write_message() {
    # Args: field0 field1 field2 ...
    # Wire format (RESP-like, CRLF): *N\r\n$len0\r\ndata0\r\n$len1\r\ndata1\r\n...
    # 所有内容拼到 _out，最后一次 printf 输出，避免多段 printf 与并发 writer 交叉
    local nfields=$# field byte_len _out="" _seg=""
    printf -v _out '*%s\r\n' "$nfields"
    for field in "$@"; do
        byte_len=$(LC_ALL=C printf '%s' "$field" | wc -c)
        byte_len=${byte_len//[[:space:]]/}
        printf -v _seg '$%s\r\n%s\r\n' "$byte_len" "$field"
        _out+="$_seg"
    done
    printf '%s' "$_out"
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
    local cmd="$1" device_write_re='(^|[[:space:]])(of=|>|1>|>>|1>>)[[:space:]]*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)([[:space:]]|$)'

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
        SubAgent) printf 'prompt description fork' ;;
        *) printf '' ;;
    esac
}

tool_args_from_msg() {
    local name="$1" param_key_string="" param_keys=() idx param_value="" _n=${#REPLY_MESSAGE[@]} _pkey i
    local -a _outvars=("$2" "$3" "$4" "$5")

    param_key_string=$(tool_param_keys "$name")
    if [[ -n "$param_key_string" ]]; then
        IFS=' ' read -r -a param_keys <<< "$param_key_string"
        for idx in "${!param_keys[@]}"; do
            _pkey="${param_keys[idx]}"
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
    local name="$1" label="" key="" i value="" _vi
    shift
    case "$name" in
        Read|Write|Edit) key="path" ;;
        Bash) key="command" ;;
        Glob|Grep) key="pattern" ;;
        TodoWrite) key="summary" ;;
        Skill) key="name" ;;
        WebSearch) key="query" ;;
        WebFetch) key="url" ;;
        SubAgent) key="description" ;;
    esac
    if [[ -n "$key" && $# -gt 0 ]]; then
        for (( i = 1; i + 1 <= $#; i += 2 )); do
            if [[ "${!i}" == "$key" ]]; then
                _vi=$(( i + 1 ))
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
    local output="$1" size marker marker_len tail_lines=5 tail_text tail_len head_len
    if (( ${#output} <= TOOL_RESULT_MAX_BYTES )); then
        printf '%s' "$output"
        return 0
    fi
    size=${#output}
    marker=$'\n\n[... truncated: showing first/last portions of %d bytes ...]\n\n'
    marker_len=$(( ${#marker} + 20 ))
    tail_text=$(printf '%s' "$output" | tail -n "$tail_lines")
    tail_len=${#tail_text}
    head_len=$(( TOOL_RESULT_MAX_BYTES - marker_len - tail_len ))
    (( head_len > 0 )) || head_len=$(( TOOL_RESULT_MAX_BYTES / 2 ))
    printf '%s'"$marker"'%s' "${output:0:$head_len}" "$size" "$tail_text"
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

is_stream_json_mode() { [[ "$OUTPUT_FORMAT" == "stream-json" ]]; }

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

# Convert REPLY_MESSAGE to a stream event JSON string (for events.jsonl and stream-json output). Prints JSON to stdout; returns 1 if type has no event representation.
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
        USAGE)       printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"kind":"agent"}' "${REPLY_MESSAGE[1]:-0}" "${REPLY_MESSAGE[2]:-0}" "${REPLY_MESSAGE[3]:-0}" "${REPLY_MESSAGE[4]:-0}" ;;
        STOP)        printf '{"type":"stop","reason":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" ;;
        CONTEXT_UPDATE) printf '{"type":"context_update","kind":"%s","trigger":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" "$(json_escape "${REPLY_MESSAGE[2]}")" ;;
        ERROR)       printf '{"type":"error","message":"%s"}' "$(json_escape "${REPLY_MESSAGE[1]}")" ;;
        RETRY)       printf '{"type":"retry"}' ;;
        *)           return 1 ;;
    esac
    return 0
}

display_event() {
    # REPLY_MESSAGE[0]=type, rest varies by type
    # Pure human-text rendering only. JSON event construction is in msg_to_stream_event().
    local _type="${REPLY_MESSAGE[0]}" _tc_kv=() i _n _tc_summary="" _tr_name _tr_text="" _um_text

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
            _n=${#REPLY_MESSAGE[@]} _tc_kv=() _tc_summary=""
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
            _tr_name="${REPLY_MESSAGE[2]}" _tr_text=""
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
            _um_text="${REPLY_MESSAGE[1]%%$'\n'*}"
            (( ${#_um_text} > 80 )) && _um_text="${_um_text:0:77}..."
            printf '\033[32m> %s\033[0m\n' "$_um_text"
            DISPLAY_LAST_CHAR=$'\n'
            ;;
        STOP)  display_ensure_newline ;;
        CONTEXT_UPDATE)
            display_ensure_newline; printf '\033[36mContext compacted (%s).\033[0m\n' "${REPLY_MESSAGE[2]}"; DISPLAY_LAST_CHAR=$'\n'
            ;;
        ERROR) display_ensure_newline; printf '\033[31mError: %s\033[0m\n' "${REPLY_MESSAGE[1]}" >&2 ;;
        *)     return 0 ;;
    esac
}

build_system_prompt() {
    local output="" agent_identity environment core_rules tool_guidance todo_guidance plan_lifecycle_guidance instruction_files skill_index selected_skills plan stable_context locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US}}}"
    locale="${locale%%.*}"
    agent_identity='You are bash-agent, a lightweight coding agent that works in a terminal.'
    [[ "$locale" == zh* ]] && agent_identity='你是 bash-agent，一个在终端中运行的轻量级编码智能体。'
    core_rules=$'- Be concise and concrete. No pleasantries, no explanations unless asked. Raw results only.\n- Prefer safe, exact edits.\n- Report failures clearly.'
    output_language_reaffirm="MUST use \"${locale}\" for all output, including your Chain of Thought/reasoning/thinking! Never mix languages! Code, commands, and file content remain as-is."
    [[ "$locale" == zh* ]] && output_language_reaffirm='再次强调：必须使用中文进行所有输出，包括你的思考过程（Chain of Thought/推理/thinking）！严禁在思考或回答中出现任何英文内容！'
    environment="lang: ${locale}"$'\n'"pwd: ${PWD:-$(pwd)}"$'\n'"home: ${HOME}"$'\n'"platform: $(uname -s 2>/dev/null || echo unknown)"$'\n'"shell: ${SHELL:-unknown}"
    tool_guidance=$'- Use Read for a single file. If you need multiple files, call Read multiple times.\n- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n- Use Glob and Grep for one pattern at a time.\n- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n- Use multiple tool calls in one response when they are independent.\n- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n- For skills, first check the skill-index section, then use Skill(name) for the matching skill.\n- SubAgent launches a background agent session. Results are injected back into your conversation when complete. Use for parallelizable or independent sub-tasks. See sub-agent-guidance section for context inheritance rules.'
    sub_agent_guidance=$'- **When to use**: delegating independent sub-tasks that do NOT need your current conversation context — e.g. investigating a separate file, running a focused search, testing a hypothesis in isolation.\n- **When NOT to use**: tasks that depend on your working context, conversation history, or intermediate state. The child agent starts with a blank slate.\n- **Fork mode**: pass `fork=true` to inherit parent session context (conversation history, plan, skills). Use when the child needs your working context.\n- **Prompt design**: write a complete, self-contained prompt. Include all file paths, function names, error messages, and constraints the child needs. Assume zero shared context.\n- **Result handling**: when the child completes, its result is injected as a user message: `[sub-agent <id>] <status> (in=<n>, out=<n>)\nThinking: ...\nText: ...`. You then get another LLM turn to interpret and act on it.\n- **Parallelism**: multiple SubAgent calls in one turn run concurrently. Use this to parallelize independent investigations. **IMPORTANT**: results return asynchronously as each sub-agent finishes — they do NOT return together. When you receive a result for one sub-agent, the others are still running. Simply wait for all results to arrive before acting. Do NOT re-launch a sub-agent just because another one finished first — match results by session_id.\n- **Failure**: if the child fails (status=failed), the result text may be partial or empty. Handle gracefully — do not retry automatically.'
    todo_guidance=$'- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.'
    plan_lifecycle_guidance=$'- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n- **Files**: PLAN_DRAFT_FILE: '"${PLAN_DRAFT_FILE:-<not set>}"$' | PLAN_FILE: '"${PLAN_FILE:-<not set>}"$'\n- **Why draft first?** Writing to PLAN_FILE immediately invalidates the system prompt cache. Use PLAN_DRAFT_FILE for all drafting iterations to avoid this cost.\n- **Drafting phase** (PLAN_DRAFT_FILE non-empty → you are drafting):\n  Every user reply MUST be classified as exactly ONE of:\n  ① REVISE (any feedback/question/change) → Edit PLAN_DRAFT_FILE → ask confirmation → stay in drafting\n  ② CONFIRM (explicit ok/go/confirmed) → call PlanConfirm IMMEDIATELY (before any other action) → TodoWrite checklist → execute\n  ③ CANCEL (explicit cancel/forget it) → Bash `: > PLAN_DRAFT_FILE` → exit to idle\n  ⚠ On CONFIRM you MUST call PlanConfirm first — no edits, no tool calls before it.\n- **Execution phase**: after PlanConfirm → TodoWrite checklist → execute tasks → PlanClear when all done\n- **Plan vs Todo**: PLAN_FILE=locked plan (only via PlanConfirm), PLAN_DRAFT_FILE=draft (edit freely), TodoWrite=progress tracker. Do NOT mix.'

    instruction_files=$(build_instruction_files_section)
    skill_index=$(build_skill_index_section)
    selected_skills=$(build_selected_skills_section)
    plan=$(read_optional_file "${PLAN_FILE:-}")
    stable_context=$(read_optional_file "${CONTEXT_SUMMARY_FILE:-}")

    append_section output "agent-identity" "$agent_identity"
    append_section output "environment" "$environment"
    append_section output "rules" "$core_rules"
    append_section output "using-your-tools" "$tool_guidance"
    append_section output "sub-agent-guidance" "$sub_agent_guidance"
    append_section output "todo-guidance" "$todo_guidance"
    append_section output "plan-lifecycle-guidance" "$plan_lifecycle_guidance"
    append_section output "instruction-files" "$instruction_files"
    append_section output "skill-index" "$skill_index"
    append_section output "selected-skills" "$selected_skills"
    append_section output "current-plan" "$plan" "${PLAN_FILE:-}"
    append_section output "context-snapshot" "$stable_context"
    append_section output "output-language" "$output_language_reaffirm"

    printf '%s' "${output%$'\n'}"
}

read_optional_file() { [[ -n "$1" && -s "$1" ]] && printf '%s' "$(<"$1")"; }

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
    local text="$1" thinking="$2" calls="$3" content="[" name id input
    content+="{\"type\":\"thinking\",\"thinking\":\"$(json_escape "$thinking")\"}"
    content+=",{\"type\":\"text\",\"text\":\"$(json_escape "$text")\"}"

    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        IFS=$'\t' read -r name id input _ <<< "$tc"
        content+=",$(build_tool_call_json_object "$name" "$id" "$input")"
    done <<< "$calls"

    content+="]"
    printf '%s' "$content"
}

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
    local cwd="${PWD:-$(pwd)}" project_key base="${BASH_AGENT_HOME:-${HOME}}"
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
    local project_dir latest="" latest_ts=0 dir ts
    project_dir="$(get_session_dir)"
    [[ -d "$project_dir" ]] || return 1
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

# --- FIFO / Main Loop ---
# 处理子 agent 通过 FIFO 发回的 AGENT_RESULT 将 result_text 注入主 agent conversation，触发 agent_loop 让主 agent 处理
handle_sub_agent_result() {
    # REPLY_MESSAGE: AGENT_RESULT <session_id> <status> <thinking> <text> <in> <out> <cr> <cc> <reqs>
    local session_id="${REPLY_MESSAGE[1]}" status="${REPLY_MESSAGE[2]}"
    local _thinking="${REPLY_MESSAGE[3]}" _text="${REPLY_MESSAGE[4]}"
    local _in="${REPLY_MESSAGE[5]:-0}" _out="${REPLY_MESSAGE[6]:-0}"
    local _cr="${REPLY_MESSAGE[7]:-0}" _cc="${REPLY_MESSAGE[8]:-0}"
    local _reqs="${REPLY_MESSAGE[9]:-0}"
    # 记录 usage（带 kind=sub_agent, sub_session_id）
    session_append_line "{\"type\":\"usage\",\"input_tokens\":$_in,\"output_tokens\":$_out,\"cache_read_input_tokens\":$_cr,\"cache_creation_input_tokens\":$_cc,\"kind\":\"sub_agent\",\"sub_session_id\":\"$(json_escape "$session_id")\"}"
    stats_inc total_input_tokens=$_in total_output_tokens=$_out total_cache_read_tokens=$_cr total_cache_creation_tokens=$_cc sub_agent_request_count=1 agent_request_count=$_reqs
    # 记录 sub_agent_end 事件
    session_append_line "{\"type\":\"sub_agent_end\",\"session_id\":\"$(json_escape "$session_id")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"$status\"}"
    ACTIVE_SUB_COUNT=$(( ACTIVE_SUB_COUNT - 1 ))
    # 展示结果摘要
    if is_stream_json_mode; then
        printf '{"type":"sub_agent_result","session_id":"%s","status":"%s","input_tokens":%s,"output_tokens":%s}\n' \
            "$(json_escape "$session_id")" "$status" "$_in" "$_out"
    else
        display_ensure_newline
        if [[ "$status" == "ok" ]]; then
            printf '\033[35m[sub-agent %s] completed (in=%s, out=%s)\033[0m\n' "$session_id" "$_in" "$_out"
        else
            printf '\033[31m[sub-agent %s] failed\033[0m\n' "$session_id"
        fi
        [[ -n "$_thinking" ]] && printf '\033[90m%.120s%s\033[0m\n' "$_thinking" "$([[ ${#_thinking} -gt 120 ]] && printf '%s' "…")"
        [[ -n "$_text" ]] && printf '%.120s%s\n' "$_text" "$([[ ${#_text} -gt 120 ]] && printf '%s' "…")"
        DISPLAY_LAST_CHAR=$'\n'
    fi
    _run_agent_loop "[sub-agent $session_id] $status (in=$_in, out=$_out)"$'\n'"Thinking: $_thinking"$'\n'"Text: $_text"
}

# 调用 agent_loop 并处理交互式终端提示符
_run_agent_loop() {
    [[ "$INTERACTIVE" == true ]] && printf '\r\033[K'
    agent_loop "$1"
    if [[ "$INTERACTIVE" == true ]]; then
        [[ "$DISPLAY_LAST_CHAR" != $'\n' ]] && printf '\n'
        printf '\033[32m>\033[0m '
    fi
}

main_loop() {
    until exec 3< "$INPUT_FIFO"; do sleep 0.01; done 2>/dev/null
    exec 4> "$INPUT_FIFO"  # keep write end open to prevent premature EOF
    while read_message <&3; do
        case "${REPLY_MESSAGE[0]}" in
            USER_INPUT)
                local _input="${REPLY_MESSAGE[2]:-${REPLY_MESSAGE[1]:-}}"
                _run_agent_loop "$_input"
                ;;
            AGENT_RESULT) handle_sub_agent_result ;;
        esac
        [[ "$INTERACTIVE" != true ]] && (( ACTIVE_SUB_COUNT == 0 )) && break
    done
    exec 4>&-
    exec 3<&-
    rm -f "$INPUT_FIFO"
}



conv_init() {
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="$(new_session_id)"
    fi
    local project_dir session_dir new_session=false
    project_dir="$(get_session_dir)"
    session_dir="${project_dir}/${SESSION_ID}"
    mkdir -p "$session_dir"

    CONV_FILE="${session_dir}/conversation.jsonl"
    SESSION_EVENT_FILE="${session_dir}/events.jsonl"
    CONTEXT_SUMMARY_FILE="${session_dir}/summary.txt"
    PLAN_FILE="${session_dir}/plan.md"
    PLAN_DRAFT_FILE="${session_dir}/plan.draft"
    STATS_FILE="${session_dir}/stats.json"
    [[ ! -s "$SESSION_EVENT_FILE" ]] && new_session=true
    touch "$CONV_FILE"
    touch "$SESSION_EVENT_FILE"
    touch "$CONTEXT_SUMMARY_FILE"
    touch "$PLAN_FILE"
    touch "$PLAN_DRAFT_FILE"
    if [[ "$new_session" == true ]]; then
        session_append_line "{\"type\":\"session_start\",\"session_id\":\"$(json_escape "$SESSION_ID")\"}"
    fi
    INPUT_FIFO="${session_dir}/input.fifo"
    [[ -p "$INPUT_FIFO" ]] || { rm -f "$INPUT_FIFO"; mkfifo "$INPUT_FIFO"; }
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

stats_inc() {
    # Args: key=delta ...  e.g. stats_inc agent_request_count=1 total_input_tokens=500
    local entry key val line=""
    for entry in "$@"; do
        key="${entry%%=*}" val="${entry#*=}"
        line+="${key}	+${val}"$'\n'
    done
    printf '%s' "$line" | awk_run -v action=update -f "$AWK_DIR/stats.awk" "$STATS_FILE"
    stats_show_osc
}

stats_set() {
    # Args: key=val ...  e.g. stats_set current_context_tokens=7794
    local entry key val line=""
    for entry in "$@"; do
        key="${entry%%=*}" val="${entry#*=}"
        line+="${key}	${val}"$'\n'
    done
    printf '%s' "$line" | awk_run -v action=update -f "$AWK_DIR/stats.awk" "$STATS_FILE"
    stats_show_osc
}

stats_get() {
    # Args: key  e.g. stats_get current_context_tokens
    awk_run -v action=dump -f "$AWK_DIR/stats.awk" "$STATS_FILE" 2>/dev/null | \
        awk -F'\t' -v k="$1" '$1 == k { print $2 }'
}

record_usage() {
    # Args: kind counter_key [write_event=true]
    # Reads REPLY_MESSAGE[1..4], updates stats, optionally logs event. Returns context token count (input+output+cache_read+cache_creation).
    local kind="$1" counter_key="$2" write_event="${3:-true}" _event \
          _in="${REPLY_MESSAGE[1]:-0}" _out="${REPLY_MESSAGE[2]:-0}" _cr="${REPLY_MESSAGE[3]:-0}" _cc="${REPLY_MESSAGE[4]:-0}"
    if [[ "$write_event" == "true" ]]; then
        _event=$(printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"kind":"%s"}' "$_in" "$_out" "$_cr" "$_cc" "$kind")
        session_append_line "$_event"
    fi
    stats_inc ${counter_key}=1 total_input_tokens=${_in} total_output_tokens=${_out} total_cache_read_tokens=${_cr} total_cache_creation_tokens=${_cc}
    echo $(( _in + _out + _cr + _cc ))
}

stats_show_osc() {
    local _dump t r i o c cr
    _dump=$(awk_run -v action=dump -f "$AWK_DIR/stats.awk" "$STATS_FILE" 2>/dev/null)
    t=$(echo "$_dump" | awk -F'\t' '$1=="current_turn_count"{print $2}')
    r=$(echo "$_dump" | awk -F'\t' '$1=="agent_request_count"{print $2}')
    i=$(echo "$_dump" | awk -F'\t' '$1=="total_input_tokens"{print $2}')
    o=$(echo "$_dump" | awk -F'\t' '$1=="total_output_tokens"{print $2}')
    c=$(echo "$_dump" | awk -F'\t' '$1=="current_context_tokens"{print $2}')
    cr=$(echo "$_dump" | awk -F'\t' '$1=="total_cache_read_tokens"{print $2}')
    awk -v m="$MODEL" -v t="${t:-0}" -v r="${r:-0}" -v i="${i:-0}" -v o="${o:-0}" -v c="${c:-0}" -v cr="${cr:-0}" '
    function f(n,s,r){s=sprintf("%d",n);while(length(s)>3){r=","substr(s,length(s)-2)r;s=substr(s,1,length(s)-3)}return s r}
    function pct(num,den){if(den+0>0)return sprintf("%.0f%%",num/den*100);return "—"}
    BEGIN{printf "\033]0;%s T:%s R:%s I:%s(%s) O:%s C:%s\007",m,f(t),f(r),f(i+cr),pct(cr,cr+i),f(o),f(c) > "/dev/stderr"}'
}

# DP compact decision: find optimal k via cache-aware economics. Returns lines to keep or "0".
compact_dp_decision() {
    awk_run -v t="$(stats_get current_turn_count)" -v total_requests="$(stats_get agent_request_count)" \
            -v total_compact="$(stats_get compact_request_count)" -v total_input="$(stats_get total_input_tokens)" \
            -v baseline_e="${DP_BASELINE_E:-8}" -v e_fixed="${DP_E_FIXED:-0}" -v L_fixed="${DP_L:-0}" \
            -v V="$DP_V" -v p_input="$DP_P_INPUT" -v p_cache="$DP_P_CACHE" -v p_out="$DP_P_OUT" \
            -v S="$DP_S" -v min_keep_ratio="$DP_MIN_KEEP_RATIO" -v r="$DP_R" -v beta="$DP_BETA" \
            -f "$AWK_DIR/compact_dp.awk" "$CONV_FILE"
}

compact_turn_keep() {
    awk -v r="$DP_MIN_KEEP_RATIO" '
    BEGIN { target_turns = 0 }
    { role[NR] = ($0 ~ /"role":"user"/ && $0 !~ /"content":\[/) ? "user" : "other" }
    END {
        if (NR == 0) { print 0; exit }
        for (i = 1; i <= NR; i++) if (role[i] == "user") total_turns++
        target = int(total_turns * r + 0.5)
        if (target < 1) target = 1
        if (target > total_turns) target = total_turns
        keep = 0; found = 0
        for (i = NR; i >= 1 && found < target; i--) { keep++; if (role[i] == "user") found++ }
        if (keep == 0) { print 0; exit }
        print keep
    }' "$CONV_FILE"
}

compact_context_window() {
    local trigger=${1:-auto} total_lines keep_lines drop tmp_dropped dropped_messages summary_response

    # 始终先算 DP 决策（经济最优）
    keep_lines=$(compact_dp_decision) || true
    [[ -n "$keep_lines" ]] || keep_lines=0
    total_lines=$(wc -l < "$CONV_FILE" 2>/dev/null || echo 0)
    # DP 返回 0（不值得）或 ≥ total_lines（全保留）→ 都算"不压缩"，进入 fallback
    if (( keep_lines == 0 )) || (( keep_lines >= total_lines && total_lines > 0 )); then
        local ct=$(stats_get current_context_tokens)
        if [[ "$trigger" == "plan_clear" || "$trigger" == "plan_confirm" ]] || (( ct > 0 && ct > MAX_CONTEXT_TOKENS * 90 / 100 )); then
            keep_lines=$(compact_turn_keep)
        else
            return 1
        fi
    fi

    # 统一 guard：keep >= total 或 keep==0 时只有 plan_clear/plan_confirm 继续
    (( keep_lines > 0 && keep_lines < total_lines )) || [[ "$trigger" == "plan_clear" || "$trigger" == "plan_confirm" ]] || return 1
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
    remaining_turns=$(awk '/"role":"user"/ && ! /"content":\[/{n++} END{print n+0}' "$CONV_FILE" 2>/dev/null)
    stats_set current_turn_count=$remaining_turns
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
    local path="$1" old_string="$2" new_string="$3" tmp diff_output added removed label="${1#/}"
    [[ -z "$path" ]] && { echo "Error: no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "Error: file not found: $path"; return 1; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/edit.XXXXXX")
    if ! printf '{"path":"%s","old_string":"%s","new_string":"%s"}' \
            "$(json_escape "$path")" "$(json_escape "$old_string")" "$(json_escape "$new_string")" \
         | awk_run -v max_bytes="$FILE_WRITE_MAX_BYTES" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/edit_file.awk" > "$tmp" 2>&1; then
        cat "$tmp"; rm -f "$tmp"; return 1
    fi
    (( $(wc -c < "$tmp") > 0 )) || { echo "Error: edit produced empty result"; rm -f "$tmp"; return 1; }
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
    local cmd="$1" timeout_secs="${2:-$TOOL_TIMEOUT_SECS}" reason output tool_rc tmpout
    [[ -z "$cmd" ]] && { echo "Error: no command provided"; return 1; }
    reason=$(deny_bash_command_reason "$cmd") || reason=""
    if [[ -n "$reason" ]]; then
        echo "Error: command blocked by bash safety policy ($reason)"
        return 1
    fi
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
    local pattern="$1" path="$2" glob="$3" context="$4" args=(-n --color never --heading)
    [[ -z "$pattern" ]] && { echo "Error: no pattern provided"; return 1; }
    [[ -n "$path" ]] || path="."
    [[ -e "$path" ]] || { echo "Error: path not found: $path"; return 1; }
    command -v rg >/dev/null 2>&1 || { echo "Error: rg is required for grep"; return 1; }
    [[ -n "$context" && "$context" =~ ^[0-9]+$ ]] && args+=(-C "$context")
    [[ -n "$glob" ]] && args+=(--glob "$glob")
    args+=("--" "$pattern" "$path")
    rg "${args[@]}" 2>/dev/null || true
}

tool_skill() {
    local skill_name="$1" skill_content=""
    skill_name="${skill_name#"${skill_name%%[![:space:]]*}"}"
    skill_name="${skill_name%"${skill_name##*[![:space:]]}"}"
    [[ -n "$skill_name" ]] || { echo "Error: no skill name provided"; return 1; }
    skill_content=$(load_skill_content "$skill_name") || { echo "Error: skill not found: $skill_name"; return 1; }
    printf 'Skill: %s\n%s' "$skill_name" "$skill_content"
}

tool_plan_confirm() {
    # 先 compact 再 mv：compact 复用旧缓存前缀，mv 后才触发缓存失效——总共一次冷启动
    if [[ -n "$PLAN_DRAFT_FILE" && -s "$PLAN_DRAFT_FILE" ]]; then
        compact_context_window plan_confirm
        mv "$PLAN_DRAFT_FILE" "$PLAN_FILE"
        : > "$PLAN_DRAFT_FILE"   # 重新创建空 draft，供下次规划使用
        printf 'Plan confirmed and locked in.'
    else
        printf 'Error: no plan draft found to confirm.'
    fi
}

tool_plan_clear() {
    compact_context_window plan_clear
    [[ -n "$PLAN_FILE" && -s "$PLAN_FILE" ]] && printf '' > "$PLAN_FILE"
    printf 'Plan cleared.'
}

tool_web_search() { curl -sS --connect-timeout 10 --max-time 30 -G --data-urlencode "q=$1" -H "Authorization: Bearer ${JINA_API_KEY:-}" -H "X-Respond-With: no-content" "https://s.jina.ai/" 2>&1; }

tool_web_fetch() { curl -sS --connect-timeout 10 --max-time 60 -G --data-urlencode "url=$1" -H "Authorization: Bearer ${JINA_API_KEY:-}" "https://r.jina.ai/" 2>&1; }

# 启动异步子 agent：后台执行 agent_loop，完成后通过 INPUT_FIFO 发回 AGENT_RESULT
# 消息格式：AGENT_RESULT <session_id> <status:ok|failed> <result_text> <in> <out> <cr> <cc> <reqs>
tool_sub_agent() {
    local prompt="$1" description="${2:-}" fork="${3:-}" sub_session_id="sub_$(new_session_id)"

    [[ -z "$prompt" ]] && { echo "Error: no prompt provided for sub-agent"; return 1; }

    session_append_line "{\"type\":\"sub_agent_start\",\"session_id\":\"$(json_escape "$sub_session_id")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"prompt\":\"$(json_escape "$prompt")\",\"description\":\"$(json_escape "$description")\",\"fork\":$fork}"

    (
        # fork 模式：复制父 session 的核心文件到子 session
        if [[ "$fork" == "true" ]]; then
            local _sub_dir="$(get_session_dir "$sub_session_id")"
            mkdir -p "$_sub_dir" && cp "$(get_session_dir "$SESSION_ID")"/{conversation.jsonl,summary.txt,plan.md} "$_sub_dir/" 2>/dev/null || true
        fi
        export SESSION_ID="$sub_session_id"
        export INTERACTIVE=false
        local _parent_input_fifo="$INPUT_FIFO"
        conv_init
        load_tool_defs
        # 正常路径发送完成后 _done=true，阻止 EXIT trap 重复发送
        local _done=false
        _send_result_via_awk() {
            local _st="${1:-failed}"
            awk_run -v session_id="$sub_session_id" -v status="$_st" \
                -v stats_file="$STATS_FILE" -v conv_file="$CONV_FILE" \
                -f "$AWK_DIR/json.awk" -f "$AWK_DIR/send_sub_result.awk" \
                > "$_parent_input_fifo"
        }
        trap '[[ "$_done" == true ]] || { _send_result_via_awk failed; }; rm -f "$INPUT_FIFO"' EXIT
        # 输出全部重定向到 /dev/null，不污染主 agent 终端
        local _status="ok"
        agent_loop "$prompt" >/dev/null || _status="failed"
        _send_result_via_awk "$_status"
        _done=true
    ) &

    printf 'Sub-agent started: session_id=%s, pid=%s' "$sub_session_id" "$!"
}

dispatch_tool() {
    local name="$1" arg1="${2:-}" arg2="${3:-}" arg3="${4:-}" arg4="${5:-}"
    case "$name" in
        Read)      tool_read "$arg1" "$arg2" "$arg3" ;;
        Write)     tool_write "$arg1" "$arg2" ;;
        Edit)      tool_edit "$arg1" "$arg2" "$arg3" ;;
        Bash)      tool_bash "$arg1" "$arg2" ;;
        Glob)      tool_glob "$arg1" "$arg2" ;;
        Grep)      tool_grep "$arg1" "$arg2" "$arg3" "$arg4" ;;
        TodoWrite) printf '%s' "$arg1" ;;
        PlanConfirm) tool_plan_confirm ;;
        PlanClear) tool_plan_clear ;;
        Skill)     tool_skill "$arg1" ;;
        WebSearch) tool_web_search "$arg1" ;;
        WebFetch)  tool_web_fetch "$arg1" ;;
        SubAgent)  tool_sub_agent "$arg1" "$arg2" "$arg3" ;;
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
    local messages="$1" max_tokens="${2:-$MAX_TOKENS}" use_thinking="${3:-$THINKING}" body system_prompt
    system_prompt=$(build_system_prompt)
    body="{\"model\":\"${MODEL}\",\"max_tokens\":${max_tokens},\"stream\":true"
    if [[ "$use_thinking" != "disabled" ]]; then
        body+=",\"thinking\":{\"type\":\"${use_thinking}\"}"
        body+=",\"output_config\":{\"effort\":\"${EFFORT}\"}"
    fi
    [[ -n "$system_prompt" ]] && body+=",\"system\":\"$(json_escape "$system_prompt")\""
    [[ -n "$TOOL_DEF_JSON" ]] && body+=",\"tools\":${TOOL_DEF_JSON}"
    body+=",\"messages\":${messages}}"
    $VERBOSE && printf '\033[90m[verbose] Request body (%dKB): %.200s...\033[0m\n' "$((${#body} / 1024))" "$body" >&2
    printf '%s' "$body" | body_convert | _stream_curl | sse_convert | sse_parse
}

run_summary_call() {
    local dropped_messages="$1" text="" last_error="" stop_reason="" messages summary_instruction=$'The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. Do NOT think. Just output the summary directly as plain text. Summarize the key information from the messages above into a concise context summary. Update the existing summary snapshot using the messages above. Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:\nReflections:'
    messages=$(conv_get_messages "${dropped_messages}"$'\n'"{\"role\":\"user\",\"content\":\"$(json_escape "$summary_instruction")\"}")
    while read_message; do
        case "${REPLY_MESSAGE[0]}" in
            TEXT)  text+="${REPLY_MESSAGE[1]}" ;;
            THINKING) ;;
            USAGE) record_usage "compact" compact_request_count >/dev/null ;;
            ERROR) last_error="${REPLY_MESSAGE[1]}" ;;
            STOP)  stop_reason="${REPLY_MESSAGE[1]}" ;;
        esac
    done < <(llm_call "$messages" "$MAX_TOKENS" "disabled")
    [[ -n "$text" ]] || die "Failed to generate context summary: empty text response (stop_reason=${stop_reason:-none}, error=${last_error:-none})"
    printf '%s' "$text"
}

# --- Agent Loop ---
agent_loop_stream() {
    local user_input="$1" turn=0
    conv_add_user "$user_input"
    # Trap SIGINT: close pipe FD to unblock read
    trap 'INTERRUPT_REQUESTED=true; exec 5<&- 2>/dev/null' INT
    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true
        # Compact before each LLM call: uses ctx_tokens from previous call's USAGE
        compact_context_window auto && write_message "CONTEXT_UPDATE" "compact" "auto"
        local text="" thinking="" tool_calls="" stop="" loop_error="" tool_conv_results="" _ctx_tokens=""
        [[ "$VERBOSE" == true ]] && printf '[debug] messages: %.500s...\n' "$(conv_get_messages "$(<"$CONV_FILE")")" >&2
        exec 5< <(llm_call "$(conv_get_messages "$(<"$CONV_FILE")")")
        while read_message <&5; do
            if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                stop="interrupted"
                break
            fi
            [[ "$VERBOSE" == true ]] && printf '[debug] type=<%s> nfields=%d\n' "${REPLY_MESSAGE[0]}" "${#REPLY_MESSAGE[@]}" >&2
            write_message "${REPLY_MESSAGE[@]}" # Forward to display
            case "${REPLY_MESSAGE[0]}" in
                RETRY)    text="" thinking="" tool_calls="" tool_conv_results="" _ctx_tokens="" ;;
                TEXT)     text+="${REPLY_MESSAGE[1]}" ;;
                THINKING) thinking+="${REPLY_MESSAGE[1]}" ;;
                TOOL_CALL)
                    local cur_tool_name cur_tool_id input arg1="" arg2="" arg3="" arg4="" output tool_rc=0 result_for_conv="" _tr_args=() i _n=${#REPLY_MESSAGE[@]}
                    cur_tool_name="${REPLY_MESSAGE[1]}"
                    cur_tool_id="${REPLY_MESSAGE[2]}"
                    input="${REPLY_MESSAGE[3]}"
                    tool_calls+="${cur_tool_name}"$'\t'"${cur_tool_id}"$'\t'"${input}"$'\n'
                    # Execute tool immediately, output result
                    tool_args_from_msg "$cur_tool_name" arg1 arg2 arg3 arg4
                    output=$(dispatch_tool "$cur_tool_name" "$arg1" "$arg2" "$arg3" "$arg4" 2>&1)
                    tool_rc=$?
                    if (( tool_rc != 0 )); then
                        output="Error: tool execution failed: $output"
                    fi
                    output=$(format_tool_result "$output")
                    result_for_conv="$output"
                    if [[ "$cur_tool_name" == "Edit" ]]; then
                        result_for_conv="$(printf '%s' "$output" | sed -n '1p')"
                    fi
                    tool_conv_results+="${cur_tool_id}"$'\t'"$(json_escape "$result_for_conv")"$'\n'
                    # Prepend file summary header for Read/Write so events.jsonl captures it
                    if [[ "$cur_tool_name" == "Read" || "$cur_tool_name" == "Write" ]]; then
                        output="$(tool_file_summary "$cur_tool_name" "$arg1")"$'\n'"$output"
                    fi
                    # TOOL_RESULT: [0]=type [1]=id [2]=name [3]=output [4..]=checklist/summary
                    _tr_args=("TOOL_RESULT" "$cur_tool_id" "$cur_tool_name" "$output")
                    [[ -n "$arg1" ]] && _tr_args+=("$arg1")
                    [[ -n "$arg2" ]] && _tr_args+=("$arg2")
                    # Search for checklist/summary in TOOL_CALL flattened KV pairs
                    for (( i = 4; i + 1 < _n; i += 2 )); do
                        if [[ "${REPLY_MESSAGE[i]}" == "checklist" ]]; then _tr_args+=("checklist" "${REPLY_MESSAGE[i+1]}"); fi
                        if [[ "${REPLY_MESSAGE[i]}" == "summary" ]]; then _tr_args+=("summary" "${REPLY_MESSAGE[i+1]}"); fi
                    done
                    write_message "${_tr_args[@]}"
                    ;;
                STOP)  stop="${REPLY_MESSAGE[1]}" ;;
                ERROR) loop_error="${REPLY_MESSAGE[1]}"; stop="error"; break ;;
                USAGE) _ctx_tokens=$(record_usage "agent" agent_request_count false) ;;
            esac
        done
        exec 5<&-
        [[ "$INTERRUPT_REQUESTED" == true ]] && { write_message "STOP" "interrupted"; break; }
        # Fatal stop reasons exit immediately
        case "$stop" in
            error|max_tokens|length)
                [[ "$stop" != "error" ]] && { write_message "ERROR" "Response truncated (max_tokens reached)"; }
                return 1
                ;;
        esac
        # Tools already executed inline; persist unless interrupted
        if [[ "$INTERRUPT_REQUESTED" != true ]]; then
            conv_add_assistant "$text" "$thinking" "$tool_calls"
            if [[ -n "$tool_conv_results" ]]; then
                conv_add_tool_results "$tool_conv_results"
            fi
            # Update context tokens from USAGE (used by next turn's compact check)
            if [[ -n "$_ctx_tokens" && "$_ctx_tokens" -gt 0 ]]; then
                stats_set current_context_tokens=${_ctx_tokens}
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
    local user_input="$1" had_error=false _se=""
    DISPLAY_LAST_CHAR=$'\n'
    PREV_WAS_THINKING=false
    INTERRUPT_REQUESTED=false
    # Trap SIGINT (Ctrl+C): close pipe FD to unblock read
    trap 'INTERRUPT_REQUESTED=true; exec 4<&- 2>/dev/null' INT
    [[ "$LOG_EVENTS" != "false" ]] && session_append_line "{\"type\":\"user_input\",\"content\":\"$(json_escape "$user_input")\"}"
    stats_inc current_turn_count=1
    # Open the process substitution
    exec 4< <(agent_loop_stream "$user_input")
    while read_message <&4; do
        [[ "${REPLY_MESSAGE[0]}" == "ERROR" ]] && had_error=true
        # SubAgent started: track active count in main shell
        [[ "${REPLY_MESSAGE[0]}" == "TOOL_CALL" && "${REPLY_MESSAGE[1]}" == "SubAgent" ]] && ACTIVE_SUB_COUNT=$(( ACTIVE_SUB_COUNT + 1 ))
        # Layer 1: Always convert and write to events.jsonl
        _se=$(msg_to_stream_event) && [[ -n "$_se" ]] && {
            [[ "$LOG_EVENTS" != "false" ]] && session_append_line "$_se"
        }
        # Layer 2: stdout — stream-json or human display
        [[ "${REPLY_MESSAGE[0]}" == "STOP" && "${REPLY_MESSAGE[1]}" == "interrupted" ]] && break
        if is_stream_json_mode; then
            [[ -n "$_se" ]] && printf '%s\n' "$_se"
        else
            display_event
        fi
    done
    exec 4<&-
    if [[ "$INTERRUPT_REQUESTED" == true ]]; then
        if is_stream_json_mode; then
            printf '{"type":"stop","reason":"interrupted"}\n'
        else
            printf '\033[36mInterrupted.\033[0m\n'
        fi
    fi
    $had_error && return 1
    return 0
}

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
  --thinking MODE         Thinking mode: adaptive | enabled | disabled (default: adaptive)
  --effort LEVEL          Reasoning effort: low | medium | high (default: high)
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
            --thinking)       THINKING="$2"; shift 2 ;;
            --effort)         EFFORT="$2"; shift 2 ;;
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
        *) die "Unknown output format: $OUTPUT_FORMAT (use human|stream-json)" ;;
    esac
}

list_sessions() {
    local dir session_dir name mod preview summary_file
    dir="$(get_session_dir)"
    if [[ ! -d "$dir" ]]; then
        echo "No sessions found."
        return
    fi
    printf "%-40s %-16s %s\n" "NAME" "MODIFIED" "PREVIEW"
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
    local history_file="${BASH_AGENT_HOME:-${HOME}}/.bash-agent/history" _saved_log_events="${LOG_EVENTS:-true}" _efile="${SESSION_EVENT_FILE:-}" _match _from_line line
    mkdir -p "$(dirname "$history_file")" 2>/dev/null || true
    touch "$history_file" 2>/dev/null || true
    history -r "$history_file" 2>/dev/null || true
    printf '\033[36mbash-agent interactive mode (type '\''exit'\'' or Ctrl+D to quit)\033[0m\n'
    # Replay recent 10 turns for resumed sessions (inlined turn-aware replay)
    if [[ -s "${SESSION_EVENT_FILE:-}" ]]; then
        LOG_EVENTS=false
        _match=$(grep -n '"type":"user_input"' "$_efile" 2>/dev/null | tail -n 10 | head -n 1) || true
        _from_line="${_match%%:*}"
        [[ -n "$_from_line" && "$_from_line" -ge 1 ]] || _from_line=1
        tail -n +"$_from_line" "$_efile" \
            | awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/event_replay.awk" \
            | while read_message; do
                display_event
            done
        printf '\n'
        DISPLAY_LAST_CHAR=$'\n'
        LOG_EVENTS="$_saved_log_events"
    fi
    stats_show_osc
    {
        exec 4> "$INPUT_FIFO"
        while true; do
            stty echo 2>/dev/null || true
            if ! IFS= read -e -r -p $'\033[32m>\033[0m ' line < /dev/tty; then
                break
            fi
            [[ "$line" == "exit" || "$line" == "quit" ]] && break
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" >> "$history_file"
            write_message "USER_INPUT" "0" "$line" >&4
        done
        exec 4>&-
    } &
    local _stdin_pid=$!

    main_loop
    trap - INT
    # 清理子进程（包括 stdin_reader 和所有后台任务）
    kill -INT -- "-$_stdin_pid" 2>/dev/null || kill -INT "$_stdin_pid" 2>/dev/null || true
    wait "$_stdin_pid" 2>/dev/null || true

    printf '\033[36mGoodbye!\033[0m\n\033[90mResume with: --session %s  or  --continue\033[0m\n' "$SESSION_ID"
}

main() {
    parse_args "$@"
    find_awk_dir
    validate_config
    conv_init
    load_tool_defs
    if [[ "$INTERACTIVE" == true ]]; then
        interactive_mode
    elif [[ -n "$USER_INPUT" || ! -t 0 ]]; then
        local input="$USER_INPUT"
        [[ -z "$input" ]] && input=$(cat)
        ( exec 3> "$INPUT_FIFO"; write_message "USER_INPUT" "0" "$input" >&3 ) &
        main_loop
    else
        INTERACTIVE=true
        interactive_mode
    fi
}

main "$@"
