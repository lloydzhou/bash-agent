#!/usr/bin/env python3
"""串行本地 SSE 回归：速度必须包含终态事件之后的读流时间。"""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        mode, provider = self.server.mode, self.server.provider
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        self.wfile.flush()

        def event(name, data):
            if provider == 'claude' and isinstance(data, dict):
                data = dict(data, type=name)
            elif provider == 'openai' and isinstance(data, dict) and 'choices' in data:
                data = dict(data, object='chat.completion.chunk')
            prefix = f'event: {name}\n' if name else ''
            value = data if isinstance(data, str) else json.dumps(data)
            self.wfile.write(f'{prefix}data: {value}\n\n'.encode())
            self.wfile.flush()

        if provider == 'claude':
            event('message_start', {'message': {'usage': {'input_tokens': 10}}})
        time.sleep(0.15)
        if mode == 'failure':
            event('error', {'type': 'error', 'error': {'message': 'test failure'}, 'message': 'test failure'})
            return
        if mode == 'eof':
            if provider == 'claude':
                event('message_delta', {'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': 50}})
            elif provider == 'openai':
                event('', {'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}],
                           'usage': {'prompt_tokens': 10, 'completion_tokens': 50}})
            return
        output = 0 if mode == 'zero' else 100
        input_tokens = 0 if mode == 'zero' else 10
        if provider == 'claude':
            event('message_start', {'message': {'usage': {'input_tokens': input_tokens}}})
            event('message_delta', {'delta': {'stop_reason': 'end_turn'}, 'usage': {'output_tokens': output}})
            event('message_stop', {})
        elif provider == 'openai':
            event('', {'choices': [{'index': 0, 'delta': {'content': 'ok'}, 'finish_reason': 'stop'}],
                       'usage': {'prompt_tokens': input_tokens, 'completion_tokens': output}})
            event('', '[DONE]')
        else:
            event('response.completed', {'response': {'status': 'completed', 'output': [],
                  'usage': {'input_tokens': input_tokens, 'output_tokens': output}}})
        # 若在 message_stop / DONE / completed 计时，速度约 666，而非约 86。
        time.sleep(1.0)


def main():
    agent = str(Path(sys.argv[1]).resolve())
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        for provider in ('claude', 'openai', 'responses'):
            server.provider = provider
            with tempfile.TemporaryDirectory(prefix='agent-speed-') as home:
                env = dict(os.environ, BASH_AGENT_HOME=home)
                command = [agent, '-p', provider, '--base-url', f'http://127.0.0.1:{server.server_port}/v1',
                           '-m', 'test', '--api-key', 'test', '--session', 'speed-regression', 'speed test']

                def run(mode):
                    server.mode = mode
                    result = subprocess.run(command, env=env, capture_output=True, timeout=30)
                    files = list(Path(home).rglob('stats.json'))
                    assert len(files) == 1, (provider, mode, result.stderr.decode(errors='replace'))
                    speed = json.loads(files[0].read_text())['last_call_speed_tok_per_sec']
                    assert type(speed) is int, (provider, mode, speed)
                    return speed, result

                speed, result = run('success')
                assert result.returncode == 0, result.stderr.decode(errors='replace')
                assert 40 <= speed <= 110, (provider, '计时未覆盖完整流', speed)
                for mode in ('failure', 'eof'):
                    actual, _ = run(mode)
                    assert actual == speed, (provider, mode, '覆盖上次速度', speed, actual)
                actual, result = run('zero')
                assert result.returncode == 0, result.stderr.decode(errors='replace')
                assert actual == 0, (provider, '零输出应清零速度', actual)
                print(f'{Path(agent).name} {provider}: 速度={speed}，失败/提前结束保留，零输出清零', flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    main()
