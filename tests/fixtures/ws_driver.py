"""webagent WS E2E 驱动 —— tests/test_webagent_acp.sh 各场景通过 heredoc 引用。"""
import asyncio
import json


class Driver:
    """单条 WS 连接：send 发消息，pump 收事件直到条件满足或超时。"""

    def __init__(self, port):
        self.port = port
        self.ws = None
        self.events = []

    async def __aenter__(self):
        self.ws = await websockets_connect("ws://127.0.0.1:%d/ws" % self.port)
        return self

    async def __aexit__(self, *exc):
        await self.ws.close()

    async def send(self, text):
        await self.ws.send(text)

    async def pump(self, timeout=15, until=None):
        """持续收事件；until(evt) 为真或超时则停。返回本次新收事件列表。"""
        got = []
        deadline = asyncio.get_event_loop().time() + timeout
        try:
            while True:
                left = deadline - asyncio.get_event_loop().time()
                if left <= 0:
                    break
                line = await asyncio.wait_for(self.ws.recv(), timeout=left)
                try:
                    obj = json.loads(line)
                except ValueError:
                    obj = {"type": "raw", "content": line}
                self.events.append(obj)
                got.append(obj)
                if until and until(obj):
                    break
        except asyncio.TimeoutError:
            pass
        return got


async def websockets_connect(url):
    import websockets
    return await websockets.connect(url)


def has(evs, t, **kw):
    """存在 type=t 且全部关键字段匹配的事件。"""
    return find(evs, t, **kw) is not None


def find(evs, t, **kw):
    for e in evs:
        if e.get("type") == t and all(e.get(k) == v for k, v in kw.items()):
            return e
    return None
