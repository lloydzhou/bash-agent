#!/usr/bin/env bash
# mock-server.sh — Minimal HTTP mock server for testing agent.sh
# Uses Python's http.server (available on any macOS/Linux with python3)
# Usage: ./mock-server.sh [port]
# Defaults to port 8888

PORT="${1:-8888}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cat <<EOF
Mock SSE server starting on http://localhost:$PORT
  Claude API:       http://localhost:$PORT/v1/messages
  OpenAI Chat:      http://localhost:$PORT/v1/chat/completions
  OpenAI Responses: http://localhost:$PORT/v1/responses
  Test with tool:  http://localhost:$PORT/v1/messages?test=tool_use

Press Ctrl+C to stop.
EOF

python3 -c "
import http.server
import json
import sys

PORT = $PORT

class MockHandler(http.server.BaseHTTPRequestHandler):
    def log(self, msg):
        print(f'  [{self.path}] {msg}', file=sys.stderr)

    def send_sse(self, events):
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        for event in events:
            if 'data: [DONE]' in event:
                self.wfile.write(('data: [DONE]\n\n').encode())
            else:
                for line in event.strip().split('\n'):
                    self.wfile.write((line + '\n').encode())
            self.wfile.flush()
        self.log('SSE complete')

    def do_POST(self):
        content_len = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_len) if content_len > 0 else ''
        self.log(f'Body: {body[:200]}...')
        test = self.path.split('?')[-1] if '?' in self.path else ''

        if b'Skill marker for tests' in body:
            self.send_sse([
                'event: message_start',
                'data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-4-20250514\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}',
                '',
                'event: content_block_start',
                'data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}',
                '',
                'event: content_block_delta',
                'data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from skill-aware\"}}',
                '',
                'event: content_block_delta',
                'data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}',
                '',
                'event: content_block_stop',
                'data: {\"type\":\"content_block_stop\",\"index\":0}',
                '',
                'event: message_delta',
                'data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}',
                '',
                'event: message_stop',
                'data: {\"type\":\"message_stop\"}',
            ])
            return

        if self.path.startswith('/v1/messages'):
            if test == 'tool_use':
                self.send_sse([
                    'event: message_start',
                    'data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-4-20250514\",\"usage\":{\"input_tokens\":15,\"output_tokens\":0}}}',
                    '',
                    'event: content_block_start',
                    'data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}',
                    '',
                    'event: content_block_delta',
                    'data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read that file.\"}}',
                    '',
                    'event: content_block_stop',
                    'data: {\"type\":\"content_block_stop\",\"index\":0}',
                    '',
                    'event: content_block_start',
                    'data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_mock123\",\"name\":\"read_file\",\"input\":{}}}',
                    '',
                    'event: content_block_delta',
                    'data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"/etc/hostname\\\"}\"}}',
                    '',
                    'event: content_block_stop',
                    'data: {\"type\":\"content_block_stop\",\"index\":1}',
                    '',
                    'event: message_delta',
                    'data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}',
                    '',
                    'event: message_stop',
                    'data: {\"type\":\"message_stop\"}',
                ])
            else:
                self.send_sse([
                    'event: message_start',
                    'data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"claude-sonnet-4-20250514\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}',
                    '',
                    'event: content_block_start',
                    'data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}',
                    '',
                    'event: content_block_delta',
                    'data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from\"}}',
                    '',
                    'event: content_block_delta',
                    'data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}',
                    '',
                    'event: content_block_stop',
                    'data: {\"type\":\"content_block_stop\",\"index\":0}',
                    '',
                    'event: message_delta',
                    'data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}',
                    '',
                    'event: message_stop',
                    'data: {\"type\":\"message_stop\"}',
                ])

        elif self.path.startswith('/v1/chat/completions'):
            self.send_sse([
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello from\"},\"finish_reason\":null}]}',
                '',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" OpenAI mock!\"},\"finish_reason\":null}]}',
                '',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" How can I help?\"},\"finish_reason\":null}]}',
                '',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}',
                '',
                'data: [DONE]',
            ])

        elif self.path.startswith('/v1/responses'):
            self.send_sse([
                'data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}',
                '',
                'data: {\"type\":\"response.content_part.added\",\"output_index\":0,\"content_index\":0,\"part\":{\"type\":\"output_text\",\"text\":\"\"}}',
                '',
                'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"Hello from\"}',
                '',
                'data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\" Responses API mock!\"}',
                '',
                'data: {\"type\":\"response.output_text.done\",\"output_index\":0,\"content_index\":0,\"text\":\"Hello from Responses API mock!\"}',
                '',
                'data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_test\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":8}}}',
                '',
                'data: [DONE]',
            ])
        else:
            self.send_response(404)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'error': f'Not found: {self.path}'}).encode())

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'status': 'ok', 'endpoints': ['/v1/messages', '/v1/chat/completions', '/v1/responses']}).encode())

httpd = http.server.HTTPServer(('127.0.0.1', PORT), MockHandler)
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    print('\nMock server stopped.')
"

# Keep PID so we can kill it
MOCK_PID=$!
echo "PID: $MOCK_PID"
echo ""
echo "Quick test commands:"
echo "  ./agent.sh -p claude --base-url http://localhost:$PORT -m test-model --raw 'Hello'"
echo "  ./agent.sh -p openai --base-url http://localhost:$PORT -m test-model --raw 'Hello'"
echo ""
echo "Or run tests:"
echo "  bash test.sh $PORT"
echo ""
echo "Press Ctrl+C to stop."
wait $MOCK_PID
