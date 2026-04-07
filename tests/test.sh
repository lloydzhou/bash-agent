#!/usr/bin/env bash
# test.sh — Test llm.sh against mock server
# Usage: ./test.sh [--no-server] [port]
#   --no-server  Don't start mock server (use an already running one)
#   port         Port number (default: 9888)

set -uo pipefail

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
LLM="$SCRIPT_DIR/../llm.sh"
PASS=0
FAIL=0

green() { printf '\033[32m✓ PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m✗ FAIL: %s\033[0m\n' "$1"; }
info()  { printf '\033[36m→ %s\033[0m\n' "$1"; }

# ===== Mock Server (Python) =====
start_mock() {
    python3 -c "
import http.server, json, sys, threading

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        cl = int(self.headers.get('Content-Length',0))
        self.rfile.read(cl)
        path = self.path
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        w = self.wfile
        if path.startswith('/v1/messages'):
            test = path.split('test=')[-1] if 'test=' in path else ''
            if test == 'tool_use':
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":15,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_123\",\"name\":\"read_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/etc/hostname\\\"}\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            else:
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
        elif path.startswith('/v1/responses'):
            for c in [
                'data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n',
                'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello from\"}\n\n',
                'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\" Responses mock!\"}\n\n',
                'data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":8}}}\n\n',
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
    # Verify it started
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

test_claude_basic() {
    info "Test 1: Claude basic text streaming"
    local output
    output=$($LLM -p claude --base-url "$BASE" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "TEXT:Hello from" && echo "$output" | grep -q "TEXT:.*mock" && echo "$output" | grep -q "STOP:end_turn"; then
        green "Claude basic streaming"; ((PASS++)) || true
    else
        red "Claude basic streaming"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_claude_raw() {
    info "Test 2: Claude raw text output"
    local output
    output=$($LLM -p claude --base-url "$BASE" -m test --api-key test --raw 'Hello' 2>&1) || true
    if echo "$output" | grep -q "Hello from" && echo "$output" | grep -q "mock server"; then
        green "Claude raw mode"; ((PASS++)) || true
    else
        red "Claude raw mode"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_claude_tool_use() {
    info "Test 3: Claude tool_use SSE parsing"
    # Direct SSE parser test (doesn't need mock server route)
    local output
    output=$(awk '
BEGIN { event=""; block_type=""; tool_name=""; tool_id=""; partial_json=""; stop_reason="" }
/^:/ { next }
/^event: / { event=substr($0,8); next }
/^data: / {
    json=substr($0,7)
    if (event=="content_block_start" && json ~ /"type":"tool_use"/) {
        block_type="tool"
        match(json, /"name":"[^"]*"/); tool_name=substr(json,RSTART+8,RLENGTH-9)
        match(json, /"id":"[^"]*"/); tool_id=substr(json,RSTART+5,RLENGTH-6)
        partial_json=""
        printf "TOOL_START:%s:%s\n",tool_name,tool_id; fflush()
    } else if (event=="content_block_delta" && block_type=="tool") {
        match(json, /"partial_json":"[^"]*"/)
        s=substr(json,RSTART+16,RLENGTH-17)
        partial_json=partial_json s
    } else if (event=="content_block_stop" && block_type=="tool") {
        printf "TOOL_INPUT:%s\n",partial_json; fflush()
        block_type=""
    } else if (event=="message_delta") {
        match(json, /"stop_reason":"[^"]*"/)
        stop_reason=substr(json,RSTART+15,RLENGTH-16)
    } else if (event=="message_stop") {
        printf "STOP:%s\n",stop_reason; fflush()
    }
    next
}' <<'SSE'
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"read_file","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/etc/hostname\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -q "TOOL_START:read_file" && echo "$output" | grep -q "TOOL_INPUT:" && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude tool_use"; ((PASS++)) || true
    else
        red "Claude tool_use"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_openai_basic() {
    info "Test 4: OpenAI Chat streaming"
    local output
    output=$($LLM -p openai --base-url "$BASE" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "TEXT:" && echo "$output" | grep -q "STOP:"; then
        green "OpenAI Chat streaming"; ((PASS++)) || true
    else
        red "OpenAI Chat streaming"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_openai_raw() {
    info "Test 5: OpenAI raw text output"
    local output
    output=$($LLM -p openai --base-url "$BASE" -m test --api-key test --raw 'Hello' 2>&1) || true
    if echo "$output" | grep -q "mock"; then
        green "OpenAI raw mode"; ((PASS++)) || true
    else
        red "OpenAI raw mode"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_verbose() {
    info "Test 6: Verbose mode"
    local output
    output=$($LLM -p claude --base-url "$BASE" -m test --api-key test -v 'Hello' 2>&1) || true
    if echo "$output" | grep -q "verbose"; then
        green "Verbose mode"; ((PASS++)) || true
    else
        red "Verbose mode"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_piped() {
    info "Test 7: Piped messages JSON"
    local output
    output=$(echo '[{"role":"user","content":"hello"}]' | $LLM -p claude --base-url "$BASE" -m test --api-key test 2>&1) || true
    if echo "$output" | grep -q "TEXT:"; then
        green "Piped messages"; ((PASS++)) || true
    else
        red "Piped messages"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_usage() {
    info "Test 8: USAGE token counting"
    local output
    output=$($LLM -p claude --base-url "$BASE" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "USAGE:in="; then
        green "USAGE output"; ((PASS++)) || true
    else
        red "USAGE output"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# ===== Main =====

if $START_SERVER; then
    trap stop_mock EXIT
    start_mock
fi

test_claude_basic
test_claude_raw
test_claude_tool_use
test_openai_basic
test_openai_raw
test_verbose
test_piped
test_usage

echo ""
echo "=============================="
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "=============================="

(( FAIL > 0 )) && exit 1 || exit 0
