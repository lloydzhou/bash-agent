#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="${AGENT:-$ROOT_DIR/src/agent.sh}"
case "$AGENT" in
    /*) ;;
    *) AGENT="$ROOT_DIR/${AGENT#./}" ;;
esac

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bash-agent-continue-test.XXXXXX")
PORT_FILE="$TMP_ROOT/port"
cleanup() {
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

python3 - "$PORT_FILE" <<'PY' &
import http.server
import sys

port_file = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        body = b'{"error":{"message":"test stop"}}'
        self.send_response(422)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as f:
    f.write(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..100}; do
    [[ -s "$PORT_FILE" ]] && break
    sleep 0.02
done
[[ -s "$PORT_FILE" ]] || { echo "mock server failed to start" >&2; exit 1; }
PORT=$(cat "$PORT_FILE")

project_key() {
    local cwd
    cwd=$(cd "$1" && pwd -P)
    cwd="${cwd#/}"
    cwd="${cwd//\//-}"
    cwd=$(printf '%s' "$cwd" | awk '{ gsub(/[^A-Za-z0-9._-]/, "-"); gsub(/-+/, "-", $0); sub(/^-+/, "", $0); sub(/-+$/, "", $0); print }')
    printf -- '-%s' "$cwd"
}

run_agent() {
    local home=$1 cwd=$2
    shift 2
    (
        cd "$cwd"
        BASH_AGENT_HOME="$home" HOME="$home" "$AGENT" \
            -p claude --base-url "http://127.0.0.1:$PORT/v1" \
            -m test --api-key test "$@" >/dev/null 2>&1 || true
    )
}

# 最新活动目录是 SubAgent 会话时，自动续聊必须选择普通会话。
home="$TMP_ROOT/latest-sub-home"
cwd="$TMP_ROOT/latest-sub-project"
mkdir -p "$home" "$cwd"
project_dir="$home/.bash-agent/projects/$(project_key "$cwd")"
mkdir -p "$project_dir/normal-session" "$project_dir/sub_latest"
printf '{}\n' > "$project_dir/normal-session/events.jsonl"
printf '{}\n' > "$project_dir/sub_latest/events.jsonl"
touch -t 202401010101 "$project_dir/normal-session/events.jsonl"
touch -t 202501010101 "$project_dir/sub_latest/events.jsonl"
run_agent "$home" "$cwd" --continue "continue-selection-marker"
grep -q 'continue-selection-marker' "$project_dir/normal-session/conversation.jsonl"
[[ ! -f "$project_dir/sub_latest/conversation.jsonl" ]]

# 只有 SubAgent 会话时，自动续聊必须创建新的普通会话。
home="$TMP_ROOT/only-sub-home"
cwd="$TMP_ROOT/only-sub-project"
mkdir -p "$home" "$cwd"
project_dir="$home/.bash-agent/projects/$(project_key "$cwd")"
mkdir -p "$project_dir/sub_only"
printf '{}\n' > "$project_dir/sub_only/events.jsonl"
run_agent "$home" "$cwd" --continue "new-session-marker"
regular_session=$(find "$project_dir" -mindepth 1 -maxdepth 1 -type d ! -name 'sub_*' -print | head -1)
regular_count=$(find "$project_dir" -mindepth 1 -maxdepth 1 -type d ! -name 'sub_*' -print | wc -l | tr -d ' ')
[[ "$regular_count" -eq 1 ]]
grep -q 'new-session-marker' "$regular_session/conversation.jsonl"

# 显式指定 SubAgent session_id 时仍允许进入。
home="$TMP_ROOT/explicit-sub-home"
cwd="$TMP_ROOT/explicit-sub-project"
mkdir -p "$home" "$cwd"
project_dir="$home/.bash-agent/projects/$(project_key "$cwd")"
run_agent "$home" "$cwd" --session sub_manual "explicit-sub-marker"
grep -q 'explicit-sub-marker' "$project_dir/sub_manual/conversation.jsonl"

printf 'PASS: %s continue session filtering\n' "$(basename "$AGENT")"
