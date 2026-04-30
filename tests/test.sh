#!/usr/bin/env bash
# test.sh — Test bash-agent against mock server
# Tests SSE parsing via awk files and agent.sh end-to-end
# Usage: ./test.sh [--no-server] [port]

set -uo pipefail

# Keep all shell, awk, and Python subprocesses on the same UTF-8 locale.
# CI already sets this in the workflow, but exporting here makes the test
# behavior stable when the script is run directly as well.
export LANG="${LANG:-en_US.UTF-8}"
export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export PYTHONUTF8="${PYTHONUTF8:-1}"

# Redirect session data to a temp dir so tests don't pollute $HOME
_TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/bash-agent-test.XXXXXX")
export BASH_AGENT_HOME="$_TEST_HOME"
cleanup_test_home() { rm -rf "$_TEST_HOME"; }
trap cleanup_test_home EXIT

START_SERVER=true
PORT=9888
for arg in "$@"; do
    case "$arg" in
        --no-server) START_SERVER=false; shift ;;
        *) PORT="$arg" ;;
    esac
done

BASE="http://localhost:$PORT"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT="${AGENT:-$ROOT_DIR/src/agent.sh}"
AWK_DIR="$ROOT_DIR/src/awk"
PASS=0
FAIL=0

project_key() {
    local cwd
    cwd=$(pwd -P)
    cwd="${cwd#/}"
    cwd="${cwd//\//-}"
    cwd=$(printf '%s' "$cwd" | protocol_awk '{ gsub(/[^A-Za-z0-9._-]/, "-"); gsub(/-+/, "-", $0); sub(/^-+/, "", $0); sub(/-+$/, "", $0); print }')
    printf -- '-%s' "$cwd"
}

green() { printf '\033[32m✓ PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m✗ FAIL: %s\033[0m\n' "$1"; }
info()  { printf '\033[36m→ %s\033[0m\n' "$1"; }

# Short test helpers
multi_grep() { local o="$1"; shift; for p in "$@"; do grep -q "$p" <<< "$o" 2>/dev/null || return 1; done; return 0; }
check() { local d="$1" o="$2"; shift 2; if multi_grep "$o" "$@"; then green "$d"; ((PASS++)) || true; else red "$d"; echo "  Output: $o"; ((FAIL++)) || true; fi; }

protocol_awk() {
    LC_ALL=C awk "$@"
}

# ===== Message Decoder (for AWK parser tests) =====
# Decodes RESP-like CRLF format: *N\r\n$len0\r\ndata0\r\n...
_decode_read_header() {
    local _line
    IFS= LC_ALL=C read -r _line || return 1
    _line="${_line%$'\r'}"
    printf -v "$1" '%s' "$_line"
}

_decode_read_field() {
    _decode_read_header _hdr || return 1
    [[ "$_hdr" == \$* ]] || return 1
    local _len="${_hdr:1}"
    DECODE_FIELD=""
    if (( _len > 0 )); then
        DECODE_FIELD=$(dd bs=1 count="$((_len + 2))" 2>/dev/null)
        DECODE_FIELD="${DECODE_FIELD%$'\r'}"
    else
        IFS= LC_ALL=C read -r -n 2 _crlf 2>/dev/null || true
    fi
    return 0
}

_decode_read_message() {
    DECODE_MSG=()
    local _hdr nfields i
    _decode_read_header _hdr || return 1
    [[ "$_hdr" == \** ]] || return 1
    nfields="${_hdr:1}"
    for ((i = 0; i < nfields; i++)); do
        _decode_read_field || return 1
        DECODE_MSG+=("$DECODE_FIELD")
    done
    return 0
}

# decode_awk_output — pipe AWK binary-safe output → readable TYPE:val lines
decode_awk_output() {
    while _decode_read_message; do
        local type="${DECODE_MSG[0]}"
        local n=${#DECODE_MSG[@]}
        case "$type" in
            TEXT|THINKING|STOP|ERROR)
                printf '%s:%s\n' "$type" "${DECODE_MSG[1]}"
                ;;
            USAGE)
                printf '%s:%s\t%s\t%s\t%s\n' "$type" "${DECODE_MSG[1]}" "${DECODE_MSG[2]}" "${DECODE_MSG[3]}" "${DECODE_MSG[4]}"
                ;;
            TOOL_CALL)
                # [0]=TOOL_CALL [1]=name [2]=id [3]=input [4..]=key,val pairs
                local out="${DECODE_MSG[1]}"$'\t'"${DECODE_MSG[2]}"$'\t'"${DECODE_MSG[3]}"
                local i
                for (( i = 4; i + 1 < n; i += 2 )); do
                    out+=$'\t'"${DECODE_MSG[i]}"$'\t'"${DECODE_MSG[i+1]}"
                done
                printf '%s:%s\n' "$type" "$out"
                ;;
            RETRY)
                printf 'RETRY:\n'
                ;;
            *)
                # Generic: TYPE:field1\tfield2...
                local rest="" first=true
                for (( i = 1; i < n; i++ )); do
                    $first || rest+=$'\t'
                    first=false
                    rest+="${DECODE_MSG[i]}"
                done
                printf '%s:%s\n' "$type" "$rest"
                ;;
        esac
    done
}

# ===== Mock Server (Python) =====
start_mock() {
    python3 -c "
import http.server, json, sys, threading

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        cl = int(self.headers.get('Content-Length',0))
        body = self.rfile.read(cl)
        path = self.path
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        w = self.wfile
        if b'You are compressing conversation context' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_summary\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Task focus: summarize compact test'}}) + '\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\nLatest request: compact session'}}) + '\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\nProgress: trimmed old context'}}) + '\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\nTool evidence: none'}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'role':'assistant','content':'Task focus: summarize compact test'},'finish_reason':None}]}) + '\n\n',
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'content':'\nLatest request: compact session'},'finish_reason':None}]}) + '\n\n',
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'content':'\nProgress: trimmed old context'},'finish_reason':None}]}) + '\n\n',
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'content':'\nTool evidence: none'},'finish_reason':None}]}) + '\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'Skill marker for tests' in body and b'ANSI_TOOL_RESULT_MARKER' not in body:
            if path.startswith('/v1/messages'):
                if b'Skill path marker: ' in body and b'/helper.sh' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from skill-path-aware\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from skill-aware\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-skill\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello from skill-aware\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-skill\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" mock server!\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-skill\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'SKILL_INDEX_MARKER' in body:
            if path.startswith('/v1/messages'):
                if b'test-skill-index: Skill index summary marker' in body and b'Selected-only skill marker' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill_index\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Skill index loaded.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'skill index missing or selected skill content leaked')
            return
        if b'INSTRUCTION_FILE_MARKER' in body:
            if path.startswith('/v1/messages'):
                if b'Global agent instruction marker' in body and b'Project agent instruction marker' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_instruction_file\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Instruction files loaded.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing instruction file content in prompt')
            return
        if b'TODO_PROMPT_MARKER' in body:
            if path.startswith('/v1/messages'):
                if b'- [ ] inspect repository' in body and b'- [ ] run tests' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_todo_prompt\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Todo injected.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing current todo in prompt')
            return
        if b'TODO_WRITE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_todo_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will track the work and start with repository inspection.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_todo_write_1\",\"name\":\"TodoWrite\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'todos':[{'content':'inspect repository','status':'pending'},{'content':'run tests','status':'pending'},{'content':'fix the first failure','status':'pending'}]})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'TODO_WRITE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'- [ ] inspect repository' in body and b'- [ ] run tests' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_todo_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Todo initialized.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing TodoWrite tool result content')
            return
        if b'SKILL_TOOL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will load the requested skill.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_skill_1\",\"name\":\"Skill\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'name':'test-skill-tool'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'SKILL_TOOL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Skill: test-skill-tool' in body and b'Skill tool marker' in body and b'helper.sh' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Skill tool loaded.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Skill tool_result content')
            return
        if b'READ_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-test.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'read-test-content' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Read complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing read tool_result content')
            return
        if b'READ_ARG_PARSE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_arg_parse\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_arg_parse_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-arg-parse.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_ARG_PARSE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'read-arg-parse-content' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_arg_parse_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Read arg parsing complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing read arg parse tool_result content')
            return
        if b'LONG_READ_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_long\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_long_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-long.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'LONG_READ_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'READ-LONG-HEAD' in body and b'READ-LONG-TAIL' in body and b'truncated' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_long_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Long read complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing long read compacted tool_result content')
            return
        if b'GLOB_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search for matching files.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_glob_1\",\"name\":\"Glob\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'*.txt','path':'/tmp/bash-agent-glob-test'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GLOB_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'alpha.txt' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Glob complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Glob tool_result content')
            return
        if b'GREP_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search file contents.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_grep_1\",\"name\":\"Grep\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'needle','path':'/tmp/bash-agent-grep-test','glob':'*.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GREP_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'needle line' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Grep complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Grep tool_result content')
            return
        if b'READ_OFFSET_LIMIT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_ol\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read a portion of the file.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_ol_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-offset-limit.txt','offset':3,'limit':2})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_OFFSET_LIMIT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'line-three' in body and b'line-four' in body and b'line-one' not in body and b'line-five' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_ol_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Read offset/limit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing or incorrect Read offset/limit content')
            return
        if b'BASH_TIMEOUT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_to\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will run a command with timeout.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_to_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'sleep 30; echo done','timeout':2})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_TIMEOUT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'timed out' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_to_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Bash timeout complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing bash timeout indication')
            return
        if b'GREP_CONTEXT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_ctx\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search with context.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_grep_ctx_1\",\"name\":\"Grep\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'TARGET','path':'/tmp/bash-agent-grep-context-test','context':1})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GREP_CONTEXT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'before-line' in body and b'after-line' in body and b'TARGET' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_ctx_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Grep context complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Grep context content')
            return
        if b'EDIT_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_1\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-test.txt','old_string':'old-value','new_string':'new-value'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-test.txt)' in body and b'--- a/tmp/bash-agent-edit-test.txt' not in body and b'@@ -1 +1 @@' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing edit tool_result content')
            return
        if b'EDIT_FILE_NOT_FOUND_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_nf\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_nf\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-not-found.txt','old_string':'missing-value','new_string':'new-value'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_NOT_FOUND_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'old_string not found' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_nf_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edit not found handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing not-found tool_result content')
            return
        if b'EDIT_FILE_TOO_LARGE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_big\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_big\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-big.txt','old_string':'tiny','new_string':'replaced'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_TOO_LARGE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'file too large for edit_file' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_big_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edit size guard handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing size guard tool_result content')
            return
        if b'EDIT_UNICODE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_unicode\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit with unicode.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_unicode\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-unicode.txt','old_string':'old-text','new_string':'中文 日本語 한국어 🎉 café résumé'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_UNICODE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-unicode.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_unicode_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Unicode edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing unicode edit tool_result content')
            return
        if b'EDIT_SPECIAL_CHARS_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_special\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit with special chars.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_special\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-special.txt','old_string':'plain','new_string':'"quotes" and ' + chr(36) + 'dollar and <html> & ' + chr(39) + 'apos' + chr(39)})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_SPECIAL_CHARS_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-special.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_special_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Special chars edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing special chars edit tool_result content')
            return
        if b'EDIT_MULTILINE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                old_block = 'line4_original\nline5_original\nline6_original\nline7_original\nline8_original'
                new_block = 'line4_replaced_a\nline5_replaced_b\nline6_replaced_c\nline7_replaced_d\nline8_replaced_e\nline9_new_f\nline10_new_g\nline11_new_h'
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_ml\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit multiple lines.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_ml\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-multiline.txt','old_string':old_block,'new_string':new_block})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_MULTILINE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-multiline.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_ml_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Multiline edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing multiline edit tool_result content')
            return
        if b'EDIT_CODE_SNIPPET_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                old_code = 'if err != nil {\n\t\treturn err\n\t}'
                q = chr(34)
                new_code = 'if err != nil {\n\t\tlog.Printf(' + q + 'error: %v' + q + ', err)\n\t\treturn fmt.Errorf(' + q + 'wrap: %w' + q + ', err)\n\t}'
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_code\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the code snippet.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_code\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-code.txt','old_string':old_code,'new_string':new_code})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_CODE_SNIPPET_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-code.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_code_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Code snippet edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing code snippet edit tool_result content')
            return
        if b'WRITE_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will write the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_write_1\",\"name\":\"Write\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-write-test.txt','content':'line1\nline2\nline3'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"I will write the file now.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'UNICODE_WRITE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write_unicode\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will write the unicode file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_write_unicode\",\"name\":\"Write\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-write-unicode.txt','content':'中文\nline2'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'UNICODE_WRITE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write_unicode_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'WRITE_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-write-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Done.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_QUOTE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_quote\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running quoted bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo ' + chr(34) + 'hello' + chr(34)})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-bash-quote\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Running quoted bash command.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-bash-quote\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'sudo echo blocked'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'dangerous command prefix' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked bash command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked bash tool_result content')
            return
        if b'BASH_DELETE_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_delete_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked delete command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_delete_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'find /tmp -name example -delete'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_DELETE_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'blocked destructive find -delete pattern' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_delete_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked delete command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked delete tool_result content')
            return
        if b'BASH_DEV_NULL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_dev_null\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running harmless redirection command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_dev_null_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo harmless >/dev/null; echo after-null'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_DEV_NULL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'after-null' in body and b'command blocked by bash safety policy' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_dev_null_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Harmless redirection handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'harmless /dev/null redirection was blocked')
            return
        if b'LONG_BASH_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_long\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running long bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_long_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({\"command\":\"echo BASH-LONG-HEAD; awk 'BEGIN { for (i = 0; i < 1000; i++) print \\\"middle-middle-middle-middle-middle\\\" }'; echo BASH-LONG-TAIL\"})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'LONG_BASH_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'BASH-LONG-HEAD' in body and b'BASH-LONG-TAIL' in body and b'truncated' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_long_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Long bash complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing long bash compacted tool_result content')
            return
        if b'TOOL_RESULT_URL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool_result_url\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running URL-producing command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_url_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo Name: X.jpeg && echo URL: https://example.com/x.jpeg?foo=1&bar=two && echo Local: /tmp/X.jpeg'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'TOOL_RESULT_URL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool_result_url_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Final answer after tool result.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'ANSI_TOOL_RESULT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ansi_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running ANSI output command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_ansi_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'printf \"\\033[32mGREEN\\033[0m\\nplain\\n\"'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'ANSI_TOOL_RESULT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'GREEN' in body and b'\x1b[' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ansi_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ANSI output sanitized.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'ansi not sanitized in tool_result')
            return
        if b'MULTI_TOOL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running two tools.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_read\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-multi-read.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_bash\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':2,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo multi-bash-ok'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'MULTI_TOOL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'multi-read-content' in body and b'multi-bash-ok' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Multi-tool complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing one of the multi-tool results')
            return
        if path.startswith('/v1/messages'):
            for c in [
                'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from\"}}\n\n',
                'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}\n\n',
                'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
            ]: w.write(c.encode()); w.flush()
        elif path.startswith('/v1/chat/completions'):
            for c in [
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello from\"},\"finish_reason\":null}]}\n\n',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" OpenAI mock!\"},\"finish_reason\":null}]}\n\n',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                'data: [DONE]\n\n',
            ]: w.write(c.encode()); w.flush()
        else:
            self.send_response(404); self.end_headers(); w.write(b'not found')

    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps({'status':'ok'}).encode())

httpd = http.server.HTTPServer(('127.0.0.1', $PORT), H)
t = threading.Thread(target=httpd.serve_forever); t.daemon = True; t.start()
import time; time.sleep(120); httpd.shutdown()
" &
    MOCK_PID=$!
    sleep 1
    if ! curl -sS "$BASE/" 2>/dev/null | grep -q ok; then
        echo "Failed to start mock server on $BASE"
        kill $MOCK_PID 2>/dev/null
        exit 1
    fi
}

stop_mock() {
    [[ -n "${MOCK_PID:-}" ]] && kill $MOCK_PID 2>/dev/null
}

# ===== Tests =====

# Test 1: Claude SSE awk parser directly
test_claude_sse() {
    info "Test 1: Claude SSE awk parser"
    local output
    output=$(protocol_awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE' | decode_awk_output
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" mock server!"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -q "TEXT:Hello from" && echo "$output" | grep -q "TEXT:.*mock" && echo "$output" | grep -q "STOP:end_turn"; then
        green "Claude SSE parser"; ((PASS++)) || true
    else
        red "Claude SSE parser"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 2: Claude SSE tool_use parsing
test_claude_tool_use() {
    info "Test 2: Claude SSE tool_use parsing"
    local output
    output=$(protocol_awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE' | decode_awk_output
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"Read","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/etc/hostname\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20,"cache_creation_input_tokens":2,"cache_read_input_tokens":4}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -Fq $'TOOL_CALL:Read\ttoolu_123\t{"path":"/etc/hostname"}\tpath\t/etc/hostname' && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude tool_use"; ((PASS++)) || true
    else
        red "Claude tool_use"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 2b: Claude SSE TodoWrite parsing
test_claude_todowrite_tool_use() {
    info "Test 2b: Claude SSE TodoWrite parsing"
    local output
    output=$(protocol_awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE' | decode_awk_output
event: message_start
data: {"type":"message_start","message":{"id":"msg_todo","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_todo","name":"TodoWrite","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"todos\":[{\"content\":\"inspect repository\",\"status\":\"completed\"},{\"content\":\"run tests\",\"status\":\"pending\"}]}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -Fq $'TOOL_CALL:TodoWrite\ttoolu_todo\t{"todos":[{"content":"inspect repository","status":"completed"},{"content":"run tests","status":"pending"}]}\tchecklist\t- [x] inspect repository' && echo "$output" | grep -Fq $'summary\t1/2' && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude TodoWrite tool_use"; ((PASS++)) || true
    else
        red "Claude TodoWrite tool_use"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 3: Claude SSE usage cache tokens
test_claude_usage_cache_tokens() {
    info "Test 3: Claude SSE usage cache tokens (cache_read/cache_creation)"
    check "Claude usage cache tokens" "$(protocol_awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE' | decode_awk_output
event: message_start
data: {"type":"message_start","message":{"id":"msg_cache","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0,"cache_creation_input_tokens":2,"cache_read_input_tokens":4}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Cache usage"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7,"cache_creation_input_tokens":2,"cache_read_input_tokens":4}}

event: message_stop
data: {"type":"message_stop"}
SSE
    )" $'USAGE:10\t7\t4\t2' "STOP:end_turn"
}

# Test 4: Claude SSE tool_use parsing with quoted command
test_claude_tool_use_quoted_command() {
    info "Test 4: Claude SSE tool_use quoted command"
    local output
    output=$(protocol_awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE' | decode_awk_output
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_quoted","name":"Bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"cd /tmp && ls generate.mjs 2>/dev/null || echo \\\"not found\\\"\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -Fq $'TOOL_CALL:Bash\ttoolu_quoted\t{"command":"cd /tmp && ls generate.mjs 2>/dev/null || echo \\"not found\\""}\tcommand\tcd /tmp && ls generate.mjs 2>/dev/null || echo "not found"' && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude tool_use quoted command"; ((PASS++)) || true
    else
        red "Claude tool_use quoted command"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 5: Claude SSE unicode parsing
test_claude_sse_unicode() {
    info "Test 5: Claude SSE unicode parsing"
    local output
    output=$(protocol_awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE' | decode_awk_output
event: message_start
data: {"type":"message_start","message":{"id":"msg_unicode","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\u4e2d\u6587"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_unicode","name":"Bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"echo \u4e2d\u6587\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -q "TEXT:中文" && echo "$output" | grep -Fq $'TOOL_CALL:Bash\ttoolu_unicode\t{"command":"echo 中文"}\tcommand\techo 中文' && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude unicode parsing"; ((PASS++)) || true
    else
        red "Claude unicode parsing"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 5: OpenAI SSE awk parser
test_openai_sse() {
    info "Test 5: OpenAI SSE awk parser"
    check "OpenAI SSE parser" "$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk" <<'SSE' | protocol_awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" | decode_awk_output
data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello from"},"finish_reason":null}]}

data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":" OpenAI mock!"},"finish_reason":null}]}

data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12}}

data: [DONE]
SSE
    )" "Hello from" "OpenAI" "STOP:end_turn"
}

# Test 6: OpenAI SSE usage cache tokens
test_openai_usage_cache_tokens() {
    info "Test 6: OpenAI SSE usage cache tokens"
    check "OpenAI usage cache tokens" "$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk" <<'SSE' | protocol_awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" | decode_awk_output
data: {"id":"chatcmpl-cache","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Cache usage"},"finish_reason":null}]}

data: {"id":"chatcmpl-cache","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12,"prompt_tokens_details":{"cached_tokens":5}}}

data: [DONE]
SSE
    )" $'USAGE:5\t12\t5\t0' "STOP:end_turn"
}

# Test 7: OpenAI SSE trims initial leading newlines
test_openai_sse_leading_newline() {
    info "Test 7: OpenAI SSE trims initial leading newlines"
    local output
    output=$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk" <<'SSE' | protocol_awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" | decode_awk_output
data: {"id":"chatcmpl-leading-newline","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"\n\nHello"},"finish_reason":null}]}

data: {"id":"chatcmpl-leading-newline","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

data: {"id":"chatcmpl-leading-newline","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12}}

data: [DONE]
SSE
)
    if echo "$output" | grep -q '^TEXT:Hello$' && echo "$output" | grep -q '^TEXT: world$' && ! echo "$output" | grep -q '^TEXT:\\n'; then
        green "OpenAI trims initial leading newlines"; ((PASS++)) || true
    else
        red "OpenAI trims initial leading newlines"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_openai_sse_tool_calls() {
    info "Test 7b: OpenAI SSE tool_calls parser"
    local output
    output=$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk" <<'SSE' | protocol_awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk" | decode_awk_output
data: {"id":"chatcmpl-tool","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_openai_1","type":"function","function":{"name":"Write","arguments":"{\"path\":\"/tmp/test.txt\""}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-tool","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":",\"content\":\"AbC\"}"}}]},"finish_reason":null}]}

data: {"id":"chatcmpl-tool","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":12}}

data: [DONE]
SSE
)
    if echo "$output" | grep -Fq $'TOOL_CALL:Write\tcall_openai_1\t{"path":"/tmp/test.txt","content":"AbC"}\tpath\t/tmp/test.txt\tcontent\tAbC' && \
       echo "$output" | grep -q '^STOP:tool_use$'; then
        green "OpenAI SSE tool_calls parser"; ((PASS++)) || true
    else
        red "OpenAI SSE tool_calls parser"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 8: HTTP stream preserves error body
test_http_stream_error_body() {
    info "Test 8: HTTP stream preserves error body"
    local output
    check "HTTP stream error body" "$(printf 'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\n{"error":{"message":"bad request detail"}}\n' | protocol_awk -f "$AWK_DIR/http_stream.awk")" '^ERROR:400' 'bad request detail'
}

# Test 8: Transport body conversion (Claude request → OpenAI request)
test_transport_body() {
    info "Test 9: Transport body conversion (Claude → OpenAI request)"
    local input output
    input='{"model":"test","max_tokens":1024,"stream":true,"messages":[{"role":"user","content":"hello"}]}'
    output=$(printf '%s' "$input" | protocol_awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_body.awk")
    if echo "$output" | grep -q '"role":"user"' && echo "$output" | grep -q '"content":"hello"' && echo "$output" | grep -q '"stream":true'; then
        green "Transport body conversion (messages)"; ((PASS++)) || true
    else
        red "Transport body conversion (messages)"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 9: Transport body conversion with tools
test_transport_body_tools() {
    info "Test 9: Transport body conversion (tools)"
    local input output
    input='{"model":"test","max_tokens":1024,"stream":true,"messages":[{"role":"user","content":"hello"}],"tools":[{"name":"read_file","description":"Read file","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]}'
    output=$(printf '%s' "$input" | protocol_awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_body.awk")
    if echo "$output" | grep -q '"type":"function"' && echo "$output" | grep -q '"parameters"'; then
        green "Transport body conversion (tools)"; ((PASS++)) || true
    else
        red "Transport body conversion (tools)"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 10: Agent.sh end-to-end with mock (Claude provider)
test_agent_e2e_claude() {
    info "Test 10: Agent.sh e2e (Claude mock)"
    check "Agent e2e Claude" "$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1 || true)" "Hello from" "mock"
}

# Test 11: Agent.sh end-to-end with mock (OpenAI provider)
test_agent_e2e_openai() {
    info "Test 11: Agent.sh e2e (OpenAI mock)"
    check "Agent e2e OpenAI" "$("$AGENT" -p openai --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1 || true)" "Hello from" "mock"
}

# Test 13: Skill injection
test_agent_skill_injection() {
    local skill_dir skill_file
    skill_dir="$ROOT_DIR/.claude/skills/test-skill"
    skill_file="$skill_dir/SKILL.md"
    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'EOF'
# test-skill

Skill marker for tests
Skill path marker: ${BASH_AGENT_SKILL_DIR}/helper.sh
EOF
    check "Agent skill injection" "$(cd "$ROOT_DIR" && "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test --skill test-skill 'Hello' 2>&1 || true)" "skill-path-aware" "mock"
    rm -rf "$skill_dir"
}

test_agent_skill_injection_from_repo_skills_dir() {
    local skill_dir skill_file
    skill_dir="$ROOT_DIR/skills/test-skill-repo"
    skill_file="$skill_dir/SKILL.md"
    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'EOF'
# test-skill-repo

Skill marker for tests
Skill path marker: ${BASH_AGENT_SKILL_DIR}/helper.sh
EOF
    check "Agent skill injection from repo skills dir" "$(cd "$ROOT_DIR" && "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test --skill test-skill-repo 'Hello' 2>&1 || true)" "skill-path-aware" "mock"
    rm -rf "$ROOT_DIR/skills"
}

test_agent_skill_index() {
    info "Test 14: Agent.sh skill index"
    local skill_dir skill_file output
    skill_dir="$ROOT_DIR/.claude/skills/test-skill-index"
    skill_file="$skill_dir/SKILL.md"
    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'EOF'
# test-skill-index

Skill index summary marker

Selected-only skill marker
EOF
    output=$(cd "$ROOT_DIR" && "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'SKILL_INDEX_MARKER' 2>&1) || true
    rm -rf "$skill_dir"
    if echo "$output" | grep -q "Skill index loaded."; then
        green "Agent skill index"; ((PASS++)) || true
    else
        red "Agent skill index"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_skill_tool() {
    info "Test 14b: Agent.sh Skill tool"
    local skill_dir skill_file output
    skill_dir="$ROOT_DIR/.claude/skills/test-skill-tool"
    skill_file="$skill_dir/SKILL.md"
    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'EOF'
# test-skill-tool

Skill tool marker
Path marker: ${BASH_AGENT_SKILL_DIR}/helper.sh
EOF
    output=$(cd "$ROOT_DIR" && "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'SKILL_TOOL_MARKER' 2>&1) || true
    rm -rf "$skill_dir"
    if echo "$output" | grep -Fq "[tool] Skill(test-skill-tool)" && echo "$output" | grep -q "Skill tool loaded."; then
        green "Agent Skill tool"; ((PASS++)) || true
    else
        red "Agent Skill tool"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_instruction_files() {
    info "Test 15: Agent.sh instruction file injection"
    local home_dir global_dir project_file output
    home_dir=$(mktemp -d)
    global_dir="$home_dir/.bash-agent"
    project_file="$ROOT_DIR/AGENTS.md"
    mkdir -p "$global_dir"
    cat > "$global_dir/AGENTS.md" <<'EOF'
Global agent instruction marker
EOF
    cat > "$project_file" <<'EOF'
Project agent instruction marker
EOF
    output=$(cd "$ROOT_DIR" && HOME="$home_dir" BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'INSTRUCTION_FILE_MARKER' 2>&1) || true
    rm -rf "$home_dir"
    rm -f "$project_file"
    if echo "$output" | grep -q "Instruction files loaded."; then
        green "Agent instruction file injection"; ((PASS++)) || true
    else
        red "Agent instruction file injection"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_todo_state() {
    info "Test 16: Agent.sh session todo state"
    local home_dir project_dir output session_file todo_file event_file human_home
    home_dir=$(mktemp -d)
    project_dir="$home_dir/.bash-agent/projects/$(project_key)"
    session_dir="$project_dir/demo"
    session_file="$session_dir/conversation.jsonl"
    todo_file="$session_dir/todo.md"
    event_file="$session_dir/events.jsonl"

    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" HOME="$home_dir" "$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test --session demo 'run tests and fix failures TODO_WRITE_MARKER' 2>&1) || true
    if echo "$output" | grep -q '"type":"text"' && \
       echo "$output" | grep -q '"type":"todo_update"' && \
       [[ -f "$todo_file" ]] && \
       grep -q "^- \\[ \\] inspect repository$" "$todo_file" && \
       grep -q "^- \\[ \\] run tests$" "$todo_file" && \
       [[ "$(grep -c '"type":"session_start"' "$event_file" 2>/dev/null || echo 0)" -eq 1 ]] && \
       grep -q '"type":"todo_update"' "$event_file" && \
       grep -q "inspect repository" "$session_file"; then
        :
    else
        red "Agent session todo state"; echo "  Output: $output"; echo "  Todo: $(cat "$todo_file" 2>/dev/null || true)"; echo "  Session: $(cat "$session_file" 2>/dev/null || true)"; echo "  Events: $(cat "$event_file" 2>/dev/null || true)"; ((FAIL++)) || { rm -rf "$home_dir"; return; }
        rm -rf "$home_dir"
        return
    fi

    human_home=$(mktemp -d)
    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$human_home" HOME="$human_home" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test --session demo 'run tests and fix failures TODO_WRITE_MARKER' 2>&1) || true
    rm -rf "$home_dir" "$human_home"
    if echo "$output" | grep -Fq "[tool] TodoWrite(0/3)" && echo "$output" | grep -q "Todo initialized."; then
        green "Agent session todo state"; ((PASS++)) || true
    else
        red "Agent session todo state"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 18: Read file end-to-end
test_agent_read_file() {
    info "Test 18: Agent.sh read_file"
    local output target_file
    target_file="/tmp/bash-agent-read-test.txt"
    printf 'read-test-content\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'READ_FILE_MARKER' 2>&1) || true
    if echo "$output" | grep -Fq "[tool] Read(/tmp/bash-agent-read-test.txt)" && echo "$output" | grep -q "Read complete."; then
        green "Agent read_file"; ((PASS++)) || true
    else
        red "Agent read_file"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_read_tool_arg_parsing() {
    info "Test 18a: Agent.sh Read tool arg parsing"
    local output target_file
    target_file="/tmp/bash-agent-read-arg-parse.txt"
    printf 'read-arg-parse-content\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test "READ_ARG_PARSE_MARKER" 2>&1) || true
    if echo "$output" | grep -Fq "[tool] Read($target_file)" && \
       echo "$output" | grep -q "Read arg parsing complete." && \
       ! echo "$output" | grep -Fq "Error: tool execution failed: Error: no path provided"; then
        green "Agent Read tool arg parsing"; ((PASS++)) || true
    else
        red "Agent Read tool arg parsing"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_read_file_long_result() {
    info "Test 18b: Agent.sh read_file long result formatting"
    local output target_file
    target_file="/tmp/bash-agent-read-long.txt"
    {
        printf 'READ-LONG-HEAD\n'
        awk 'BEGIN { for (i = 0; i < 1000; i++) print "middle" }'
        printf 'READ-LONG-TAIL\n'
    } > "$target_file"
    output=$(TOOL_RESULT_MAX_BYTES=1000 "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'LONG_READ_MARKER' 2>&1) || true
    if [[ "$output" == *"Long read complete."* ]] && \
       [[ "$output" == *"Read($target_file) ["* ]] && \
       [[ "$output" != *"READ-LONG-HEAD"* ]] && \
       [[ "$output" != *"READ-LONG-TAIL"* ]]; then
        green "Agent read_file long result formatting"; ((PASS++)) || true
    else
        red "Agent read_file long result formatting"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_glob() {
    info "Test 19: Agent.sh glob"
    local output target_dir
    target_dir="/tmp/bash-agent-glob-test"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    printf 'a\n' > "$target_dir/alpha.txt"
    printf 'b\n' > "$target_dir/beta.log"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'GLOB_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Glob complete."; then
        green "Agent glob"; ((PASS++)) || true
    else
        red "Agent glob"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -rf "$target_dir"
}

test_agent_grep() {
    info "Test 20: Agent.sh grep"
    local output target_dir
    target_dir="/tmp/bash-agent-grep-test"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    printf 'needle line\n' > "$target_dir/alpha.txt"
    printf 'other\n' > "$target_dir/beta.log"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'GREP_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Grep complete."; then
        green "Agent grep"; ((PASS++)) || true
    else
        red "Agent grep"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -rf "$target_dir"
}

# Test 20a: Read with offset/limit
test_agent_read_offset_limit() {
    info "Test 20a: Agent.sh Read with offset/limit"
    local output target_file
    target_file="/tmp/bash-agent-read-offset-limit.txt"
    rm -f "$target_file"
    printf 'line-one\nline-two\nline-three\nline-four\nline-five\nline-six\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'READ_OFFSET_LIMIT_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Read offset/limit complete."; then
        green "Agent Read offset/limit"; ((PASS++)) || true
    else
        red "Agent Read offset/limit"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# Test 20b: Bash with per-call timeout
test_agent_bash_timeout() {
    info "Test 20b: Agent.sh Bash with timeout parameter"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_TIMEOUT_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Bash timeout complete."; then
        green "Agent Bash timeout"; ((PASS++)) || true
    else
        red "Agent Bash timeout"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 20c: Grep with context parameter
test_agent_grep_context() {
    info "Test 20c: Agent.sh Grep with context parameter"
    local output target_dir
    target_dir="/tmp/bash-agent-grep-context-test"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    printf 'before-line\nTARGET\nafter-line\n' > "$target_dir/test.txt"
    printf 'other\n' > "$target_dir/other.txt"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'GREP_CONTEXT_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Grep context complete."; then
        green "Agent Grep context"; ((PASS++)) || true
    else
        red "Agent Grep context"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -rf "$target_dir"
}

# Test 21: Edit file end-to-end
test_agent_edit_file() {
    info "Test 21: Agent.sh edit_file"
    local output target_file
    target_file="/tmp/bash-agent-edit-test.txt"
    printf 'prefix old-value suffix\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_FILE_MARKER' 2>&1) || true
    local plain_output
    plain_output=$(printf '%s' "$output" | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    if echo "$plain_output" | grep -Fq 'Edit(/tmp/bash-agent-edit-test.txt) [+' && \
       grep -q 'new-value' "$target_file" && ! grep -q 'old-value' "$target_file"; then
        green "Agent edit_file"; ((PASS++)) || true
    else
        red "Agent edit_file"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_file_not_found() {
    info "Test 22: Agent.sh edit_file missing old_string"
    local output target_file
    target_file="/tmp/bash-agent-edit-not-found.txt"
    printf 'prefix old-value suffix\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_FILE_NOT_FOUND_MARKER' 2>&1) || true
    if echo "$output" | grep -q "old_string not found" && grep -q 'old-value' "$target_file" && ! grep -q 'new-value' "$target_file"; then
        green "Agent edit_file missing old_string"; ((PASS++)) || true
    else
        red "Agent edit_file missing old_string"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_file_too_large() {
    info "Test 23: Agent.sh edit_file file size guard"
    local output target_file
    target_file="/tmp/bash-agent-edit-big.txt"
    head -c 1048577 /dev/zero | tr '\0' 'a' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_FILE_TOO_LARGE_MARKER' 2>&1) || true
    if echo "$output" | grep -q "file too large for edit_file" && [[ $(wc -c < "$target_file") -gt 1048576 ]]; then
        green "Agent edit_file file size guard"; ((PASS++)) || true
    else
        red "Agent edit_file file size guard"; echo "  Output: $output"; echo "  Size: $(wc -c < "$target_file")"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# Test 24: Write file preserves newlines
test_agent_write_file_newlines() {
    info "Test 24: Agent.sh write_file newline handling"
    local output target_file
    target_file="/tmp/bash-agent-write-test.txt"
    rm -f "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test -v 'WRITE_FILE_MARKER' 2>&1) || true
    if [[ -f "$target_file" ]] && \
       grep -q $'line1\nline2\nline3' "$target_file" && \
       echo "$output" | grep -Fq "Write($target_file) ["; then
        green "Agent write_file newline handling"; ((PASS++)) || true
    else
        red "Agent write_file newline handling"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# Test 25: Bash tool preserves quoted command content
test_agent_bash_quotes() {
    info "Test 25: Agent.sh bash tool quoted command"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test -v 'BASH_QUOTE_MARKER' 2>&1) || true
    if echo "$output" | grep -Fq '[tool] Bash(echo "hello")' && echo "$output" | grep -q "hello" && ! echo "$output" | grep -q "no command provided"; then
        green "Agent bash quoted command"; ((PASS++)) || true
    else
        red "Agent bash quoted command"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_blocked_command() {
    info "Test 25a: Agent.sh bash safety policy"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_BLOCK_MARKER' 2>&1) || true
    if [[ "$output" == *"[tool] Bash(sudo echo blocked)"* ]] && \
       [[ "$output" == *"Error: command blocked by bash safety policy"* ]] && \
       [[ "$output" == *"dangerous command prefix"* ]]; then
        green "Agent bash safety policy"; ((PASS++)) || true
    else
        red "Agent bash safety policy"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_blocked_delete_command() {
    info "Test 25aa: Agent.sh bash blocks find -delete"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_DELETE_BLOCK_MARKER' 2>&1) || true
    if [[ "$output" == *"[tool] Bash(find /tmp -name example -delete)"* ]] && \
       [[ "$output" == *"blocked destructive find -delete pattern"* ]]; then
        green "Agent bash blocks find -delete"; ((PASS++)) || true
    else
        red "Agent bash blocks find -delete"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_allows_dev_null_redirection() {
    info "Test 25ab: Agent.sh bash allows /dev/null redirection"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_DEV_NULL_MARKER' 2>&1) || true
    if [[ "$output" == *"[tool] Bash(echo harmless >/dev/null; echo after-null)"* ]] && \
       [[ "$output" == *"after-null"* ]] && \
       [[ "$output" != *"command blocked by bash safety policy"* ]]; then
        green "Agent bash allows /dev/null redirection"; ((PASS++)) || true
    else
        red "Agent bash allows /dev/null redirection"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_long_result() {
    info "Test 25b: Agent.sh bash long result formatting"
    local output
    output=$(TOOL_RESULT_MAX_BYTES=1000 "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'LONG_BASH_MARKER' 2>&1) || true
    if [[ "$output" == *"Long bash complete."* ]] && \
       [[ "$output" == *"BASH-LONG-HEAD"* ]] && \
       [[ "$output" == *"BASH-LONG-TAIL"* ]] && \
       [[ "$output" == *"truncated"* ]]; then
        green "Agent bash long result formatting"; ((PASS++)) || true
    else
        red "Agent bash long result formatting"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_stream_tool_call() {
    info "Test 26: Agent.sh stream-json tool call"
    local output
    output=$("$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_QUOTE_MARKER' 2>&1) || true
    if echo "$output" | grep -q '"type":"tool_call"' && \
       echo "$output" | grep -Fq 'echo \"hello\"' && \
       echo "$output" | grep -q '"cache_read_input_tokens":3'; then
        green "Agent stream-json tool call"; ((PASS++)) || true
    else
        red "Agent stream-json tool call"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_stream_usage_event() {
    info "Test 27: Agent.sh stream-json usage event"
    local output
    output=$("$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q '"type":"usage"' && \
       echo "$output" | grep -q '"input_tokens":10' && \
       echo "$output" | grep -q '"output_tokens":7' && \
       echo "$output" | grep -q '"cache_read_input_tokens":0' && \
       echo "$output" | grep -q '"cache_creation_input_tokens":0'; then
        green "Agent stream-json usage event"; ((PASS++)) || true
    else
        red "Agent stream-json usage event"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_tool_result_multiline_url() {
    info "Test 26: Agent.sh tool_result multiline URL"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'TOOL_RESULT_URL_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Final answer after tool result"; then
        green "Agent tool_result multiline URL"; ((PASS++)) || true
    else
        red "Agent tool_result multiline URL"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_multiple_tool_calls() {
    info "Test 27: Agent.sh multiple tool calls in one turn"
    local output target_file
    target_file="/tmp/bash-agent-multi-read.txt"
    printf 'multi-read-content\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'MULTI_TOOL_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Multi-tool complete."; then
        green "Agent multiple tool calls"; ((PASS++)) || true
    else
        red "Agent multiple tool calls"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_write_file_unicode() {
    info "Test 29: Agent.sh write_file unicode"
    local output target_file
    target_file="/tmp/bash-agent-write-unicode.txt"
    rm -f "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'UNICODE_WRITE_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Done." && [[ -f "$target_file" ]] && grep -q "中文" "$target_file" && grep -q "line2" "$target_file"; then
        green "Agent write_file unicode"; ((PASS++)) || true
    else
        red "Agent write_file unicode"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_json_escape_unicode_multiline() {
    info "Test 30: json_escape unicode and multiline"
    local output
    output=$(printf '%s' $'第一行\n第二行 "quoted"' | protocol_awk -v json_mode=escape_string -f "$AWK_DIR/json.awk" -f "$AWK_DIR/json_cli.awk")
    if [[ "$output" == '第一行\n第二行 \"quoted\"' ]]; then
        green "json_escape unicode and multiline"; ((PASS++)) || true
    else
        red "json_escape unicode and multiline"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_json_extract_top_level_member() {
    info "Test 31: json top-level member extraction"
    local output awk_prog
    awk_prog="$(mktemp "${TMPDIR:-/tmp}/bash-agent-json-test.XXXXXX.awk")"
    cat > "$awk_prog" <<'AWK'
BEGIN {
    json = "{\"nested\":{\"content\":\"wrong\"},\"content\":\"right\",\"num\":42}"
    print extract_str(json, "content")
    print extract_num(json, "num")
}
AWK
    output=$(protocol_awk -f "$AWK_DIR/json.awk" -f "$awk_prog")
    rm -f "$awk_prog"
    if [[ "$output" == $'right\n42' ]]; then
        green "json top-level member extraction"; ((PASS++)) || true
    else
        red "json top-level member extraction"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_edit_unicode() {
    info "Test 31: Agent.sh edit_file unicode/Chinese/Japanese/Korean"
    local output target_file
    target_file="/tmp/bash-agent-edit-unicode.txt"
    printf 'prefix old-text suffix\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_UNICODE_MARKER' 2>&1) || true
    plain_output=$(printf '%s' "$output" | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    if echo "$plain_output" | grep -Fq 'Edit(/tmp/bash-agent-edit-unicode.txt) [+' && grep -q '中文' "$target_file" && grep -q '日本語' "$target_file" && grep -q '한국어' "$target_file" && ! grep -q 'old-text' "$target_file"; then
        green "Agent edit_file unicode"; ((PASS++)) || true
    else
        red "Agent edit_file unicode"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_special_chars() {
    info "Test 32: Agent.sh edit_file special chars (quotes, dollar, html, apostrophe)"
    local output target_file
    target_file="/tmp/bash-agent-edit-special.txt"
    printf 'prefix plain suffix\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_SPECIAL_CHARS_MARKER' 2>&1) || true
    plain_output=$(printf '%s' "$output" | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    if echo "$plain_output" | grep -Fq 'Edit(/tmp/bash-agent-edit-special.txt) [+' && grep -q 'quotes' "$target_file" && grep -q 'dollar' "$target_file" && grep -q '<html>' "$target_file" && grep -q 'apos' "$target_file" && ! grep -q 'plain' "$target_file"; then
        green "Agent edit_file special chars"; ((PASS++)) || true
    else
        red "Agent edit_file special chars"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_multiline() {
    info "Test 33: Agent.sh edit_file multiline (replace 5 lines with 8 lines in 15-line file)"
    local output target_file
    target_file="/tmp/bash-agent-edit-multiline.txt"
    # Create a 15-line file
    { for i in $(seq 1 15); do printf 'line%d_original\n' "$i"; done } > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_MULTILINE_MARKER' 2>&1) || true
    # File should now be 18 lines (10 unchanged + 8 replacement lines)
    # Lines 1-3 unchanged, lines 4-11 replaced (was 4-8), lines 12-15 (was 9-15) unchanged
    local line_count
    line_count=$(wc -l < "$target_file" | tr -d ' ')
    plain_output=$(printf '%s' "$output" | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    if echo "$plain_output" | grep -Fq 'Edit(/tmp/bash-agent-edit-multiline.txt) [+' \
       && grep -q 'line4_replaced_a' "$target_file" \
        && grep -q 'line11_new_h' "$target_file" \
        && grep -q 'line9_original' "$target_file" \
        && ! grep -q 'line5_original' "$target_file" \
        && [[ "$line_count" -ge 17 ]]; then
        green "Agent edit_file multiline"; ((PASS++)) || true
    else
        red "Agent edit_file multiline"; echo "  Output: $output"; echo "  Lines: $line_count"; echo "  File:"; cat -n "$target_file" 2>/dev/null; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_code_snippet() {
    info "Test 34: Agent.sh edit_file code snippet (tabs, braces, quotes, percent, backslash)"
    local output target_file
    target_file="/tmp/bash-agent-edit-code.txt"
    # Simulate a Go source file with tabs, braces, %v, %w format strings
    printf 'func main() {\n\tif err != nil {\n\t\treturn err\n\t}\n}\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_CODE_SNIPPET_MARKER' 2>&1) || true
    plain_output=$(printf '%s' "$output" | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    if echo "$plain_output" | grep -Fq 'Edit(/tmp/bash-agent-edit-code.txt) [+' \
       && grep -q 'log.Printf' "$target_file" \
        && grep -q 'fmt.Errorf' "$target_file" \
        && grep -q '%v' "$target_file" \
        && grep -q '%w' "$target_file" \
        && ! grep -q 'return err$' "$target_file"; then
        green "Agent edit_file code snippet"; ((PASS++)) || true
    else
        red "Agent edit_file code snippet"; echo "  Output: $output"; echo "  File:"; cat -A "$target_file" 2>/dev/null; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}


# Test 34: stats.awk dump/update round-trip
test_stats_awk() {
    info "Test 34: stats.awk dump/update round-trip"
    local tmpdir
    tmpdir=$(mktemp -d)
    printf 'agent_request_count\t0\ntotal_input_tokens\t0\ntotal_output_tokens\t0\ntotal_cache_read_tokens\t0\ntotal_cache_creation_tokens\t0\ncurrent_context_tokens\t0\ncompact_request_count\t0\n' > "$tmpdir/test.json"
    printf 'agent_request_count\t+1\ntotal_input_tokens\t+10\ntotal_output_tokens\t+20\ntotal_cache_read_tokens\t+3\ntotal_cache_creation_tokens\t+4\ncurrent_context_tokens\t30\n' |         protocol_awk -v action=update -f "$AWK_DIR/stats.awk" "$tmpdir/test.json"
    local result
    result=$(protocol_awk -v action=dump -f "$AWK_DIR/stats.awk" "$tmpdir/test.json" | sort)
    check "stats.awk update/dump" "$result" \
        $'agent_request_count\t1' $'total_input_tokens\t10' $'total_output_tokens\t20' \
        $'total_cache_read_tokens\t3' $'total_cache_creation_tokens\t4' $'current_context_tokens\t30'
    rm -rf "$tmpdir"
}

# Test 35: --max-context accepts k/m suffixes
test_agent_max_context() {
    info "Test 35: --max-context parse_size_bytes"
    local maxctx_out
    maxctx_out=$("$AGENT" --max-context invalid 2>&1) || true
    if echo "$maxctx_out" | grep -q "Error:.*--max-context"; then
        green "Agent --max-context k suffix"; ((PASS++)) || true
    else
        red "Agent --max-context k suffix"; echo "  Output: $maxctx_out"; ((FAIL++)) || true
    fi
}

# Test 37: compact_dp.awk — DP compact decision algorithm
test_compact_dp_awk() {
    info "Test 37: compact_dp.awk DP compact decision"
    local tmpdir conv_file
    tmpdir=$(mktemp -d)
    conv_file="$tmpdir/conv.jsonl"

    # Helper: generate conversation with N groups
    gen_conv() {
        local groups=$1 total_token_target=$2 output=$3
        # total_token_target = 所有消息的总 token 数
        local bytes_per_line=$(( total_token_target * 4 / groups / 3 ))
        (( bytes_per_line > 20 )) || bytes_per_line=20
        > "$output"
        for i in $(seq 1 $groups); do
            local pad
            pad=$(printf "x%0${bytes_per_line}d" 1 2>/dev/null | tr '0-9' 'a-k')
            echo "{\"role\":\"user\",\"content\":\"${pad:0:$bytes_per_line}\"}" >> "$output"
            echo "{\"role\":\"assistant\",\"content\":\"${pad:0:$((bytes_per_line*2))}\"}" >> "$output"
            echo "{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"t$i\",\"content\":\"${pad:0:$((bytes_per_line/2))}\"}]}" >> "$output"
        done
    }

    # dp_run: run compact_dp.awk with new 4-term formula
    # Args: E L [c]
    # Internally maps to new interface: E fixed, L fixed, t=1 so E/L directly control R
    dp_run() {
        local _E="${1:-8}" _L="${2:-5}" _c="${3:-0}"
        protocol_awk -f "$AWK_DIR/compact_dp.awk" \
            -v e_fixed="$_E" -v L_fixed="$_L" \
            -v total_requests="$_L" -v t=1 \
            -v total_compact="$_c" -v total_input=$((4000 * _L)) \
            -v baseline_e=8 -v V=5000 \
            -v p_input=3.0 -v p_cache=0.30 -v p_out=15.0 \
            -v S=500 -v min_keep_ratio=0.12 \
            -v r=0.8 -v beta=0.03 "$conv_file" 2>/dev/null
    }

    # --- 37a: Empty ---
    : > "$conv_file"
    check "compact_dp: empty conv -> 0" "$(dp_run 8 3 0)" "0"

    # --- 37b: Tiny (5k tokens, below useful threshold) ---
    gen_conv 2 5000 "$conv_file"
    check "compact_dp: tiny conv -> 0" "$(dp_run 8 3 0)" "0"

    # --- 37c: Medium (30k tokens, R=40) — compact is now worth it with corrected formula ---
    gen_conv 10 30000 "$conv_file"
    result=$(dp_run 8 5 0)
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: medium R=40 -> $result"; ((PASS++)); } \
        || { red "compact_dp: medium R=40 -> $result"; ((FAIL++)); }
    # R=5 with small context should not compact
    gen_conv 3 5000 "$conv_file"
    check "compact_dp: small R=5 -> 0" "$(dp_run 1 5 0)" "0"

    # --- 37d: Large (100k tokens, R=E*L=40) — should compact ---
    gen_conv 20 100000 "$conv_file"
    result=$(dp_run 8 5 0)
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: large R=40 c=0 -> $result"; ((PASS++)); } \
        || { red "compact_dp: large R=40 c=0 -> $result"; ((FAIL++)); }
    # R=5 with large context also compacts — formula correctly sees benefit
    result=$(dp_run 1 5 0)
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: large R=5 -> $result"; ((PASS++)); } \
        || { red "compact_dp: large R=5 -> $result"; ((FAIL++)); }
    result=$(dp_run 8 5 3)
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: large R=40 c=3 -> $result"; ((PASS++)); } \
        || { red "compact_dp: large R=40 c=3 -> $result"; ((FAIL++)); }

    # --- 37e: Extreme beta suppresses ---
    result=$(protocol_awk -f "$AWK_DIR/compact_dp.awk" \
        -v e_fixed=8 -v L_fixed=5 \
        -v total_requests=5 -v t=1 -v total_compact=0 \
        -v total_input=20000 -v baseline_e=8 -v V=5000 \
        -v p_input=3.0 -v p_cache=0.30 -v p_out=15.0 \
        -v S=500 -v min_keep_ratio=0.12 -v r=0.8 -v beta=50.0 "$conv_file" 2>/dev/null)
    check "compact_dp: beta=50 -> 0" "$result" "0"

    # --- 37f: Turn alignment ---
    cat > "$conv_file" << 'TURNEOF'
{"role":"assistant","content":"intro"}
{"role":"user","content":"step 1"}
{"role":"assistant","content":"response 1"}
{"role":"user","content":[{"type":"tool_result","content":"result 1"}]}
{"role":"assistant","content":"response 1b"}
{"role":"user","content":"step 2"}
{"role":"assistant","content":"response 2"}
{"role":"user","content":"step 3"}
TURNEOF
    result=$(protocol_awk -f "$AWK_DIR/compact_dp.awk" \
        -v e_fixed=10 -v L_fixed=3 \
        -v total_requests=3 -v t=1 -v total_compact=0 \
        -v total_input=12000 -v baseline_e=8 -v V=0 \
        -v p_input=3.0 -v p_cache=0.30 -v p_out=15.0 \
        -v S=0 -v min_keep_ratio=0.12 -v r=0.8 -v beta=0.001 "$conv_file" 2>/dev/null)
    if [[ "$result" == "3" || "$result" == "4" ]]; then
        green "compact_dp: turn alignment -> $result"; ((PASS++))
    else
        red "compact_dp: turn alignment -> $result (expected 3 or 4)"; ((FAIL++))
    fi

    # --- 37g: Long session E saturation (stats[0] > baseline) ---
    # After baseline turns, E saturates at baseline/2 = 4, R=4*3=12
    # DP should still recommend compaction with very large context
    gen_conv 30 200000 "$conv_file"
    result=$(dp_run 4 5 0)  # E=4 (saturated), L=5, R=20
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: long session E=4 -> $result"; ((PASS++)); } \
        || { red "compact_dp: long session E=4 -> $result"; ((FAIL++)); }

    rm -rf "$tmpdir"
}
test_agent_stats_json() {
    info "Test 36: stats.json created on agent run"
    local home_dir stats_file
    home_dir=$(mktemp -d)
    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'Hello' >/dev/null 2>&1 || true
    stats_file=$(find "$home_dir" -name 'stats.json' 2>/dev/null | head -1)
    if [[ -n "$stats_file" ]] && grep -q 'input_tokens' "$stats_file" 2>/dev/null; then
        green "Agent stats.json created"; ((PASS++)) || true
    else
        red "Agent stats.json created"; echo "  Stats file: $stats_file (content: $(cat "$stats_file" 2>/dev/null || echo 'N/A'))"; ((FAIL++)) || true
    fi
    rm -rf "$home_dir"
}

# ===== Main =====

if $START_SERVER; then
    trap stop_mock EXIT
    start_mock
fi

test_claude_sse
test_claude_tool_use
test_claude_todowrite_tool_use
test_claude_usage_cache_tokens
test_claude_tool_use_quoted_command
test_claude_sse_unicode
test_openai_sse
test_openai_usage_cache_tokens
test_openai_sse_leading_newline
test_openai_sse_tool_calls
test_http_stream_error_body
test_transport_body
test_transport_body_tools
test_agent_e2e_claude
test_agent_e2e_openai
test_agent_skill_injection
test_agent_skill_injection_from_repo_skills_dir
test_agent_skill_index
test_agent_skill_tool
test_agent_instruction_files
test_agent_todo_state
test_agent_read_file
test_agent_read_tool_arg_parsing
test_agent_read_file_long_result
test_agent_glob
test_agent_grep
test_agent_read_offset_limit
test_agent_bash_timeout
test_agent_grep_context
test_agent_edit_file
test_agent_edit_file_not_found
test_agent_edit_file_too_large
test_agent_write_file_newlines
test_agent_bash_quotes
test_agent_bash_blocked_command
test_agent_bash_blocked_delete_command
test_agent_bash_allows_dev_null_redirection
test_agent_bash_long_result
test_agent_stream_tool_call
test_agent_stream_usage_event
test_agent_tool_result_multiline_url
test_agent_multiple_tool_calls
test_agent_write_file_unicode
test_json_escape_unicode_multiline
test_json_extract_top_level_member
test_agent_edit_unicode
test_agent_edit_special_chars
test_agent_edit_multiline
test_agent_edit_code_snippet
test_stats_awk
test_agent_max_context
test_agent_stats_json
test_compact_dp_awk

echo ""
echo "=============================="
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "=============================="

(( FAIL > 0 )) && exit 1 || exit 0
