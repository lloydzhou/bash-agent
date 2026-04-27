#!/usr/bin/env bash
# test_curl_retry.sh — Test curl retry handling across http_stream.awk + SSE parsers
# Simulates what curl --retry produces: multiple HTTP responses concatenated on stdout

set -uo pipefail
AWK_DIR="$(cd "$(dirname "$0")/../src/awk" && pwd)"
PASS=0 FAIL=0

assert_output() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf '\033[32m  PASS\033[0m %s\n' "$desc"
        ((PASS++))
    else
        printf '\033[31m  FAIL\033[0m %s\n' "$desc"
        printf '    expected: %s\n' "$(printf '%s' "$expected" | head -5 | sed 's/$/|/')"
        printf '    actual:   %s\n' "$(printf '%s' "$actual" | head -5 | sed 's/$/|/')"
        ((FAIL++))
    fi
}

# ============================================================================
# Test 1: http_stream.awk — single response (baseline, no retry)
# ============================================================================
printf '\n=== Test 1: http_stream.awk single response ===\n'
input1='HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_start
data: {"type":"content_block_start","content_block":{"type":"text"}}

event: content_block_delta
data: {"type":"content_block_delta","delta":{"text":"Hello"}}

event: content_block_stop
data: {"type":"content_block_stop"}

event: message_stop
data: {"type":"message_stop"}
'

actual1=$(printf '%s\n' "$input1" | awk -f "$AWK_DIR/http_stream.awk")
# Should NOT contain RETRY:
if ! printf '%s\n' "$actual1" | grep -q '^RETRY:'; then
    assert_output "no RETRY on single response" "ok" "ok"
else
    assert_output "no RETRY on single response" "ok" "FAIL: RETRY found"
fi
# Should contain the SSE data
if printf '%s\n' "$actual1" | grep -q 'event: message_start'; then
    assert_output "SSE data passes through" "ok" "ok"
else
    assert_output "SSE data passes through" "ok" "FAIL: SSE data missing"
fi

# ============================================================================
# Test 2: http_stream.awk — two responses (curl retry simulation)
# ============================================================================
printf '\n=== Test 2: http_stream.awk two responses (retry) ===\n'
input2='HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_delta
data: {"type":"content_block_delta","delta":{"text":"Partial"}}
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_delta
data: {"type":"content_block_delta","delta":{"text":"Retry"}}
'

actual2=$(printf '%s\n' "$input2" | awk -f "$AWK_DIR/http_stream.awk")
retry_count=$(printf '%s\n' "$actual2" | grep -c '^RETRY:' || true)
assert_output "RETRY emitted once" "1" "$retry_count"

# Second response headers should NOT appear as body output
header_leak=$(printf '%s\n' "$actual2" | grep -c '^Content-Type:' || true)
assert_output "second headers not leaked as body" "0" "$header_leak"

# Both SSE events should pass through
event_count=$(printf '%s\n' "$actual2" | grep -c '^event:' || true)
assert_output "SSE events from both responses pass through" "4" "$event_count"

# ============================================================================
# Test 3: Full pipeline — http_stream.awk | claude_sse.awk with retry
# ============================================================================
printf '\n=== Test 3: Full pipeline http_stream + claude_sse with retry ===\n'
input3='HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"First response partial text"}}
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":50}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Retry response text"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
'

actual3=$(printf '%s\n' "$input3" | awk -f "$AWK_DIR/http_stream.awk" \
    | awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk")

# Should have RETRY: in output
retry_in_sse=$(printf '%s\n' "$actual3" | grep -c '^RETRY:' || true)
assert_output "RETRY passed through to SSE output" "1" "$retry_in_sse"

# Both TEXT events should appear
text_count=$(printf '%s\n' "$actual3" | grep -c '^TEXT:' || true)
assert_output "both TEXT events emitted" "2" "$text_count"

# STOP should only appear once (from second response, at EOF)
stop_count=$(printf '%s\n' "$actual3" | grep -c '^STOP:' || true)
assert_output "STOP emitted only once at EOF" "1" "$stop_count"

# STOP should be from second response
stop_value=$(printf '%s\n' "$actual3" | grep '^STOP:' | head -1)
assert_output "STOP is end_turn" "STOP:end_turn" "$stop_value"

# USAGE should only appear once
usage_count=$(printf '%s\n' "$actual3" | grep -c '^USAGE:' || true)
assert_output "USAGE emitted only once at EOF" "1" "$usage_count"

# No ERROR should appear
error_count=$(printf '%s\n' "$actual3" | grep -c '^ERROR:' || true)
assert_output "no ERROR emitted" "0" "$error_count"

# ============================================================================
# Test 4: Full pipeline with tool call in first response, retry mid-tool
# ============================================================================
printf '\n=== Test 4: Tool call interrupted by retry ===\n'
input4='HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":100}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_stale","name":"Read","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":\\"/tmp/stale"}}
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":100}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Fresh start"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":10}}

event: message_stop
data: {"type":"message_stop"}
'

actual4=$(printf '%s\n' "$input4" | awk -f "$AWK_DIR/http_stream.awk" \
    | awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk")

# Should NOT have a TOOL_CALL from the stale first response (no content_block_stop was received)
tool_call_count=$(printf '%s\n' "$actual4" | grep -c '^TOOL_CALL:' || true)
assert_output "no stale TOOL_CALL from interrupted first response" "0" "$tool_call_count"

# Should have TEXT from second response
text_content=$(printf '%s\n' "$actual4" | grep '^TEXT:' | sed 's/^TEXT://' | sed 's/\\n/\n/g; s/\\\\/\\/g')
assert_output "TEXT from retry response" "TEXT:Fresh start" "$(grep '^TEXT:' <<<"$actual4")"

# ============================================================================
# Test 5: HTTP error then retry with success
# ============================================================================
printf '\n=== Test 5: HTTP 500 then retry with 200 ===\n'
input5='HTTP/1.1 500 Internal Server Error
Content-Type: application/json

{"error":"overloaded"}
HTTP/1.1 200 OK
Content-Type: text/event-stream

event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":50}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"After retry"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {"type":"message_stop"}
'

actual5=$(printf '%s\n' "$input5" | awk -f "$AWK_DIR/http_stream.awk" \
    | awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk")

# Should have RETRY
retry5=$(printf '%s\n' "$actual5" | grep -c '^RETRY:' || true)
assert_output "RETRY emitted on 500→200" "1" "$retry5"

# Should have TEXT from successful retry
text5=$(printf '%s\n' "$actual5" | grep -c '^TEXT:' || true)
assert_output "TEXT from retry after 500" "1" "$text5"

# Should have final STOP
stop5=$(printf '%s\n' "$actual5" | grep -c '^STOP:' || true)
assert_output "STOP emitted after retry" "1" "$stop5"

# NO ERROR should be emitted — the 500 was swallowed by retry
error5=$(printf '%s\n' "$actual5" | grep -c '^ERROR:' || true)
assert_output "no ERROR from swallowed 500" "0" "$error5"

# ============================================================================
# Test 5b: All retries fail — final ERROR emitted at EOF
# ============================================================================
printf '\n=== Test 5b: All retries fail → ERROR at EOF ===\n'
input5b='HTTP/1.1 500 Internal Server Error
Content-Type: application/json

{"error":"first attempt"}

HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{"error":"second attempt"}

HTTP/1.1 500 Internal Server Error
Content-Type: application/json

{"error":"final attempt"}
'

actual5b=$(printf '%s\n' "$input5b" | awk -f "$AWK_DIR/http_stream.awk")

# Should have 2 RETRY events (3 responses, 2 transitions)
retry5b=$(printf '%s\n' "$actual5b" | grep -c '^RETRY:' || true)
assert_output "2 RETRY events for 3 failed responses" "2" "$retry5b"

# Only the FINAL error should be emitted at EOF
error5b=$(printf '%s\n' "$actual5b" | grep '^ERROR:' || true)
assert_output "final ERROR at EOF" "ERROR:500	HTTP 500: {\"error\":\"final attempt\"}" "$error5b"

# ============================================================================
# Test 6: OpenAI SSE with retry
# ============================================================================
printf '\n=== Test 6: OpenAI SSE with retry ===\n'
input6='HTTP/1.1 200 OK
Content-Type: text/event-stream

data: {"choices":[{"delta":{"content":"Partial OpenAI"}}]}
data: {"choices":[{"delta":{"content":" text"}}]}
HTTP/1.1 200 OK
Content-Type: text/event-stream

data: {"choices":[{"delta":{"content":"Retry OpenAI"}}]}
data: {"choices":[{"delta":{"content":" response"},"finish_reason":"stop"}],"usage":{"prompt_tokens":50,"completion_tokens":10}}
data: [DONE]
'

actual6=$(printf '%s\n' "$input6" | awk -f "$AWK_DIR/http_stream.awk" \
    | awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk" \
    | awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk")

retry6=$(printf '%s\n' "$actual6" | grep -c '^RETRY:' || true)
assert_output "RETRY in OpenAI pipeline" "1" "$retry6"

text6=$(printf '%s\n' "$actual6" | grep -c '^TEXT:' || true)
assert_output "TEXT events from both responses" "4" "$text6"

stop6=$(printf '%s\n' "$actual6" | grep -c '^STOP:' || true)
assert_output "STOP emitted once at EOF" "1" "$stop6"

# ============================================================================
# Summary
# ============================================================================
printf '\n========================================\n'
printf 'Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
((FAIL > 0)) && exit 1
exit 0
