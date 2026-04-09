#!/usr/bin/env bash
# test.sh — Test bash-agent against mock server
# Tests SSE parsing via awk files and agent.sh end-to-end
# Usage: ./test.sh [--no-server] [port]

set -uo pipefail

START_SERVER=true
PORT=9888
for arg in "$@"; do
    case "$arg" in
        --no-server) START_SERVER=false; shift ;;
        *) PORT="$arg" ;;
    esac
done

BASE="http://localhost:$PORT"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT="$ROOT_DIR/src/agent.sh"
AWK_DIR="$ROOT_DIR/src/awk"
PASS=0
FAIL=0

project_key() {
    local cwd
    cwd=$(pwd -P)
    cwd="${cwd#/}"
    cwd="${cwd//\//-}"
    cwd=$(printf '%s' "$cwd" | awk '{ gsub(/[^A-Za-z0-9._-]/, "-"); gsub(/-+/, "-", $0); sub(/^-+/, "", $0); sub(/-+$/, "", $0); print }')
    printf -- '-%s' "$cwd"
}

green() { printf '\033[32m✓ PASS: %s\033[0m\n' "$1"; }
red()   { printf '\033[31m✗ FAIL: %s\033[0m\n' "$1"; }
info()  { printf '\033[36m→ %s\033[0m\n' "$1"; }

# ===== Mock Server (Python) =====
start_mock() {
    python3 -c "
import http.server, json, sys, threading

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_POST(self):
        cl = int(self.headers.get('Content-Length',0))
        body = self.rfile.read(cl)
        path = self.path
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        w = self.wfile
        if b'You are compressing conversation context' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_summary\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Task focus: summarize compact test\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\nLatest request: compact session\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\nProgress: trimmed old context\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\\nTool evidence: none\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Task focus: summarize compact test\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\nLatest request: compact session\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\nProgress: trimmed old context\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\\nTool evidence: none\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'Skill marker for tests' in body:
            if path.startswith('/v1/messages'):
                if b'Skill path marker: ' in body and b'/helper.sh' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from skill-path-aware\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from skill-aware\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-skill\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello from skill-aware\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-skill\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" mock server!\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-skill\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'SKILL_INDEX_MARKER' in body:
            if path.startswith('/v1/messages'):
                if b'test-skill-index: Skill index summary marker' in body and b'Selected-only skill marker' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill_index\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Skill index loaded.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'skill index missing or selected skill content leaked')
            return
        if b'INSTRUCTION_FILE_MARKER' in body:
            if path.startswith('/v1/messages'):
                if b'Global agent instruction marker' in body and b'Project agent instruction marker' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_instruction_file\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Instruction files loaded.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing instruction file content in prompt')
            return
        if b'READ_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_1\",\"name\":\"read_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-test.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'read-test-content' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Read complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing read tool_result content')
            return
        if b'EDIT_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_1\",\"name\":\"edit_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-test.txt','old_string':'old-value','new_string':'new-value'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'OK: edited /tmp/bash-agent-edit-test.txt' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing edit tool_result content')
            return
        if b'EDIT_FILE_NOT_FOUND_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_nf\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_nf\",\"name\":\"edit_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-not-found.txt','old_string':'missing-value','new_string':'new-value'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_NOT_FOUND_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'old_string not found' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_nf_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edit not found handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing not-found tool_result content')
            return
        if b'EDIT_FILE_TOO_LARGE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_big\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_big\",\"name\":\"edit_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-big.txt','old_string':'tiny','new_string':'replaced'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_TOO_LARGE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'file too large for edit_file' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_big_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Edit size guard handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing size guard tool_result content')
            return
        if b'WRITE_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will write the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_write_1\",\"name\":\"write_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-write-test.txt','content':'line1\nline2\nline3'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"I will write the file now.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'WRITE_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-write-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Done.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_QUOTE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_quote\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running quoted bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_1\",\"name\":\"bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo ' + chr(34) + 'hello' + chr(34)})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-bash-quote\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Running quoted bash command.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-bash-quote\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'TOOL_RESULT_URL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool_result_url\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running URL-producing command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_url_1\",\"name\":\"bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo Name: X.jpeg && echo URL: https://example.com/x.jpeg?foo=1&bar=two && echo Local: /tmp/X.jpeg'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'TOOL_RESULT_URL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool_result_url_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Final answer after tool result.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'ANSI_TOOL_RESULT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ansi_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running ANSI output command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_ansi_1\",\"name\":\"bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'printf \"\\033[32mGREEN\\033[0m\\nplain\\n\"'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'ANSI_TOOL_RESULT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'GREEN' in body and b'\x1b[' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ansi_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ANSI output sanitized.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'ansi not sanitized in tool_result')
            return
        if b'MULTI_TOOL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running two tools.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_read\",\"name\":\"read_file\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-multi-read.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_bash\",\"name\":\"bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':2,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo multi-bash-ok'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'MULTI_TOOL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'multi-read-content' in body and b'multi-bash-ok' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Multi-tool complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing one of the multi-tool results')
            return
        if path.startswith('/v1/messages'):
            for c in [
                'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_test\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello from\"}}\n\n',
                'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" mock server!\"}}\n\n',
                'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
            ]: w.write(c.encode()); w.flush()
        elif path.startswith('/v1/chat/completions'):
            for c in [
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hello from\"},\"finish_reason\":null}]}\n\n',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\" OpenAI mock!\"},\"finish_reason\":null}]}\n\n',
                'data: {\"id\":\"chatcmpl-test\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                'data: [DONE]\n\n',
            ]: w.write(c.encode()); w.flush()
        else:
            self.send_response(404); self.end_headers(); w.write(b'not found')

    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps({'status':'ok'}).encode())

httpd = http.server.HTTPServer(('127.0.0.1', $PORT), H)
t = threading.Thread(target=httpd.serve_forever); t.daemon = True; t.start()
import time; time.sleep(120); httpd.shutdown()
" &
    MOCK_PID=$!
    sleep 1
    if ! curl -sS "$BASE/" 2>/dev/null | grep -q ok; then
        echo "Failed to start mock server on $BASE"
        kill $MOCK_PID 2>/dev/null
        exit 1
    fi
}

stop_mock() {
    [[ -n "${MOCK_PID:-}" ]] && kill $MOCK_PID 2>/dev/null
}

# ===== Tests =====

# Test 1: Claude SSE awk parser directly
test_claude_sse() {
    info "Test 1: Claude SSE awk parser"
    local output
    output=$(awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE'
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello from"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" mock server!"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -q "TEXT:Hello from" && echo "$output" | grep -q "TEXT:.*mock" && echo "$output" | grep -q "STOP:end_turn"; then
        green "Claude SSE parser"; ((PASS++)) || true
    else
        red "Claude SSE parser"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 2: Claude SSE tool_use parsing
test_claude_tool_use() {
    info "Test 2: Claude SSE tool_use parsing"
    local output
    output=$(awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE'
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_123","name":"read_file","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/etc/hostname\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -q "TOOL_START:read_file" && echo "$output" | grep -q "TOOL_INPUT:" && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude tool_use"; ((PASS++)) || true
    else
        red "Claude tool_use"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 3: Claude SSE tool_use parsing with quoted command
test_claude_tool_use_quoted_command() {
    info "Test 3: Claude SSE tool_use quoted command"
    local output
    output=$(awk -v verbose=false -f "$AWK_DIR/json.awk" -f "$AWK_DIR/claude_sse.awk" <<'SSE'
event: message_start
data: {"type":"message_start","message":{"id":"msg_test","role":"assistant","content":[],"model":"test","usage":{"input_tokens":10,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_quoted","name":"bash","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"cd /tmp && ls generate.mjs 2>/dev/null || echo \\\"not found\\\"\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}

event: message_stop
data: {"type":"message_stop"}
SSE
)
    if echo "$output" | grep -q 'TOOL_START:bash:toolu_quoted' && echo "$output" | grep -Fq 'TOOL_INPUT:{"command":"cd /tmp && ls generate.mjs 2>/dev/null || echo \"not found\""}' && echo "$output" | grep -q "STOP:tool_use"; then
        green "Claude tool_use quoted command"; ((PASS++)) || true
    else
        red "Claude tool_use quoted command"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 4: OpenAI SSE awk parser
test_openai_sse() {
    info "Test 4: OpenAI SSE awk parser"
    local output
    output=$(awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/openai_sse.awk" <<'SSE'
data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello from"},"finish_reason":null}]}

data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{"content":" OpenAI mock!"},"finish_reason":null}]}

data: {"id":"chatcmpl-test","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":12}}

data: [DONE]
SSE
)
    if echo "$output" | grep -q "TEXT:Hello from" && echo "$output" | grep -q "TEXT:.*OpenAI" && echo "$output" | grep -q "STOP:stop"; then
        green "OpenAI SSE parser"; ((PASS++)) || true
    else
        red "OpenAI SSE parser"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 5: Message format conversion
test_convert_messages() {
    info "Test 5: Message format conversion (Claude → OpenAI)"
    local output
    output=$(printf '%s' '[{"role":"user","content":"hello"}]' | awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/convert_messages.awk")
    if echo "$output" | grep -q '"role":"user"' && echo "$output" | grep -q '"content":"hello"'; then
        green "Message conversion (simple)"; ((PASS++)) || true
    else
        red "Message conversion (simple)"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 6: Tool format conversion
test_convert_tools() {
    info "Test 6: Tool format conversion (Claude → OpenAI)"
    local output
    output=$(printf '%s' '[{"name":"read_file","description":"Read file","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]' | awk -f "$AWK_DIR/json.awk" -f "$AWK_DIR/convert_tools.awk")
    if echo "$output" | grep -q '"type":"function"' && echo "$output" | grep -q '"parameters"'; then
        green "Tool conversion"; ((PASS++)) || true
    else
        red "Tool conversion"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 7: Agent.sh end-to-end with mock (Claude provider)
test_agent_e2e_claude() {
    info "Test 7: Agent.sh e2e (Claude mock)"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "Hello from" && echo "$output" | grep -q "mock"; then
        green "Agent e2e Claude"; ((PASS++)) || true
    else
        red "Agent e2e Claude"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 8: Agent.sh end-to-end with mock (OpenAI provider)
test_agent_e2e_openai() {
    info "Test 8: Agent.sh e2e (OpenAI mock)"
    local output
    output=$("$AGENT" -p openai --base-url "$BASE/v1" -m test --api-key test 'Hello' 2>&1) || true
    if echo "$output" | grep -q "Hello from" && echo "$output" | grep -q "mock"; then
        green "Agent e2e OpenAI"; ((PASS++)) || true
    else
        red "Agent e2e OpenAI"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 9: Compact subcommand
test_agent_compact() {
    info "Test 9: Agent.sh compact subcommand"
    local home_dir session_dir session_file summary_file output
    home_dir=$(mktemp -d)
    session_dir="$home_dir/.bash-agent/projects/$(project_key)"
    mkdir -p "$session_dir"
    session_file="$session_dir/demo.jsonl"
    summary_file="$session_dir/demo.summary.txt"
    : > "$session_file"
    for i in $(seq 1 45); do
        printf '{"role":"user","content":"message %s"}\n' "$i" >> "$session_file"
    done
    output=$(HOME="$home_dir" "$AGENT" compact -p claude --base-url "$BASE/v1" --api-key test --session demo 2>&1) || true
    if echo "$output" | grep -q "Context compacted" && grep -q "Task focus: summarize compact test" "$summary_file" && [[ "$(wc -l < "$session_file")" -eq 4 ]]; then
        green "Agent compact subcommand"; ((PASS++)) || true
    else
        red "Agent compact subcommand"; echo "  Output: $output"; echo "  Session lines: $(wc -l < "$session_file")"; echo "  Summary: $(cat "$summary_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
}

# Test 10: Skill injection
test_agent_skill_injection() {
    info "Test 10: Agent.sh skill injection"
    local skill_dir skill_file output
    skill_dir="$ROOT_DIR/.claude/skills/test-skill"
    skill_file="$skill_dir/SKILL.md"
    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'EOF'
# test-skill

Skill marker for tests
Skill path marker: ${BASH_AGENT_SKILL_DIR}/helper.sh
EOF
    output=$(cd "$ROOT_DIR" && "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test --skill test-skill 'Hello' 2>&1) || true
    rm -rf "$skill_dir"
    if echo "$output" | grep -q "skill-path-aware" && echo "$output" | grep -q "mock"; then
        green "Agent skill injection"; ((PASS++)) || true
    else
        red "Agent skill injection"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_skill_index() {
    info "Test 11: Agent.sh skill index"
    local skill_dir skill_file output
    skill_dir="$ROOT_DIR/.claude/skills/test-skill-index"
    skill_file="$skill_dir/SKILL.md"
    mkdir -p "$skill_dir"
    cat > "$skill_file" <<'EOF'
# test-skill-index

Skill index summary marker

Selected-only skill marker
EOF
    output=$(cd "$ROOT_DIR" && "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'SKILL_INDEX_MARKER' 2>&1) || true
    rm -rf "$skill_dir"
    if echo "$output" | grep -q "Skill index loaded."; then
        green "Agent skill index"; ((PASS++)) || true
    else
        red "Agent skill index"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_instruction_files() {
    info "Test 12: Agent.sh instruction file injection"
    local home_dir global_dir project_file output
    home_dir=$(mktemp -d)
    global_dir="$home_dir/.bash-agent"
    project_file="$ROOT_DIR/AGENTS.md"
    mkdir -p "$global_dir"
    cat > "$global_dir/AGENTS.md" <<'EOF'
Global agent instruction marker
EOF
    cat > "$project_file" <<'EOF'
Project agent instruction marker
EOF
    output=$(cd "$ROOT_DIR" && HOME="$home_dir" "$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'INSTRUCTION_FILE_MARKER' 2>&1) || true
    rm -rf "$home_dir"
    rm -f "$project_file"
    if echo "$output" | grep -q "Instruction files loaded."; then
        green "Agent instruction file injection"; ((PASS++)) || true
    else
        red "Agent instruction file injection"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

# Test 13: Read file end-to-end
test_agent_read_file() {
    info "Test 13: Agent.sh read_file"
    local output target_file
    target_file="/tmp/bash-agent-read-test.txt"
    printf 'read-test-content\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'READ_FILE_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Read complete."; then
        green "Agent read_file"; ((PASS++)) || true
    else
        red "Agent read_file"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# Test 14: Edit file end-to-end
test_agent_edit_file() {
    info "Test 14: Agent.sh edit_file"
    local output target_file
    target_file="/tmp/bash-agent-edit-test.txt"
    printf 'prefix old-value suffix\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_FILE_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Edit complete." && grep -q 'new-value' "$target_file" && ! grep -q 'old-value' "$target_file"; then
        green "Agent edit_file"; ((PASS++)) || true
    else
        red "Agent edit_file"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_file_not_found() {
    info "Test 15: Agent.sh edit_file missing old_string"
    local output target_file
    target_file="/tmp/bash-agent-edit-not-found.txt"
    printf 'prefix old-value suffix\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_FILE_NOT_FOUND_MARKER' 2>&1) || true
    if echo "$output" | grep -q "old_string not found" && grep -q 'old-value' "$target_file" && ! grep -q 'new-value' "$target_file"; then
        green "Agent edit_file missing old_string"; ((PASS++)) || true
    else
        red "Agent edit_file missing old_string"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

test_agent_edit_file_too_large() {
    info "Test 16: Agent.sh edit_file file size guard"
    local output target_file
    target_file="/tmp/bash-agent-edit-big.txt"
    head -c 1048577 /dev/zero | tr '\0' 'a' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'EDIT_FILE_TOO_LARGE_MARKER' 2>&1) || true
    if echo "$output" | grep -q "file too large for edit_file" && [[ $(wc -c < "$target_file") -gt 1048576 ]]; then
        green "Agent edit_file file size guard"; ((PASS++)) || true
    else
        red "Agent edit_file file size guard"; echo "  Output: $output"; echo "  Size: $(wc -c < "$target_file")"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# Test 17: Write file preserves newlines
test_agent_write_file_newlines() {
    info "Test 17: Agent.sh write_file newline handling"
    local output target_file
    target_file="/tmp/bash-agent-write-test.txt"
    rm -f "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test -v 'WRITE_FILE_MARKER' 2>&1) || true
    if [[ -f "$target_file" ]] && grep -q $'line1\nline2\nline3' "$target_file"; then
        green "Agent write_file newline handling"; ((PASS++)) || true
    else
        red "Agent write_file newline handling"; echo "  Output: $output"; echo "  File: $(cat "$target_file" 2>/dev/null || true)"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# Test 18: Bash tool preserves quoted command content
test_agent_bash_quotes() {
    info "Test 18: Agent.sh bash tool quoted command"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test -v 'BASH_QUOTE_MARKER' 2>&1) || true
    if echo "$output" | grep -q "hello" && ! echo "$output" | grep -q "no command provided"; then
        green "Agent bash quoted command"; ((PASS++)) || true
    else
        red "Agent bash quoted command"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_tool_result_multiline_url() {
    info "Test 19: Agent.sh tool_result multiline URL"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'TOOL_RESULT_URL_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Final answer after tool result"; then
        green "Agent tool_result multiline URL"; ((PASS++)) || true
    else
        red "Agent tool_result multiline URL"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_tool_result_strips_ansi() {
    info "Test 20: Agent.sh tool_result strips ANSI"
    local output
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'ANSI_TOOL_RESULT_MARKER' 2>&1) || true
    if echo "$output" | grep -q "ANSI output sanitized."; then
        green "Agent tool_result strips ANSI"; ((PASS++)) || true
    else
        red "Agent tool_result strips ANSI"; echo "  Output: $output"; ((FAIL++)) || true
    fi
}

test_agent_multiple_tool_calls() {
    info "Test 21: Agent.sh multiple tool calls in one turn"
    local output target_file
    target_file="/tmp/bash-agent-multi-read.txt"
    printf 'multi-read-content\n' > "$target_file"
    output=$("$AGENT" -p claude --base-url "$BASE/v1" -m test --api-key test 'MULTI_TOOL_MARKER' 2>&1) || true
    if echo "$output" | grep -q "Multi-tool complete."; then
        green "Agent multiple tool calls"; ((PASS++)) || true
    else
        red "Agent multiple tool calls"; echo "  Output: $output"; ((FAIL++)) || true
    fi
    rm -f "$target_file"
}

# ===== Main =====

if $START_SERVER; then
    trap stop_mock EXIT
    start_mock
fi

test_claude_sse
test_claude_tool_use
test_claude_tool_use_quoted_command
test_openai_sse
test_convert_messages
test_convert_tools
test_agent_e2e_claude
test_agent_e2e_openai
test_agent_compact
test_agent_skill_injection
test_agent_skill_index
test_agent_instruction_files
test_agent_read_file
test_agent_edit_file
test_agent_edit_file_not_found
test_agent_edit_file_too_large
test_agent_write_file_newlines
test_agent_bash_quotes
test_agent_tool_result_multiline_url
test_agent_tool_result_strips_ansi
test_agent_multiple_tool_calls

echo ""
echo "=============================="
printf "Results: \033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "=============================="

(( FAIL > 0 )) && exit 1 || exit 0
