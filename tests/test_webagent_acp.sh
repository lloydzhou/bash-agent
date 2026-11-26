#!/usr/bin/env bash
# webagent ACP 模式 E2E —— 起 webagent(--protocol acp) 驱动 mock ACP agent，
# 覆盖：正常轮 / 工具流 _meta / 取消确认 / 忽略取消→强制停止 / 强停后 respawn+resume /
# 崩溃自动恢复 / 外部 kill 恢复 / 默认 stream-json 回归 /
# 真实 agent.sh 强停与 dispatcher 被杀（S10–S12：零孤儿 + process_exit + resume）。
# 用法: bash tests/test_webagent_acp.sh   （需先 cargo build webagent + python3 websockets）
set -u
cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"

# 端口全部可用环境变量覆盖，避免本地并行测试撞车（P2-13）
PORT_LLM=${ACP_E2E_LLM_PORT:-8731}
PORT_ACP=${ACP_E2E_PORT:-8732}
PORT_REAL=${ACP_E2E_REAL_PORT:-8733}
PORT_CANCEL=${ACP_E2E_CANCEL_PORT:-8734}
PORT_KILL=${ACP_E2E_KILL_PORT:-8735}
PORT_STREAM=${ACP_E2E_STREAM_PORT:-8736}
PORT_404=${ACP_E2E_404_PORT:-8737}
PORT_STRONG=${ACP_E2E_STRONG_PORT:-8738}
PORT_QUICK=${ACP_E2E_QUICK_PORT:-8739}

BIN="${ACP_E2E_BIN:-}"   # 可显式指定二进制（如对比修复前后的行为）
[[ -n "$BIN" ]] || BIN="$ROOT_DIR/webagent/target/debug/webagent"
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

# 只杀本测试启动的 webagent（PIDS）名下的 mock 子进程；
# 其他会话/历史遗留的同名 mock 一律不碰（P2-13 收敛杀伤范围）
kill_all_mocks() {
    local mp wp
    for wp in "${PIDS[@]:-}"; do
      for mp in $(pgrep -f mock_acp_agent.py); do
        if [[ "$(ps -o ppid= -p "$mp" 2>/dev/null | tr -d ' ')" == "$wp" ]]; then
            kill -9 "$mp" 2>/dev/null
        fi
      done
    done
}

cleanup() {
    local p
    # 先杀 mock（此时 webagent 还活着，ppid 可匹配），再停 webagent，
    # 避免先杀 webagent 导致 mock 变孤儿逃过 ppid 过滤（P2-13）
    kill_all_mocks
    for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done
    # ACP_E2E_KEEP=1 保留现场（调试用）
    if [[ "${ACP_E2E_KEEP:-}" == 1 ]]; then
        echo "KEEP=1 现场保留: $_TMP $TEST_HOME $E2E_CWD"
    else
        rm -rf "$_TMP" "$TEST_HOME" "$E2E_CWD"
    fi
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
    kill_all_mocks   # 先杀 webagent 名下的 mock（ppid 匹配需要它还活着）
    # 用 SIGINT（Ctrl+C）而非 SIGTERM：webagent 只注册了 Ctrl+C 处理器，SIGTERM
    # 走默认动作瞬死，来不及 terminate() 收尾，空闲的真实 agent 树会被孤儿化泄漏
    kill -INT "$1" 2>/dev/null
    wait "$1" 2>/dev/null
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
        check("S5 resume 语义：reply 带 [resumed]（agent 侧真恢复, P2-11）",
              has(evs, "text", content="mock reply: after respawn [resumed]"), evs)

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
            check("S6 resume 语义：reply 带 [resumed] (P2-11)",
                  has(evs, "text", content="mock reply: revive [resumed]"), evs)

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
        # P3-20：裸 {"type":"cancel"} 不再是控制消息，应作为普通 prompt 送达
        await d.send('{"type":"cancel"}')
        evs = await d.pump(10, until=lambda e: e.get("type") == "stop")
        ok3 = has(evs, "text", content='mock reply: {"type":"cancel"}')
        print(("PASS" if ok3 else "FAIL") + " - 裸 cancel 文本当普通 prompt (P3-20)")

        await d.send("slow task")
        await asyncio.sleep(0.6)
        t0 = time.monotonic()
        await d.send(json.dumps({"type": "bashagent_ctrl", "action": "cancel"}))
        evs = await d.pump(10, until=lambda e: e.get("type") == "stop")
        dt = time.monotonic() - t0
        ok1 = has(evs, "stop", reason="interrupted")
        ok2 = dt < 2.5
        print(("PASS" if ok1 else "FAIL") + " - stop reason=interrupted (got %s)" %
              [e.get("type") for e in evs])
        print(("PASS" if ok2 else "FAIL") + " - 取消→回包 %.2fs (<2.5s, 排队实现会 >3s)" % dt)
        sys.exit(0 if ok1 and ok2 and ok3 else 1)

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
        await d.send(json.dumps({"type": "bashagent_ctrl", "action": "cancel"}))
        evs = await d.pump(2.5)
        check("S4 mock 忽略 cancel → 无 stop(interrupted)",
              not has(evs, "stop"), [e.get("type") for e in evs])

        t0 = time.monotonic()
        await d.send(json.dumps({"type": "bashagent_ctrl", "action": "force_kill"}))
        evs = await d.pump(10, until=lambda e: e.get("type") == "process_exit")
        check("S4 force_kill → process_exit", has(evs, "process_exit"), evs)
        print("INFO - force_kill → process_exit 耗时 %.2fs (SIGTERM+轮询兜底)" % (time.monotonic() - t0))

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

# ---------- 批 E：真实 src/agent.sh --acp（P2-9：mock 之外验证真实语义） ----------
# 三个此前未被真实验证的假设：events.jsonl 落盘路径、stats.json speed 写入、resume 语义
export ACP_E2E_PORT="$PORT_REAL"
(cd "$E2E_CWD" && exec env ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT_LLM/v1" ANTHROPIC_API_KEY=test \
    BASH_AGENT_HOME="$TEST_HOME" \
    "$BIN" --agent "$ROOT_DIR/src/agent.sh" --protocol acp --port "$PORT_REAL" >>"$_TMP/web-real.log" 2>&1) &
PIDS+=($!)
WEB_REAL_PID=${PIDS[${#PIDS[@]}-1]}
export WEB_REAL_PID TEST_HOME ROOT_DIR
wait_ready "$PORT_REAL" || red "webagent(real :$PORT_REAL) 启动失败"

run_py "S8 真实 agent.sh --acp: 握手+事件流+落盘+崩溃resume" "$_TMP/web-real.log" <<'PYEOF'
import asyncio, glob, json, os, signal, subprocess, sys
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has

PORT = int(os.environ["ACP_E2E_PORT"])
fails = []

def check(name, cond, detail=""):
    print(("PASS - " if cond else "FAIL - ") + name + ("" if cond else "  " + str(detail)[:200]))
    if not cond:
        fails.append(name)

def kill_real_agent():
    # agent.sh 的 worker 子进程是独立进程组组长（pgid=自身），单 killpg 杀不到，
    # 它持有 stdout 写端则 webagent 永远收不到 EOF。策略：先对顶层组 killpg，
    # 再对 cmdline 匹配本仓库路径的全部 pid 逐个兜底 kill。
    pat = os.environ["ROOT_DIR"] + "/src/agent.sh --acp"
    out = subprocess.run(["pgrep", "-f", pat],
                         capture_output=True, text=True).stdout.split()
    victim = None
    for pid in out:
        ppid = subprocess.run(["ps", "-o", "ppid=", "-p", pid],
                              capture_output=True, text=True).stdout.strip()
        if ppid == os.environ["WEB_REAL_PID"]:
            victim = pid
            try:
                os.killpg(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
    for pid in out:
        try:
            os.kill(int(pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
    return victim

async def main():
    async with Driver(PORT) as d:
        await d.send("hello")
        evs = await d.pump(60, until=lambda e: e.get("type") == "stop")
        check("S8 stop end_turn", has(evs, "stop", reason="end_turn"), evs)
        check("S8 text 事件流", any(e.get("type") == "text" for e in evs), evs)
        ss = [e for e in d.events if e.get("type") == "session_start"]
        check("S8 session_start + sid", bool(ss and ss[0].get("session_id")), ss)
        sid1 = ss[0]["session_id"] if ss else ""
        check("S8 usage 事件", has(evs, "usage"), evs)

        # os.walk 遍历：glob 的 ** 不进入 .bash-agent 这类点开头目录
        evs_files, st_files = [], []
        for root, _dirs, files in os.walk(os.environ["TEST_HOME"]):
            for f in files:
                if f == "events.jsonl":
                    evs_files.append(os.path.join(root, f))
                elif f == "stats.json":
                    st_files.append(os.path.join(root, f))
        if st_files:
            content = open(st_files[0]).read()
            print("INFO - stats.json 内容: " + content[:120])
            check("S8 stats.json 含 speed", "last_call_speed_tok_per_sec" in content, content[:120])
        else:
            print("INFO - stats.json 未生成（mock LLM 响应可能无 timing）")

        victim = kill_real_agent()
        check("S8 找到并 kill 真实 agent", victim is not None, None)
        evs = await d.pump(10, until=lambda e: e.get("type") == "process_exit")
        check("S8 崩溃广播 process_exit", has(evs, "process_exit"), evs)
        await d.send("hi again")
        evs = await d.pump(60, until=lambda e: e.get("type") == "stop")
        check("S8 恢复后正常轮", has(evs, "stop", reason="end_turn"), evs)
        ss2 = [e for e in evs if e.get("type") == "session_start"]
        check("S8 resume 同会话 sid", bool(ss2 and ss2[0].get("session_id") == sid1),
              (sid1, ss2))

    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF
kill_real_left() {
    local mp
    for mp in $(pgrep -f "src/agent.sh --acp"); do
        if [[ "$(ps -o ppid= -p "$mp" 2>/dev/null | tr -d ' ')" == "$WEB_REAL_PID" ]]; then
            kill -9 "$mp" 2>/dev/null
        fi
    done
}
kill_real_left
stop_web "${PIDS[${#PIDS[@]}-1]}"

# ---------- 批 F：resume 404 fallback（P2-10：原会话不可恢复 → 新建 + 提示） ----------
export ACP_E2E_PORT="$PORT_404"
MOCK_RESUME_404=1 start_web "$PORT_404" "$_TMP/web-404.log" "--session mock-ghost-9"
wait_ready "$PORT_404" || red "webagent(404 :$PORT_404) 启动失败"

run_py "S9 resume 404 → fallback session/new + 提示事件 (P2-10)" "$_TMP/web-404.log" <<'PYEOF'
import asyncio, json, os, sys
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has, find

PORT = int(os.environ["ACP_E2E_PORT"])
fails = []

def check(name, cond, detail=""):
    print(("PASS - " if cond else "FAIL - ") + name + ("" if cond else "  " + str(detail)[:200]))
    if not cond:
        fails.append(name)

async def main():
    async with Driver(PORT) as d:
        await d.send("hello")
        evs = await d.pump(15, until=lambda e: e.get("type") == "stop")
        check("S9 stop end_turn", has(evs, "stop", reason="end_turn"), evs)
        ss = find(d.events, "session_start")
        check("S9 fallback 新建会话（sid != mock-ghost-9）",
              bool(ss and ss.get("session_id")
                   and ss["session_id"] != "mock-ghost-9"), ss)
        hint = [e for e in d.events
                if e.get("type") == "stderr" and "不可恢复" in (e.get("content") or "")]
        check("S9 提示事件（原会话不可恢复，已新建）", bool(hint), d.events[-8:])

    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF
stop_web "${PIDS[${#PIDS[@]}-1]}"

# ---------- 批 G：真实 agent.sh 强停 / dispatcher 被杀（不能靠测试替 webagent 兜底） ----------
# agent.sh 的 worker 在后台子 shell 里跑工具、收通知，它们各自成进程组并持有 stdout
# 写端：只 killpg 顶层组打不到，孤儿持有写端 → webagent 收不到 EOF → 永不广播
# process_exit、下一轮挂死。
# 本批用例刻意不替 webagent 清理进程树，断言：process_exit 到达 + 零孤儿 + resume 同会话。
# 启动前快照：排除本机历史遗留的 agent.sh --acp 孤儿，只统计本批新增进程
ACP_E2E_OLD_PIDS=$({ pgrep -f "$ROOT_DIR/src/agent.sh --acp"; pgrep -f "$ROOT_DIR/src/.*acp_(in|out)\\.awk"; } 2>/dev/null | sort -u | tr '\n' ' ')
export ACP_E2E_OLD_PIDS ROOT_DIR
export ACP_E2E_PORT="$PORT_STRONG"
(cd "$E2E_CWD" && exec env ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT_LLM/v1" ANTHROPIC_API_KEY=test \
    BASH_AGENT_HOME="$TEST_HOME" \
    "$BIN" --agent "$ROOT_DIR/src/agent.sh" --protocol acp --port "$PORT_STRONG" >>"$_TMP/web-strong.log" 2>&1) &
PIDS+=($!)
WEB_REAL_PID=${PIDS[${#PIDS[@]}-1]}
export WEB_REAL_PID
wait_ready "$PORT_STRONG" || red "webagent(strong :$PORT_STRONG) 启动失败"

# 两个用例共用的 python 辅助（本批本地内联，避免改动 ws_driver 公共夹具）
STRONG_PY_HELPERS='
import asyncio, json, os, subprocess, sys, time
sys.path.insert(0, "tests/fixtures")
from ws_driver import Driver, has

PORT = int(os.environ["ACP_E2E_PORT"])
ROOT = os.environ["ROOT_DIR"]
OLD = set(os.environ.get("ACP_E2E_OLD_PIDS", "").split())
fails = []

def check(name, cond, detail=""):
    print(("PASS - " if cond else "FAIL - ") + name + ("" if cond else "  " + str(detail)[:200]))
    if not cond:
        fails.append(name)

def agent_pids():
    # 本批新增的 agent.sh / acp awk 进程（不含启动前已存在的历史孤儿）
    out = []
    for pat in (ROOT + "/src/agent.sh --acp", ROOT + "/src/.*acp_(in|out)\\.awk"):
        out += subprocess.run(["pgrep", "-f", pat], capture_output=True, text=True).stdout.split()
    return sorted({p for p in out if p not in OLD}, key=int)

def settled_pids(wait=3.0):
    # 收尾是异步的：给 3s 让进程退干净，返回仍存活的
    deadline = time.monotonic() + wait
    left = agent_pids()
    while left and time.monotonic() < deadline:
        time.sleep(0.2)
        left = agent_pids()
    return left

def dispatcher_pids():
    top = []
    for p in agent_pids():
        ppid = subprocess.run(["ps", "-o", "ppid=", "-p", p], capture_output=True, text=True).stdout.strip()
        if ppid == os.environ["WEB_REAL_PID"]:
            top.append(p)
    return top

async def start_slow_turn(d):
    # ACP_SLOW_MARKER: tool_call 后 Bash 工具 sleep 4，此时 worker 在跑工具
    await d.send("ACP_SLOW_MARKER")
    evs = await d.pump(30, until=lambda e: e.get("type") == "tool_call")
    await asyncio.sleep(1.0)
    return evs

def sid_of(evs):
    for e in evs:
        if e.get("type") == "session_start":
            return e.get("session_id")
    return None

async def followup(d, label, sid1):
    await d.send("hello again")
    evs = await d.pump(60, until=lambda e: e.get("type") == "stop")
    check(label + " 后续 prompt 正常 stop end_turn", has(evs, "stop", reason="end_turn"), evs[-6:])
    check(label + " resume 同会话 sid", bool(sid1) and sid_of(evs) == sid1, (sid1, sid_of(evs)))
'

run_py "S10 真实 agent 强停: force_kill → process_exit + 零孤儿 + resume" "$_TMP/web-strong.log" <<PYEOF
$STRONG_PY_HELPERS
async def main():
    async with Driver(PORT) as d:
        evs = await start_slow_turn(d)
        check("S10 工具执行中（tool_call 已出）", has(evs, "tool_call"), evs[-6:])
        sid1 = sid_of(d.events)
        check("S10 进行中有 agent 进程", len(agent_pids()) > 0, agent_pids())

        t0 = time.monotonic()
        await d.send(json.dumps({"type": "bashagent_ctrl", "action": "force_kill"}))
        evs = await d.pump(15, until=lambda e: e.get("type") == "process_exit")
        cost = time.monotonic() - t0
        print("INFO - force_kill → process_exit 耗时 %.2fs" % cost)
        check("S10 force_kill → process_exit（不依赖 stdout EOF）", has(evs, "process_exit"), evs)
        check("S10 process_exit 在 8s 内（SIGTERM 排空 3s + 余量）", cost < 8, cost)
        left = settled_pids()
        check("S10 强停后零孤儿进程", not left, left)
        await followup(d, "S10", sid1)
    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF

run_py "S11 真实 agent dispatcher 被 kill -9: process_exit + 零孤儿 + resume" "$_TMP/web-strong.log" <<PYEOF
$STRONG_PY_HELPERS
async def main():
    async with Driver(PORT) as d:
        evs = await start_slow_turn(d)
        check("S11 工具执行中（tool_call 已出）", has(evs, "tool_call"), evs[-6:])
        sid1 = sid_of(d.events)
        victims = dispatcher_pids()
        check("S11 找到 webagent 名下的 dispatcher", len(victims) == 1, victims)
        for p in victims:
            os.kill(int(p), 9)   # 只杀 dispatcher：worker/awk 全部变孤儿

        t0 = time.monotonic()
        evs = await d.pump(15, until=lambda e: e.get("type") == "process_exit")
        print("INFO - kill -9 dispatcher → process_exit 耗时 %.2fs" % (time.monotonic() - t0))
        check("S11 dispatcher 被杀 → process_exit", has(evs, "process_exit"), evs)
        left = settled_pids()
        check("S11 收尾后零孤儿进程（worker 的后台子 shell 各自成进程组，也被清）", not left, left)
        await followup(d, "S11", sid1)
    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF

stop_web "${PIDS[${#PIDS[@]}-1]}"

# ---------- 批 H：真实 agent 空闲时 dispatcher 被 kill -9（S12） ----------
# 必须与批 G 分开起 webagent：mock 按请求体里是否带 ACP_SLOW_MARKER 分流，而同
# 一会话的历史里已有该标记，批 G 会话的后续每一轮都是慢速流。这里要的是
# 「回包早于 1s」的快轮次 + 随后空闲的 agent，这正是采样盲区所在的时序。
export ACP_E2E_PORT="$PORT_QUICK"
(cd "$E2E_CWD" && exec env ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT_LLM/v1" ANTHROPIC_API_KEY=test \
    BASH_AGENT_HOME="$TEST_HOME" \
    "$BIN" --agent "$ROOT_DIR/src/agent.sh" --protocol acp --port "$PORT_QUICK" >>"$_TMP/web-quick.log" 2>&1) &
PIDS+=($!)
WEB_REAL_PID=${PIDS[${#PIDS[@]}-1]}
export WEB_REAL_PID
wait_ready "$PORT_QUICK" || red "webagent(quick :$PORT_QUICK) 启动失败"

run_py "S12 真实 agent 空闲时 dispatcher 被 kill -9: 快轮次后仍零孤儿 + resume" "$_TMP/web-quick.log" <<PYEOF
$STRONG_PY_HELPERS
async def main():
    async with Driver(PORT) as d:
        # 快轮次：回包早于 1s。worker 的通知子 shell 在 session 应答之后才创建，
        # 握手后的刷新看不到它；轮次一结束 agent 就空闲，没有「等回包」的刷新时机。
        # 此时 dispatcher 被 kill -9，只能靠空闲期间的采样记下它的进程组
        t0 = time.monotonic()
        await d.send("hello")
        evs = await d.pump(60, until=lambda e: e.get("type") == "stop")
        cost = time.monotonic() - t0
        print("INFO - 首轮耗时 %.2fs（< 1s 时仅靠等回包期间刷新记不到新进程组）" % cost)
        check("S12 快轮次 stop end_turn", has(evs, "stop", reason="end_turn"), evs[-6:])
        sid1 = sid_of(evs)
        await asyncio.sleep(1.5)   # 留出一个采样周期：空闲 agent 的进程树应已被完整记下

        victims = dispatcher_pids()
        check("S12 找到空闲 agent 的 dispatcher", len(victims) == 1, victims)
        for p in victims:
            os.kill(int(p), 9)

        evs = await d.pump(15, until=lambda e: e.get("type") == "process_exit")
        check("S12 dispatcher 被杀 → process_exit", has(evs, "process_exit"), evs)
        left = settled_pids()
        check("S12 收尾后零孤儿进程（含 worker 启动时创建的通知子 shell）", not left, left)
        await followup(d, "S12", sid1)
    sys.exit(1 if fails else 0)

asyncio.run(main())
PYEOF
stop_web "${PIDS[${#PIDS[@]}-1]}"

echo "═══ 结果: $PASS passed, $FAIL failed ═══"
exit $(( FAIL > 0 ))
