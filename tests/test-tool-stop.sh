#!/usr/bin/env bash
# Test: verify llm.sh outputs STOP:tool_use when called with --tools
# This tests the specific bug: agent.sh gets empty stop reason
#
# Usage: ANTHROPIC_API_KEY=xxx ./tests/test-tool-stop.sh
#   or:  ANTHROPIC_BASE_URL=xxx ./tests/test-tool-stop.sh  (for BigModel etc.)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
LLM_SH="$ROOT_DIR/llm.sh"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

pass=0
fail=0

assert_contains() {
    local label="$1" output="$2" expected="$3"
    if echo "$output" | grep -qF "$expected"; then
        printf "${GREEN}PASS${RESET} %s: found [%s]\n" "$label" "$expected"
        (( pass++ )) || true
    else
        printf "${RED}FAIL${RESET} %s: expected [%s]\n" "$label" "$expected"
        printf "  Output:\n%s\n" "$output" | sed 's/^/    /'
        (( fail++ )) || true
    fi
}

assert_not_empty() {
    local label="$1" output="$2"
    if [[ -n "$output" ]]; then
        printf "${GREEN}PASS${RESET} %s: got output (%d lines)\n" "$label" "$(echo "$output" | wc -l | tr -d ' ')"
        (( pass++ )) || true
    else
        printf "${RED}FAIL${RESET} %s: empty output\n" "$label"
        (( fail++ )) || true
    fi
}

# --- Setup: create temp tools file ---
TMPDIR_WORK=$(mktemp -d "${TMPDIR:-/tmp}/llm-test.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT

cat > "$TMPDIR_WORK/tools.json" <<'EOF'
[
  {
    "name": "read_file",
    "description": "Read file contents",
    "input_schema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "File path" }
      },
      "required": ["path"]
    }
  }
]
EOF

cat > "$TMPDIR_WORK/messages.json" <<'EOF'
[{"role":"user","content":"Read the file /etc/hostname and tell me its contents"}]
EOF

# --- Resolve API key and base URL ---
API_KEY="${ANTHROPIC_API_KEY:-}"
BASE_URL="${ANTHROPIC_BASE_URL:-}"
PROVIDER="${TEST_PROVIDER:-claude}"
MODEL="${TEST_MODEL:-glm-4.5-air}"

if [[ -z "$API_KEY" ]]; then
    printf "${RED}ERROR: ANTHROPIC_API_KEY not set${RESET}\n" >&2
    exit 1
fi

# Build llm.sh args
MSG_FILE="$TMPDIR_WORK/messages.json"
LLM_ARGS=(-p "$PROVIDER" -m "$MODEL" --tools "$TMPDIR_WORK/tools.json" --messages "$MSG_FILE")
[[ -n "$BASE_URL" ]] && LLM_ARGS+=(--base-url "$BASE_URL")

printf "${CYAN}=== Test: llm.sh with --tools ===${RESET}\n"
printf "Provider: %s  Model: %s  BaseURL: %s\n" "$PROVIDER" "$MODEL" "${BASE_URL:-(default)}"
printf "API Key: %s...\n\n" "${API_KEY:0:8}"

# ================================================================
# Test 1: llm.sh direct call with tools (verbose)
# ================================================================
printf "${YELLOW}--- Test 1: llm.sh --tools direct (verbose) ---${RESET}\n"
output=$(VERBOSE=true "$LLM_SH" "${LLM_ARGS[@]}" 2>"$TMPDIR_WORK/verbose.err" || true)

printf "stdout:\n%s\n" "$output" | sed 's/^/  /'
printf "stderr (sse-debug):\n"
cat "$TMPDIR_WORK/verbose.err" | head -50 | sed 's/^/  /'

assert_contains "llm.sh outputs TOOL_START" "$output" "TOOL_START:read_file"
assert_contains "llm.sh outputs TOOL_INPUT" "$output" "TOOL_INPUT:"
assert_contains "llm.sh outputs STOP" "$output" "STOP:"
assert_not_empty "llm.sh STOP value" "$(echo "$output" | grep '^STOP:')"

# ================================================================
# Test 2: llm.sh direct call with tools (non-verbose)
# ================================================================
printf "\n${YELLOW}--- Test 2: llm.sh --tools direct (non-verbose) ---${RESET}\n"
output2=$("$LLM_SH" "${LLM_ARGS[@]}" 2>/dev/null || true)

printf "stdout:\n%s\n" "$output2" | sed 's/^/  /'

assert_contains "llm.sh outputs STOP" "$output2" "STOP:"

# Show the actual STOP line
stop_line=$(echo "$output2" | grep '^STOP:' || true)
if [[ -n "$stop_line" ]]; then
    printf "  STOP line: ${GREEN}%s${RESET}\n" "$stop_line"
else
    printf "  ${RED}No STOP line found!${RESET}\n"
    printf "  All output lines:\n"
    echo "$output2" | nl | sed 's/^/    /'
fi

# ================================================================
# Test 3: llm.sh direct call WITHOUT tools (baseline)
# ================================================================
printf "\n${YELLOW}--- Test 3: llm.sh WITHOUT tools (baseline) ---${RESET}\n"
output3=$("$LLM_SH" -p "$PROVIDER" -m "$MODEL" --messages "$MSG_FILE" ${BASE_URL:+--base-url "$BASE_URL"} 2>/dev/null || true)

assert_contains "llm.sh baseline outputs STOP" "$output3" "STOP:"
stop_line3=$(echo "$output3" | grep '^STOP:' || true)
printf "  STOP line: ${GREEN}%s${RESET}\n" "$stop_line3"

# ================================================================
# Test 4: Simulate agent.sh's read loop
# ================================================================
printf "\n${YELLOW}--- Test 4: Simulate agent.sh while-read loop ---${RESET}\n"
captured_stop=""
captured_text=""
captured_tools=""
"$LLM_SH" "${LLM_ARGS[@]}" 2>/dev/null | {
    while IFS= read -r line; do
        case "$line" in
            TEXT:*) captured_text+="${line#TEXT:}" ;;
            TOOL_START:*) captured_tools+="${line#TOOL_START:}
" ;;
            TOOL_INPUT:*) true ;;
            STOP:*) captured_stop="${line#STOP:}" ;;
            USAGE:*) true ;;
            ERROR:*) printf "ERROR: %s\n" "${line#ERROR:}" >&2 ;;
        esac
    done
    # Write captured values to a file so outer shell can read them
    echo "$captured_stop" > "$TMPDIR_WORK/captured_stop"
    echo "$captured_text" > "$TMPDIR_WORK/captured_text"
    echo "$captured_tools" > "$TMPDIR_WORK/captured_tools"
} || true

# Read back captured values
stop_val=$(cat "$TMPDIR_WORK/captured_stop" 2>/dev/null || true)
text_val=$(cat "$TMPDIR_WORK/captured_text" 2>/dev/null || true)
tools_val=$(cat "$TMPDIR_WORK/captured_tools" 2>/dev/null || true)

printf "  captured_stop: [%s]\n" "$stop_val"
printf "  captured_text: [%s...]\n" "${text_val:0:60}"
printf "  captured_tools: [%s]\n" "$tools_val"

if [[ -n "$stop_val" ]]; then
    printf "${GREEN}PASS${RESET} agent loop captured stop: [%s]\n" "$stop_val"
    (( pass++ )) || true
else
    printf "${RED}FAIL${RESET} agent loop: stop is EMPTY (reproduces the bug!)\n"
    (( fail++ )) || true
fi

# ================================================================
# Summary
# ================================================================
printf "\n${CYAN}=== Summary: %d passed, %d failed ===${RESET}\n" "$pass" "$fail"
[[ $fail -eq 0 ]] && exit 0 || exit 1
