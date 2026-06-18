#!/usr/bin/env bash
# bash-agent — AI Agent in pure bash/awk
# Supports: Anthropic Claude, OpenAI Chat
# No dependencies beyond: bash, curl, awk

set -uo pipefail

# User Options
PROVIDER="claude"
MODEL=""
API_KEY=""
BASE_URL=""
USER_INPUT=""
MAX_TOKENS=16384
MAX_TURNS=1000
MAX_CONTEXT_TOKENS=200000
TOOL_TIMEOUT_SECS=600
OUTPUT_FORMAT="human"
VERBOSE=false
: "${TOOL_RESULT_MAX_BYTES:=100000}"
: "${BASH_AGENT_BASH_MODE:=0467}"  # system external network workspace; octal rwx bits per scope
: "${EFFORT:=high}"           # thinking effort: low|medium|high|xhigh|max
: "${THINKING:=adaptive}"     # thinking mode: adaptive|enabled|disabled

# Internal Runtime State
INTERACTIVE=false
LOG_EVENTS=true
FORK=false
declare -a HEADER_ARGS=()
declare -a SKILL_NAMES=()
INTERRUPT_REQUESTED=false
DISPLAY_LAST_CHAR=$'\n'
PREV_WAS_THINKING=false

util_awk_run() { LC_ALL=C LANG=C awk "$@"; }

util_write_msg() {
    # Args: field0 field1 field2 ...
    # Wire format (RESP-like, CRLF): *N\r\n$len0\r\ndata0\r\n$len1\r\ndata1\r\n...
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

util_read_msg() {
    # Reads RESP-like CRLF format: *N\r\n$len0\r\ndata0\r\n...
    local _old_lc_all="${LC_ALL:-}"
    LC_ALL=C
    REPLY_MESSAGE=()
    local nfields i _hdr _len _field _want _remain _chunk

    IFS= read -r _hdr || [[ -n "$_hdr" ]]
    _hdr="${_hdr%$'\r'}"
    [[ -n "$_hdr" && "$_hdr" == \** ]] || { LC_ALL="${_old_lc_all}"; return 1; }
    nfields="${_hdr:1}"

    for ((i = 0; i < nfields; i++)); do
        IFS= read -r _hdr || [[ -n "$_hdr" ]]
        _hdr="${_hdr%$'\r'}"
        [[ -n "$_hdr" && "$_hdr" == \$* ]] || { LC_ALL="${_old_lc_all}"; return 1; }
        _len="${_hdr:1}"
        _field=""
        if (( _len > 0 )); then
            _want=$((_len + 2))
            while (( ${#_field} < _want )); do
                _remain=$((_want - ${#_field}))
                IFS= read -r -d '' -n "$_remain" _chunk 2>/dev/null || true
                _field+="$_chunk"
                [[ -z "$_chunk" ]] && break
            done
            _field="${_field%$'\r\n'}"
        else
            IFS= read -r -n 2 _crlf 2>/dev/null || true
        fi
        REPLY_MESSAGE+=("$_field")
    done
    LC_ALL="${_old_lc_all}"
    return 0
}

util_new_session_id() {
    printf '%s-%04x' "$(date +%Y%m%d-%H%M%S)" "$(( RANDOM << 1 | (RANDOM & 1) ))"
}

util_run_timeout() {
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

util_die() {
    printf '\033[31mError: %s\033[0m\n' "$*" >&2
    exit 1
}

util_parse_size() {
    local raw="${1:-}" lower num
    lower=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *k) num="${lower%k}";  [[ "$num" =~ ^[0-9]+$ ]] || return 1; printf '%s' $(( num * 1000 )) ;;
        *m) num="${lower%m}";  [[ "$num" =~ ^[0-9]+$ ]] || return 1; printf '%s' $(( num * 1000 * 1000 )) ;;
        *g) num="${lower%g}";  [[ "$num" =~ ^[0-9]+$ ]] || return 1; printf '%s' $(( num * 1000 * 1000 * 1000 )) ;;
        *)  [[ "$lower" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$lower" ;;
    esac
}

util_json_escape() {
    local _s="${1:-}"
    _s="${_s//\\/\\\\}" _s="${_s//\"/\\\"}" _s="${_s//$'\n'/\\n}" _s="${_s//$'\r'/\\r}" _s="${_s//$'\t'/\\t}" _s="${_s//$'\b'/\\b}" _s="${_s//$'\f'/\\f}"
    printf '%s' "$_s"
}

util_is_stream_json() { [[ "$OUTPUT_FORMAT" == "stream-json" ]]; }

util_append_section() {
    local __outvar="$1" tag="$2" content="$3" name="${4:-}" wrapped
    [[ -n "$content" ]] || return 0
    if [[ -n "$name" ]]; then
        wrapped=$(printf '<%s name="%s">\n%s\n</%s>' "$tag" "$(util_json_escape "$name")" "$content" "$tag")
    else
        wrapped=$(printf '<%s>\n%s\n</%s>' "$tag" "$content" "$tag")
    fi
    printf -v "$__outvar" '%s%s\n' "${!__outvar}" "$wrapped"
}

util_msg_to_stream() {
    local _type="${REPLY_MESSAGE[0]}"
    case "$_type" in
        TEXT)        printf '{"type":"text","content":"%s"}' "$(util_json_escape "${REPLY_MESSAGE[1]}")" ;;
        THINKING)    printf '{"type":"thinking","content":"%s"}' "$(util_json_escape "${REPLY_MESSAGE[1]}")" ;;
        TOOL_CALL)
            printf '{"type":"tool_call","name":"%s","id":"%s","input":%s}' \
                "$(util_json_escape "${REPLY_MESSAGE[1]}")" \
                "$(util_json_escape "${REPLY_MESSAGE[2]}")" \
                "${REPLY_MESSAGE[3]}"
            ;;
        TOOL_RESULT)
            printf '{"type":"tool_result","tool_use_id":"%s","name":"%s","content":"%s"}' \
                "$(util_json_escape "${REPLY_MESSAGE[1]}")" \
                "$(util_json_escape "${REPLY_MESSAGE[2]}")" \
                "$(util_json_escape "${REPLY_MESSAGE[3]}")"
            ;;
        USAGE)       printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"kind":"agent"}' "${REPLY_MESSAGE[1]:-0}" "${REPLY_MESSAGE[2]:-0}" "${REPLY_MESSAGE[3]:-0}" "${REPLY_MESSAGE[4]:-0}" ;;
        SUB_AGENT_RESULT) printf '{"type":"sub_agent_result","session_id":"%s","status":"%s","input_tokens":%s,"output_tokens":%s,"thinking":"%s","text":"%s"}' \
            "$(util_json_escape "${REPLY_MESSAGE[1]}")" "${REPLY_MESSAGE[2]}" "${REPLY_MESSAGE[3]}" "${REPLY_MESSAGE[4]}" \
            "$(util_json_escape "${REPLY_MESSAGE[5]}")" "$(util_json_escape "${REPLY_MESSAGE[6]}")" ;;
        STOP)        printf '{"type":"stop","reason":"%s"}' "$(util_json_escape "${REPLY_MESSAGE[1]}")" ;;
        CONTEXT_UPDATE) printf '{"type":"context_update","kind":"%s","trigger":"%s"}' "$(util_json_escape "${REPLY_MESSAGE[1]}")" "$(util_json_escape "${REPLY_MESSAGE[2]}")" ;;
        ERROR)       printf '{"type":"error","message":"%s"}' "$(util_json_escape "${REPLY_MESSAGE[1]}")" ;;
        RETRY)       printf '{"type":"retry"}' ;;
        *)           return 1 ;;
    esac
    return 0
}

util_read_optional() { [[ -n "$1" && -s "$1" ]] && printf '%s' "$(<"$1")"; }

store_session_image_dir() { printf '%s/%s/images' "$(store_session_get_dir)" "${SESSION_ID:-}"; }

agent_image_next_name() {
    local count=$(ls "$(store_session_image_dir)"/*.png 2>/dev/null | wc -l | tr -d ' ')
    printf '%d.png' "$((count + 1))"
}

agent_image_clipboard_to_cache() {
    local name path tmp
    name="$(agent_image_next_name)" || return 1
    path="$(store_session_image_dir)/$name"
    tmp="$path.tmp.$$"
    trap 'rm -f "$tmp" 2>/dev/null || true; trap - RETURN' RETURN

    osascript -e 'set theImage to the clipboard as «class PNGf»' \
        -e "set theFile to open for access POSIX file \"$tmp\" with write permission" \
        -e 'write theImage to theFile' \
        -e 'close access theFile' >/dev/null 2>&1 \
    || wl-paste --type image/png >"$tmp" 2>/dev/null \
    || xclip -selection clipboard -t image/png -o >"$tmp" 2>/dev/null \
    || return 1

    [[ -s "$tmp" ]] || return 1
    command -v oxipng >/dev/null 2>&1 && oxipng -o 4 --strip safe --quiet "$tmp" >/dev/null 2>&1
    mv "$tmp" "$path" || return 1
    printf '%s' "$name"
}

agent_image_insert_placeholder_readline() {
    local p line point
    [[ -n "${READLINE_LINE+x}" ]] || return 1
    local image_name
    image_name="$(agent_image_clipboard_to_cache)" || return 1
    p="[Image #${image_name%.png}]"
    line="$READLINE_LINE"
    point=${READLINE_POINT:-${#line}}
    [[ "$point" =~ ^[0-9]+$ ]] || point=${#line}
    (( point > ${#line} )) && point=${#line}
    READLINE_LINE="${line:0:point}${p}${line:point}"
    READLINE_POINT=$((point + ${#p}))
}

agent_image_describe() {
    local api_key="${DESCRIBE_API_KEY:-}" model="${DESCRIBE_MODEL:-glm-4v-flash}" \
          base_url="${DESCRIBE_BASE_URL:-https://open.bigmodel.cn/api/paas/v4}" paths=("$@") tmp desc="" p
    [[ ${#paths[@]} -eq 0 || -z "$api_key" ]] && return 0
    tmp=$(mktemp) || return 1
    trap 'rm -f "$tmp"' RETURN
    printf '{"model":"%s","stream":true,"messages":[{"role":"user","content":[{"type":"text","text":"Output all visible text from each image, separated by a blank line between images. Transcribe every character including special symbols (arrows, prompts, dots, slashes). Preserve exact spacing and line breaks. Pay attention to date formats (month names, numbers). Do not summarize or describe - just output the raw text exactly as shown. If an image has no text, briefly describe what you see."}' "$model" > "$tmp"
    for p in "${paths[@]}"; do
        printf ',{"type":"image_url","image_url":{"url":"data:image/png;base64,' >> "$tmp"
        base64 < "$p" | tr -d '\n\r' >> "$tmp"
        printf '"}}' >> "$tmp"
    done
    printf ']}]}' >> "$tmp"
    while util_read_msg; do
        case "${REPLY_MESSAGE[0]}" in
            TEXT) desc+="${REPLY_MESSAGE[1]}" ;;
            STOP) break ;;
        esac
    done < <(curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 \
        --connect-timeout 5 --speed-limit 1 --speed-time 60 \
        -H "Content-Type: application/json" -H "Authorization: Bearer $api_key" \
        -d "@$tmp" "${base_url}/chat/completions" 2>&1 | \
        util_awk_run -f "$AWK_DIR/http_stream.awk" | \
        util_awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk" | \
        sse_parse)
    printf '%s' "$desc"
}

util_find_skill_dirs() {
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

util_load_skill_content() {
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
    done < <(util_find_skill_dirs)
    return 1
}

util_build_skill_index() {
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
            summary=$(util_awk_run -f "$AWK_DIR/skill_summary.awk" "$skill_file")
            output+="- ${skill_name}"
            [[ -n "$summary" ]] && output+=": ${summary}"
            output+=$'\n'
        done
    done < <(util_find_skill_dirs)

    printf '%s' "${output%$'\n'}"
}

util_build_skills_section() {
    local output="" skill_name skill_content
    if [[ ${#SKILL_NAMES[@]} -eq 0 ]]; then
        printf ''
        return 0
    fi
    for skill_name in "${SKILL_NAMES[@]}"; do
        skill_content=$(util_load_skill_content "$skill_name") || util_die "Skill not found: $skill_name (expected .claude/skills/$skill_name/SKILL.md or ~/.claude/skills/$skill_name/SKILL.md)"
        util_append_section output "skill" "$skill_content" "$skill_name"
    done
    printf '%s' "${output%$'\n'}"
}

util_find_instruction_file() {
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

util_build_instructions_section() {
    local output="" global_file project_file global_content project_content
    global_file=$(util_find_instruction_file "${HOME}/.bash-agent" 2>/dev/null || true)
    project_file=$(util_find_instruction_file "${PWD:-$(pwd)}" 2>/dev/null || true)

    if [[ -n "$global_file" ]]; then
        global_content=$(<"$global_file") || return 1
        util_append_section output "instruction-file" "$global_content" "global"
    fi
    if [[ -n "$project_file" ]]; then
        project_content=$(<"$project_file") || return 1
        util_append_section output "instruction-file" "$project_content" "project"
    fi
    printf '%s' "${output%$'\n'}"
}

util_build_tool_call_json() {
    local name="$1" id="$2" input="$3" type="${4:-tool_use}"
    if [[ "$type" == "tool_use" ]]; then
        printf '{"type":"tool_use","id":"%s","name":"%s","input":%s}' \
            "$(util_json_escape "$id")" \
            "$(util_json_escape "$name")" \
            "$input"
    else
        printf '{"name":"%s","id":"%s","input":%s}' \
            "$(util_json_escape "$name")" \
            "$(util_json_escape "$id")" \
            "$input"
    fi
}

util_build_tool_result_json() {
    local tid="$1" result="$2" type="${3:-tool_result}"
    printf '{"type":"%s","tool_use_id":"%s","content":"%s"}' \
        "$(util_json_escape "$type")" \
        "$(util_json_escape "$tid")" \
        "$result"
}

util_build_assistant_json() {
    local text="$1" thinking="$2" calls="$3" content="[" name id input
    content+="{\"type\":\"thinking\",\"thinking\":\"$(util_json_escape "$thinking")\"}"
    content+=",{\"type\":\"text\",\"text\":\"$(util_json_escape "$text")\"}"
    while IFS= read -r tc; do
        [[ -z "$tc" ]] && continue
        IFS=$'\t' read -r name id input _ <<< "$tc"
        content+=",$(util_build_tool_call_json "$name" "$id" "$input")"
    done <<< "$calls"
    content+="]"
    printf '%s' "$content"
}

util_find_awk_dir() {
    if [[ -n "${AWK_DIR:-}" ]]; then
        [[ -d "$AWK_DIR" ]] && return
        util_die "AWK_DIR not found: $AWK_DIR"
    fi
    # Fallback: awk/ alongside agent.sh
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/awk" ]]; then
        AWK_DIR="$script_dir/awk"
        return
    fi
    util_die "Cannot find awk/ directory. Set AWK_DIR or ensure awk/ exists alongside agent.sh"
}

util_load_tool_defs() {
    local tools_file script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    tools_file="$script_dir/tools.json"
    [[ -f "$tools_file" ]] || util_die "Cannot find tools.json: $tools_file"
    TOOL_DEF_JSON=$(<"$tools_file")
}

# store
store_session_init() {
    if [[ -z "${SESSION_ID:-}" ]]; then
        SESSION_ID="$(util_new_session_id)"
    fi
    local project_dir session_dir new_session=false
    project_dir="$(store_session_get_dir)"
    session_dir="${project_dir}/${SESSION_ID}"
    mkdir -p "$session_dir"

    CONV_FILE="${session_dir}/conversation.jsonl"
    SESSION_EVENT_FILE="${session_dir}/events.jsonl"
    CONTEXT_SUMMARY_FILE="${session_dir}/summary.txt"
    PLAN_FILE="${session_dir}/plan.md"
    PLAN_DRAFT_FILE="${session_dir}/plan.draft"
    STATS_FILE="${session_dir}/stats.json"
    [[ ! -s "$SESSION_EVENT_FILE" ]] && new_session=true
    touch "$CONV_FILE" "$SESSION_EVENT_FILE" "$CONTEXT_SUMMARY_FILE" "$PLAN_FILE" "$PLAN_DRAFT_FILE" "$STATS_FILE"
    mkdir -p "${session_dir}/images" 2>/dev/null || true
    if [[ "$new_session" == true ]]; then
        store_event_append "{\"type\":\"session_start\",\"session_id\":\"$(util_json_escape "$SESSION_ID")\"}"
    fi
    INPUT_FIFO="${session_dir}/input.fifo"
    [[ -p "$INPUT_FIFO" ]] || { rm -f "$INPUT_FIFO"; mkfifo "$INPUT_FIFO"; }
}

store_session_fork() {
    local parent_dir="$1" child_dir="$2"
    mkdir -p "$child_dir"
    cp "$parent_dir"/{conversation.jsonl,summary.txt,plan.md} "$child_dir/" 2>/dev/null || true
}

store_session_get_dir() {
    local cwd="${PWD:-$(pwd)}" project_key base="${BASH_AGENT_HOME:-${HOME}}"
    cwd="$(cd "$cwd" && pwd -P)"
    project_key="$(printf '%s' "$cwd" | util_awk_run '
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

store_session_get_latest_dir() {
    local project_dir latest="" latest_ts=0 dir ts
    project_dir="$(store_session_get_dir)"
    [[ -d "$project_dir" ]] || return 1
    for dir in "$project_dir"/*/; do
        [[ -d "$dir" ]] || continue
        ts=$(stat -f "%m" "$dir/events.jsonl" 2>/dev/null || stat -c "%Y" "$dir/events.jsonl" 2>/dev/null || stat -f "%m" "$dir" 2>/dev/null || stat -c "%Y" "$dir" 2>/dev/null || echo 0)
        (( ts > latest_ts )) && { latest_ts=$ts; latest="$dir"; }
    done
    [[ -n "$latest" ]] && basename "$latest" || return 1
}

store_session_resolve_continue() {
    local latest_id=""
    latest_id="$(store_session_get_latest_dir || true)"
    if [[ -n "$latest_id" ]]; then
        SESSION_ID="$latest_id"
    else
        SESSION_ID="$(util_new_session_id)"
    fi
}

# 处理子 agent 通过 FIFO 发回的 AGENT_RESULT 将 result_text 注入主 agent conversation，触发 agent_loop 让主 agent 处理
store_event_append() {
    [[ -n "${SESSION_EVENT_FILE:-}" ]] || return 0
    if util_is_stream_json; then printf '%s\n' "$1" | tee -a "$SESSION_EVENT_FILE"; else printf '%s\n' "$1" >> "$SESSION_EVENT_FILE"; fi
}

store_conv_add_user() {
    local content; content=$(util_json_escape "$1")
    printf '{"role":"user","content":"%s"}\n' "$content" >> "$CONV_FILE"
}

store_conv_add_assistant() {
    local text="$1" thinking="$2" calls="$3" content
    content=$(util_build_assistant_json "$text" "$thinking" "$calls")
    printf '{"role":"assistant","content":%s}\n' "$content" >> "$CONV_FILE"
}

store_conv_add_tool_results() {
    # $1: newline-separated list of id<TAB>json_escaped_result
    local results="$1" content="[" first=true tid="" result=""
    while IFS=$'\t' read -r tid result; do
        [[ -z "$tid" ]] && continue
        $first || content+=","
        first=false
        content+=$(util_build_tool_result_json "$tid" "$result")
    done <<< "$results"
    content+="]"
    printf '{"role":"user","content":%s}\n' "$content" >> "$CONV_FILE"
}

store_conv_get_messages() {
    local input="${1:-$(<"$CONV_FILE")}" result="[" first=true
    while IFS= read -r msg; do
        [[ -z "$msg" ]] && continue
        $first || result+=","
        first=false
        result+="$msg"
    done <<< "$input"
    printf '%s]' "$result"
}

store_summary_set() {
    local text="$1"
    [[ -n "${CONTEXT_SUMMARY_FILE:-}" ]] || return 0
    [[ -n "$text" ]] || return 0
    printf '%s\n' "$text" > "$CONTEXT_SUMMARY_FILE"
}

store_stats_update() {
    # Args: key=val(覆盖) / key=+val(累加)  e.g. store_stats_update agent_request_count=+1 current_context_tokens=7794
    printf '%s\n' "$@" | util_awk_run -v action=update -f "$AWK_DIR/stats.awk" "$STATS_FILE"
    display_term_title
}

store_stats_get() {
    # Args: key  e.g. store_stats_get current_context_tokens
    util_awk_run -v action=get -v key="$1" -f "$AWK_DIR/stats.awk" "$STATS_FILE"
}

# — store_conv: conversation 数据操作 API —

store_conv_line_count() { wc -l < "$CONV_FILE" 2>/dev/null || echo 0; }

store_conv_head_to() { head -n "$1" "$CONV_FILE" > "$2"; } # $1=lines, $2=outfile

store_conv_trim_tail() {
    # $1=lines to keep from tail
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/conv_trim.XXXXXX")
    tail -n "$1" "$CONV_FILE" > "$tmp"
    mv "$tmp" "$CONV_FILE"
}

store_conv_user_turn_count() {
    awk '/"role":"user"/ && ! /"content":\[/{n++} END{print n+0}' "$CONV_FILE" 2>/dev/null
}

store_conv_dp_decision() {
    # $*=stats params — delegates to compact_dp.awk
    util_awk_run -v t="$1" -v total_requests="$2" \
        -v total_compact="$3" -v total_input="$4" \
        -v baseline_e="${5:-${DP_BASELINE_E:-8}}" -v e_fixed="${6:-${DP_E_FIXED:-0}}" -v L_fixed="${7:-${DP_L:-0}}" \
        -v V="${8:-${DP_V:-5000}}" -v p_input="${9:-${DP_P_INPUT:-3.0}}" -v p_cache="${10:-${DP_P_CACHE:-0.30}}" -v p_out="${11:-${DP_P_OUT:-15.0}}" \
        -v S="${12:-${DP_S:-500}}" -v min_keep_ratio="${13:-${DP_MIN_KEEP_RATIO:-0.25}}" -v r="${14:-${DP_R:-0.8}}" -v beta="${15:-${DP_BETA:-0.03}}" \
        -v max_context="${16:-${MAX_CONTEXT_TOKENS:-200000}}" -v quality_penalty="${17:-${DP_QUALITY_PENALTY:-0.2}}" \
        -f "$AWK_DIR/compact_dp.awk" "$CONV_FILE"
}

store_conv_turn_keep() {
    util_awk_run -v ratio="${1:-0.12}" -f "$AWK_DIR/compact_turn_keep.awk" "$CONV_FILE"
}

# — store_stats: stats 格式化 API —
store_stats_format_title() { util_awk_run -v model="$1" ${2:+-v status="$2"} -f "$AWK_DIR/term_title.awk" "$STATS_FILE"; }

# — store_conv: sub-agent 结果发送 —
store_sub_send_result() {
    # $1=session_id $2=status $3=output_file
    util_awk_run -v session_id="$1" -v status="$2" \
        -v stats_file="$STATS_FILE" -v conv_file="$CONV_FILE" \
        -f "$AWK_DIR/json.awk" -f "$AWK_DIR/send_sub_result.awk" \
        > "$3"
}

# — store_plan: plan 文件操作 —
store_plan_confirm() { [[ -n "$PLAN_DRAFT_FILE" && -s "$PLAN_DRAFT_FILE" ]] && { mv "$PLAN_DRAFT_FILE" "$PLAN_FILE"; : > "$PLAN_DRAFT_FILE"; return 0; }; return 1; }

store_plan_clear() { [[ -n "$PLAN_FILE" && -s "$PLAN_FILE" ]] && printf '' > "$PLAN_FILE"; }

store_plan_read() { [[ -n "$PLAN_FILE" && -s "$PLAN_FILE" ]] && printf '%s' "$(<"$PLAN_FILE")"; }

store_plan_draft_read() { [[ -n "$PLAN_DRAFT_FILE" && -s "$PLAN_DRAFT_FILE" ]] && printf '%s' "$(<"$PLAN_DRAFT_FILE")"; }

store_plan_draft_has() { [[ -n "$PLAN_DRAFT_FILE" && -s "$PLAN_DRAFT_FILE" ]]; }

store_summary_get() {
    [[ -n "$CONTEXT_SUMMARY_FILE" && -s "$CONTEXT_SUMMARY_FILE" ]] && printf '%s' "$(<"$CONTEXT_SUMMARY_FILE")"
}

store_event_recent_turn_lines() {
    local turns="${1:-10}" _match _from_line
    [[ -s "${SESSION_EVENT_FILE:-}" ]] || return 0
    _match=$(grep -n '"type":"user_input"' "$SESSION_EVENT_FILE" 2>/dev/null | tail -n "$turns" | head -n 1) || true
    _from_line="${_match%%:*}"
    [[ -n "$_from_line" && "$_from_line" -ge 1 ]] || _from_line=1
    tail -n +"$_from_line" "$SESSION_EVENT_FILE"
}

store_session_list_rows() {
    local dir session_dir name mod preview summary_file ts
    dir="$(store_session_get_dir)"
    [[ -d "$dir" ]] || return 0
    for session_dir in "$dir"/*/; do
        [[ -d "$session_dir" ]] || continue
        name=$(basename "$session_dir")
        ts=$(stat -f "%m" "$session_dir" 2>/dev/null || stat -c "%Y" "$session_dir" 2>/dev/null || echo 0)
        mod=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$session_dir" 2>/dev/null || stat -c "%y" "$session_dir" 2>/dev/null | cut -d. -f1)
        summary_file="${session_dir}/summary.txt"
        preview=""
        [[ -s "$summary_file" ]] && preview=$(grep -m1 -v '^[[:space:]]*$' "$summary_file" 2>/dev/null || true)
        [[ ${#preview} -gt 60 ]] && preview="${preview:0:57}..."
        printf '%s\t%s\t%s\t%s\n' "$ts" "$name" "$mod" "$preview"
    done | sort -t$'\t' -rn -k1 | cut -f2-
}

# llm
llm_stream_curl() {
    exec 9< <(curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 --connect-timeout 5 --speed-limit 1 --speed-time 60 "${HEADER_ARGS[@]}" -d @- "$API_URL" 2>&1)
    curl_pid=$!
    echo "$curl_pid" > "/tmp/agent_curl_pid.$$" 2>/dev/null || true
    util_awk_run -f "$AWK_DIR/http_stream.awk" <&9
    exec 9<&-
    rm -f "/tmp/agent_curl_pid.$$" 2>/dev/null || true
}

llm_call() {
    local messages="$1" max_tokens="${2:-$MAX_TOKENS}" use_thinking="${3:-$THINKING}" body system_prompt
    system_prompt=$(agent_build_prompt)
    # 字段顺序对齐 Go/Rust 的 map 字母序：max_tokens→messages→model→output_config→stream→system→thinking→tools
    local use_think=0; [[ "$use_thinking" != "disabled" ]] && use_think=1
    body="{\"max_tokens\":${max_tokens},\"messages\":${messages},\"model\":\"${MODEL}\""
    (( use_think )) && body+=",\"output_config\":{\"effort\":\"${EFFORT}\"}"
    body+=",\"stream\":true"
    [[ -n "$system_prompt" ]] && body+=",\"system\":\"$(util_json_escape "$system_prompt")\""
    (( use_think )) && body+=",\"thinking\":{\"type\":\"${use_thinking}\"}"
    [[ -n "$TOOL_DEF_JSON" ]] && body+=",\"tools\":${TOOL_DEF_JSON}"
    body+="}"
    $VERBOSE && printf '\033[90m[verbose] Request body (%dKB): %s...\033[0m\n' "$((${#body} / 1024))" "${body:0:200}" >&2
    printf '%s' "$body" | util_body_convert | llm_stream_curl | sse_convert | sse_parse
}

llm_summary_call() {
    local dropped_messages="$1" text="" last_error="" stop_reason="" messages summary_instruction=$'The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. Do NOT think. Just output the summary directly as plain text. Summarize the key information from the messages above into a concise context summary. Update the existing summary snapshot using the messages above. Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:\nReflections:'
    messages=$(store_conv_get_messages "${dropped_messages}"$'\n'"{\"role\":\"user\",\"content\":\"$(util_json_escape "$summary_instruction")\"}")
    while util_read_msg; do
        case "${REPLY_MESSAGE[0]}" in
            TEXT)  text+="${REPLY_MESSAGE[1]}" ;;
            THINKING) ;;
            USAGE) agent_record_usage "compact" compact_request_count >/dev/null ;;
            ERROR) last_error="${REPLY_MESSAGE[1]}" ;;
            STOP)  stop_reason="${REPLY_MESSAGE[1]}" ;;
        esac
    done < <(llm_call "$messages" "" disabled)
    [[ -n "$text" ]] || util_die "Failed to generate context summary: empty text response (stop_reason=${stop_reason:-none}, error=${last_error:-none})"
    printf '%s' "$text"
}
# tool
tool_dispatch() {
    local name="$1"; shift
    case "$name" in
        Read)      tool_read "$@" ;;
        Write)     tool_write "$1" "$2" ;;
        Edit)      tool_edit "$@" ;;
        Bash)      tool_bash "$1" "$2" ;;
        Glob)      tool_glob "$1" "$2" ;;
        Grep)      tool_grep "$1" "$2" "$3" "$4" ;;
        TodoWrite) printf '%s' "$1" ;;
        PlanConfirm) tool_plan_confirm ;;
        PlanClear) tool_plan_clear ;;
        Skill)     tool_skill "$1" ;;
        WebSearch) tool_web_search "$1" ;;
        WebFetch)  tool_web_fetch "$1" ;;
        SubAgent)  tool_sub_agent "$1" "$2" "$3" ;;
        *)
            echo "unknown tool: $name"
            return 1
            ;;
    esac
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
    _TOOL_ARGS=()

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
            _TOOL_ARGS+=("$param_value")
        done
    fi
}


tool_call_summary() {
    local name="$1" label="" key="" i value="" _vi
    shift
    case "$name" in
        PlanConfirm|PlanClear) printf '%s()' "$name"; return 0 ;;
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
        printf '%s()' "$name"
    fi
}

tool_format_result() {
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
    local kind="$1" path="$2" bytes lines offset="$3" limit="$4" _rng=
    [[ -n "$path" && -f "$path" ]] || { printf '%s(%s)' "$kind" "$path"; return 0; }
    bytes=$(wc -c < "$path" 2>/dev/null || echo 0)
    bytes=${bytes//[[:space:]]/}
    lines=$(util_awk_run 'END { print NR }' "$path" 2>/dev/null || echo 0)
    lines=${lines//[[:space:]]/}
    [[ -n "$offset$limit" ]] && _rng=", offset=${offset:-1}, limit=${limit:-$lines}"
    printf '%s(%s) [%s lines, %s bytes%s]' "$kind" "$path" "$lines" "$bytes" "$_rng"
}


# Build and write TOOL_RESULT message: forwards checklist/summary from original TOOL_CALL
tool_emit_result() {
    local tool_id="$1" tool_name="$2" output="$3"
    local i _n=${#REPLY_MESSAGE[@]} _tr_args=("TOOL_RESULT" "$tool_id" "$tool_name" "$output")
    for (( i = 4; i + 1 < _n; i += 2 )); do
        [[ "${REPLY_MESSAGE[i]}" == "checklist" ]] && _tr_args+=("checklist" "${REPLY_MESSAGE[i+1]}")
        [[ "${REPLY_MESSAGE[i]}" == "summary" ]]  && _tr_args+=("summary"  "${REPLY_MESSAGE[i+1]}")
    done
    util_write_msg "${_tr_args[@]}"
}

tool_bash_mode_normalize() {
    local mode="${1:-0467}"
    [[ "$mode" =~ ^[0-7][0-7][0-7][0-7]$ ]] && printf '%s' "$mode" || printf '0000'
}

TOOL_BASH_RE_ROOT_DELETE='(^|[[:space:];|&])rm[[:space:]]+-[^[:space:]]*[rf][^[:space:]]*[[:space:]]+/([[:space:]]|$|[*])'
TOOL_BASH_RE_SYSTEM_PATH='(^|[[:space:]"'\''])(/etc|/usr|/bin|/sbin|/var|/library|/system|/dev)(/|[[:space:]"'\'']|$)'
TOOL_BASH_RE_SENSITIVE_PATH='(^|[[:space:]"'\''])(~|\$home)/(\.ssh|\.gnupg|\.aws|\.docker)(/|[[:space:]"'\'']|$)|(^|[[:space:]"'\''])([^[:space:]"'\'']*\.(env|pem|key)|[^[:space:]"'\'']*(token|credential|secret)[^[:space:]"'\'']*)'
TOOL_BASH_RE_EXTERNAL_PATH='(^|[[:space:]"'\''])(~|\$home)(/|[[:space:]"'\'']|$)|(^|[[:space:]"'\''])/[A-Za-z0-9._-]'
TOOL_BASH_RE_DEVICE_WRITE='(^|[[:space:]])(of=|>|1>|>>|1>>)[[:space:]]*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)([[:space:]]|$)'

tool_bash_add_mode() {
    local scopes="$1" perms="$2"
    TOOL_BASH_REQUIRED_MASK=$(( TOOL_BASH_REQUIRED_MASK | ((scopes & 8 ? perms << 9 : 0)) | ((scopes & 4 ? perms << 6 : 0)) | ((scopes & 2 ? perms << 3 : 0)) | ((scopes & 1 ? perms : 0)) ))
}

tool_bash_add_path() {
    local path="$1" perms="$2" scope=1
    path="${path#\"}"; path="${path%\"}"; path="${path#\'}"; path="${path%\'}"
    path="${path#of=}"; path="${path%;}"; path="${path%,}"; path="${path%)}"
    [[ -z "$path" || "$path" == /tmp || "$path" == /tmp/* || "$path" == /dev/null || "$path" == '&'* ]] && return 0
    # 根目录 / 和 /* 归类为 system（防止绕过 system 权限检查）
    [[ "$path" == "/" || "$path" == "/*" ]] && scope=8
    if [[ "$path" == /dev/tcp* ]]; then
        scope=2
    elif [[ "$path" =~ $TOOL_BASH_RE_SENSITIVE_PATH || "$path" =~ $TOOL_BASH_RE_SYSTEM_PATH ]]; then
        scope=8
    elif [[ -n "$CWD" && ("$path" == "$CWD" || "$path" == "$CWD"/*) ]]; then
        scope=1
    elif [[ "$path" =~ $TOOL_BASH_RE_EXTERNAL_PATH || "$path" == *..* ]]; then
        scope=4
    fi
    tool_bash_add_mode "$scope" "$perms"
}

tool_bash_scan_segment() {
    local seg="$1" tok redir=0 path_bits=4 flags=0
    case "$seg" in
        sudo|sudo\ *|su|su\ *|doas|doas\ *|shutdown*|reboot*|halt*|poweroff*) tool_bash_add_mode 8 1 ;;
        mkfs*|fdisk*|diskutil*|mount\ *|umount\ *) tool_bash_add_mode 8 2 ;;
        *'curl '*|*'wget '*|*'http '*|*'https://'*|*'http://'*|git\ clone*|git\ fetch*|git\ pull*|git\ ls-remote*) tool_bash_add_mode 2 4 ;;
    esac
    case "$seg" in
        git\ push*|*'scp '*|*'curl -d '*|*'curl --data'*|*'curl -f '*|*'curl -t '*) tool_bash_add_mode 2 2 ;;
        *'| bash'*|*'| sh'*|*'eval '*|*'source <('*|*'bash -c $('*|*'sh -c $('*) [[ "$seg" == *'curl '* || "$seg" == *'wget '* || "$seg" == *'http://'* || "$seg" == *'https://'* ]] && tool_bash_add_mode 2 1 ;;
    esac
    [[ "$seg" =~ $TOOL_BASH_RE_ROOT_DELETE || "$seg" =~ $TOOL_BASH_RE_DEVICE_WRITE ]] && tool_bash_add_mode 8 2
    case "$seg" in
        ./*|bash\ *|sh\ *|zsh\ *|python*|node\ *|ruby\ *|perl\ *|npm\ test*|npm\ run*|make*|cargo\ test*|cargo\ build*|go\ test*|git\ commit*|git\ add*|git\ checkout*|git\ merge*|git\ rebase*|git\ stash*|*'function '*|*'()'*|*'{'*|*' if '*|if\ *|*' for '*|for\ *|*' while '*|while\ *|*' case '*|case\ *|*':(){:|:&};:'*) tool_bash_add_mode 1 1 ;;
    esac
    case "$seg" in
        *'>'*|*'tee '*|mkdir\ *|touch\ *|cp\ *|mv\ *|rm\ *|*' rm '*|*'sed -i'*|*' -delete'*|git\ fetch*|git\ pull*|git\ clone*|npm\ install*|pnpm\ install*|yarn\ install*|cargo\ build*|go\ test*|git\ commit*|git\ add*|git\ checkout*|git\ merge*|git\ rebase*|git\ stash*|npm\ test*) path_bits=6; flags=1 ;;
    esac
    local -a _tokens
    read -ra _tokens <<< "$seg"
    for tok in "${_tokens[@]}"; do
        (( redir )) && { tool_bash_add_path "$tok" "$redir"; flags=3; redir=0; continue; }
        case "$tok" in
            '>'|'>>'|'1>'|'1>>') redir=2; continue ;;
            '<>') redir=6; continue ;;
            '2>'*|'2>>'*) continue ;;
            '>'*|'>>'*) tool_bash_add_path "${tok#*>}" 2; flags=3; continue ;;
            '<>'*) tool_bash_add_path "${tok#<>}" 6; flags=3; continue ;;
            /*|./*|../*|~/*) tool_bash_add_path "$tok" "$path_bits"; flags=3 ;;
            *) [[ "$tok" =~ $TOOL_BASH_RE_SENSITIVE_PATH ]] && { tool_bash_add_path "$tok" "$path_bits"; flags=3; } ;;
        esac
    done
    (( flags == 1 )) && [[ "$seg" != *'/tmp/'* ]] && tool_bash_add_mode 1 2
}

tool_bash_scan_script() {
    local script="$1" normalized segment
    script=${script//$'\\\n'/ }
    [[ "$script" == *'/dev/tcp'* ]] && tool_bash_add_mode 2 6
    normalized=${script//&&/$'\n'}
    normalized=${normalized//||/$'\n'}
    normalized=${normalized//;/$'\n'}
    while IFS= read -r segment; do
        segment="${segment#"${segment%%[![:space:]]*}"}"
        segment="${segment%"${segment##*[![:space:]]}"}"
        [[ -z "$segment" ]] && continue
        tool_bash_scan_segment "$segment"
    done <<< "$normalized"
}

tool_classify_bash_required_mode() {
    local cmd="$1" lowered
    CWD=$(printf '%s' "${PWD:-$(pwd)}" | tr '[:upper:]' '[:lower:]')
    TOOL_BASH_REQUIRED_MASK=0
    [[ -z "$cmd" ]] && { TOOL_BASH_REQUIRED_MODE="0000"; printf '%s' "$TOOL_BASH_REQUIRED_MODE"; return 0; }
    lowered=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')
    tool_bash_scan_script "$lowered"
    (( TOOL_BASH_REQUIRED_MASK == 0 )) && tool_bash_add_mode 1 4
    printf -v TOOL_BASH_REQUIRED_MODE '%04o' "$TOOL_BASH_REQUIRED_MASK"
    printf '%s' "$TOOL_BASH_REQUIRED_MODE"
}

tool_bash_mode_allows() {
    local allowed required
    allowed=$(tool_bash_mode_normalize "$1")
    required=$(tool_bash_mode_normalize "$2")
    (( (8#$required & (4095 ^ 8#$allowed)) == 0 ))
}

tool_read() {
    local path="$1" offset="${2:-1}" limit="${3:-0}"
    [[ -z "$path" ]] && { echo "no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "file not found: $path"; return 1; }
    [[ ! -r "$path" ]] && { echo "permission denied: $path"; return 1; }
    if (( limit > 0 )); then
        sed -n "${offset},$((offset + limit - 1))p" "$path"
    else
        sed -n "${offset},\$p" "$path"
    fi
}

tool_write() {
    local path="$1" content="$2"
    [[ -z "$path" ]] && { echo "no path provided"; return 1; }
    mkdir -p "$(dirname "$path")" 2>/dev/null
    printf '%s' "$content" > "$path"
    echo "OK: wrote $(wc -c < "$path" 2>/dev/null || echo '?') bytes to $path"
}

tool_edit() {
    local path="$1" old_string="$2" new_string="$3" tmp diff_output added removed label="${1#/}"
    [[ -z "$path" ]] && { echo "no path provided"; return 1; }
    [[ ! -f "$path" ]] && { echo "file not found: $path"; return 1; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/edit.XXXXXX")
    if ! printf '{"path":"%s","old_string":"%s","new_string":"%s"}' \
            "$(util_json_escape "$path")" "$(util_json_escape "$old_string")" "$(util_json_escape "$new_string")" \
         | util_awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/edit_file.awk" > "$tmp" 2>&1; then
        cat "$tmp"; rm -f "$tmp"; return 1
    fi
    (( $(wc -c < "$tmp") > 0 )) || { echo "edit produced empty result"; rm -f "$tmp"; return 1; }
    diff_output=$(diff -u --color=always --label "a/$label" --label "b/$label" "$path" "$tmp" 2>&1) || true
    [[ "$diff_output" == *"unsupported --color"* || "$diff_output" == *"unrecognized option '--color'"* ]] \
        && diff_output=$(diff -u --label "a/$label" --label "b/$label" "$path" "$tmp" 2>&1) || true
    added=$(printf '%s\n' "$diff_output" | grep -cE $'^(\033\[[0-9;]*m)*\+[^+]') || added=0
    removed=$(printf '%s\n' "$diff_output" | grep -cE $'^(\033\[[0-9;]*m)*-[^-]') || removed=0
    cat "$tmp" > "$path"
    rm -f "$tmp"
    printf 'Success: Edit(%s) [+%s -%s lines]\n' "$path" "$added" "$removed"
    [[ -n "$diff_output" ]] && printf '%s\n' "$diff_output"
}

tool_bash() {
    local cmd="$1" timeout_secs="${2:-$TOOL_TIMEOUT_SECS}" allowed_mode required_mode tool_rc tmpout
    [[ -z "$cmd" ]] && { echo "no command provided"; return 1; }
    allowed_mode=$(tool_bash_mode_normalize "${BASH_AGENT_BASH_MODE:-0467}")
    tool_classify_bash_required_mode "$cmd" >/dev/null
    required_mode="${TOOL_BASH_REQUIRED_MODE:-0000}"
    if ! tool_bash_mode_allows "$allowed_mode" "$required_mode"; then
        echo "command blocked by bash safety policy (required=$required_mode allowed=$allowed_mode; mode=system/external/network/workspace bits=4:read,2:write,1:execute)"
        return 1
    fi
    tmpout=$(mktemp)
    if [[ -n "$timeout_secs" && "$timeout_secs" =~ ^[0-9]+$ && "$timeout_secs" -gt 0 ]]; then
        util_run_timeout "$timeout_secs" bash -lc "$cmd" > "$tmpout" 2>&1
        tool_rc=$?
        if (( tool_rc == 124 )); then
            printf '\n[... command timed out after %s seconds ...]' "$timeout_secs" >> "$tmpout"
        fi
    else
        bash -lc "$cmd" > "$tmpout" 2>&1
        tool_rc=$?
    fi
    util_awk_run -f "$AWK_DIR/sanitize_utf8.awk" "$tmpout"
    rm -f "$tmpout"
    return "$tool_rc"
}

tool_glob() {
    local pattern="$1" path="$2"
    [[ -z "$pattern" ]] && { echo "no pattern provided"; return 1; }
    [[ -n "$path" ]] || path="."
    [[ -d "$path" ]] || { echo "directory not found: $path"; return 1; }
    command -v rg >/dev/null 2>&1 || { echo "rg is required for glob"; return 1; }
    rg --files "$path" -g "$pattern" 2>/dev/null || true
}

tool_grep() {
    local pattern="$1" path="$2" glob="$3" context="$4" args=(-n --color never --heading)
    [[ -z "$pattern" ]] && { echo "no pattern provided"; return 1; }
    [[ -n "$path" ]] || path="."
    [[ -e "$path" ]] || { echo "path not found: $path"; return 1; }
    command -v rg >/dev/null 2>&1 || { echo "rg is required for grep"; return 1; }
    [[ -n "$context" && "$context" =~ ^[0-9]+$ ]] && args+=(-C "$context")
    [[ -n "$glob" ]] && args+=(--glob "$glob")
    args+=("--" "$pattern" "$path")
    rg "${args[@]}" 2>/dev/null || true
}

tool_skill() {
    local skill_name="$1" skill_content=""
    skill_name="${skill_name#"${skill_name%%[![:space:]]*}"}"
    skill_name="${skill_name%"${skill_name##*[![:space:]]}"}"
    [[ -n "$skill_name" ]] || { echo "no skill name provided"; return 1; }
    skill_content=$(util_load_skill_content "$skill_name") || { echo "skill not found: $skill_name"; return 1; }
    printf 'Skill: %s\n%s' "$skill_name" "$skill_content"
}

tool_plan_confirm() {
    # 先 compact 再 mv：compact 复用旧缓存前缀，mv 后才触发缓存失效——总共一次冷启动
    if store_plan_draft_has; then
        agent_compact_context plan_confirm
        store_plan_confirm
        printf 'Plan confirmed and locked in.'
    else
        printf 'no plan draft found to confirm.'
        return 1
    fi
}

tool_plan_clear() {
    agent_compact_context plan_clear
    store_plan_clear
    printf 'Plan cleared.'
}

tool_web_search() { curl -sS --connect-timeout 10 --max-time 30 -G --data-urlencode "q=$1" -H "Authorization: Bearer ${JINA_API_KEY:-}" -H "X-Respond-With: no-content" "https://s.jina.ai/" 2>&1; }

tool_web_fetch() { curl -sS --connect-timeout 10 --max-time 60 -H "Authorization: Bearer ${JINA_API_KEY:-}" "https://r.jina.ai/$1" 2>&1; }

# 启动异步子 agent：后台执行 agent_loop，完成后通过 INPUT_FIFO 发回 AGENT_RESULT
# 消息格式：AGENT_RESULT <session_id> <status:ok|failed> <result_text> <in> <out> <cr> <cc> <reqs>
tool_sub_agent() {
    local prompt="$1" description="${2:-}" fork="${3:-}" sub_session_id="sub_$(util_new_session_id)"

    [[ -z "$prompt" ]] && { echo "no prompt provided for sub-agent"; return 1; }

    store_event_append "{\"type\":\"sub_agent_start\",\"session_id\":\"$(util_json_escape "$sub_session_id")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"prompt\":\"$(util_json_escape "$prompt")\",\"description\":\"$(util_json_escape "$description")\",\"fork\":$fork}"

    (
        # fork mode needs to copy conversation and summary to new session dir
        if [[ "$fork" == "true" ]]; then
            store_session_fork "$(store_session_get_dir)/${SESSION_ID}" "$(store_session_get_dir)/${sub_session_id}"
        fi
        export SESSION_ID="$sub_session_id"
        export INTERACTIVE=false
        local _parent_input_fifo="$INPUT_FIFO"
        store_session_init
        util_load_tool_defs
        local _done=false _status="failed"
        trap '[[ "$_done" == true ]] || store_sub_send_result "$sub_session_id" "$_status" "$_parent_input_fifo"; rm -f "$INPUT_FIFO"' EXIT
        # Silence the child shell completely; close all inherited FDs
        exec </dev/null >/dev/null 2>&1
        exec 3<&- 2>/dev/null; exec 4<&- 2>/dev/null
        exec 8<&- 2>/dev/null; exec 5<&- 2>/dev/null
        agent_loop "$prompt" && _status="ok"
        store_sub_send_result "$sub_session_id" "$_status" "$_parent_input_fifo"
        _done=true
    ) &

    printf 'Sub-agent started: session_id=%s, pid=%s' "$sub_session_id" "$!"
}

# display
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

display_sub_agent_result() {
    local session_id="$1" status="$2" _in="$3" _out="$4" _thinking="$5" _text="$6"
    if [[ "$INTERACTIVE" == true && "$DISPLAY_LAST_CHAR" == $'\n' ]]; then
        env printf '\r\033[K'
    fi
    display_ensure_newline
    if [[ "$status" == "ok" ]]; then
        printf '\033[35m[sub-agent %s] completed (in=%s, out=%s)\033[0m\n' "$session_id" "$_in" "$_out"
    else
        printf '\033[31m[sub-agent %s] failed\033[0m\n' "$session_id"
    fi
    [[ -n "$_thinking" ]] && printf '\033[90m%s%s\033[0m\n' "${_thinking:0:120}" "$([[ ${#_thinking} -gt 120 ]] && printf '…')"
    [[ -n "$_text" ]] && printf '%s%s\n' "${_text:0:120}" "$([[ ${#_text} -gt 120 ]] && printf '…')"
    DISPLAY_LAST_CHAR=$'\n'
}

# Convert REPLY_MESSAGE to a stream event JSON string. Prints JSON to stdout;
# returns 1 if type has no event representation.
# Render a single RESP message from REPLY_MESSAGE in human-readable mode.
# stream-json output is emitted by store_event_append teeing the event line.
display_message() {
    local _type="${REPLY_MESSAGE[0]}" _tc_kv=() i _n _tc_summary="" _tr_name _tr_text="" _um_text
    case "$_type" in
        TEXT)
            if [[ "$INTERACTIVE" == true && "$DISPLAY_LAST_CHAR" == $'\n' ]]; then
                env printf '\r\033[K'
                DISPLAY_LAST_CHAR=''
            fi
            # Insert newline when transitioning from thinking to text
            if [[ "$PREV_WAS_THINKING" == true && "$DISPLAY_LAST_CHAR" != $'\n' ]]; then
                printf '\n'
                DISPLAY_LAST_CHAR=$'\n'
            fi
            PREV_WAS_THINKING=false
            [[ -n "${REPLY_MESSAGE[1]}" ]] && display_human_text "${REPLY_MESSAGE[1]}"
            ;;
        THINKING)
            if [[ "$INTERACTIVE" == true && "$DISPLAY_LAST_CHAR" == $'\n' ]]; then
                env printf '\r\033[K'
                DISPLAY_LAST_CHAR=''
            fi
            [[ -n "${REPLY_MESSAGE[1]}" ]] && printf '\033[90m%s\033[0m' "${REPLY_MESSAGE[1]}"
            if [[ "${REPLY_MESSAGE[1]}" == *$'\n' ]]; then
                DISPLAY_LAST_CHAR=$'\n'
            else
                DISPLAY_LAST_CHAR="${REPLY_MESSAGE[1]: -1}"
            fi
            PREV_WAS_THINKING=true
            ;;
        TOOL_CALL)
            if [[ "$INTERACTIVE" == true && "$DISPLAY_LAST_CHAR" == $'\n' ]]; then
                env printf '\r\033[K'
                DISPLAY_LAST_CHAR=''
            fi
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
        SUB_AGENT_RESULT)
            display_sub_agent_result "${REPLY_MESSAGE[1]}" "${REPLY_MESSAGE[2]}" "${REPLY_MESSAGE[3]}" "${REPLY_MESSAGE[4]}" "${REPLY_MESSAGE[5]}" "${REPLY_MESSAGE[6]}"
            ;;
        IMAGE_DESCRIBE)
            [[ -n "${REPLY_MESSAGE[2]}" ]] && { display_human_text "$(printf '\033[36m📸 %s: %s\033[0m\n' "${REPLY_MESSAGE[1]}" "${REPLY_MESSAGE[2]}")"; DISPLAY_LAST_CHAR=$'\n'; }
            ;;
        USER_MESSAGE)
            display_ensure_newline
            _um_text="${REPLY_MESSAGE[1]%%$'\n'*}"
            (( ${#_um_text} > 80 )) && _um_text="${_um_text:0:77}..."
            printf '\033[32m> %s\033[0m\n' "$_um_text"
            DISPLAY_LAST_CHAR=$'\n'
            ;;
        STOP)
            if [[ "${REPLY_MESSAGE[1]-}" == "interrupted" ]]; then
                display_ensure_newline
                printf '\033[36mInterrupted.\033[0m\n'
                DISPLAY_LAST_CHAR=$'\n'
            else
                display_ensure_newline
            fi
            ;;
        CONTEXT_UPDATE)
            display_ensure_newline; printf '\033[36mContext compacted (%s).\033[0m\n' "${REPLY_MESSAGE[2]}"; DISPLAY_LAST_CHAR=$'\n'
            ;;
        ERROR) display_ensure_newline; printf '\033[31mError: %s\033[0m\n' "${REPLY_MESSAGE[1]}" >&2 ;;
        *)     return 0 ;;
    esac
}

display_term_title() { store_stats_format_title "$MODEL" "${1:-}"; }

# 子进程渲染：从管道读取 RESP 消息，渲染到 stdout（终端）
display_stream() { while util_read_msg; do display_message; done; }

agent_compact_context() {
    local trigger=${1:-auto} total_lines keep_lines drop tmp_dropped dropped_messages summary_response

    # 始终先算 DP 决策（经济最优）— 直接调用 store 层
    keep_lines=$(store_conv_dp_decision \
        "$(store_stats_get current_turn_count)" "$(store_stats_get agent_request_count)" \
        "$(store_stats_get compact_request_count)" "$(store_stats_get total_input_tokens)") || true
    [[ -n "$keep_lines" ]] || keep_lines=0
    total_lines=$(store_conv_line_count)
    # DP 返回 0（不值得）或 ≥ total_lines（全保留）→ 都算"不压缩"，进入 fallback
    if (( keep_lines == 0 )) || (( keep_lines >= total_lines && total_lines > 0 )); then
        local ct=$(store_stats_get current_context_tokens)
        if [[ "$trigger" == "plan_clear" || "$trigger" == "plan_confirm" ]] || (( ct > 0 && ct > MAX_CONTEXT_TOKENS * 90 / 100 )); then
            keep_lines=$(store_conv_turn_keep "${DP_MIN_KEEP_RATIO:-0.25}")
        else
            return 1
        fi
    fi

    # 统一 guard：keep >= total 或 keep==0 时只有 plan_clear/plan_confirm 继续
    (( keep_lines > 0 && keep_lines < total_lines )) || [[ "$trigger" == "plan_clear" || "$trigger" == "plan_confirm" ]] || return 1
    drop=$(( total_lines - keep_lines ))
    tmp_dropped=$(mktemp "${TMPDIR:-/tmp}/dropped.XXXXXX")
    store_conv_head_to "$drop" "$tmp_dropped"
    dropped_messages=$(<"$tmp_dropped")

    summary_response=$(llm_summary_call "$dropped_messages")
    store_summary_set "$summary_response"
    if (( keep_lines < total_lines )); then
        store_conv_trim_tail "$keep_lines"
    fi
    rm -f "$tmp_dropped"
    # 注意：不再重置 current_turn_count — 它应始终保持 session 累计计数
    return 0
}


# agent
agent_build_prompt() {
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

    instruction_files=$(util_build_instructions_section)
    skill_index=$(util_build_skill_index)
    selected_skills=$(util_build_skills_section)
    plan=$(store_plan_read)
    stable_context=$(store_summary_get)

    util_append_section output "agent-identity" "$agent_identity"
    util_append_section output "environment" "$environment"
    util_append_section output "rules" "$core_rules"
    util_append_section output "using-your-tools" "$tool_guidance"
    util_append_section output "sub-agent-guidance" "$sub_agent_guidance"
    util_append_section output "todo-guidance" "$todo_guidance"
    util_append_section output "plan-lifecycle-guidance" "$plan_lifecycle_guidance"
    util_append_section output "instruction-files" "$instruction_files"
    util_append_section output "skill-index" "$skill_index"
    util_append_section output "selected-skills" "$selected_skills"
    util_append_section output "current-plan" "$plan" "${PLAN_FILE:-}"
    util_append_section output "context-snapshot" "$stable_context"
    util_append_section output "output-language" "$output_language_reaffirm"

    printf '%s' "${output%$'\n'}"
}

agent_record_usage() {
    # Args: kind counter_key [write_event=true]
    # Reads REPLY_MESSAGE[1..4], updates stats, optionally logs event. Returns context token count (input+output+cache_read+cache_creation).
    local kind="$1" counter_key="$2" write_event="${3:-true}" _event \
          _in="${REPLY_MESSAGE[1]:-0}" _out="${REPLY_MESSAGE[2]:-0}" _cr="${REPLY_MESSAGE[3]:-0}" _cc="${REPLY_MESSAGE[4]:-0}"
    if [[ "$write_event" == "true" ]]; then
        _event=$(printf '{"type":"usage","input_tokens":%s,"output_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"kind":"%s"}' "$_in" "$_out" "$_cr" "$_cc" "$kind")
        store_event_append "$_event"
    fi
    store_stats_update ${counter_key}=+1 total_input_tokens=+${_in} total_output_tokens=+${_out} total_cache_read_tokens=+${_cr} total_cache_creation_tokens=+${_cc}
    echo $(( _in + _out + _cr + _cc ))
}

agent_handle_sub_result() {
    local silent="${1:-false}"
    # REPLY_MESSAGE: AGENT_RESULT <session_id> <status> <thinking> <text> <in> <out> <cr> <cc> <reqs>
    local session_id="${REPLY_MESSAGE[1]}" status="${REPLY_MESSAGE[2]}"
    local _thinking="${REPLY_MESSAGE[3]}" _text="${REPLY_MESSAGE[4]}"
    local _in="${REPLY_MESSAGE[5]:-0}" _out="${REPLY_MESSAGE[6]:-0}"
    local _cr="${REPLY_MESSAGE[7]:-0}" _cc="${REPLY_MESSAGE[8]:-0}"
    local _reqs="${REPLY_MESSAGE[9]:-0}"
    # 记录 usage（带 kind=sub_agent, sub_session_id）
    store_event_append "{\"type\":\"usage\",\"input_tokens\":$_in,\"output_tokens\":$_out,\"cache_read_input_tokens\":$_cr,\"cache_creation_input_tokens\":$_cc,\"kind\":\"sub_agent\",\"sub_session_id\":\"$(util_json_escape "$session_id")\"}"
    store_stats_update total_input_tokens=+$_in total_output_tokens=+$_out total_cache_read_tokens=+$_cr total_cache_creation_tokens=+$_cc sub_agent_request_count=+1 agent_request_count=+$_reqs
    # 记录 sub_agent_result 事件，供 replay 和 stream-json 复现子 agent 回显
    store_event_append "{\"type\":\"sub_agent_result\",\"session_id\":\"$(util_json_escape "$session_id")\",\"status\":\"$status\",\"input_tokens\":$_in,\"output_tokens\":$_out,\"thinking\":\"$(util_json_escape "$_thinking")\",\"text\":\"$(util_json_escape "$_text")\"}"
    # 记录 sub_agent_end 事件
    store_event_append "{\"type\":\"sub_agent_end\",\"session_id\":\"$(util_json_escape "$session_id")\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"$status\"}"
    active_sub_count=$(( active_sub_count - 1 ))
    [[ "$silent" == true ]] && return 0
    # 展示结果摘要——通过 fd 7 交给 display_stream，不直接写 stdout（避免和子进程争终端）
    util_is_stream_json || ( util_write_msg "SUB_AGENT_RESULT" "$session_id" "$status" "$_in" "$_out" "$_thinking" "$_text" ) >&4 2>/dev/null || true
    agent_run_loop "[sub-agent $session_id] $status (in=$_in, out=$_out)"$'\n'"Thinking: $_thinking"$'\n'"Text: $_text" sub_agent_result
}

# 调用 agent_loop 并处理交互式终端提示符

agent_run_loop() {
    local turn_kind="${2:-user_input}"
    agent_loop "$1" "$turn_kind"
    display_term_title "idle"
    if [[ "$INTERACTIVE" == true ]]; then
        printf '\033[32m>\033[0m '
    fi
}


# 调用 agent_loop 并处理交互式终端提示符

# 统一清理所有管道 FD（按源→宿的级联顺序关闭）
cleanup_all_pipes() {
    exec 4>&- 2>/dev/null   # display_stream 管道
    exec 5>&- 2>/dev/null   # INPUT_FIFO 写入端
    exec 3<&- 2>/dev/null   # INPUT_FIFO 读取端
    exec 7<&- 2>/dev/null   # agent_loop_stream 管道 (agent_loop)
    exec 8<&- 2>/dev/null   # llm_call 管道 (agent_loop_stream)
}

agent_main_loop() {
    until exec 3< "$INPUT_FIFO"; do sleep 0.01; done 2>/dev/null
    exec 5> "$INPUT_FIFO"  # keep write end open to prevent premature EOF
    exec 4> >(display_stream)
    local display_pid=$! active_sub_count=0
    while util_read_msg <&3; do
        case "${REPLY_MESSAGE[0]}" in
            SESSION_END)
                break
                ;;
            USER_INPUT)
                agent_run_loop "${REPLY_MESSAGE[2]:-${REPLY_MESSAGE[1]:-}}"
                ;;
            AGENT_RESULT)
                if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                    agent_handle_sub_result true
                else
                    agent_handle_sub_result
                fi
                ;;
        esac
        [[ "$INTERACTIVE" != true ]] && (( active_sub_count == 0 )) && break
    done
    exec 4>&-
    wait "$display_pid" 2>/dev/null || true
    cleanup_all_pipes
    rm -f "$INPUT_FIFO"
}

agent_loop_stream() {
    local user_input="$1" turn=0
    # Trap SIGINT: close pipe FD to unblock read
    trap 'INTERRUPT_REQUESTED=true; cleanup_all_pipes' INT
    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true
        # Compact before each LLM call: uses ctx_tokens from previous call's USAGE
        agent_compact_context auto && util_write_msg "CONTEXT_UPDATE" "compact" "auto"
        local text="" thinking="" tool_calls="" stop="" loop_error="" tool_conv_results="" _ctx_tokens=""
        [[ "$VERBOSE" == true ]] && printf '[debug] messages: %.500s...\n' "$(store_conv_get_messages)" >&2
        exec 8< <(llm_call "$(store_conv_get_messages)")
        while util_read_msg <&8; do
            if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                stop="interrupted"
                break
            fi
            [[ "$VERBOSE" == true ]] && printf '[debug] type=<%s> nfields=%d\n' "${REPLY_MESSAGE[0]}" "${#REPLY_MESSAGE[@]}" >&2
            util_write_msg "${REPLY_MESSAGE[@]}" # Forward to display
            case "${REPLY_MESSAGE[0]}" in
                RETRY)    text="" thinking="" tool_calls="" tool_conv_results="" _ctx_tokens="" ;;
                TEXT)     text+="${REPLY_MESSAGE[1]}" ;;
                THINKING) thinking+="${REPLY_MESSAGE[1]}" ;;
                TOOL_CALL)
                    local cur_tool_name="${REPLY_MESSAGE[1]}" cur_tool_id="${REPLY_MESSAGE[2]}" input="${REPLY_MESSAGE[3]}" output result_for_conv
                    tool_calls+="${cur_tool_name}"$'\t'"${cur_tool_id}"$'\t'"${input}"$'\n'
                    tool_args_from_msg "$cur_tool_name"
                    output=$(tool_dispatch "$cur_tool_name" ${_TOOL_ARGS[@]+"${_TOOL_ARGS[@]}"} 2>&1) || {
                        output="Error: $output"
                    }
                    output=$(tool_format_result "$output")
                    result_for_conv="$output"
                    case "$cur_tool_name" in
                        Edit)       result_for_conv="$(printf '%s' "$output" | sed -n '1p')" ;;
                        Read|Write) output="$(tool_file_summary "$cur_tool_name" "${_TOOL_ARGS[0]:-}" "${_TOOL_ARGS[1]:-}" "${_TOOL_ARGS[2]:-}")"$'\n'"$output" ;;
                    esac
                    tool_conv_results+="${cur_tool_id}"$'\t'"$(util_json_escape "$result_for_conv")"$'\n'
                    tool_emit_result "$cur_tool_id" "$cur_tool_name" "$output"
                    ;;
                STOP)  stop="${REPLY_MESSAGE[1]}" ;;
                ERROR) loop_error="${REPLY_MESSAGE[1]}"; stop="error"; break ;;
                USAGE) _ctx_tokens=$(agent_record_usage "agent" agent_request_count false) ;;
            esac
        done
        exec 8<&-
        [[ "$INTERRUPT_REQUESTED" == true ]] && { util_write_msg "STOP" "interrupted"; break; }
        # Fatal stop reasons exit immediately
        case "$stop" in
            error|max_tokens|length)
                [[ "$stop" != "error" ]] && { util_write_msg "ERROR" "Response truncated (max_tokens reached)"; }
                return 1
                ;;
        esac
        # Tools already executed inline; persist unless interrupted
        if [[ "$INTERRUPT_REQUESTED" != true ]]; then
            store_conv_add_assistant "$text" "$thinking" "$tool_calls"
            if [[ -n "$tool_conv_results" ]]; then
                store_conv_add_tool_results "$tool_conv_results"
            fi
            # Update context tokens from USAGE (used by next turn's compact check)
            if [[ -n "$_ctx_tokens" && "$_ctx_tokens" -gt 0 ]]; then
                store_stats_update current_context_tokens=${_ctx_tokens}
            fi
            # tool_use/tool_calls → loop continues; anything else → break
            [[ "$stop" == "tool_use" || "$stop" == "tool_calls" ]] || { util_write_msg "STOP" "$stop"; break; }
        else
            util_write_msg "STOP" "interrupted"
            break
        fi
    done
    if (( turn >= MAX_TURNS )); then
        util_write_msg "ERROR" "Max turns ($MAX_TURNS) reached"
    fi
}

agent_loop() {
    local user_input="$1" turn_kind="${2:-user_input}" _se="" _type="" _reason="" had_error=false
    INTERRUPT_REQUESTED=false
    [[ "$turn_kind" == user_input ]] && store_event_append "{\"type\":\"user_input\",\"content\":\"$(util_json_escape "$user_input")\"}"
    # 展开图片占位符：events 记录原始文本，conversation/LLM 使用展开后的长文本
    if [[ "$turn_kind" == user_input && "$user_input" == *"[Image #"* ]]; then
        local _rest="$user_input" _images="" _paths="" desc
        while [[ "$_rest" =~ \[Image\ #([0-9]+)\] ]]; do
            [[ -f "$(store_session_image_dir)/${BASH_REMATCH[1]}.png" ]] && _paths+=" $(store_session_image_dir)/${BASH_REMATCH[1]}.png"
            _images+="${_images:+ }${BASH_REMATCH[0]}"
            _rest="${_rest#*"${BASH_REMATCH[0]}"}"
        done
        desc=$(agent_image_describe $_paths)
        store_event_append "{\"type\":\"image_describe\",\"images\":\"$_images\",\"content\":\"$(util_json_escape "$desc")\"}"
        util_write_msg "IMAGE_DESCRIBE" "$_images" "$desc" >&4 2>/dev/null || true
        user_input+=$'\n\n<attached-images>\n'"$desc"$'\n</attached-images>'
    fi
    store_conv_add_user "$user_input"
    store_stats_update current_turn_count=+1
    # Trap SIGINT (Ctrl+C): close pipe FD to unblock read, kill curl
    trap 'INTERRUPT_REQUESTED=true; kill "$(cat "/tmp/agent_curl_pid.$$" 2>/dev/null)" 2>/dev/null; exec 7<&- 2>/dev/null' INT
    # Open the process substitution
    exec 7< <(agent_loop_stream "$user_input")
    while util_read_msg <&7; do
        _type="${REPLY_MESSAGE[0]-}"
        _reason="${REPLY_MESSAGE[1]-}"
        [[ "$_type" == "TOOL_CALL" && "$_reason" == "SubAgent" ]] && active_sub_count=$(( active_sub_count + 1 ))
        _se=$(util_msg_to_stream) && [[ -n "$_se" ]] && store_event_append "$_se"
        util_is_stream_json || ( util_write_msg "${REPLY_MESSAGE[@]}" ) >&4 2>/dev/null || true
        if [[ "$_type" == "ERROR" ]]; then
            had_error=true
            break
        fi
        [[ "$_type" == "STOP" && "$_reason" == "interrupted" ]] && break
    done
    exec 7<&-
    rm -f "/tmp/agent_curl_pid.$$" 2>/dev/null || true
    $had_error && return 1
    return 0
}

# cli
usage() {
    cat <<'EOF'
Usage: agent.sh [options] [prompt]

Options:
  -p, --provider PROV     LLM provider: claude | openai (default: claude)
  -m, --model MODEL       Model name (default: claude-sonnet-4-20250514)
  --max-tokens N          Max output tokens (default: 16384)
  --tool-timeout N        Tool execution timeout in seconds (default: 600)
  --skill NAME            Load a skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)
  --max-turns N           Max agent turns (default: 1000)
  --max-context N         Max context tokens before compact (default: 200000; supports k/m)
  --api-key KEY           API key (default from env)
  --base-url URL          Override API base URL (for Ollama, DeepSeek, etc.)
  --effort LEVEL          Thinking effort: low|medium|high|xhigh|max (default: high)
  --thinking MODE         Thinking mode: adaptive|enabled|disabled (default: adaptive)
  --output-format FMT     Output format: human | stream-json
  --print                 Alias for --output-format stream-json
  --session [NAME]        Use named session (persist conversation)
  --continue              Continue most recent session
  --fork                  When resuming, create a new forked session instead of reusing the source (use with --session <id> or --continue)
  --list-sessions         List all saved sessions
  -v, --verbose           Verbose mode
  -i, --interactive       Interactive mode (REPL)
  -h, --help              Show this help

Environment:
  ANTHROPIC_API_KEY       API key for Claude
  OPENAI_API_KEY          API key for OpenAI
  DEEPSEEK_API_KEY        API key for DeepSeek (auto-detected, uses Anthropic-compatible endpoint)
  ANTHROPIC_BASE_URL      Claude API base URL
  OPENAI_BASE_URL         OpenAI API base URL
  BASH_AGENT_HOME         Override base directory for session storage (default: $HOME)
  BASH_AGENT_BASH_MODE    Bash tool permissions as 4 octal rwx digits: system/external/network/workspace (default: 0467)
  EFFORT                  Default thinking effort (default: high)
  THINKING                Default thinking mode (default: adaptive)
  MODEL                   Default model name

Examples:
  ./agent.sh "Read /etc/hostname and tell me what it says"
  ./agent.sh -m claude-sonnet-4-20250514 "List files in /tmp"
  ./agent.sh --session code-review "Analyze this code"
  ./agent.sh --skill shell-safety "List files in /tmp"
  ./agent.sh --continue "What did we discuss?"
  ./agent.sh --fork --continue "Branch off the last session"
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
            --max-tokens)    MAX_TOKENS=$(util_parse_size "$2") || { util_die "Invalid --max-tokens: $2"; }; shift 2 ;;
            --tool-timeout)  TOOL_TIMEOUT_SECS="$2"; shift 2 ;;
            --skill)         SKILL_NAMES+=("$2"); shift 2 ;;
            --max-turns)     MAX_TURNS="$2"; shift 2 ;;
            --max-context)
                MAX_CONTEXT_TOKENS=$(util_parse_size "$2") || util_die "Invalid --max-context: $2"
                shift 2
                ;;
            --api-key)       API_KEY="$2"; shift 2 ;;
            --base-url)      BASE_URL="$2"; shift 2 ;;
            --effort)        EFFORT="$2"; shift 2 ;;
            --thinking)      THINKING="$2"; shift 2 ;;
            --output-format)  OUTPUT_FORMAT="$2"; shift 2 ;;
            --print)         OUTPUT_FORMAT="stream-json"; shift ;;
            --session)
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    SESSION_ID="$2"; shift 2
                else
                    SESSION_ID="$(util_new_session_id)"
                    shift
                fi
                ;;
            --continue)
                if [[ -z "${SESSION_ID:-}" ]]; then
                    store_session_resolve_continue
                fi
                shift
                ;;
            --fork)
                FORK=true
                [[ -z "${SESSION_ID:-}" ]] && store_session_resolve_continue
                shift
                ;;
            --list-sessions)
                list_sessions
                exit 0
                ;;
            -v|--verbose)    VERBOSE=true; shift ;;
            -i|--interactive) INTERACTIVE=true; shift ;;
            -h|--help)       usage ;;
            -*)              util_die "Unknown option: $1" ;;
            *)               USER_INPUT="$1"; shift ;;
        esac
    done

    case "$OUTPUT_FORMAT" in
        human|stream-json) ;;
        *) util_die "Unknown output format: $OUTPUT_FORMAT (use human|stream-json)" ;;
    esac
}

list_sessions() {
    local found=false name mod preview
    if [[ ! -d "$(store_session_get_dir)" ]]; then
        echo "No sessions found."
        return
    fi
    printf "%-40s %-16s %s\n" "NAME" "MODIFIED" "PREVIEW"
    while IFS=$'\t' read -r name mod preview; do
        [[ -n "$name" ]] || continue
        found=true
        printf "%-40s %-16s %s\n" "$name" "$mod" "$preview"
    done < <(store_session_list_rows)
    $found || echo "No sessions found."
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
            util_body_convert() { cat; }
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
            util_body_convert() { util_awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_body.awk"; }
            sse_convert()  { util_awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk"; }
            ;;
        *)
            util_die "Unknown provider: $PROVIDER (use claude|openai)"
            ;;
    esac

    # Auto-detect DeepSeek API key: if DEEPSEEK_API_KEY is set, use DeepSeek's Anthropic endpoint
    if [[ -z "$API_KEY" && -z "$BASE_URL" && -n "${DEEPSEEK_API_KEY:-}" ]]; then
        PROVIDER="claude"
        API_KEY="$DEEPSEEK_API_KEY"
        BASE_URL="https://api.deepseek.com/anthropic"
        : "${MODEL:=deepseek-v4-flash}"
    fi

    if [[ -z "$API_KEY" && -z "$BASE_URL" ]]; then
        case "$PROVIDER" in
            claude) util_die "No API key. Set ANTHROPIC_API_KEY or use --api-key" ;;
            openai) util_die "No API key. Set OPENAI_API_KEY or use --api-key" ;;
        esac
    fi

    # Unified SSE parser — same for all providers (sse_convert normalizes to Claude format)
    sse_parse() { util_awk_run -v verbose="${VERBOSE:-false}" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk"; }
}

interactive_mode() {
    local history_file="${BASH_AGENT_HOME:-${HOME}}/.bash-agent/history" line
    mkdir -p "$(dirname "$history_file")" 2>/dev/null || true
    touch "$history_file" 2>/dev/null || true
    history -r "$history_file" 2>/dev/null || true
    printf '\033[36mbash-agent interactive mode (type '\''exit'\'' or Ctrl+D to quit)\033[0m\n'
    # Replay recent 10 turns for resumed sessions (turn-aware replay)
    if store_event_recent_turn_lines 10 \
        | util_awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/event_replay.awk" \
        | ( display_stream )
    then
        printf '\n'
        DISPLAY_LAST_CHAR=$'\n'
    fi
    display_term_title "idle"
    {
        exec 5> "$INPUT_FIFO"
        set -o emacs 2>/dev/null || true
        bind -x '"\C-v": agent_image_insert_placeholder_readline' 2>/dev/null || true
        while true; do
            stty echo 2>/dev/null || true
            if ! IFS= read -e -r -p $'\033[32m>\033[0m ' line < /dev/tty; then
                util_write_msg "SESSION_END" "0" >&5
                break
            fi
            [[ "$line" == "exit" || "$line" == "quit" ]] && {
                util_write_msg "SESSION_END" "0" >&5
                break
            }
            [[ -z "$line" ]] && continue
            printf '%s\n' "$line" >> "$history_file"
            util_write_msg "USER_INPUT" "0" "$line" >&5
        done
        exec 5>&-
    } &
    local _stdin_pid=$!

    agent_main_loop
    trap - INT
    # 清理子进程（包括 stdin_reader 和所有后台任务）
    kill -INT -- "-$_stdin_pid" 2>/dev/null || kill -INT "$_stdin_pid" 2>/dev/null || true
    wait "$_stdin_pid" 2>/dev/null || true

    printf '\033[36mGoodbye!\033[0m\n\033[90mResume with: --session %s  or  --continue\033[0m\n' "$SESSION_ID"
}

main() {
    parse_args "$@"
    util_find_awk_dir
    validate_config
    if [[ "${FORK:-}" == true ]]; then
        local fork_source_id="${SESSION_ID:-}"
        SESSION_ID="$(util_new_session_id)"
        store_session_init
        store_session_fork "$(store_session_get_dir)/${fork_source_id}" "$(store_session_get_dir)/${SESSION_ID}"
        store_event_append "{\"type\":\"session_fork\",\"session_id\":\"$(util_json_escape "$SESSION_ID")\",\"source_session_id\":\"$(util_json_escape "$fork_source_id")\"}"
    else
        store_session_init
    fi
    util_load_tool_defs
    if [[ "$INTERACTIVE" == true ]]; then
        interactive_mode
    elif [[ -n "$USER_INPUT" || ! -t 0 ]]; then
        local input="$USER_INPUT"
        [[ -z "$input" ]] && input=$(cat)
        ( exec 5> "$INPUT_FIFO"; util_write_msg "USER_INPUT" "0" "$input" >&5 ) &
        agent_main_loop
    else
        INTERACTIVE=true
        interactive_mode
    fi
}

main "$@"
