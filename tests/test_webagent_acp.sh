#!/usr/bin/env bash
# webagent ACP 模式 E2E —— 起 webagent(--protocol acp) 驱动 mock ACP agent，
# 覆盖：正常轮 / 工具流 _meta / 取消确认 / 忽略取消→强制停止 / 强停后 respawn+resume /
# 崩溃自动恢复 / 外部 kill 恢复 / 默认 stream-json 回归。
# 用法: bash tests/test_webagent_acp.sh   （需先 cargo build webagent + python3 websockets）
set -u
cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"

PORT_LLM=${ACP_E2E_LLM_PORT:-8731}
PORT_ACP=${ACP_E2E_PORT:-8732}
PORT_CANCEL=${ACP_E2E_CANCEL_PORT:-8734}
PORT_KILL=${ACP_E2E_KILL_PORT:-8735}
PORT_STREAM=${ACP_E2E_STREAM_PORT:-8736}

BIN="$ROOT_DIR/webagent/target/debug/webagent"
[[ -x "$BIN" ]] || BIN="$ROOT_DIR/webagent/target/release/webagent"
if [[ ! -x "$BIN" ]]; then
    echo "webagent 二进制不存在，先: cargo build --manifest-path webagent/Cargo.toml"; exit 1
fi
if ! python3 -c 'import websockets' 2>/dev/null; then
    echo "缺 python websockets 模块（pip3 install websockets）"; exit 1
fi

PASS=0; FAIL=0
_TMP=$(mktemp -d "${TMPDIR:-/tmp}/acp-e2e.XXXXXX")
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/acp-e2e-home.XXXXXX")
E2E_CWD=$(mktemp -d "${TMPDIR:-/tmp}/acp-e2e-cwd.XXXXXX")
PIDS=()

green() { printf '\033[32m✓ %s\033[0m\n' "$1"; ((PASS++)) || true; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$1"; ((FAIL++)) || true; }

kill_all_mocks() {
    python3 - <<'PYK'
import os, signal, subprocess
out = subprocess.run(["pgrep", "-f", "mock_acp_agent.py"],
                     capture_output=True, text=True).stdout.split()
for pid in out:
    try:
        os.kill(int(pid), signal.SIGKILL)
    except Exception:
        pass
PYK
}

cleanup() {
    local p
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    kill_all_mocks
    rm -rf "$_TMP" "$TEST_HOME" "$E2E_CWD"
}
trap cleanup EXIT

# $1=端口 $2=日志 $3=webagent 额外参数(可选)；MOCK_* 等环境变量由调用行传入
start_web() {
    local port="$1" log="$2" extra="${3:-}"
    ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT_LLM/v1" ANTHROPIC_API_KEY=test \
        BASH_AGENT_HOME="$TEST_HOME" \
        "$BIN" --agent "$ROOT_DIR/tests/fixtures/mock_acp_agent.py" \
        --protocol acp --port "$port" $extra >>"$log" 2>&1 &
    PIDS+=($!)
}

wait_ready() {  # $1=端口
    local i
    for i in $(seq 1 50); do
        lsof -ti :"$1" -sTCP:LISTEN >/dev/null 2>&1 && return 0
        sleep 0.2
    done
    return 1
}

stop_web() {  # $1=pid
    kill "$1" 2>/dev/null
    wait "$1" 2>/dev/null
    kill_all_mocks
}

run_py() {  # $1=场景名 $2=失败时附加日志(可选)；python 脚本从函数 stdin 读
    local name="$1" log="${2:-}"
    if python3 - 2>"$_TMP/py.err"; then
        green "$name"
    else
        red "$name"
        head -10 "$_TMP/py.err" | sed 's/^/    /'
        if [[ -n "$log" && -f "$log" ]]; then
            echo "    ---- $(basename "$log") 尾部:"
            tail -6 "$log" | sed 's/^/    /'
        fi
    fi
}

echo "═══ webagent ACP E2E (mock agent; LLM mock :$PORT_LLM) ═══"

# ---------- mock LLM（stream-json 回归用例） ----------
BASH_AGENT_TEST_PORT="$PORT_LLM" python3 tests/fixtures/mock_server.py >"$_TMP/llm.log" 2>&1 &
PIDS+=($!)
sleep 1
curl -sS "http://127.0.0.1:$PORT_LLM/" 2>/dev/null | grep -q ok \
    || { echo "mock LLM (: $PORT_LLM) 启动失败:"; cat "$_TMP/llm.log"; exit 1; }

# ---------- 批 A：默认延迟 mock —— 场景链 ----------
export ACP_E2E_PORT="$PORT_ACP"
start_web "$PORT_ACP" "$_TMP/web-acp.log"
wait_ready "$PORT_ACP" || red "webagent(acp :$PORT_ACP) 启动失败"

run_py "S1/S2/S5/S6 场景链: 正常轮 + 工具流_meta + 崩溃自动恢复 + 外部kill恢复" <<'PYEOF'
import asyncio, os, re, signal, subprocess, sys
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has

PORT = int(os.environ["ACP_E2E_PORT"])
fails = []

def check(name, cond, detail=""):
    print(("PASS - " if cond else "FAIL - ") + name + ("" if cond else "  " + str(detail)[:200]))
    if not cond:
        fails.append(name)

def sid_of(evs):
    """从 session_start 事件取 (pid, 计数)；mock sid = mock-<pid>-<计数>。"""
    for e in evs:
        if e.get("type") == "session_start":
            sid = e.get("session_id") or ""
            m = re.match(r"mock-(\d+)-(\d+)$", sid)
            if m:
                return m.groups()
    return None

async def main():
    async with Driver(PORT) as d:
        await d.send("hello")
        evs = await d.pump(15, until=lambda e: e.get("type") == "stop")
        check("S1 stop end_turn", has(evs, "stop", reason="end_turn"), evs)
        check("S1 text 转发", has(evs, "text", content="mock reply: hello"), evs)
        check("S1 usage 转发", has(evs, "usage"), evs)
        check("S1 session_start", has(evs, "session_start"), evs)
        old = sid_of(d.events)
        check("S1 session_start 报告 mock-<pid>-1", old is not None and old[1] == "1", old)

        await d.send("use tool please")
        evs = await d.pump(15, until=lambda e: e.get("type") == "stop")
        check("S2 tool_call name=MockBash", has(evs, "tool_call", name="MockBash"), evs)
        check("S2 tool_result name=MockBash", has(evs, "tool_result", name="MockBash"), evs)
        check("S2 stop end_turn", has(evs, "stop", reason="end_turn"), evs)

        await d.send("please crash now")
        evs = await d.pump(15, until=lambda e: e.get("type") == "process_exit")
        await d.pump(1.0)
        check("S5 崩溃广播 process_exit", has(evs, "process_exit"), evs)
        check("S5 worker error 事件", any(e.get("type") == "error" for e in d.events[-6:]))
        await d.send("after respawn")
        evs = await d.pump(15, until=lambda e: e.get("type") == "stop")
        check("S5 respawn 后正常轮", has(evs, "stop", reason="end_turn"), evs)
        new = sid_of(evs)
        # resume 时 webagent 原样沿用传入 sid → session_start 显示旧 sid（mock-*-1）
        # 恰是 resume 证据；若退化为 session/new 则计数变 2（mock-<新pid>-2）
        check("S5 resume 同会话（sid 原样保留 mock-*-1）",
              bool(old and new and new == old), (old, new))

        out = subprocess.run(["pgrep", "-f", "mock_acp_agent.py"],
                             capture_output=True, text=True).stdout.split()
        victim = None
        for pid in out:
            cmd = subprocess.run(["ps", "-p", pid, "-o", "command="],
                                 capture_output=True, text=True).stdout
            if "webagent" not in cmd:
                victim = pid
                break
        check("S6 找到 mock 进程(排除 webagent 自身)", victim is not None, out)
        if victim:
            os.kill(int(victim), signal.SIGKILL)
            evs = await d.pump(10, until=lambda e: e.get("type") == "process_exit")
            check("S6 外部 kill 后 process_exit", has(evs, "process_exit"), evs)
            await d.send("revive")
            evs = await d.pump(15, until=lambda e: e.get("type") == "stop")
            check("S6 自动恢复后正常轮", has(evs, "stop", reason="end_turn"), evs)

    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF
stop_web "${PIDS[${#PIDS[@]}-1]}"

# ---------- 批 B：取消确认（mock delay 3s，cancel 旁路应即时生效） ----------
export ACP_E2E_PORT="$PORT_CANCEL"
MOCK_DELAY=3 start_web "$PORT_CANCEL" "$_TMP/web-cancel.log"
wait_ready "$PORT_CANCEL" || red "webagent(cancel :$PORT_CANCEL) 启动失败"

run_py "S3 进行中取消 → cancelled 回包（旁路即时）" <<'PYEOF'
import asyncio, json, os, sys, time
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has

PORT = int(os.environ["ACP_E2E_PORT"])

async def main():
    async with Driver(PORT) as d:
        await d.send("slow task")
        await asyncio.sleep(0.6)
        t0 = time.monotonic()
        await d.send(json.dumps({"type": "cancel"}))
        evs = await d.pump(10, until=lambda e: e.get("type") == "stop")
        dt = time.monotonic() - t0
        ok1 = has(evs, "stop", reason="interrupted")
        ok2 = dt < 2.5
        print(("PASS" if ok1 else "FAIL") + " - stop reason=interrupted (got %s)" %
              [e.get("type") for e in evs])
        print(("PASS" if ok2 else "FAIL") + " - 取消→回包 %.2fs (<2.5s, 排队实现会 >3s)" % dt)
        sys.exit(0 if ok1 and ok2 else 1)

asyncio.run(main())
PYEOF
stop_web "${PIDS[${#PIDS[@]}-1]}"

# ---------- 批 C：mock 忽略 cancel —— 无 cancelled 回包 → 强制停止 → respawn+resume ----------
export ACP_E2E_PORT="$PORT_KILL"
MOCK_DELAY=6 MOCK_IGNORE_CANCEL=1 start_web "$PORT_KILL" "$_TMP/web-kill.log" "--cancel-timeout-ms 1000"
wait_ready "$PORT_KILL" || red "webagent(kill :$PORT_KILL) 启动失败"

run_py "S4 忽略取消无回包 → force_kill → respawn+resume" <<'PYEOF'
import asyncio, json, os, re, sys, time
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has

PORT = int(os.environ["ACP_E2E_PORT"])
fails = []

def check(name, cond, detail=""):
    print(("PASS - " if cond else "FAIL - ") + name + ("" if cond else "  " + str(detail)[:200]))
    if not cond:
        fails.append(name)

def sid_of(evs):
    for e in evs:
        if e.get("type") == "session_start":
            m = re.match(r"mock-(\d+)-(\d+)$", e.get("session_id") or "")
            if m:
                return m.groups()
    return None

async def main():
    async with Driver(PORT) as d:
        await d.send("long task")
        await asyncio.sleep(0.6)
        await d.send(json.dumps({"type": "cancel"}))
        evs = await d.pump(2.5)
        check("S4 mock 忽略 cancel → 无 stop(interrupted)",
              not has(evs, "stop"), [e.get("type") for e in evs])

        t0 = time.monotonic()
        await d.send(json.dumps({"type": "force_kill"}))
        evs = await d.pump(10, until=lambda e: e.get("type") == "process_exit")
        check("S4 force_kill → process_exit", has(evs, "process_exit"), evs)
        print("INFO - force_kill → process_exit 耗时 %.2fs (SIGTERM+2s 兜底)" % (time.monotonic() - t0))

        await d.send("after kill")
        evs = await d.pump(15, until=lambda e: e.get("type") == "stop")
        check("S4 强停后 respawn 正常轮", has(evs, "stop", reason="end_turn"), evs)
        check("S4 重新握手 session_start", has(evs, "session_start"), evs)
        sid = sid_of(evs)
        check("S4 resume 同会话计数(mock-<新pid>-1)",
              bool(sid and sid[1] == "1"), sid)

    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF
stop_web "${PIDS[${#PIDS[@]}-1]}"

# ---------- 批 D：默认 stream-json 回归（src/agent.sh + mock LLM） ----------
export ACP_E2E_PORT="$PORT_STREAM" ACP_E2E_LLM_PORT="$PORT_LLM"
ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT_LLM/v1" ANTHROPIC_API_KEY=test \
    BASH_AGENT_HOME="$TEST_HOME" \
    "$BIN" --agent "$ROOT_DIR/src/agent.sh" --port "$PORT_STREAM" >>"$_TMP/web-stream.log" 2>&1 &
PIDS+=($!)
wait_ready "$PORT_STREAM" || red "webagent(stream :$PORT_STREAM) 启动失败"

run_py "S7 默认 stream-json 模式回归不变" "$_TMP/web-stream.log" <<'PYEOF'
import asyncio, os, sys
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has

PORT = int(os.environ["ACP_E2E_PORT"])

async def main():
    import subprocess, urllib.request
    llm_port = os.environ["ACP_E2E_LLM_PORT"]
    ps = subprocess.run(["pgrep", "-fl", "mock_server.py"], capture_output=True, text=True).stdout.strip()
    print("INFO - mock_server 进程:", ps or "无")
    try:
        body = urllib.request.urlopen("http://127.0.0.1:%s/" % llm_port, timeout=3).read()
        print("INFO - LLM 根路径:", body[:40])
    except Exception as e:
        print("INFO - LLM 不可达:", e)
    async with Driver(PORT) as d:
        await d.send("hello")
        evs = await d.pump(45, until=lambda e: e.get("type") == "stop")
        ok1 = has(evs, "stop", reason="end_turn")
        ok2 = any(e.get("type") == "text" for e in evs)
        print(("PASS" if ok1 else "FAIL") + " - stop end_turn")
        print(("PASS" if ok2 else "FAIL") + " - text 事件流正常")
        sys.exit(0 if ok1 and ok2 else 1)

asyncio.run(main())
PYEOF
stop_web "${PIDS[${#PIDS[@]}-1]}"

echo "═══ 结果: $PASS passed, $FAIL failed ═══"
exit $(( FAIL > 0 ))
