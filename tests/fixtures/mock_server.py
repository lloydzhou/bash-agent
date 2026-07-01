import http.server, json, sys, threading
import os

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    # --- Capture last request for external inspection ---
    last_body = b''
    last_headers = {}

    def do_POST(self):
        cl = int(self.headers.get('Content-Length',0))
        body = self.rfile.read(cl)
        path = self.path
        H.last_body = body
        H.last_headers = dict(self.headers)
        # --- Early error returns (must be before send_response(200)) ---
        # SubAgent failure mock: child agent request -> 422 error
        # Only match child requests (no SUB_FAIL_MARKER in body)
        if b'SUB_FAIL_CHILD' in body and b'SUB_FAIL_MARKER' not in body:
            if path.startswith('/v1/messages'):
                self.send_response(422)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error':{'type':'invalid_request','message':'simulated child failure'}},sort_keys=True).encode())
            return
        # SubAgent fork-failure mock: fork child request -> 422 error
        # Fork child inherits parent conversation (which has SUB_FORK_FAIL_MARKER), so
        # we only exclude requests that contain tool_result (those are from main agent).
        if b'SUB_FORK_FAIL_CHILD' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                self.send_response(422)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({'error':{'type':'invalid_request','message':'simulated fork child failure'}},sort_keys=True).encode())
            return
        # --- Normal flow ---
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        w = self.wfile
        if b'The conversation context above needs to be compacted' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_summary\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'Task focus: summarize compact test'}}) + '\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\nLatest request: compact session'}}) + '\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\nProgress: trimmed old context'}}) + '\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'\nTool evidence: none'}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":7}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'role':'assistant','content':'Task focus: summarize compact test'},'finish_reason':None}]}) + '\n\n',
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'content':'\nLatest request: compact session'},'finish_reason':None}]}) + '\n\n',
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'content':'\nProgress: trimmed old context'},'finish_reason':None}]}) + '\n\n',
                    'data: ' + json.dumps({'id':'chatcmpl-summary','object':'chat.completion.chunk','created':1234567890,'model':'gpt-4o','choices':[{'index':0,'delta':{'content':'\nTool evidence: none'},'finish_reason':None}]}) + '\n\n',
                    'data: {\"id\":\"chatcmpl-summary\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- SubAgent mock moved above Skill marker check ---
        if b'Skill marker for tests' in body and b'ANSI_TOOL_RESULT_MARKER' not in body:
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
        if b'TODO_PROMPT_MARKER' in body:
            if path.startswith('/v1/messages'):
                if b'- [ ] inspect repository' in body and b'- [ ] run tests' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_todo_prompt\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Todo injected.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing current todo in prompt')
            return
        if b'TODO_WRITE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_todo_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will track the work and start with repository inspection.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_todo_write_1\",\"name\":\"TodoWrite\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'todos':[{'content':'inspect repository','status':'pending'},{'content':'run tests','status':'pending'},{'content':'fix the first failure','status':'pending'}]})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'TODO_WRITE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'- [ ] inspect repository' in body and b'- [ ] run tests' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_todo_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Todo initialized.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing TodoWrite tool result content')
            return
        if b'PLAN_CLEAR_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_plan_clear\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Plan is complete, I will clear it now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_plan_clear_1\",\"name\":\"PlanClear\",\"input\":{}}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'PLAN_CLEAR_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_plan_clear_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Plan cleared and context compacted.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'SKILL_TOOL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will load the requested skill.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_skill_1\",\"name\":\"Skill\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'name':'test-skill-tool'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'SKILL_TOOL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Skill: test-skill-tool' in body and b'Skill tool marker' in body and b'helper.sh' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_skill_tool_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Skill tool loaded.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Skill tool_result content')
            return
        if b'READ_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-test.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
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
        if b'READ_ARG_PARSE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_arg_parse\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_arg_parse_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-arg-parse.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_ARG_PARSE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'read-arg-parse-content' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_arg_parse_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Read arg parsing complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing read arg parse tool_result content')
            return
        if b'LONG_READ_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_long\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_long_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-long.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'LONG_READ_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'READ-LONG-HEAD' in body and b'READ-LONG-TAIL' in body and b'truncated' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_long_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Long read complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing long read compacted tool_result content')
            return
        if b'GLOB_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search for matching files.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_glob_1\",\"name\":\"Glob\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'*.txt','path':'/tmp/bash-agent-glob-test'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GLOB_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'alpha.txt' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Glob complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Glob tool_result content')
            return
        if b'GLOB_NO_MATCH_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob_none\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search for matching files.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_glob_none_1\",\"name\":\"Glob\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'*.missing','path':'/tmp/bash-agent-glob-nomatch-test'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GLOB_NO_MATCH_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob_none_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Glob no-match complete.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GREP_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search file contents.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_grep_1\",\"name\":\"Grep\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'needle','path':'/tmp/bash-agent-grep-test','glob':'*.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GREP_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'needle line' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Grep complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Grep tool_result content')
            return
        if b'GREP_NO_MATCH_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_none\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search file contents.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_grep_none_1\",\"name\":\"Grep\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'needle','path':'/tmp/bash-agent-grep-nomatch-test','glob':'*.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GREP_NO_MATCH_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_none_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Grep no-match complete.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_OFFSET_LIMIT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_ol\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will read a portion of the file.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_read_ol_1\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-read-offset-limit.txt','offset':3,'limit':2})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'READ_OFFSET_LIMIT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'line-three' in body and b'line-four' in body and b'line-one' not in body and b'line-five' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_read_ol_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Read offset/limit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing or incorrect Read offset/limit content')
            return
        if b'BASH_TIMEOUT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_to\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will run a command with timeout.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_to_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'sleep 30; echo done','timeout':2})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_TIMEOUT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'timed out' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_to_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Bash timeout complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing bash timeout indication')
            return
        if b'GREP_CONTEXT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_ctx\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will search with context.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_grep_ctx_1\",\"name\":\"Grep\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'pattern':'TARGET','path':'/tmp/bash-agent-grep-context-test','context':1})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'GREP_CONTEXT_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'before-line' in body and b'after-line' in body and b'TARGET' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_grep_ctx_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Grep context complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing Grep context content')
            return
        if b'EDIT_FILE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_1\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-test.txt','old_string':'old-value','new_string':'new-value'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_FILE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-test.txt)' in body and b'--- a/tmp/bash-agent-edit-test.txt' not in body and b'@@ -1 +1 @@' not in body:
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
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_nf\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-not-found.txt','old_string':'missing-value','new_string':'new-value'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
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
        if b'EDIT_UNICODE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_unicode\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit with unicode.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_unicode\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-unicode.txt','old_string':'old-text','new_string':'中文 日本語 한국어 🎉 café résumé'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_UNICODE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-unicode.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_unicode_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Unicode edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing unicode edit tool_result content')
            return
        if b'EDIT_SPECIAL_CHARS_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_special\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit with special chars.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_special\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-special.txt','old_string':'plain','new_string':'"quotes" and ' + chr(36) + 'dollar and <html> & ' + chr(39) + 'apos' + chr(39)})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_SPECIAL_CHARS_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-special.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_special_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Special chars edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing special chars edit tool_result content')
            return
        if b'EDIT_MULTILINE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                old_block = 'line4_original\nline5_original\nline6_original\nline7_original\nline8_original'
                new_block = 'line4_replaced_a\nline5_replaced_b\nline6_replaced_c\nline7_replaced_d\nline8_replaced_e\nline9_new_f\nline10_new_g\nline11_new_h'
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_ml\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit multiple lines.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_ml\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-multiline.txt','old_string':old_block,'new_string':new_block})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_MULTILINE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-multiline.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_ml_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Multiline edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing multiline edit tool_result content')
            return
        if b'EDIT_CODE_SNIPPET_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                old_code = 'if err != nil {\n\t\treturn err\n\t}'
                q = chr(34)
                new_code = 'if err != nil {\n\t\tlog.Printf(' + q + 'error: %v' + q + ', err)\n\t\treturn fmt.Errorf(' + q + 'wrap: %w' + q + ', err)\n\t}'
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_code\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will edit the code snippet.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_edit_code\",\"name\":\"Edit\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-edit-code.txt','old_string':old_code,'new_string':new_code})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'EDIT_CODE_SNIPPET_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'Edit(/tmp/bash-agent-edit-code.txt)' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_edit_code_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Code snippet edit complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing code snippet edit tool_result content')
            return
        if b'WRITE_FILE_MARKER' in body and b'"tool_result"' not in body and b'"role":"tool"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will write the file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_write_1\",\"name\":\"Write\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-write-test.txt','content':'line1\nline2\nline3'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"I will write the file now.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_write_1\",\"type\":\"function\",\"function\":{\"name\":\"Write\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/bash-agent-write-test.txt\\\"\"}}]},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\",\\\"content\\\":\\\"line1\\\\nline2\\\\nline3\\\"}\"}}]},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-write\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'UNICODE_WRITE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write_unicode\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I will write the unicode file now.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_write_unicode\",\"name\":\"Write\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-write-unicode.txt','content':'中文\nline2'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'UNICODE_WRITE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_write_unicode_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'WRITE_FILE_MARKER' in body and (b'"tool_result"' in body or b'"role":"tool"' in body):
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
        # --- sensenova-style OpenAI SSE (finish_reason:"" + name:"" in subsequent chunks) ---
        if b'SENSENOVA_STYLE_MARKER' in body and b'"tool_result"' not in body and b'"role":"tool"' not in body:
            if path.startswith('/v1/chat/completions'):
                for c in [
                    # chunk 1: reasoning + tool_call start (id+name present, finish_reason="")
                    'data: {\"id\":\"chatcmpl-sn\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"Calling tool.\"},\"finish_reason\":\"\"}]}\n\n',
                    # chunk 2: tool_call with id+name (finish_reason="")
                    'data: {\"id\":\"chatcmpl-sn\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_sn_1\",\"type\":\"function\",\"function\":{\"name\":\"Write\",\"arguments\":\"\"}}]},\"finish_reason\":\"\"}]}\n\n',
                    # chunk 3: arguments delta — sensenova sends id:"" and name:"" instead of omitting
                    'data: {\"id\":\"chatcmpl-sn\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"\",\"type\":\"function\",\"function\":{\"name\":\"\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/bash-agent-sensenova-test.txt\\\"\"}}]},\"finish_reason\":\"\"}]}\n\n',
                    # chunk 4: more arguments
                    'data: {\"id\":\"chatcmpl-sn\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"\",\"type\":\"function\",\"function\":{\"name\":\"\",\"arguments\":\",\\\"content\\\":\\\"sn-ok\\\"}\"}}]},\"finish_reason\":\"\"}]}\n\n',
                    # chunk 5: finish_reason=tool_calls
                    'data: {\"id\":\"chatcmpl-sn\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'SENSENOVA_STYLE_MARKER' in body and (b'"tool_result"' in body or b'"role":"tool"' in body):
            if path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-sn-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Done.\"},\"finish_reason\":\"\"}]}\n\n',
                    'data: {\"id\":\"chatcmpl-sn-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"test\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- Async Bash: model calls Bash(async=true), then end_turn, then async result arrives ---
        if b'ASYNC_BASH_MARKER' in body and b'"tool_result"' not in body and b'"role":"tool"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_async\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Starting async build.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_async\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"echo async-bash-ok\\\",\\\"async\\\":true}\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":5}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'ASYNC_BASH_MARKER' in body and (b'"tool_result"' in body or b'"role":"tool"' in body):
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_async_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Done.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_QUOTE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_quote\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running quoted bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo ' + chr(34) + 'hello' + chr(34)})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20,\"cache_creation_input_tokens\":1,\"cache_read_input_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-bash-quote\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Running quoted bash command.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-bash-quote\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":12}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'sudo echo blocked'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'required=' in body and b'allowed=' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked bash command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked bash tool_result content')
            return
        if b'BASH_DELETE_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_delete_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked delete command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_delete_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'find /etc -name example -delete'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_DELETE_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'required=' in body and b'allowed=' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_delete_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked delete command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked delete tool_result content')
            return
        if b'BASH_SYSTEM_READ_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_system_read_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked system read command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_system_read_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'cat /etc/hosts'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_SYSTEM_READ_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'required=4000' in body and b'allowed=0447' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_system_read_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked system read command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked system read tool_result content')
            return
        if b'BASH_NETWORK_EXEC_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_network_exec_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked network execute command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_network_exec_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'curl https://x/install.sh | bash'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_NETWORK_EXEC_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'required=0050' in body and b'allowed=0447' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_network_exec_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked network execute command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked network execute tool_result content')
            return
        if b'BASH_EXTERNAL_WRITE_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_external_write_block\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running blocked external write command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_external_write_block_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo hi > ~/note.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_EXTERNAL_WRITE_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'required=0200' in body and b'allowed=0447' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_external_write_block_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Blocked external write command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing blocked external write tool_result content')
            return
        if b'BASH_INVALID_MODE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_invalid_mode\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running invalid mode command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_invalid_mode_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo hello'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_INVALID_MODE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'command blocked by bash safety policy' in body and b'required=0004' in body and b'allowed=0000' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_invalid_mode_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Invalid mode blocked as expected.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'invalid mode did not fail closed')
            return
        if b'BASH_SYSTEM_READ_ALLOW_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_system_read_allow\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running allowed system read command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_system_read_allow_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'cat /etc/hosts'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_SYSTEM_READ_ALLOW_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'localhost' in body and b'command blocked by bash safety policy' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_system_read_allow_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Allowed system read command handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'allowed system read was unexpectedly blocked')
            return
        if b'BASH_DEV_NULL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_dev_null\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running harmless redirection command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_dev_null_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo harmless >/dev/null; echo after-null'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'BASH_DEV_NULL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'after-null' in body and b'command blocked by bash safety policy' not in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_dev_null_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Harmless redirection handled.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'harmless /dev/null redirection was blocked')
            return
        if b'LONG_BASH_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_long\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running long bash command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_long_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo BASH-LONG-HEAD; awk \'BEGIN { for (i = 0; i < 1000; i++) print "middle-middle-middle-middle-middle" }\'; echo BASH-LONG-TAIL'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'LONG_BASH_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'BASH-LONG-HEAD' in body and b'BASH-LONG-TAIL' in body and b'truncated' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_long_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Long bash complete.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing long bash compacted tool_result content')
            return
        if b'TOOL_RESULT_URL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool_result_url\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running URL-producing command.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_url_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
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
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_ansi_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
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
        # --- Bash UTF-8 sanitize: command produces illegal UTF-8 bytes ---
        # Stage 1: return Bash tool call with printf that emits illegal bytes
        if b'BASH_UTF8_SANITIZE_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_utf8\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running command with illegal UTF-8.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_bash_utf8_1\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':"printf '\\x80\\x81\\xc0\\xaf\\xff Hello \\xe4\\xbd\\xa0'"})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2: after tool_result — verify sanitized output is valid UTF-8
        if b'BASH_UTF8_SANITIZE_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                # body must be valid UTF-8 (no illegal bytes leaked into JSON)
                try:
                    body.decode('utf-8')
                except UnicodeDecodeError:
                    self.send_response(422); self.end_headers(); w.write(b'tool_result body contains illegal UTF-8')
                    return
                if b'Hello' in body and b'ufffd' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_bash_utf8_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"UTF-8 sanitized OK.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing sanitized UTF-8 content in tool_result')
            return
        # --- SubAgent 4-stage mock ---
        # Stage 1: main agent first request -> SubAgent tool_call
        if b'SUB_AGENT_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub1\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_sub\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'SUB_CHILD_COUNT','description':'line count'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":10}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2: sub-agent request (body has SUB_CHILD_COUNT, no tool_result)
        if b'SUB_CHILD_COUNT' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub2\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"1545 lines.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 3: main agent after SubAgent tool_result -> acknowledge (not when result context arrives)
        if b'SUB_AGENT_MARKER' in body and b'"tool_result"' in body and b'Sub-agent started' in body and b'[sub-agent sub_' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub3\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Waiting for sub-agent.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 4: main agent after AGENT_RESULT -> final answer
        if b'SUB_AGENT_MARKER' in body and b'[sub-agent sub_' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub4\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Sub-agent reports: 1545 lines.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- SubAgent multi (two SubAgents in one response) ---
        # Stage 1: main agent -> TWO SubAgent tool_calls
        if b'SUB_MULTI_MARKER' in body and b'"tool_result"' not in body and b'SUB_CHILD_A' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi1\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_a\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'SUB_CHILD_A','description':'task A'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_b\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'SUB_CHILD_B','description':'task B'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2a: child A request
        if b'SUB_CHILD_A' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_child_a\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Result A: 42.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2b: child B request
        if b'SUB_CHILD_B' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_child_b\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Result B: 99.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 3: main agent after both tool_results (no [sub-agent] yet)
        if b'SUB_MULTI_MARKER' in body and b'"tool_result"' in body and b'[sub-agent sub_' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi3\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Waiting for sub-agents.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 4: main agent with one or both [sub-agent] results -> final answer
        if b'SUB_MULTI_MARKER' in body and b'[sub-agent sub_' in body:
            if path.startswith('/v1/messages'):
                # Count how many sub-agent results are in the body
                sub_count = body.count(b'[sub-agent sub_')
                if sub_count >= 2:
                    final_text = 'Both results: A=42, B=99.'
                else:
                    final_text = 'Partial result received, waiting for more.'
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi4\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':final_text}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- SubAgent failure mock ---
        # Stage 1: main agent -> SubAgent tool_call with SUB_FAIL_CHILD prompt
        if b'SUB_FAIL_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fail1\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_sub_fail\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'SUB_FAIL_CHILD','description':'failing child'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":10}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 3: main agent after failed SubAgent -> acknowledge
        if b'SUB_FAIL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fail3\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Sub-agent failed.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- SubAgent fork-failure mock ---
        # Stage 1: main agent -> SubAgent tool_call with fork=true, prompt triggers child failure
        if b'SUB_FORK_FAIL_MARKER' in body and b'SUB_FORK_FAIL_CHILD' not in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fork_fail1\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_sub_fork_fail\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'SUB_FORK_FAIL_CHILD','description':'fork failing child','fork':True})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":10}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2: fork child -> 422 error (handled in early error returns above)
        # Stage 3: main agent after fork-fail AGENT_RESULT -> acknowledge
        if b'SUB_FORK_FAIL_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fork_fail3\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fork child failed, no stale content.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- SubAgent fork mock ---
        # Stage 1: main agent first request -> SubAgent tool_call with fork=true
        # 只有当请求体包含 SUB_FORK_MARKER 且不包含 SUB_FORK_CHILD 且不包含 tool_result 时
        if b'SUB_FORK_MARKER' in body and b'SUB_FORK_CHILD' not in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fork1\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_sub_fork\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'SUB_FORK_CHILD','description':'fork test child','fork':True})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":10}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2: sub-agent request (body has SUB_FORK_CHILD, no tool_result)
        # 子 agent 的请求体包含 SUB_FORK_CHILD，且没有 tool_result
        if b'SUB_FORK_CHILD' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fork2\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fork child result: hello from fork.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 3: main agent after SubAgent fork tool_result -> acknowledge
        if b'SUB_FORK_MARKER' in body and b'"tool_result"' in body and b'Sub-agent started' in body and b'[sub-agent sub_' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fork3\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Waiting for fork child.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 4: main agent after AGENT_RESULT -> final answer
        if b'SUB_FORK_MARKER' in body and b'[sub-agent sub_' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_sub_fork4\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fork result: hello from fork.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- SubAgent fork context inheritance mock ---
        # Stage 1: parent -> SubAgent tool_call with fork=true
        if b'FORK_CTX_MARKER' in body and b'FORK_CTX_CHILD' not in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ctx_fork1\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_ctx_fork\",\"name\":\"SubAgent\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':0,'delta':{'type':'input_json_delta','partial_json': json.dumps({'prompt':'FORK_CTX_CHILD','description':'fork context test child','fork':True})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":10}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 2: fork child -> text response
        if b'FORK_CTX_CHILD' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ctx_fork2\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fork child with context.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 3: parent after tool_result -> acknowledge
        if b'FORK_CTX_MARKER' in body and b'"tool_result"' in body and b'Sub-agent started' in body and b'[sub-agent sub_' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ctx_fork3\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Waiting for fork child context.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # Stage 4: parent after AGENT_RESULT -> final answer
        if b'FORK_CTX_MARKER' in body and b'[sub-agent sub_' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ctx_fork4\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Fork context verified.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":5}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # --- End SubAgent mock ---
        if b'MULTI_TOOL_MARKER' in body and b'"tool_result"' not in body and b'"role":"tool"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_multi_tool\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Running two tools.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_read\",\"name\":\"Read\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':1,'delta':{'type':'input_json_delta','partial_json': json.dumps({'path':'/tmp/bash-agent-multi-read.txt'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_multi_bash\",\"name\":\"Bash\",\"input\":{}}}\n\n',
                    'event: content_block_delta\ndata: ' + json.dumps({'type':'content_block_delta','index':2,'delta':{'type':'input_json_delta','partial_json': json.dumps({'command':'echo multi-bash-ok'})}}) + '\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            elif path.startswith('/v1/chat/completions'):
                for c in [
                    'data: {\"id\":\"chatcmpl-multi\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Running two tools.\"},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-multi\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_multi_read\",\"type\":\"function\",\"function\":{\"name\":\"Read\",\"arguments\":\"{\\\"path\\\":\\\"/tmp/bash-agent-multi-read.txt\\\"}\"}},{\"index\":1,\"id\":\"call_multi_bash\",\"type\":\"function\",\"function\":{\"name\":\"Bash\",\"arguments\":\"{\\\"command\\\":\\\"echo \"}}]},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-multi\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"multi-bash-ok\\\"}\"}}]},\"finish_reason\":null}]}\n\n',
                    'data: {\"id\":\"chatcmpl-multi\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20}}\n\n',
                    'data: [DONE]\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'MULTI_TOOL_MARKER' in body and (b'"tool_result"' in body or b'"role":"tool"' in body):
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
            elif path.startswith('/v1/chat/completions'):
                if b'multi-read-content' in body and b'multi-bash-ok' in body:
                    for c in [
                        'data: {\"id\":\"chatcmpl-multi-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Multi-tool complete.\"},\"finish_reason\":null}]}\n\n',
                        'data: {\"id\":\"chatcmpl-multi-done\",\"object\":\"chat.completion.chunk\",\"created\":1234567890,\"model\":\"gpt-4o\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2}}\n\n',
                        'data: [DONE]\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'missing one of the multi-tool results')
            return
        # --- Diff-check e2e markers (DIFF_CHECKLIST.md coverage) ---
        # PL2: PlanConfirm — mock returns PlanConfirm tool call
        if b'PLAN_CONFIRM_MV_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_plan_confirm\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Plan confirmed.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_plan_confirm_1\",\"name\":\"PlanConfirm\",\"input\":{}}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'PLAN_CONFIRM_MV_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_plan_confirm_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Plan confirmed and locked.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        # T5: device write protection — mock tells agent to run dd of=/dev/sda
        if b'DEV_WRITE_BLOCK_MARKER' in body and b'"tool_result"' not in body:
            if path.startswith('/v1/messages'):
                for c in [
                    'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_dev_write\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                    'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Writing to device.\"}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                    'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_dev_write\",\"name\":\"Bash\",\"input\":{\"command\":\"dd if=/dev/zero of=/dev/sda bs=1M count=1\"}}}\n\n',
                    'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n',
                    'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":20}}\n\n',
                    'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                ]: w.write(c.encode()); w.flush()
            return
        if b'DEV_WRITE_BLOCK_MARKER' in body and b'"tool_result"' in body:
            if path.startswith('/v1/messages'):
                if b'blocked' in body or b'refused' in body or b'device' in body:
                    for c in [
                        'event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_dev_write_done\",\"role\":\"assistant\",\"content\":[],\"model\":\"test\",\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\n',
                        'event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n',
                        'event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Device write blocked.\"}}\n\n',
                        'event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n',
                        'event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n',
                        'event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n',
                    ]: w.write(c.encode()); w.flush()
                else:
                    self.send_response(422); self.end_headers(); w.write(b'device write was NOT blocked')
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
        if self.path == '/last-request':
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps({
                'body': H.last_body.decode('utf-8', errors='replace'),
                'headers': {k: v for k, v in H.last_headers.items()}
            }).encode())
            return
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(json.dumps({'status':'ok'}).encode())

httpd = http.server.HTTPServer(('127.0.0.1', int(os.environ['BASH_AGENT_TEST_PORT'])), H)
t = threading.Thread(target=httpd.serve_forever)
t.daemon = True
t.start()
import time
time.sleep(120)
httpd.shutdown()
