#!/usr/bin/env bash
# ACP stdio 冒烟测试 — 独立可跑，不需要 Zed / t3code。
# 用法: bash tests/acp_smoke.sh
#
# 流程: 起 mock LLM server → spawn `agent.sh --acp` → 模拟 ACP client 走
# initialize → session/new → prompt(回复) → prompt(guard 拦截) →
# prompt+cancel(取消) → EOF 退出，实时打印 agent 发出的每一帧。
set -u
cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"
AGENT="$ROOT_DIR/src/agent.sh"

PORT=${ACP_SMOKE_PORT:-9899}
BASE="http://localhost:$PORT"
_TMP=$(mktemp -d "${TMPDIR:-/tmp}/acp-smoke.XXXXXX")
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/acp-smoke-home.XXXXXX")
SESSION_CWD=$(mktemp -d "${TMPDIR:-/tmp}/acp-smoke-cwd.XXXXXX")
PASS=0; FAIL=0

green() { printf '\033[32m✓ %s\033[0m\n' "$1"; ((PASS++)) || true; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$1"; ((FAIL++)) || true; }
cleanup() { stop_agent; [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$_TMP" "$TEST_HOME" "$SESSION_CWD"; }
trap cleanup EXIT

# ---------- mock LLM server ----------
BASH_AGENT_TEST_PORT="$PORT" python3 tests/fixtures/mock_server.py & MOCK_PID=$!
sleep 1
curl -sS "$BASE/" 2>/dev/null | grep -q ok || { echo "mock server 启动失败"; exit 1; }

# ---------- spawn agent --acp ----------
FIFO="$_TMP/stdin.fifo"; OUT="$_TMP/stdout.log"
rm -f "$FIFO"; mkfifo "$FIFO"
: > "$OUT"
BASH_AGENT_HOME="$TEST_HOME" ANTHROPIC_BASE_URL="$BASE/v1" ANTHROPIC_API_KEY=test \
    bash "$AGENT" --acp < "$FIFO" > "$OUT" 2>"$_TMP/stderr.log" &
AGENT_PID=$!
OFF=0
exec 20>"$FIFO"

send() { printf '%s\n' "$1" >&20 2>/dev/null; }

readline() {  # $1=timeout秒 → LINE（字节偏移轮询，命令替换剥尾换行所以按字节数判完整行）
    local _end=$(( SECONDS + ${1:-10} )) _b _l _lb
    while (( SECONDS < _end )); do
        _b=$(wc -c < "$OUT" 2>/dev/null); _b=${_b//[[:space:]]/}
        if (( ${_b:-0} > OFF )); then
            _l=$(tail -c +$(( OFF + 1 )) "$OUT" 2>/dev/null | head -n 1)
            _lb=$(printf '%s' "$_l" | wc -c); _lb=${_lb//[[:space:]]/}
            if (( _lb + 1 <= _b - OFF )); then
                OFF=$(( OFF + _lb + 1 )); LINE="$_l"; return 0
            fi
        fi
        sleep 0.2
    done
    return 1
}

# 打印一帧的可读摘要；追加到 $2（当前场景的帧文件）供断言
show() {
    python3 -c '
import json, sys
o = json.loads(sys.argv[1])
m = o.get("method") or ("reply id=" + str(o.get("id")))
line = "  <- " + m
r = o.get("result") or {}
p = o.get("params") or {}
if isinstance(r, dict) and "sessionId" in r: line += " | sessionId=" + r["sessionId"]
if isinstance(r, dict) and "stopReason" in r: line += " | stopReason=" + r["stopReason"]
if isinstance(r, dict) and "protocolVersion" in r: line += " | protocolVersion=%s" % r["protocolVersion"]
if isinstance(p, dict) and "sessionId" in p: line += " | sessionId=" + p["sessionId"]
u = p.get("update") if isinstance(p, dict) else None
if isinstance(u, dict):
    t = u.get("sessionUpdate")
    if t == "agent_message_chunk":
        line += " | message: " + ((u.get("content") or {}).get("text", "") or "")[:80]
    elif t == "tool_call":
        line += " | tool_call %s %s (%s)" % (u.get("toolCallId"), u.get("kind"), u.get("status"))
    elif t == "tool_call_update":
        line += " | tool_update %s status=%s" % (u.get("toolCallId"), u.get("status"))
    else:
        line += " | " + str(t)
print(line)' "$1" >&2 2>/dev/null || printf '  <- %s\n' "$1" >&2
    [[ -n "${2:-}" ]] && printf '%s\n' "$1" >> "$2"
    return 0
}

collect() {  # $1=reqid $2=帧文件 $3=timeout秒 → 读到该 id 的回包为止
    : > "$2"
    local _end=$(( SECONDS + ${3:-30} ))
    while (( SECONDS < _end )); do
        readline 1 || continue
        show "$LINE" "$2"
        [[ "$LINE" == *'"id":'"$1,"* ]] && return 0
    done
    return 1
}

stop_agent() {
    exec 20>&- 2>/dev/null
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$AGENT_PID" 2>/dev/null || break
        sleep 1
    done
    kill -0 "$AGENT_PID" 2>/dev/null && kill "$AGENT_PID" 2>/dev/null
    wait "$AGENT_PID" 2>/dev/null
    ACP_EXIT=$?
}

echo "═══ ACP 冒烟测试: agent --acp over stdio (mock LLM: :$PORT) ═══"

# ---------- 场景 1: 握手 ----------
echo "── 握手: initialize + session/new"
send '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'
if readline 10; then
    show "$LINE" "$_TMP/s1.log"
    grep -q '"protocolVersion":1' <<< "$LINE" && green "initialize 回包 protocolVersion=1" || red "initialize 回包缺少 protocolVersion"
else
    red "initialize 无回包"; exit 1
fi
send '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"'"$SESSION_CWD"'","mcpServers":[]}}'
if readline 10; then
    show "$LINE" "$_TMP/s1.log"
    SID="$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' <<< "$LINE")"
    [[ -n "$SID" ]] && green "session/new → sessionId=$SID" || { red "session/new 未返回 sessionId"; exit 1; }
else
    red "session/new 无回包"; exit 1
fi

# ---------- 场景 2: 普通 prompt ----------
echo "── prompt: 纯文本回复"
send '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"'"$SID"'","prompt":[{"type":"text","text":"Hello"}]}}'
if collect 2 "$_TMP/s2.log" 30; then
    grep -q '"sessionUpdate":"agent_message_chunk"' "$_TMP/s2.log" \
        && grep -q '"stopReason":"end_turn"' "$_TMP/s2.log" \
        && green "update 序列 (agent_message_chunk → … → end_turn)" \
        || red "update 序列不完整"
    python3 -c '
import json, sys
bad = 0
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln: continue
    try:
        assert json.loads(ln).get("jsonrpc") == "2.0"
    except Exception:
        bad += 1
sys.exit(1 if bad else 0)' "$_TMP/s2.log" \
        && green "stdout 帧全部为合法 JSON-RPC 2.0" || red "stdout 存在非法帧"
else
    red "prompt 未收到回包"
fi

# ---------- 场景 3: 工具调用被 bash-guard 拦截 ----------
echo "── prompt: ACP_GUARD_MARKER (Bash 危险命令 → guard 拦截)"
send '{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"'"$SID"'","prompt":[{"type":"text","text":"ACP_GUARD_MARKER"}]}}'
if collect 3 "$_TMP/s3.log" 40; then
    grep -q '"sessionUpdate":"tool_call"' "$_TMP/s3.log" \
        && grep -q '"sessionUpdate":"tool_call_update","toolCallId":"toolu_acp_guard","status":"failed"' "$_TMP/s3.log" \
        && grep -q '"stopReason":"end_turn"' "$_TMP/s3.log" \
        && green "tool_call → tool_call_update(failed, guard 拦截) → end_turn" \
        || red "guard 拦截序列不完整"
else
    red "guard 场景未收到回包"
fi

# ---------- 场景 4: 取消 ----------
echo "── prompt: ACP_SLOW_MARKER + 3 秒后 session/cancel"
send '{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"'"$SID"'","prompt":[{"type":"text","text":"ACP_SLOW_MARKER"}]}}'
sleep 3
send '{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"'"$SID"'"}}'
if collect 4 "$_TMP/s4.log" 30; then
    grep -q '"stopReason":"cancelled"' "$_TMP/s4.log" \
        && green "取消生效: stopReason=cancelled" \
        || red "取消未生效 (无 cancelled 回包)"
else
    red "cancel 场景未收到回包"
fi

# ---------- 场景 5: EOF 退出 ----------
echo "── 关闭 stdin (EOF)"
stop_agent
[[ "$ACP_EXIT" == "0" ]] && green "退出码 0" || red "退出码非 0: $ACP_EXIT"

echo "═══ 结果: $PASS passed, $FAIL failed ═══"
exit $(( FAIL > 0 ))
