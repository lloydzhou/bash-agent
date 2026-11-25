#!/usr/bin/env python3
"""最小 ACP mock agent —— tests/test_webagent_acp.sh 专用。

stdin/stdout 行分隔 JSON-RPC；行为由环境变量控制：
- MOCK_DELAY（秒，默认 0.2）：prompt 回包前的延迟
- MOCK_IGNORE_CANCEL=1：忽略 session/cancel（不回 cancelled，模拟取消无响应）
- prompt 文本含 "crash"：SIGKILL 自杀（不回包，模拟 agent 崩溃）
- prompt 文本含 "tool"：额外发 tool_call + tool_call_update（测 _meta 工具名转发）
- 每轮 prompt 附带一条 _bash-agent/usage 通知（测 usage 转发）

session/new 的 sessionId 格式为 mock-<pid>-<计数>；session/resume 原样返回
传入 id —— 测试用「计数不变且 pid 变化」断言走了 resume 而不是 new。
"""
import json
import os
import signal
import sys
import threading
import time

DELAY = float(os.environ.get("MOCK_DELAY", "0.2"))
IGNORE_CANCEL = os.environ.get("MOCK_IGNORE_CANCEL") == "1"

LOCK = threading.Lock()
STATE = {"cancelled": False}
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
    send({"jsonrpc": "2.0", "method": "session/update", "params": {
        "sessionId": SID, "update": {
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": "mock reply: " + text}}}})
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
            send({"jsonrpc": "2.0", "id": msg["id"], "result": {"sessionId": SID}})
        elif method == "session/resume":
            SID = msg["params"]["sessionId"]
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
