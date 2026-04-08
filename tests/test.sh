#!/usr/bin/env bash
# test.sh — Test bash-agent against mock server
# Tests SSE parsing via awk files and agent.sh end-to-end
# Usage: ./test.sh [--no-server] [port]

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
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT="$ROOT_DIR/src/agent.sh"
AWK_DIR="$ROOT_DIR/src/awk"
PASS=0
FAIL=0

project_key() {
    local cwd
    cwd=$(pwd -P)
    cwd="${cwd#/}"
    cwd="${cwd//\//-}"
    cwd=$(printf '%s' "$cwd" | awk '{ gsub(/[^A-Za-z0-9._-]/, "-"); gsub(/-+/, "-", $0); sub(/^-+/, "", $0); sub(/-+$/, "", $0); print }')
    printf -- '-%s' "$cwd"
}

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
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Task focus: summarize compact test\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\nLatest request: compact session\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\nProgress: trimmed old context\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\nTool evidence: none\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Task focus: summarize compact test\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\nLatest request: compact session\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\nProgress: trimmed old context\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\nTool evidence: none\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/responses'):
                for c in [
                    'data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n',
                    'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Task focus: summarize compact test\"}\n\n',
                    'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"\\nLatest request: compact session\"}\n\n',
                    'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"\\nProgress: trimmed old context\"}\n\n',
                    'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"\\nTool evidence: none\"}\n\n',
                    'data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_summary\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":8}}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
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
    output=$(awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE'
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
    output=$(awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE'
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

# Test 3: OpenAI SSE awk parser
test_openai_sse() {
    info "Test 3: OpenAI SSE awk parser"
    local output
    output=$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/openai_sse.awk" <<'SSE'
data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello from"},"finish_reason":null}]}

data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":" OpenAI mock!"},"finish_reason":null}]}

data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12}}

data: [DONE]
SSE
)
    if echo "$output" | grep -q "TEXT:Hello from" && echo "$output" | grep -q "TEXT:.*OpenAI" && echo "$output" | grep -q "STOP:stop"; then
        green "OpenAI SSE parser"; ((PASS++)) || true
    else
        red "OpenAI SSE parser"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 4: OpenAI Responses SSE awk parser
test_openai_responses_sse() {
    info "Test 4: OpenAI Responses SSE awk parser"
    local output
    output=$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/openai_responses.awk" <<'SSE'
data: {"type":"response.output_item.added","output_index":0,"item":{"type":"message","role":"assistant","content":[]}}

data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"Hello from"}

data: {"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":" Responses mock!"}

data: {"type":"response.completed","response":{"id":"resp_test","status":"completed","usage":{"input_tokens":10,"output_tokens":8}}}
SSE
)
    if echo "$output" | grep -q "TEXT:Hello from" && echo "$output" | grep -q "TEXT:.*Responses" && echo "$output" | grep -q "STOP:end_turn"; then
        green "OpenAI Responses SSE parser"; ((PASS++)) || true
    else
        red "OpenAI Responses SSE parser"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 5: Message format conversion
test_convert_messages() {
    info "Test 5: Message format conversion (Claude → OpenAI)"
    local output
    output=$(printf '%s' '[{"role":"user","content":"hello"}]' | awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/convert_messages.awk")
    if echo "$output" | grep -q '"role":"user"' && echo "$output" | grep -q '"content":"hello"'; then
        green "Message conversion (simple)"; ((PASS++)) || true
    else
        red "Message conversion (simple)"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 6: Tool format conversion
test_convert_tools() {
    info "Test 6: Tool format conversion (Claude → OpenAI)"
    local output
    output=$(printf '%s' '[{"name":"read_file","description":"Read file","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]' | awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/convert_tools.awk")
    if echo "$output" | grep -q '"type":"function"' && echo "$output" | grep -q '"parameters"'; then
        green "Tool conversion"; ((PASS++)) || true
    else
        red "Tool conversion"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 7: Agent.sh end-to-end with mock (Claude provider)
test_agent_e2e_claude() {
    info "Test 7: Agent.sh e2e (Claude mock)"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "Hello from" && echo "$output" | grep -q "mock"; then
        green "Agent e2e Claude"; ((PASS++)) || true
    else
        red "Agent e2e Claude"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 8: Agent.sh end-to-end with mock (OpenAI provider)
test_agent_e2e_openai() {
    info "Test 8: Agent.sh e2e (OpenAI mock)"
    local output
    output=$("$AGENT" -p openai --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "Hello from" && echo "$output" | grep -q "mock"; then
        green "Agent e2e OpenAI"; ((PASS++)) || true
    else
        red "Agent e2e OpenAI"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 9: Compact subcommand
test_agent_compact() {
    info "Test 9: Agent.sh compact subcommand"
    local home_dir session_dir session_file summary_file output
    home_dir=$(mktemp -d)
    session_dir="$home_dir/.bash-agent/projects/$(project_key)"
    mkdir -p "$session_dir"
    session_file="$session_dir/demo.jsonl"
    summary_file="$session_dir/demo.summary.txt"
    : > "$session_file"
    for i in $(seq 1 45); do
        printf '{"role":"user","content":"message %s"}\n' "$i" >> "$session_file"
    done
    output=$(HOME="$home_dir" "$AGENT" compact -p claude --base-url "$BASE/v1" --api-key test --session demo 2>&1) || true
    if echo "$output" | grep -q "Context compacted" && grep -q "Task focus: summarize compact test" "$summary_file" && [[ "$(wc -l < "$session_file")" -eq 4 ]]; then
        green "Agent compact subcommand"; ((PASS++)) || true
    else
        red "Agent compact subcommand"; echo "  Output: $output"; echo "  Session lines: $(wc -l < "$session_file")"; echo "  Summary: $(cat "$summary_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
}

# ===== Main =====

if $START_SERVER; then
    trap stop_mock EXIT
    start_mock
fi

test_claude_sse
test_claude_tool_use
test_openai_sse
test_openai_responses_sse
test_convert_messages
test_convert_tools
test_agent_e2e_claude
test_agent_e2e_openai
test_agent_compact

echo ""
echo "=============================="
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "=============================="

(( FAIL > 0 )) && exit 1 || exit 0
