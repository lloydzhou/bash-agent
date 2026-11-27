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
        nm = ((u.get("_meta") or {}).get("bash-agent") or {}).get("name")
        line += " | tool_call %s %s (%s)%s" % (u.get("toolCallId"), u.get("kind"), u.get("status"), (" name=" + nm) if nm else "")
    elif t == "tool_call_update":
        nm = ((u.get("_meta") or {}).get("bash-agent") or {}).get("name")
        line += " | tool_update %s status=%s%s" % (u.get("toolCallId"), u.get("status"), (" name=" + nm) if nm else "")
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
        && grep -q '"_meta":{"bash-agent":{"name":"Bash"}}' "$_TMP/s3.log" \
        && grep -q '"stopReason":"end_turn"' "$_TMP/s3.log" \
        && green "tool_call → tool_call_update(failed, guard 拦截) → end_turn（带 _meta 工具名）" \
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

# ---------- 场景 5: 非法 method 的错误回包必须转义（issue #116-3）----------
echo "── 非法 method（含双引号/反斜杠）→ 错误回包仍是合法 JSON"
send '{"jsonrpc":"2.0","id":50,"method":"x\"y\\z"}'
if readline 10; then
    show "$LINE" "$_TMP/s5json.log"
    python3 -c 'import json,sys; json.loads(sys.argv[1])' "$LINE" 2>/dev/null \
        && green "错误回包是合法 JSON（客户端可控 method 已转义）" \
        || red "错误回包非法 JSON: $LINE"
    grep -q '"code":-32601' <<< "$LINE" && green "错误码 -32601" || red "错误码不是 -32601"
else
    red "非法 method 无回包"
fi

# ---------- 场景 6: worker 崩溃后可 resume（issue #116-4）----------
echo "── kill -9 worker → session/resume 成功 → prompt 正常"
# worker = dispatcher 的 bash 子进程中「子进程含非 awk」的那个
# （另两个 bash 子进程是 acp_out/acp_in 的进程替换包装，只 fork awk）
find_worker() {
    local i p sub
    for ((i = 0; i < 40; i++)); do
        for p in $(ps -o pid=,ppid=,comm= -ax | awk -v root="$AGENT_PID" '$2==root && $3=="bash"{print $1}'); do
            sub=$(ps -o pid=,ppid=,comm= -ax | awk -v pp="$p" '$2==pp && $3!="awk"{print $1}')
            [[ -n "$sub" ]] && { printf '%s' "$p"; return 0; }
        done
        sleep 0.25
    done
    return 1
}
WORKER_PID="$(find_worker)"
NOTIFY_PID_FILE="$(find "$TEST_HOME" -name notify.pid -path "*${SID}*" 2>/dev/null | head -1)"
NOTIFY_PID="$(cat "$NOTIFY_PID_FILE" 2>/dev/null)"
if [[ -n "$WORKER_PID" ]]; then
    kill -9 "$WORKER_PID" 2>/dev/null; sleep 0.5
    send '{"jsonrpc":"2.0","id":6,"method":"session/resume","params":{"sessionId":"'"$SID"'","cwd":"'"$SESSION_CWD"'","mcpServers":[]}}'
    if collect 6 "$_TMP/s6.log" 15; then
        grep -q '"id":6,"result"' "$_TMP/s6.log" \
            && green "worker 崩溃后 session/resume 成功（不再误报 already active）" \
            || red "resume 被拒绝: $(head -1 "$_TMP/s6.log")"
    else
        red "resume 无回包"
    fi
    if [[ -n "$NOTIFY_PID" ]]; then
        kill -0 "$NOTIFY_PID" 2>/dev/null \
            && red "notify 子 shell 未被 reap 清理（pid=$NOTIFY_PID）" \
            || green "worker 的 notify 子 shell 已清理"
    fi
    sleep 1
    send '{"jsonrpc":"2.0","id":7,"method":"session/prompt","params":{"sessionId":"'"$SID"'","prompt":[{"type":"text","text":"Hello after resume"}]}}'
    if collect 7 "$_TMP/s6b.log" 30; then
        grep -q '"id":7,"result":{"stopReason":"end_turn"' "$_TMP/s6b.log" \
            && green "resume 后 prompt 正常 (end_turn)" \
            || red "resume 后 prompt 回包异常"
    else
        red "resume 后 prompt 无回包"
    fi
else
    red "找不到 worker pid（跳过 resume 场景）"
fi

# ---------- 场景 7: EOF 退出 ----------
echo "── 关闭 stdin (EOF)"
stop_agent
[[ "$ACP_EXIT" == "0" ]] && green "退出码 0" || red "退出码非 0: $ACP_EXIT"

# ---------- 场景 8: killpg(SIGTERM) 不丢回包（issue #116-5）----------
echo "── killpg(SIGTERM) 进行中 prompt → stopReason=cancelled 仍送达"
OUT2="$_TMP/stdout2.log"; FIFO2="$_TMP/stdin2.fifo"
: > "$OUT2"; : > "$_TMP/stderr2.log"; rm -f "$FIFO2"; mkfifo "$FIFO2"
# setsid 让 agent 独立成进程组，才能用 killpg 精确复现 webagent 的 terminate()
BASH_AGENT_HOME="$TEST_HOME" ANTHROPIC_BASE_URL="$BASE/v1" ANTHROPIC_API_KEY=test \
    python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' \
    bash "$AGENT" --acp < "$FIFO2" > "$OUT2" 2>"$_TMP/stderr2.log" &
AGENT2_PID=$!
exec 20>&- 2>/dev/null; exec 20>"$FIFO2"
OUT="$OUT2"; OFF=0
send '{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"'"$SESSION_CWD"'","mcpServers":[]}}'
if readline 10; then
    SID2="$(sed -n 's/.*"sessionId":"\([^"]*\)".*/\1/p' <<< "$LINE")"
    sleep 2
    send '{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"'"$SID2"'","prompt":[{"type":"text","text":"ACP_SLOW_MARKER"}]}}'
    sleep 3
    kill -TERM -- "-$AGENT2_PID" 2>/dev/null
    if collect 2 "$_TMP/s8.log" 25; then
        grep -q '"id":2,"result":{"stopReason":"cancelled"' "$_TMP/s8.log" \
            && green "killpg 后仍收到 cancelled（acp_out 忽略 TERM + drain 走完整取消）" \
            || red "回包不是 cancelled: $(grep '"id":2' "$_TMP/s8.log" | head -1)"
    else
        red "killpg 后回包丢失"
    fi
    wait "$AGENT2_PID" 2>/dev/null
    [[ $? -eq 0 ]] && green "SIGTERM 后 agent 正常退出（退出码 0）" || red "SIGTERM 后退出码非 0"
    kill -0 "$AGENT2_PID" 2>/dev/null && kill -9 -- "-$AGENT2_PID" 2>/dev/null
else
    red "killpg 场景 session/new 无回包"
fi

echo "═══ 结果: $PASS passed, $FAIL failed ═══"
exit $(( FAIL > 0 ))
