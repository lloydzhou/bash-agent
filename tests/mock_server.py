#!/usr/bin/env python3
"""简单的 mock server 用于测试 C agent"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import sys

class MockHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/v1/messages':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            request = json.loads(body)
            
            # 获取用户消息
            messages = request.get('messages', [])
            user_msg = ""
            for msg in messages:
                if msg.get('role') == 'user':
                    content = msg.get('content', [])
                    for c in content:
                        if c.get('type') == 'text':
                            user_msg = c.get('text', '')
                            break
            
            # 生成响应
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            
            # 发送 SSE 事件
            response_text = f"Echo: {user_msg}"
            
            # message_start
            event = {
                "type": "message_start",
                "message": {
                    "id": "msg_mock",
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": "mock-model",
                    "usage": {"input_tokens": 10, "output_tokens": 0}
                }
            }
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            
            # content_block_start
            event = {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "text", "text": ""}
            }
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            
            # content_block_delta
            event = {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "text_delta", "text": response_text}
            }
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            
            # content_block_stop
            event = {"type": "content_block_stop", "index": 0}
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            
            # message_delta
            event = {
                "type": "message_delta",
                "delta": {"stop_reason": "end_turn"},
                "usage": {"output_tokens": 20}
            }
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            
            # message_stop
            event = {"type": "message_stop"}
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # 静默日志
        pass

def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    server = HTTPServer(('127.0.0.1', port), MockHandler)
    print(f"Mock server running on http://127.0.0.1:{port}")
    server.serve_forever()

if __name__ == '__main__':
    main()
