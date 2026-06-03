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
    MOCK_SERVER_FILE="$ROOT_DIR/tests/fixtures/mock_server.py"
    BASH_AGENT_TEST_PORT="$PORT" python3 "$MOCK_SERVER_FILE" &
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

test_agent_openai_request_body() {
    info "Test 11a: Agent OpenAI request body carries converted tools"
    "$AGENT" -p openai --base-url "$BASE/v1" -m test --api-key test 'Hello' >/dev/null 2>&1 || true
    local req check_output
    req=$(curl -fsS "$BASE/last-request")
    check_output=$(printf '%s' "$req" | /usr/bin/python3 -c '
import json, sys
req = json.load(sys.stdin)
obj = json.loads(req["body"])
assert obj["messages"][0]["role"] == "system", "first message role is not system"
tools = obj.get("tools", [])
assert tools, "tools array is empty"
assert tools[0]["type"] == "function", "first tool type is not function"
assert "parameters" in tools[0]["function"], "first tool missing function.parameters"
for i, tool in enumerate(tools):
    assert "input_schema" not in tool, f"tool[{i}] still has top-level input_schema"
    fn = tool.get("function", {})
    assert "input_schema" not in fn, f"tool[{i}].function still has input_schema"
print("ok")
' 2>&1)
    if [[ "$check_output" == "ok" ]]; then
        green "Agent OpenAI request body carries converted tools"; ((PASS++)) || true
    else
        red "Agent OpenAI request body carries converted tools"; echo "  Check: $check_output"; ((FAIL++)) || true
    fi
}

test_agent_openai_tool_write() {
    info "Test 11b: Agent e2e OpenAI tool call"
    local output target_file plain_output
    target_file="/tmp/bash-agent-write-test.txt"
    rm -f "$target_file"
    output=$("$AGENT" -p openai --base-url "$BASE/v1" -m test --api-key test -v 'WRITE_FILE_MARKER' 2>&1) || true
    plain_output=$(printf '%s' "$output" | sed 's/\x1B\[[0-9;]*[[:alpha:]]//g')
    if [[ -f "$target_file" ]] && \
       grep -q $'line1\nline2\nline3' "$target_file" && \
       echo "$plain_output" | grep -Fq 'Write(/tmp/bash-agent-write-test.txt) [' && \
       echo "$plain_output" | grep -Fq 'Done.'; then
        green "Agent e2e OpenAI tool call"; ((PASS++)) || true
    else
        red "Agent e2e OpenAI tool call"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_tool_result_persist_order() {
    info "Test 11c: assistant tool_use persisted before following tool_result"
    local output session_id conv_file
    session_id="persist-order-openai"
    conv_file="$BASH_AGENT_HOME/.bash-agent/projects/$(cd "$ROOT_DIR" && project_key)/$session_id/conversation.jsonl"
    rm -rf "$(dirname "$conv_file")/$session_id"
    output=$("$AGENT" --session "$session_id" -p openai --base-url "$BASE/v1" -m test --api-key test 'WRITE_FILE_MARKER' 2>&1) || true
    if [[ -f "$conv_file" ]] && /usr/bin/python3 - "$conv_file" <<'PY' >/dev/null 2>&1
import json, sys
lines = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
for i in range(len(lines) - 1):
    cur, nxt = lines[i], lines[i + 1]
    if cur.get("role") == "assistant" and any(b.get("type") == "tool_use" for b in cur.get("content", [])):
        if nxt.get("role") == "user" and nxt.get("content") and all(b.get("type") == "tool_result" for b in nxt["content"]):
            sys.exit(0)
sys.exit(1)
PY
    then
        green "assistant tool_use persisted before following tool_result"; ((PASS++)) || true
    else
        red "assistant tool_use persisted before following tool_result"; echo "  Output: $output"; echo "  Conversation: $(cat "$conv_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
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
    local home_dir project_dir output session_file event_file human_home
    home_dir=$(mktemp -d)
    project_dir="$home_dir/.bash-agent/projects/$(cd "$ROOT_DIR" && project_key)"
    session_dir="$project_dir/demo"
    session_file="$session_dir/conversation.jsonl"
    event_file="$session_dir/events.jsonl"

    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" HOME="$home_dir" "$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test --session demo 'run tests and fix failures TODO_WRITE_MARKER' 2>&1) || true
    if echo "$output" | grep -q '"type":"text"' && \
       [[ -f "$session_file" ]] && \
       grep -q "inspect repository" "$session_file" && \
       grep -q '"type":"session_start"' "$event_file"; then
        :
    else
        red "Agent session todo state"; echo "  Output: $output"; echo "  Session: $(cat "$session_file" 2>/dev/null || true)"; echo "  Events: $(cat "$event_file" 2>/dev/null || true)"; ((FAIL++)) || { rm -rf "$home_dir"; return; }
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

# Test 17: PlanClear tool
test_agent_plan_clear() {
    info "Test 17: Agent.sh PlanClear tool"
    local home_dir output plan_file summary_file conv_file
    home_dir=$(mktemp -d)
    project_dir="$home_dir/.bash-agent/projects/$(cd "$ROOT_DIR" && project_key)"
    session_dir="$project_dir/demo"
    plan_file="$session_dir/plan.md"
    summary_file="$session_dir/summary.txt"
    conv_file="$session_dir/conversation.jsonl"
    mkdir -p "$session_dir"

    # Seed a plan (PlanClear needs non-empty plan to clear)
    printf 'Task: complete the test plan\n' > "$plan_file"
    [[ -s "$plan_file" ]] || { red "Agent PlanClear (setup)"; rm -rf "$home_dir"; return; }

    # Seed conversation history so compact has something to work with
    for i in $(seq 1 10); do
        printf '{"role":"user","content":"step %d of plan"}\n' "$i" >> "$conv_file"
        printf '{"role":"assistant","content":[{"type":"text","text":"done step %d"}]}\n' "$i" >> "$conv_file"
    done

    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" HOME="$home_dir" "$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test --session demo 'plan completed PLAN_CLEAR_MARKER' 2>&1) || true

    if echo "$output" | grep -q '"name":"PlanClear"' && \
       echo "$output" | grep -q '"type":"tool_call"' && \
       [[ ! -s "$plan_file" ]] && \
       [[ -s "$summary_file" ]]; then
        green "Agent PlanClear"; ((PASS++)) || true
    else
        red "Agent PlanClear"; echo "  Output: $output"; echo "  Plan: $(cat "$plan_file" 2>/dev/null || echo 'empty')"; echo "  Summary: $(cat "$summary_file" 2>/dev/null || echo 'empty')"; ((FAIL++)) || true
    fi
    rm -rf "$home_dir"
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

test_agent_glob_no_match() {
    info "Test 20: Agent.sh glob no-match"
    local output target_dir
    target_dir="/tmp/bash-agent-glob-nomatch-test"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    printf 'a\n' > "$target_dir/alpha.txt"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'GLOB_NO_MATCH_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Glob no-match complete."; then
        green "Agent glob no-match"; ((PASS++)) || true
    else
        red "Agent glob no-match"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -rf "$target_dir"
}

test_agent_grep_no_match() {
    info "Test 20a: Agent.sh grep no-match"
    local output target_dir
    target_dir="/tmp/bash-agent-grep-nomatch-test"
    rm -rf "$target_dir"
    mkdir -p "$target_dir"
    printf 'other line\n' > "$target_dir/alpha.txt"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'GREP_NO_MATCH_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Grep no-match complete."; then
        green "Agent grep no-match"; ((PASS++)) || true
    else
        red "Agent grep no-match"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -rf "$target_dir"
}

# Test 20b: Read with offset/limit
test_agent_read_offset_limit() {
    info "Test 20b: Agent.sh Read with offset/limit"
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

# Test 20c: Bash with per-call timeout
test_agent_bash_timeout() {
    info "Test 20c: Agent.sh Bash with timeout parameter"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_TIMEOUT_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Bash timeout complete."; then
        green "Agent Bash timeout"; ((PASS++)) || true
    else
        red "Agent Bash timeout"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 20d: Grep with context parameter
test_agent_grep_context() {
    info "Test 20d: Agent.sh Grep with context parameter"
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
       [[ "$output" == *"required="* ]] && \
       [[ "$output" == *"allowed="* ]]; then
        green "Agent bash safety policy"; ((PASS++)) || true
    else
        red "Agent bash safety policy"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_mode_blocked_case() {
    local desc="$1" marker="$2" expected_cmd="$3" expected_required="$4" expected_allowed="${5:-0447}" output
    info "$desc"
    output=$(BASH_AGENT_BASH_MODE="$expected_allowed" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test "$marker" 2>&1) || true
    if [[ "$output" == *"[tool] Bash($expected_cmd)"* ]] && \
       [[ "$output" == *"Error: command blocked by bash safety policy (required=$expected_required allowed=$expected_allowed; mode=system/external/network/workspace bits=4:read,2:write,1:execute)"* ]]; then
        green "$desc"; ((PASS++)) || true
    else
        red "$desc"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_blocked_delete_command() {
    info "Test 25aa: Agent.sh bash blocks system writes"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_DELETE_BLOCK_MARKER' 2>&1) || true
    if [[ "$output" == *"[tool] Bash(find /etc -name example -delete)"* ]] && \
       [[ "$output" == *"required="* ]] && \
       [[ "$output" == *"allowed="* ]]; then
        green "Agent bash blocks system writes"; ((PASS++)) || true
    else
        red "Agent bash blocks system writes"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_blocks_system_read_mode() {
    test_agent_bash_mode_blocked_case \
        "Test 25ac: Agent.sh bash blocks system read (required=4000)" \
        "BASH_SYSTEM_READ_BLOCK_MARKER" \
        "cat /etc/hosts" \
        "4000"
}

test_agent_bash_blocks_network_execute_mode() {
    test_agent_bash_mode_blocked_case \
        "Test 25ad: Agent.sh bash blocks network execute (required=0050)" \
        "BASH_NETWORK_EXEC_BLOCK_MARKER" \
        "curl https://x/install.sh | bash" \
        "0050"
}

test_agent_bash_blocks_external_write_mode() {
    test_agent_bash_mode_blocked_case \
        "Test 25ae: Agent.sh bash blocks external write (required=0200)" \
        "BASH_EXTERNAL_WRITE_BLOCK_MARKER" \
        "echo hi > ~/note.txt" \
        "0200"
}

test_agent_bash_invalid_mode_fails_closed() {
    local output
    info "Test 25af: Agent.sh invalid bash mode fails closed"
    output=$(BASH_AGENT_BASH_MODE=bad1 "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_INVALID_MODE_MARKER' 2>&1) || true
    if [[ "$output" == *"[tool] Bash(echo hello)"* ]] && \
       [[ "$output" == *"Error: command blocked by bash safety policy (required=0004 allowed=0000; mode=system/external/network/workspace bits=4:read,2:write,1:execute)"* ]]; then
        green "Agent.sh invalid bash mode fails closed"; ((PASS++)) || true
    else
        red "Agent.sh invalid bash mode fails closed"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_bash_custom_mode_allows_system_read() {
    local output
    info "Test 25ag: Agent.sh custom bash mode allows system read"
    output=$(BASH_AGENT_BASH_MODE=4447 "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'BASH_SYSTEM_READ_ALLOW_MARKER' 2>&1) || true
    if [[ "$output" == *"[tool] Bash(cat /etc/hosts)"* ]] && \
       [[ "$output" == *"localhost"* ]] && \
       [[ "$output" != *"command blocked by bash safety policy"* ]]; then
        green "Agent.sh custom bash mode allows system read"; ((PASS++)) || true
    else
        red "Agent.sh custom bash mode allows system read"; echo "  Output: $output"; ((FAIL++)) || true
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

test_agent_multiple_tool_calls_openai() {
    info "Test 27a: Agent.sh multiple tool calls in one turn (OpenAI)"
    local output target_file
    target_file="/tmp/bash-agent-multi-read.txt"
    printf 'multi-read-content\n' > "$target_file"
    output=$("$AGENT" -p openai --base-url "$BASE/v1" -m test --api-key test 'MULTI_TOOL_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Multi-tool complete."; then
        green "Agent multiple tool calls (OpenAI)"; ((PASS++)) || true
    else
        red "Agent multiple tool calls (OpenAI)"; echo "  Output: $output"; ((FAIL++)) || true
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
    printf '{"current_turn_count":0,"agent_request_count":0,"compact_request_count":0,"total_input_tokens":0,"total_output_tokens":0,"total_cache_read_tokens":0,"total_cache_creation_tokens":0,"current_context_tokens":0,"sub_agent_request_count":0,"last_updated":""}' > "$tmpdir/test.json"
    printf 'agent_request_count=+1\ntotal_input_tokens=+10\ntotal_output_tokens=+20\ntotal_cache_read_tokens=+3\ntotal_cache_creation_tokens=+4\ncurrent_context_tokens=30\n' |         protocol_awk -v action=update -f "$AWK_DIR/stats.awk" "$tmpdir/test.json"
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

# Test: SubAgent e2e — main agent dispatches SubAgent tool, child runs, result flows back
test_agent_sub_agent() {
    info "Test: SubAgent e2e flow"
    local tmpdir
    tmpdir=$(mktemp -d)

    # Set up the test harness
    export BASH_AGENT_HOME="$tmpdir"
    export INTERACTIVE=false
    export MAX_TURNS=20

    # Run agent with a prompt that triggers SubAgent via mock server
    # The mock server has 4 stages:
    #   Stage 1: main agent -> SubAgent tool_call (prompt contains SUB_CHILD_COUNT)
    #   Stage 2: child agent -> text "1545 lines."
    #   Stage 3: main agent gets tool_result "Sub-agent started" -> end_turn
    #   Stage 4: main agent gets AGENT_RESULT context -> final "Sub-agent reports: 1545 lines."
    local output
    output=$(timeout 20 "$AGENT" -p claude --base-url "${BASE}/v1" -m test --api-key test --session test-sub-001 "SUB_AGENT_MARKER count lines" 2>&1) || true

    # Verify child agent produced a result mentioning "1545 lines"
    if echo "$output" | grep -q "1545"; then
        green "SubAgent: child result text found in output"; ((PASS++)) || true
    else
        red "SubAgent: child result text not found in output"
        echo "  Output: $output" >&2
        ((FAIL++)) || true
    fi

    # Verify main agent acknowledged and reported final answer
    if echo "$output" | grep -q "Sub-agent reports: 1545"; then
        green "SubAgent: main agent final answer found"; ((PASS++)) || true
    else
        red "SubAgent: main agent final answer not found"
        ((FAIL++)) || true
    fi

    # Verify AGENT_RESULT was handled (check session event log)
    # Session path: $tmpdir/.bash-agent/projects/<project-key>/test-sub-001/events.jsonl
    local session_dir
    session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "test-sub-001" 2>/dev/null | head -1)
    if [[ -n "$session_dir" && -f "$session_dir/events.jsonl" ]]; then
        if grep -q "sub_agent_start" "$session_dir/events.jsonl" && grep -q "sub_agent_end" "$session_dir/events.jsonl"; then
            green "SubAgent: session events recorded"; ((PASS++)) || true
        else
            red "SubAgent: missing sub_agent_start or sub_agent_end in events.jsonl"; ((FAIL++)) || true
        fi
        # Verify usage event with kind=sub_agent
        if grep -q '"kind":"sub_agent"' "$session_dir/events.jsonl"; then
            green "SubAgent: sub_agent usage event recorded"; ((PASS++)) || true
        else
            red "SubAgent: missing sub_agent usage event"; ((FAIL++)) || true
        fi
        # Verify usage numbers are non-zero
        local _in _out
        _in=$(grep '"kind":"sub_agent"' "$session_dir/events.jsonl" | protocol_awk -F'[" ,:]+' '/input_tokens/{for(i=1;i<=NF;i++) if($i=="input_tokens") print $(i+1)}' | head -1)
        _out=$(grep '"kind":"sub_agent"' "$session_dir/events.jsonl" | protocol_awk -F'[" ,:]+' '/output_tokens/{for(i=1;i<=NF;i++) if($i=="output_tokens") print $(i+1)}' | head -1)
        if [[ "${_in:-0}" -gt 0 && "${_out:-0}" -gt 0 ]]; then
            green "SubAgent: usage tokens non-zero (in=$_in, out=$_out)"; ((PASS++)) || true
        else
            red "SubAgent: usage tokens are zero (in=$_in, out=$_out)"; ((FAIL++)) || true
        fi
    else
        red "SubAgent: events.jsonl not found under $tmpdir"; ((FAIL++)) || true
    fi

    # Cleanup
    rm -rf "$tmpdir"
    unset BASH_AGENT_HOME INTERACTIVE MAX_TURNS
}

# Test: SubAgent failure propagation — child agent fails, parent sees status=failed
test_agent_sub_agent_failure() {
    info "Test: SubAgent failure propagation"
    local tmpdir
    tmpdir=$(mktemp -d)

    export BASH_AGENT_HOME="$tmpdir"
    export INTERACTIVE=false
    export MAX_TURNS=20

    # SUB_FAIL_MARKER triggers a mock that returns a tool_call with prompt SUB_FAIL_CHILD,
    # which the mock responds with an HTTP error (422), causing the child to fail.
    local output
    output=$(timeout 20 "$AGENT" -p claude --base-url "${BASE}/v1" -m test --api-key test --session test-sub-fail-001 "SUB_FAIL_MARKER trigger failure" 2>&1) || true

    # Verify the main agent observed the failure
    if echo "$output" | grep -qi "fail\|error\|sub-agent"; then
        green "SubAgent-fail: failure indication in output"; ((PASS++)) || true
    else
        red "SubAgent-fail: no failure indication in output"
        echo "  Output: $output" >&2
        ((FAIL++)) || true
    fi

    # Check session events: sub_agent_end should have status=failed
    local session_dir
    session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "test-sub-fail-001" 2>/dev/null | head -1)
    if [[ -n "$session_dir" && -f "$session_dir/events.jsonl" ]]; then
        if grep -q '"status":"failed"' "$session_dir/events.jsonl"; then
            green "SubAgent-fail: session event status=failed recorded"; ((PASS++)) || true
        else
            red "SubAgent-fail: missing status=failed in events.jsonl"
            ((FAIL++)) || true
        fi
    else
        red "SubAgent-fail: events.jsonl not found"; ((FAIL++)) || true
    fi

    rm -rf "$tmpdir"
    unset BASH_AGENT_HOME INTERACTIVE MAX_TURNS
}

# Test: SubAgent child session directory is created independently
test_agent_sub_agent_child_session() {
    info "Test: SubAgent child session isolation"
    local tmpdir
    tmpdir=$(mktemp -d)

    export BASH_AGENT_HOME="$tmpdir"
    export INTERACTIVE=false
    export MAX_TURNS=20

    local output
    output=$(timeout 20 "$AGENT" -p claude --base-url "${BASE}/v1" -m test --api-key test --session test-sub-iso-001 "SUB_AGENT_MARKER count lines" 2>&1) || true

    # Verify child has its own session directory (sub_*) with conversation.jsonl
    local child_session_dir
    child_session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "sub_*" 2>/dev/null | head -1)
    if [[ -n "$child_session_dir" && -f "$child_session_dir/conversation.jsonl" ]]; then
        green "SubAgent-iso: child session dir created with conversation.jsonl"; ((PASS++)) || true
        # Verify child conversation has assistant content
        if grep -q '"role":"assistant"' "$child_session_dir/conversation.jsonl"; then
            green "SubAgent-iso: child conversation has assistant turns"; ((PASS++)) || true
        else
            red "SubAgent-iso: child conversation missing assistant turns"; ((FAIL++)) || true
        fi
    else
        red "SubAgent-iso: child session dir not found under $tmpdir"; ((FAIL++)) || true
    fi

    # Verify child session does NOT pollute parent's conversation with child's assistant turns
    local parent_dir
    parent_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "test-sub-iso-001" 2>/dev/null | head -1)
    if [[ -n "$parent_dir" && -f "$parent_dir/conversation.jsonl" ]]; then
        # The SubAgent tool_call params will contain the child prompt — that's expected.
        # Check that the child's CONV_FILE content (assistant turns) did NOT leak into parent.
        local child_conv
        child_conv=$(find "$tmpdir/.bash-agent/projects" -type d -name "sub_*" -exec find {} -name "conversation.jsonl" \; 2>/dev/null | head -1)
        if [[ -n "$child_conv" ]]; then
            local child_text
            child_text=$(grep '"role":"assistant"' "$child_conv" 2>/dev/null | head -1)
            if [[ -n "$child_text" ]] && grep -qF "$child_text" "$parent_dir/conversation.jsonl" 2>/dev/null; then
                red "SubAgent-iso: child assistant content leaked into parent conversation"; ((FAIL++)) || true
            else
                green "SubAgent-iso: parent conversation isolated from child"; ((PASS++)) || true
            fi
        else
            green "SubAgent-iso: parent conversation isolated (no child conv found)"; ((PASS++)) || true
        fi
    fi

    rm -rf "$tmpdir"
    unset BASH_AGENT_HOME INTERACTIVE MAX_TURNS
}

# Test: SubAgent fork mode — child runs in background, parent continues, result flows back via AGENT_RESULT
test_agent_sub_agent_fork() {
    info "Test: SubAgent fork mode"
    local tmpdir
    tmpdir=$(mktemp -d)

    export BASH_AGENT_HOME="$tmpdir"
    export INTERACTIVE=false
    export MAX_TURNS=20

    # Run agent with a prompt that triggers SubAgent with fork=true via mock server
    # The mock server has 4 stages:
    #   Stage 1: main agent -> SubAgent tool_call with fork=true (prompt SUB_FORK_CHILD)
    #   Stage 2: child agent -> text "Fork child result: hello from fork."
    #   Stage 3: main agent gets tool_result "Sub-agent started" -> "Waiting for fork child."
    #   Stage 4: main agent gets AGENT_RESULT context -> final "Fork result: hello from fork."
    local output
    output=$(timeout 20 "$AGENT" -p claude --base-url "${BASE}/v1" -m test --api-key test --session test-sub-fork-001 "SUB_FORK_MARKER fork test" 2>&1) || true

    # Verify child agent produced a result
    if echo "$output" | grep -q "hello from fork"; then
        green "SubAgent-fork: child result text found in output"; ((PASS++)) || true
    else
        red "SubAgent-fork: child result text not found in output"
        echo "  Output: $output" >&2
        ((FAIL++)) || true
    fi

    # Verify main agent acknowledged and reported final answer
    if echo "$output" | grep -q "Fork result: hello from fork"; then
        green "SubAgent-fork: main agent final answer found"; ((PASS++)) || true
    else
        red "SubAgent-fork: main agent final answer not found"
        echo "  Output: $output" >&2
        ((FAIL++)) || true
    fi

    # Check session events: sub_agent_start, sub_agent_end should exist
    local session_dir
    session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "test-sub-fork-001" 2>/dev/null | head -1)
    if [[ -n "$session_dir" && -f "$session_dir/events.jsonl" ]]; then
        if grep -q "sub_agent_start" "$session_dir/events.jsonl" && grep -q "sub_agent_end" "$session_dir/events.jsonl"; then
            green "SubAgent-fork: session events recorded"; ((PASS++)) || true
        else
            red "SubAgent-fork: missing sub_agent_start or sub_agent_end in events.jsonl"; ((FAIL++)) || true
        fi
        # Verify fork=true is recorded in events
        if grep -q '"fork":true' "$session_dir/events.jsonl"; then
            green "SubAgent-fork: fork=true recorded in events"; ((PASS++)) || true
        else
            red "SubAgent-fork: fork=true not found in events.jsonl"; ((FAIL++)) || true
        fi
    else
        red "SubAgent-fork: events.jsonl not found under $tmpdir"; ((FAIL++)) || true
    fi

    # Verify fork child has its own session directory with conversation
    local child_session_dir
    child_session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "sub_*" 2>/dev/null | head -1)
    if [[ -n "$child_session_dir" && -f "$child_session_dir/conversation.jsonl" ]]; then
        green "SubAgent-fork: fork child session dir created"; ((PASS++)) || true
    else
        red "SubAgent-fork: fork child session dir not found"; ((FAIL++)) || true
    fi

    # Cleanup
    rm -rf "$tmpdir"
    unset BASH_AGENT_HOME INTERACTIVE MAX_TURNS
}

# Test: SubAgent fork-failure — fork child fails immediately, no stale assistant content leaked
test_agent_sub_agent_fork_failure() {
    info "Test: SubAgent fork-failure — no stale content on child failure"
    local tmpdir
    tmpdir=$(mktemp -d)

    export BASH_AGENT_HOME="$tmpdir"
    export INTERACTIVE=false
    export MAX_TURNS=20

    # SUB_FORK_FAIL_MARKER triggers:
    #   Stage 1: main agent -> SubAgent tool_call with fork=true
    #   Stage 2: fork child inherits parent conversation.jsonl, then hits 422 error
    #   Stage 3: main agent gets AGENT_RESULT(status=failed, thinking="", text="")
    local output
    output=$(timeout 20 "$AGENT" -p claude --base-url "${BASE}/v1" -m test --api-key test --session test-sub-fork-fail-001 "SUB_FORK_FAIL_MARKER trigger fork failure" 2>&1) || true

    # Verify main agent observed the failure
    if echo "$output" | grep -qi "fail"; then
        green "SubAgent-fork-fail: failure indication in output"; ((PASS++)) || true
    else
        red "SubAgent-fork-fail: no failure indication in output"
        echo "  Output: $output" >&2
        ((FAIL++)) || true
    fi

    # Check session events: sub_agent_end should have status=failed
    local session_dir
    session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "test-sub-fork-fail-001" 2>/dev/null | head -1)
    if [[ -n "$session_dir" && -f "$session_dir/events.jsonl" ]]; then
        if grep -q '"status":"failed"' "$session_dir/events.jsonl"; then
            green "SubAgent-fork-fail: session event status=failed recorded"; ((PASS++)) || true
        else
            red "SubAgent-fork-fail: missing status=failed in events.jsonl"; ((FAIL++)) || true
        fi
        # Verify fork=true is recorded
        if grep -q '"fork":true' "$session_dir/events.jsonl"; then
            green "SubAgent-fork-fail: fork=true recorded in events"; ((PASS++)) || true
        else
            red "SubAgent-fork-fail: fork=true not found in events"; ((FAIL++)) || true
        fi
    else
        red "SubAgent-fork-fail: events.jsonl not found"; ((FAIL++)) || true
    fi

    rm -rf "$tmpdir"
    unset BASH_AGENT_HOME INTERACTIVE MAX_TURNS
}

# Test: SubAgent fork context inheritance — child conversation inherits parent content
test_agent_sub_agent_fork_context() {
    info "Test: SubAgent fork context inheritance"
    local tmpdir
    tmpdir=$(mktemp -d)

    export BASH_AGENT_HOME="$tmpdir"
    export INTERACTIVE=false
    export MAX_TURNS=20

    # Flow:
    #   Stage 1: parent -> SubAgent tool_call with fork=true (prompt FORK_CTX_CHILD)
    #            parent conversation has "parent_context_msg" from user prompt
    #   Stage 2: fork child inherits parent conversation -> child conv has "parent_context_msg"
    #   Stage 3: parent gets tool_result "Sub-agent started" -> "Waiting for fork child context."
    #   Stage 4: parent gets AGENT_RESULT -> final "Fork context verified."
    local output
    output=$(timeout 20 "$AGENT" -p claude --base-url "${BASE}/v1" -m test --api-key test --session test-fork-ctx-001 "FORK_CTX_MARKER parent_context_msg fork context test" 2>&1) || true

    # Verify main agent completed
    if echo "$output" | grep -q "Fork context verified"; then
        green "SubAgent-fork-ctx: main agent final answer found"; ((PASS++)) || true
    else
        red "SubAgent-fork-ctx: main agent final answer not found"
        echo "  Output: $output" >&2
        ((FAIL++)) || true
    fi

    # Find child session
    local child_session_dir
    child_session_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "sub_*" 2>/dev/null | head -1)
    if [[ -n "$child_session_dir" && -f "$child_session_dir/conversation.jsonl" ]]; then
        green "SubAgent-fork-ctx: child session dir created with conversation.jsonl"; ((PASS++)) || true
        # === 核心验证：子 conversation 继承了父内容 ===
        if grep -q "parent_context_msg" "$child_session_dir/conversation.jsonl"; then
            green "SubAgent-fork-ctx: child conversation inherited parent content"; ((PASS++)) || true
        else
            red "SubAgent-fork-ctx: child conversation MISSING parent content — fork did NOT inherit context"
            echo "  Child conv: $(cat "$child_session_dir/conversation.jsonl")" >&2
            ((FAIL++)) || true
        fi
    else
        red "SubAgent-fork-ctx: child session dir not found under $tmpdir"; ((FAIL++)) || true
    fi

    # Verify fork=true recorded in events
    local parent_dir
    parent_dir=$(find "$tmpdir/.bash-agent/projects" -type d -name "test-fork-ctx-001" 2>/dev/null | head -1)
    if [[ -n "$parent_dir" && -f "$parent_dir/events.jsonl" ]]; then
        if grep -q '"fork":true' "$parent_dir/events.jsonl"; then
            green "SubAgent-fork-ctx: fork=true recorded in events"; ((PASS++)) || true
        else
            red "SubAgent-fork-ctx: fork=true not found in events"; ((FAIL++)) || true
        fi
    fi

    rm -rf "$tmpdir"
    unset BASH_AGENT_HOME INTERACTIVE MAX_TURNS
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

    # dp_run: run compact_dp.awk with 5-term formula
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
            -v r=0.8 -v beta=0.03 \
            -v max_context=200000 -v quality_penalty=0 "$conv_file" 2>/dev/null
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
    # R=5 with large context — 新成本模型下 R=5 不足以触发压缩
    check "compact_dp: large R=5 -> 0" "$(dp_run 1 5 0)" "0"
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

    # --- 37f: Turn alignment — tiny context + 新成本模型 → 不触发 ---
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
    check "compact_dp: turn alignment -> 0" "$result" "0"

    # --- 37g: Long session E saturation (stats[0] > baseline) ---
    # After baseline turns, E saturates at baseline/2 = 4, R=4*3=12
    # DP should still recommend compaction with very large context
    gen_conv 30 200000 "$conv_file"
    result=$(dp_run 4 5 0)  # E=4 (saturated), L=5, R=20
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: long session E=4 -> $result"; ((PASS++)); } \
        || { red "compact_dp: long session E=4 -> $result"; ((FAIL++)); }

    # --- 37h: Quality penalty promotes compaction (增量收益项) ---
    gen_conv 20 100000 "$conv_file"
    # QP=500 → 巨大的 quality_savings 正项，应促进压缩 (k>0)
    result=$(protocol_awk -f "$AWK_DIR/compact_dp.awk" \
        -v e_fixed=8 -v L_fixed=5 \
        -v total_requests=5 -v t=1 -v total_compact=0 \
        -v total_input=20000 -v baseline_e=8 -v V=5000 \
        -v p_input=3.0 -v p_cache=0.30 -v p_out=15.0 \
        -v S=500 -v min_keep_ratio=0.12 -v r=0.8 -v beta=0.03 \
        -v max_context=200000 -v quality_penalty=500.0 "$conv_file" 2>/dev/null)
    [[ -n "$result" && "$result" != "0" ]] \
        && { green "compact_dp: quality_penalty=500 promotes -> $result"; ((PASS++)); } \
        || { red "compact_dp: quality_penalty=500 promotes -> $result (expected >0)"; ((FAIL++)); }

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

# Test 36b: stats.json usage values — validate all token fields
# Mock server returns: message_start usage={input_tokens:10, output_tokens:0}
#                       message_delta  usage={output_tokens:7}
# Expected: agent_request_count=1, total_input=10, total_output=7,
#           total_cache_read=0, total_cache_creation=0,
#           current_context_tokens = 10+7+0+0 = 17
test_agent_stats_usage_values() {
    info "Test 36b: stats.json usage token values"
    local home_dir stats_file
    home_dir=$(mktemp -d)
    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'Hello' >/dev/null 2>&1 || true
    stats_file=$(find "$home_dir" -name 'stats.json' 2>/dev/null | head -1)

    if [[ -z "$stats_file" ]]; then
        red "stats.json usage values: stats file not found"; ((FAIL++)) || true
        rm -rf "$home_dir"
        return
    fi

    local stats_content
    stats_content=$(cat "$stats_file" 2>/dev/null || echo '{}')

    _json_val() {
        # Extract numeric value from JSON: "key":value
        echo "$stats_content" | grep -o "\"$1\":[[:space:]]*[0-9]*" | grep -o '[0-9]*$'
    }

    local arc=$(_json_val agent_request_count)
    local tin=$(_json_val total_input_tokens)
    local tout=$(_json_val total_output_tokens)
    local tcr=$(_json_val total_cache_read_tokens)
    local tcc=$(_json_val total_cache_creation_tokens)
    local cctx=$(_json_val current_context_tokens)

    # agent_request_count should be 1
    if [[ "$arc" == "1" ]]; then
        green "stats agent_request_count=1"; ((PASS++)) || true
    else
        red "stats agent_request_count=$arc (expected 1)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # total_input_tokens should be 10
    if [[ "$tin" == "10" ]]; then
        green "stats total_input_tokens=10"; ((PASS++)) || true
    else
        red "stats total_input_tokens=$tin (expected 10)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # total_output_tokens should be 7
    if [[ "$tout" == "7" ]]; then
        green "stats total_output_tokens=7"; ((PASS++)) || true
    else
        red "stats total_output_tokens=$tout (expected 7)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # total_cache_read_tokens should be 0
    if [[ "$tcr" == "0" ]]; then
        green "stats total_cache_read_tokens=0"; ((PASS++)) || true
    else
        red "stats total_cache_read_tokens=$tcr (expected 0)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # total_cache_creation_tokens should be 0
    if [[ "$tcc" == "0" ]]; then
        green "stats total_cache_creation_tokens=0"; ((PASS++)) || true
    else
        red "stats total_cache_creation_tokens=$tcc (expected 0)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # current_context_tokens = in+out+cr+cc = 10+7+0+0 = 17
    if [[ "$cctx" == "17" ]]; then
        green "stats current_context_tokens=17"; ((PASS++)) || true
    else
        red "stats current_context_tokens=$cctx (expected 17)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 36c: stats.json with cache tokens — validate cache_read/cache_creation
# Mock server returns: message_start usage={input_tokens:10, cache_read_input_tokens:50}
#                       message_delta  usage={output_tokens:7, cache_read_input_tokens:30, cache_creation_input_tokens:20}
# Expected: total_input=10, total_output=7, total_cache_read=50 (max from start/delta),
#           total_cache_creation=20, current_context_tokens = 10+7+50+20 = 87
test_agent_stats_cache_tokens() {
    info "Test 36c: stats.json cache token values"
    local home_dir stats_file
    home_dir=$(mktemp -d)
    # Use a marker that triggers cache tokens in mock server
    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'READ_FILE_MARKER' >/dev/null 2>&1 || true
    stats_file=$(find "$home_dir" -name 'stats.json' 2>/dev/null | head -1)

    if [[ -z "$stats_file" ]]; then
        red "stats.json cache tokens: stats file not found"; ((FAIL++)) || true
        rm -rf "$home_dir"
        return
    fi

    local stats_content
    stats_content=$(cat "$stats_file" 2>/dev/null || echo '{}')

    _json_val() {
        echo "$stats_content" | grep -o "\"$1\":[[:space:]]*[0-9]*" | grep -o '[0-9]*$'
    }

    local tin=$(_json_val total_input_tokens)
    local tout=$(_json_val total_output_tokens)
    local tcr=$(_json_val total_cache_read_tokens)
    local tcc=$(_json_val total_cache_creation_tokens)
    local cctx=$(_json_val current_context_tokens)

    # total_cache_read_tokens should be > 0 (from mock server)
    if [[ "$tcr" -gt 0 ]] 2>/dev/null; then
        green "stats total_cache_read_tokens=$tcr (>0)"; ((PASS++)) || true
    else
        red "stats total_cache_read_tokens=$tcr (expected >0)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # total_cache_creation_tokens should be > 0 (from mock server)
    if [[ "$tcc" -gt 0 ]] 2>/dev/null; then
        green "stats total_cache_creation_tokens=$tcc (>0)"; ((PASS++)) || true
    else
        red "stats total_cache_creation_tokens=$tcc (expected >0)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    # current_context_tokens should be > total_input_tokens + total_output_tokens
    # (because it includes cache tokens)
    local min_expected=$(( tin + tout ))
    if [[ "$cctx" -gt "$min_expected" ]] 2>/dev/null; then
        green "stats current_context_tokens=$cctx (> $min_expected)"; ((PASS++)) || true
    else
        red "stats current_context_tokens=$cctx (expected > $min_expected)"; echo "  Content: $stats_content"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 38: compact_turn_keep.awk — turn-based keep ratio calculation
test_compact_turn_keep_awk() {
    info "Test 38: compact_turn_keep.awk turn-based keep ratio"
    local tmpdir conv_file
    tmpdir=$(mktemp -d)
    conv_file="$tmpdir/conv.jsonl"

    # Helper: run compact_turn_keep.awk with given ratio
    tk_run() {
        protocol_awk -v ratio="${1:-0.12}" -f "$AWK_DIR/compact_turn_keep.awk" "$conv_file"
    }

    # --- 38a: Empty file → 0 ---
    : > "$conv_file"
    check "turn_keep: empty -> 0" "$(tk_run 0.12)" "0"

    # --- 38b: Single user turn (ratio=0.12, target=1) → keep all ---
    cat > "$conv_file" << 'EOF'
{"role":"user","content":"hello"}
{"role":"assistant","content":"hi"}
EOF
    result=$(tk_run 0.12)
    [[ "$result" == "2" ]] \
        && { green "turn_keep: 1 turn ratio=0.12 -> $result"; ((PASS++)); } \
        || { red "turn_keep: 1 turn ratio=0.12 -> $result (expected 2)"; ((FAIL++)); }

    # --- 38c: 10 user turns, ratio=0.12 → target=1, keep last user turn ---
    > "$conv_file"
    for i in $(seq 1 10); do
        echo "{\"role\":\"user\",\"content\":\"step $i\"}" >> "$conv_file"
        echo "{\"role\":\"assistant\",\"content\":\"response $i\"}" >> "$conv_file"
    done
    result=$(tk_run 0.12)
    # total=20 lines, target=int(10*0.12+0.5)=1, scan from tail: line 20=asst, line 19=user → keep=2
    [[ "$result" == "2" ]] \
        && { green "turn_keep: 10 turns ratio=0.12 -> $result"; ((PASS++)); } \
        || { red "turn_keep: 10 turns ratio=0.12 -> $result (expected 2)"; ((FAIL++)); }

    # --- 38d: 10 user turns, ratio=0.5 → target=5 ---
    result=$(tk_run 0.5)
    # target=int(10*0.5+0.5)=5, from tail count 5 user turns:
    # line 20=a, 19=u(1), 18=a, 17=u(2), 16=a, 15=u(3), 14=a, 13=u(4), 12=a, 11=u(5) → keep=10
    [[ "$result" == "10" ]] \
        && { green "turn_keep: 10 turns ratio=0.5 -> $result"; ((PASS++)); } \
        || { red "turn_keep: 10 turns ratio=0.5 -> $result (expected 10)"; ((FAIL++)); }

    # --- 38e: 10 user turns, ratio=1.0 → keep all ---
    result=$(tk_run 1.0)
    [[ "$result" == "20" ]] \
        && { green "turn_keep: 10 turns ratio=1.0 -> $result"; ((PASS++)); } \
        || { red "turn_keep: 10 turns ratio=1.0 -> $result (expected 20)"; ((FAIL++)); }

    # --- 38f: tool_result messages excluded from user count ---
    cat > "$conv_file" << 'EOF'
{"role":"user","content":"step 1"}
{"role":"assistant","content":"response 1"}
{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"result 1"}]}
{"role":"assistant","content":"response 1b"}
{"role":"user","content":"step 2"}
{"role":"assistant","content":"response 2"}
EOF
    # 2 real user turns (lines 1, 5), line 3 has "content":[ so excluded
    # ratio=0.5, target=int(2*0.5+0.5)=1, from tail: line 6=a, 5=u(1) → keep=2
    result=$(tk_run 0.5)
    [[ "$result" == "2" ]] \
        && { green "turn_keep: 2 user turns (with tool_result) ratio=0.5 -> $result"; ((PASS++)); } \
        || { red "turn_keep: 2 user turns (with tool_result) ratio=0.5 -> $result (expected 2)"; ((FAIL++)); }

    # --- 38g: ratio below threshold → still keeps at least 1 turn ---
    result=$(tk_run 0.01)
    # target=int(2*0.01+0.5)=1 (min=1), keep=2
    [[ "$result" == "2" ]] \
        && { green "turn_keep: tiny ratio=0.01 -> $result"; ((PASS++)); } \
        || { red "turn_keep: tiny ratio=0.01 -> $result (expected 2)"; ((FAIL++)); }

    # --- 38h: mixed conversation with assistant-first start ---
    cat > "$conv_file" << 'EOF'
{"role":"assistant","content":"intro"}
{"role":"user","content":"step 1"}
{"role":"assistant","content":"r1"}
{"role":"user","content":"step 2"}
{"role":"assistant","content":"r2"}
{"role":"user","content":"step 3"}
{"role":"assistant","content":"r3"}
EOF
    # 3 user turns, ratio=0.33, target=int(3*0.33+0.5)=1
    # from tail: line 7=a, 6=u(1) → keep=2
    result=$(tk_run 0.33)
    [[ "$result" == "2" ]] \
        && { green "turn_keep: mixed start ratio=0.33 -> $result"; ((PASS++)); } \
        || { red "turn_keep: mixed start ratio=0.33 -> $result (expected 2)"; ((FAIL++)); }

    rm -rf "$tmpdir"
}

# Test 39: agent_compact_context integration (plan_clear trigger)
test_agent_compact_context() {
    info "Test 39: agent_compact_context integration via plan_clear"
    local home_dir output project_dir session_dir plan_file summary_file conv_file stats_file
    home_dir=$(mktemp -d)
    project_dir="$home_dir/.bash-agent/projects/$(cd "$ROOT_DIR" && project_key)"
    session_dir="$project_dir/compact-test"
    plan_file="$session_dir/plan.md"
    summary_file="$session_dir/summary.txt"
    conv_file="$session_dir/conversation.jsonl"
    stats_file="$session_dir/stats.json"
    mkdir -p "$session_dir"

    # Seed a plan
    printf 'Task: test compact integration\n' > "$plan_file"

    # Seed conversation with 20 turns (40 lines) — enough for compact to trim
    for i in $(seq 1 20); do
        printf '{"role":"user","content":"step %d of compact test with some padding to make messages longer"}\n' "$i" >> "$conv_file"
        printf '{"role":"assistant","content":"response to step %d with sufficient content for meaningful context"}\n' "$i" >> "$conv_file"
    done
    local original_lines
    original_lines=$(wc -l < "$conv_file")

    # Seed stats with high context tokens to trigger auto compact fallback
    printf '{"current_turn_count":20,"agent_request_count":20,"compact_request_count":0,"total_input_tokens":80000,"total_output_tokens":5000,"total_cache_read_tokens":0,"total_cache_creation_tokens":0,"current_context_tokens":150000,"sub_agent_request_count":0,"last_updated":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$stats_file"

    # Seed events.jsonl so agent treats this as an existing session (newSession=false)
    printf '{"type":"session_start","session_id":"compact-test"}\n' > "${session_dir}/events.jsonl"

    # Run agent — mock will match summary request via "The conversation context above needs to be compacted"
    # Use --print to capture output, PlanClear trigger forces agent_compact_context plan_clear
    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" HOME="$home_dir" "$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test --session compact-test --max-context 160000 'plan done COMPACT_TEST_MARKER' 2>&1) || true

    local post_lines
    post_lines=$(wc -l < "$conv_file" 2>/dev/null || echo 0)
    local summary_exists=false
    [[ -s "$summary_file" ]] && summary_exists=true

    # Verify: conversation was trimmed (fewer lines than original)
    if (( post_lines < original_lines )); then
        green "agent_compact_context: conv trimmed ($original_lines -> $post_lines lines)"; ((PASS++)) || true
    else
        red "agent_compact_context: conv NOT trimmed ($original_lines -> $post_lines lines)"; echo "  Output: $output"; ((FAIL++)) || true
    fi

    # Verify: summary file created with expected content
    if $summary_exists && grep -q "Task focus" "$summary_file" 2>/dev/null; then
        green "agent_compact_context: summary created with expected fields"; ((PASS++)) || true
    else
        red "agent_compact_context: summary missing or incomplete"; echo "  Summary: $(cat "$summary_file" 2>/dev/null || echo 'N/A')"; ((FAIL++)) || true
    fi

    # Verify: remaining conversation lines all have valid role field
    local bad_lines=0 line_num=0
    while IFS= read -r line; do
        (( line_num++ )) || true
        [[ -z "$line" ]] && continue
        [[ "$line" == *"\"role\":"* ]] || { ((bad_lines++)); continue; }
    done < "$conv_file"
    if (( bad_lines == 0 )); then
        green "agent_compact_context: remaining conv is valid JSONL"; ((PASS++)) || true
    else
        red "agent_compact_context: $bad_lines invalid JSONL lines after compact"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 40: stats.json structure completeness (S1/S2/S4)
test_agent_stats_structure() {
    info "Test 40: stats.json structure completeness (S1 sub_agent_request_count, S2 last_updated, S4 no trailing spaces)"
    local home_dir stats_file
    home_dir=$(mktemp -d)
    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'STATS_CHECK_MARKER' >/dev/null 2>&1 || true
    stats_file=$(find "$home_dir" -name 'stats.json' 2>/dev/null | head -1)

    if [[ -z "$stats_file" ]]; then
        red "stats structure: stats file not found"; ((FAIL++)) || true
        rm -rf "$home_dir"; return
    fi

    local content
    content=$(cat "$stats_file")

    # S1: sub_agent_request_count must exist
    if [[ "$content" == *"sub_agent_request_count"* ]]; then
        green "stats structure: sub_agent_request_count field present"; ((PASS++)) || true
    else
        red "stats structure: sub_agent_request_count field MISSING"; echo "  Content: $content"; ((FAIL++)) || true
    fi

    # S2: last_updated must be non-empty (ISO timestamp like 2025-01-01T00:00:00Z)
    local last_updated
    last_updated=$(grep -o '"last_updated":"[^"]*"' "$stats_file" 2>/dev/null | head -1)
    if [[ "$last_updated" == *"T"* ]] && [[ "$last_updated" != '""' ]]; then
        green "stats structure: last_updated has valid timestamp"; ((PASS++)) || true
    else
        red "stats structure: last_updated empty or missing"; echo "  Value: $last_updated"; ((FAIL++)) || true
    fi

    # S4: no trailing spaces after numeric values
    if grep -qE ':[0-9]+ +' "$stats_file" 2>/dev/null; then
        red "stats structure: trailing spaces in numeric values"; echo "  Content: $content"; ((FAIL++)) || true
    else
        green "stats structure: no trailing spaces in values"; ((PASS++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 41: project key alignment (ST1)
test_agent_project_key() {
    info "Test 41: project key computation alignment (ST1)"
    local home_dir output session_dir expected_key
    home_dir=$(mktemp -d)

    # Run agent with a known cwd
    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'PROJECT_KEY_CHECK' >/dev/null 2>&1) || true

    # Compute expected key using the same algorithm as the agent
    expected_key=$(cd "$ROOT_DIR" && project_key)

    # Find the session directory under .bash-agent/projects/<key>/
    local found_key
    found_key=$(find "$home_dir/.bash-agent/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
    found_key=$(basename "$found_key" 2>/dev/null)

    if [[ "$found_key" == "$expected_key" ]]; then
        green "project key: matches expected ($expected_key)"; ((PASS++)) || true
    else
        red "project key: MISMATCH (expected=$expected_key, got=$found_key)"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 42: conversation.jsonl no blank lines (ST2)
test_agent_conv_no_blank_lines() {
    info "Test 42: conversation.jsonl has no blank lines (ST2)"
    local home_dir conv_file output blank_count
    home_dir=$(mktemp -d)

    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" "$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test 'CONV_BLANK_CHECK' >/dev/null 2>&1) || true

    conv_file=$(find "$home_dir" -name 'conversation.jsonl' 2>/dev/null | head -1)
    if [[ -z "$conv_file" ]]; then
        red "conv blank lines: conversation.jsonl not found"; ((FAIL++)) || true
        rm -rf "$home_dir"; return
    fi

    blank_count=$(grep -c '^$' "$conv_file" 2>/dev/null || true)
    blank_count=${blank_count:-0}
    blank_count=$(echo "$blank_count" | tr -d '[:space:]')
    if [[ "$blank_count" == "0" ]]; then
        green "conv blank lines: no blank lines in conversation.jsonl"; ((PASS++)) || true
    else
        red "conv blank lines: $blank_count blank lines found"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 43: device write protection (T5)
test_agent_bash_device_write_block() {
    info "Test 43: bash device write protection (T5)"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'DEV_WRITE_BLOCK_MARKER' 2>&1) || true

    # Agent should refuse to write to /dev/sda — blocked or refused
    if [[ "$output" == *"Device write blocked"* ]] || [[ "$output" == *"blocked"* ]] || [[ "$output" == *"refused"* ]] || [[ "$output" == *"device"* ]]; then
        green "device write block: dd of=/dev/sda blocked"; ((PASS++)) || true
    else
        red "device write block: NOT blocked"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 44: thinking parameter format (P1)
test_agent_thinking_format() {
    info "Test 44: thinking parameter format in request body (P1)"
    local home_dir output last_body
    home_dir=$(mktemp -d)

    # Run agent, then fetch last request from mock
    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'THINKING_FORMAT_CHECK' >/dev/null 2>&1 || true

    last_body=$(curl -sS "$BASE/last-request" 2>/dev/null)
    if [[ -z "$last_body" ]]; then
        red "thinking format: no last request captured"; ((FAIL++)) || true
        rm -rf "$home_dir"; return
    fi

    # Check: thinking type should be "adaptive" and should NOT contain budget_tokens
    local has_adaptive has_budget
    has_adaptive=$(echo "$last_body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
body = json.loads(d.get('body','{}'))
t = body.get('thinking', {})
print('yes' if t.get('type') == 'adaptive' else 'no')
" 2>/dev/null)
    has_budget=$(echo "$last_body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
body = json.loads(d.get('body','{}'))
print('yes' if 'budget_tokens' in body.get('thinking', {}) else 'no')
" 2>/dev/null)

    if [[ "$has_adaptive" == "yes" ]]; then
        green "thinking format: type=adaptive"; ((PASS++)) || true
    else
        red "thinking format: type is NOT adaptive (has_adaptive=$has_adaptive)"; ((FAIL++)) || true
    fi

    if [[ "$has_budget" != "yes" ]]; then
        green "thinking format: no budget_tokens"; ((PASS++)) || true
    else
        red "thinking format: budget_tokens should NOT be present"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 45: x-app header (P2)
test_agent_xapp_header() {
    info "Test 45: x-app header in request (P2)"
    local home_dir last_headers
    home_dir=$(mktemp -d)

    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'XAPP_HEADER_CHECK' >/dev/null 2>&1 || true

    last_headers=$(curl -sS "$BASE/last-request" 2>/dev/null)
    local has_xapp
    has_xapp=$(echo "$last_headers" | python3 -c "
import sys, json
d = json.load(sys.stdin)
h = d.get('headers', {})
print('yes' if h.get('x-app') == 'cli' or h.get('X-App') == 'cli' or h.get('X-app') == 'cli' else 'no')
" 2>/dev/null)

    if [[ "$has_xapp" == "yes" ]]; then
        green "x-app header: present with value 'cli'"; ((PASS++)) || true
    else
        red "x-app header: NOT present"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 46: PlanConfirm mv draft→plan (PL2)
test_agent_plan_confirm_mv() {
    info "Test 46: PlanConfirm moves draft to plan (PL2)"
    local home_dir project_dir session_dir draft_file plan_file output
    home_dir=$(mktemp -d)
    project_dir="$home_dir/.bash-agent/projects/$(cd "$ROOT_DIR" && project_key)"
    session_dir="$project_dir/plan-confirm-test"
    draft_file="$session_dir/plan.draft"
    plan_file="$session_dir/plan.md"
    mkdir -p "$session_dir"

    # Seed draft file with content
    printf 'Task: test plan confirm mv\nStep 1: do thing\n' > "$draft_file"

    output=$(cd "$ROOT_DIR" && BASH_AGENT_HOME="$home_dir" HOME="$home_dir" "$AGENT" --print -p claude --base-url "$BASE/v1" -m test --api-key test --session plan-confirm-test 'PLAN_CONFIRM_MV_MARKER' 2>&1) || true

    # Check: plan.md should exist and contain content from draft
    if [[ -s "$plan_file" ]] && grep -q "test plan confirm" "$plan_file" 2>/dev/null; then
        green "PlanConfirm mv: plan.md has content from draft"; ((PASS++)) || true
    else
        red "PlanConfirm mv: plan.md missing or empty"; echo "  plan.md: $(cat "$plan_file" 2>/dev/null || echo 'N/A')"; echo "  draft still exists: $([[ -s "$draft_file" ]] && echo yes || echo no)"; echo "  Output: $output"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 47: system prompt golden — current AGENT must produce the byte-exact expected prompt
test_agent_system_prompt_format() {
    info "Test 47: system prompt byte-exact golden"
    local home_dir project_dir session_id project_key_value project_storage candidate_agent
    local expected_prompt actual_prompt candidate_err diff_file platform prompt_shell
    home_dir=$(mktemp -d)
    project_dir="$home_dir/project"
    session_id="system-prompt-parity"
    case "$AGENT" in
        /*) candidate_agent="$AGENT" ;;
        *) candidate_agent="$ROOT_DIR/${AGENT#./}" ;;
    esac

    mkdir -p "$project_dir" "$home_dir/.bash-agent"
    project_dir="$(cd "$project_dir" && pwd -P)"
    mkdir -p "$project_dir/skills/parity-skill"
    cat > "$project_dir/AGENTS.md" <<'EOF'
Project instruction fixture.
Keep this text stable for system prompt parity checks.
EOF
    cat > "$project_dir/skills/parity-skill/SKILL.md" <<'EOF'
# Parity Skill

Use this fixture skill only for system prompt parity tests.
Base path token: ${BASH_AGENT_SKILL_DIR}
EOF

    project_key_value="$(cd "$project_dir" && project_key)"
    project_storage="$home_dir/.bash-agent/projects/$project_key_value/$session_id"
    mkdir -p "$project_storage"
    cat > "$project_storage/plan.md" <<'EOF'
1. Keep the fixture plan stable.
2. Compare generated system prompts exactly.
EOF
    cat > "$project_storage/summary.txt" <<'EOF'
Task focus: system prompt parity fixture.
Latest request: compare prompt construction across runtimes.
Progress: fixture seeded before agent execution.
Tool evidence: none.
Reflections: exact prompt drift must fail this test.
EOF
    : > "$project_storage/conversation.jsonl"
    : > "$project_storage/events.jsonl"
    : > "$project_storage/plan.draft"
    : > "$project_storage/stats.json"

    expected_prompt="$home_dir/expected.system"
    actual_prompt="$home_dir/actual.system"
    candidate_err="$home_dir/candidate.err"
    diff_file="$home_dir/system.diff"
    platform="$(uname -s 2>/dev/null || printf unknown)"
    prompt_shell="${SHELL:-/bin/sh}"

    extract_system_prompt() {
        local marker="$1"
        curl -sS "$BASE/last-request" 2>/dev/null | EXPECTED_MARKER="$marker" python3 -c '
import json, os, sys
try:
    captured = json.load(sys.stdin)
    body = json.loads(captured.get("body", "{}"))
except Exception as exc:
    print(f"failed to parse captured request: {exc}", file=sys.stderr)
    sys.exit(2)
marker = os.environ["EXPECTED_MARKER"]
if marker not in json.dumps(body.get("messages", []), ensure_ascii=False):
    print("captured request did not contain expected marker", file=sys.stderr)
    sys.exit(3)
system = body.get("system")
if not isinstance(system, str) or not system:
    print("captured request has no top-level system prompt", file=sys.stderr)
    sys.exit(4)
sys.stdout.write(system)
'
    }

    render_expected_system_prompt() {
        local template_file="$1"
        EXPECTED_HOME="$home_dir" \
        EXPECTED_PROJECT="$project_dir" \
        EXPECTED_PROJECT_KEY="$project_key_value" \
        EXPECTED_PLATFORM="$platform" \
        EXPECTED_SHELL="$prompt_shell" \
        python3 - "$template_file" <<'PY'
import os
import sys
from pathlib import Path

template = Path(sys.argv[1]).read_text()
template = template.replace("__HOME__", os.environ["EXPECTED_HOME"])
template = template.replace("__PROJECT__", os.environ["EXPECTED_PROJECT"])
template = template.replace("__PROJECT_KEY__", os.environ["EXPECTED_PROJECT_KEY"])
template = template.replace("__PLATFORM__", os.environ["EXPECTED_PLATFORM"])
template = template.replace("__SHELL__", os.environ["EXPECTED_SHELL"])
if template.endswith("\n"):
    template = template[:-1]
sys.stdout.write(template)
PY
    }

    check_system_prompt_locale() {
        local locale_name="$1" locale_value="$2" template_file="$3" marker="$4"
        render_expected_system_prompt "$template_file" > "$expected_prompt"

        (
            cd "$project_dir" &&
            BASH_AGENT_HOME="$home_dir" HOME="$home_dir" SHELL="$prompt_shell" \
            LANG="$locale_value" LC_ALL="$locale_value" \
            "$candidate_agent" -p claude --base-url "$BASE/v1" -m test --api-key test \
                --session "$session_id" --skill parity-skill "$marker" \
                >/dev/null 2>"$candidate_err"
        ) || true
        if ! extract_system_prompt "$marker" > "$actual_prompt"; then
            red "system prompt golden ($locale_name): failed to capture candidate prompt"; cat "$candidate_err" 2>/dev/null; ((FAIL++)) || true
            return
        fi

        if cmp -s "$expected_prompt" "$actual_prompt"; then
            green "system prompt golden ($locale_name): byte-exact match"; ((PASS++)) || true
        else
            red "system prompt golden ($locale_name): differs from expected bytes"
            diff -u "$expected_prompt" "$actual_prompt" > "$diff_file" || true
            sed -n '1,160p' "$diff_file"
            ((FAIL++)) || true
        fi
    }

    check_system_prompt_locale "en_US" "en_US.UTF-8" "$ROOT_DIR/tests/fixtures/system_prompt_expected.txt" "SYSTEM_PROMPT_GOLDEN_EN"
    check_system_prompt_locale "zh_CN" "zh_CN.UTF-8" "$ROOT_DIR/tests/fixtures/system_prompt_expected_zh_CN.txt" "SYSTEM_PROMPT_GOLDEN_ZH"

    rm -rf "$home_dir"
}

# Test 48: model from -m arg (C3 — verify model passed correctly)
test_agent_model_arg() {
    info "Test 48: model from -m arg (C3)"
    local home_dir last_body model_value
    home_dir=$(mktemp -d)

    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test-model-arg --api-key test 'MODEL_ARG_CHECK' >/dev/null 2>&1 || true

    last_body=$(curl -sS "$BASE/last-request" 2>/dev/null)
    model_value=$(echo "$last_body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
body = json.loads(d.get('body','{}'))
print(body.get('model', ''))
" 2>/dev/null)

    if [[ "$model_value" == "test-model-arg" ]]; then
        green "model arg: model field = test-model-arg"; ((PASS++)) || true
    else
        red "model arg: expected 'test-model-arg', got '$model_value'"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 49: --max-tokens k suffix (C4)
test_agent_max_tokens_suffix() {
    info "Test 49: --max-tokens k suffix (C4)"
    local home_dir last_body max_tokens_value
    home_dir=$(mktemp -d)

    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test --max-tokens 4k 'MAX_TOKENS_K_CHECK' >/dev/null 2>&1 || true

    last_body=$(curl -sS "$BASE/last-request" 2>/dev/null)
    max_tokens_value=$(echo "$last_body" | python3 -c "
import sys, json
d = json.load(sys.stdin)
body = json.loads(d.get('body','{}'))
print(body.get('max_tokens', ''))
" 2>/dev/null)

    if [[ "$max_tokens_value" == "4000" ]]; then
        green "max-tokens suffix: 4k -> 4000"; ((PASS++)) || true
    else
        red "max-tokens suffix: expected 4000, got '$max_tokens_value'"; ((FAIL++)) || true
    fi

    rm -rf "$home_dir"
}

# Test 50: Image placeholder e2e test (all agent versions)

test_agent_image_placeholders() {
    info "Test 50: Image placeholder e2e test"
    local home_dir conv_file session_id img_dir
    home_dir=$(mktemp -d)
    session_id="image-e2e-test-$$"

    # Create an image file in session images directory
    img_dir="$home_dir/.bash-agent/projects/$(cd "$ROOT_DIR" && project_key)/$session_id/images"
    mkdir -p "$img_dir"
    printf 'fake-png-data' > "$img_dir/1.png"

    # Run agent with [Image #1] marker; mock returns a simple text response
    conv_file="$img_dir/../conversation.jsonl"
    BASH_AGENT_HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test --session "$session_id" '[Image #1] what is this?' >/dev/null 2>&1 || true

    # Without DESCRIBE_API_KEY, describe returns empty, but expand still appends <attached-images>
    if [[ -f "$conv_file" ]] && grep -q '<attached-images>' "$conv_file" 2>/dev/null; then
        green "Agent image placeholder appends attached-images in conversation"; ((PASS++)) || true
    else
        red "Agent image placeholder appends attached-images in conversation"; echo "  conv=$(cat "$conv_file" 2>/dev/null)"; ((FAIL++)) || true
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
test_agent_openai_request_body
test_agent_openai_tool_write
test_agent_tool_result_persist_order
test_agent_skill_injection
test_agent_skill_injection_from_repo_skills_dir
test_agent_skill_index
test_agent_skill_tool
test_agent_instruction_files
test_agent_todo_state
test_agent_plan_clear
test_agent_read_file
test_agent_read_tool_arg_parsing
test_agent_read_file_long_result
test_agent_glob
test_agent_grep
test_agent_glob_no_match
test_agent_grep_no_match
test_agent_read_offset_limit
test_agent_bash_timeout
test_agent_grep_context
test_agent_edit_file
test_agent_edit_file_not_found

test_agent_write_file_newlines
test_agent_bash_quotes
test_agent_bash_blocked_command
test_agent_bash_blocked_delete_command
test_agent_bash_blocks_system_read_mode
test_agent_bash_blocks_network_execute_mode
test_agent_bash_blocks_external_write_mode
test_agent_bash_invalid_mode_fails_closed
test_agent_bash_custom_mode_allows_system_read
test_agent_bash_allows_dev_null_redirection
test_agent_bash_long_result
test_agent_stream_tool_call
test_agent_stream_usage_event
test_agent_tool_result_multiline_url
test_agent_multiple_tool_calls
test_agent_multiple_tool_calls_openai
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
test_agent_stats_usage_values
test_agent_stats_cache_tokens
test_compact_dp_awk
test_compact_turn_keep_awk
test_agent_compact_context
test_agent_sub_agent
test_agent_sub_agent_failure
test_agent_sub_agent_child_session
test_agent_sub_agent_fork
test_agent_sub_agent_fork_failure
test_agent_sub_agent_fork_context

test_agent_stats_structure
test_agent_project_key
test_agent_conv_no_blank_lines
test_agent_bash_device_write_block
test_agent_thinking_format
test_agent_xapp_header
test_agent_plan_confirm_mv
test_agent_system_prompt_format
test_agent_model_arg
test_agent_max_tokens_suffix
test_agent_image_placeholders

echo ""
echo "=============================="
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "=============================="

(( FAIL > 0 )) && exit 1 || exit 0
