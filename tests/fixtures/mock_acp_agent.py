#!/usr/bin/env python3
"""最小 ACP mock agent —— tests/test_webagent_acp.sh 专用。

stdin/stdout 行分隔 JSON-RPC；行为由环境变量控制：
- MOCK_DELAY（秒，默认 0.2）：prompt 回包前的延迟
- MOCK_IGNORE_CANCEL=1：忽略 session/cancel（不回 cancelled，模拟取消无响应）
- MOCK_RESUME_404=1：session/resume 回 -32002 会话不存在（测 webagent
  resume 失败 fallback 到 session/new 的分支，P2-10）
- prompt 文本含 "crash"：SIGKILL 自杀（不回包，模拟 agent 崩溃）
- prompt 文本含 "tool"：额外发 tool_call + tool_call_update（测 _meta 工具名转发）
- 每轮 prompt 附带一条 _bash-agent/usage 通知（测 usage 转发）

session/new 的 sessionId 格式为 mock-<pid>-<计数>；session/resume 原样返回
传入 id —— 测试用「计数不变且 pid 变化」断言走了 resume 而不是 new。
resume 成功后回复文本带 [resumed] 后缀（P2-11：让 E2E 能断言 agent 侧
真的恢复了会话，而不只是 webagent 没丢 target）。
"""
import json
import os
import signal
import sys
import threading
import time

DELAY = float(os.environ.get("MOCK_DELAY", "0.2"))
IGNORE_CANCEL = os.environ.get("MOCK_IGNORE_CANCEL") == "1"
RESUME_404 = os.environ.get("MOCK_RESUME_404") == "1"

LOCK = threading.Lock()
STATE = {"cancelled": False, "resumed": False}
SID = None
NEW_COUNT = 0


def send(obj):
    with LOCK:
        sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
        sys.stdout.flush()


def prompt_worker(req_id, text):
    STATE["cancelled"] = False
    if "crash" in text:
        os.kill(os.getpid(), signal.SIGKILL)
    if "tool" in text:
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SID, "update": {
                "sessionUpdate": "tool_call", "toolCallId": "mock-tool-1",
                "kind": "execute", "status": "in_progress",
                "rawInput": {"command": "echo"},
                "_meta": {"bash-agent": {"name": "MockBash"}}}}})
    # 分片轮询 cancelled：cancel 通知一到即提前结束延迟
    end = time.time() + DELAY
    while time.time() < end and not STATE["cancelled"]:
        time.sleep(0.02)
    if "tool" in text:
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": SID, "update": {
                "sessionUpdate": "tool_call_update", "toolCallId": "mock-tool-1",
                "status": "completed",
                "content": [{"type": "content",
                             "content": {"type": "text", "text": "ok"}}],
                "_meta": {"bash-agent": {"name": "MockBash"}}}}})
    reply = "mock reply: " + text
    if STATE["resumed"]:
        reply += " [resumed]"
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": SID, "update": {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": reply}}}})
    send({"jsonrpc": "2.0", "method": "_bash-agent/usage", "params": {
        "type": "usage", "input_tokens": 1, "output_tokens": 2}})
    reason = "cancelled" if STATE["cancelled"] else "end_turn"
    send({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": reason}})


def main():
    global SID, NEW_COUNT
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            continue
        method = msg.get("method")
        if method is None:
            continue  # mock 不处理 client 侧回包
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {
                "protocolVersion": 1, "agentCapabilities": {}}})
        elif method == "session/new":
            NEW_COUNT += 1
            SID = "mock-%d-%d" % (os.getpid(), NEW_COUNT)
            STATE["resumed"] = False
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": SID}})
        elif method == "session/resume":
            if RESUME_404:
                send({"jsonrpc": "2.0", "id": msg["id"], "error": {
                    "code": -32002,
                    "message": "Session not found: %s" % msg["params"].get("sessionId")}})
            else:
                SID = msg["params"]["sessionId"]
                STATE["resumed"] = True
                send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": SID}})
        elif method == "session/prompt":
            text = "".join(c.get("text", "")
                           for c in msg["params"].get("prompt", []))
            threading.Thread(
                target=prompt_worker, args=(msg["id"], text), daemon=True).start()
        elif method == "session/cancel":
            if not IGNORE_CANCEL:
                STATE["cancelled"] = True


if __name__ == "__main__":
    main()
