# 三协议大图、原数组、路径边界及关闭路径回归。
import pathlib, tempfile, subprocess, json, base64, os, struct, zlib, time
# 默认保留大图压力测试；功能回归可指定较小尺寸，独立报告协议转换瓶颈。
size = int(os.environ.get('VISION_TEST_SIZE', '640'))
repo = pathlib.Path(__file__).resolve().parents[1]
temporary = tempfile.TemporaryDirectory()
root = pathlib.Path(temporary.name).resolve()
(root / 's/images').mkdir(parents=True)
images = []
for i in range(1, 3):

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = b''.join((b'\x00' + os.urandom(size * 3) for _ in range(size)))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
    p = root / f's/images/{i}.png'
    p.write_bytes(png)
    images.append(p)
text = '<attached-images>\nThese placeholders map to local image files:\n' + '\n'.join((f'[Image #{i}] => {p}' for (i, p) in enumerate(images, 1))) + '\nUse <skill-index>\n</attached-images>'
body = {'model': 'test', 'max_tokens': 100, 'messages': [{'role': 'user', 'content': text}]}
(root / 'body').write_text(json.dumps(body))
# 通过真实消息读取入口展开，发送阶段仅捕获请求，不访问网络。
read_and_send = f"""
AGENT_VISION=on
TOOL_DEF_JSON='[]'
CONV_FILE='{root}/conv.jsonl'
python3 -c 'import json,sys; [print(json.dumps(m, ensure_ascii=False)) for m in json.load(sys.stdin)["messages"]]' < '{root}/body' > "$CONV_FILE"
agent_build_prompt() {{ printf '固定提示'; }}
llm_stream_curl() {{ cat; }}
sse_convert() {{ cat; }}
sse_parse() {{ cat; }}
messages=$(store_conv_get_messages) || exit 1
llm_call "$messages"
"""
for source in ['src/agent.sh', 'dist/agent.sh']:
    for provider in ['claude', 'openai', 'responses']:
        library = root / 'library.sh'
        library.write_text((repo / source).read_text().rsplit('main "$@"', 1)[0])
        script = f"""source '{library}'\nAWK_DIR='{repo}/src/awk'\nstore_session_get_dir() {{ printf '%s' '{root}'; }}\nPROVIDER={provider}\nAPI_KEY=test\nvalidate_config\n{read_and_send}\n"""
        started = time.monotonic()
        r = subprocess.run(['bash', '-c', script], capture_output=True, timeout=40)
        assert r.returncode == 0, r.stderr
        data = json.loads(r.stdout)
        if provider == 'claude':
            assert [b['type'] for b in data['messages'][0]['content']] == ['image'] * len(images)
        assert '<attached-images>' not in r.stdout.decode(), (source, provider)
        assert (root / 'body').read_text() == json.dumps(body)
        encoded = []

        def scan(x):
            if isinstance(x, dict):
                for (k, v) in x.items():
                    if k == 'data':
                        encoded.append(v)
                    elif k in ('image_url', 'url') and isinstance(v, str):
                        encoded.append(v.split(',', 1)[1])
                    else:
                        scan(v)
            elif isinstance(x, list):
                for v in x:
                    scan(v)
        scan(data)
        assert [base64.b64decode(v) for v in encoded] == [p.read_bytes() for p in images], (source, provider)
        print(source, provider, '通过', len(r.stdout), '耗时', round(time.monotonic() - started, 3), flush=True)
        for quoted in [text, text.replace('/images/1.png', '/images/99.png')]:
            for content in [quoted, [{'type': 'text', 'text': quoted}]]:
                (root / 'body').write_text(json.dumps(dict(body, messages=[{'role': 'assistant', 'content': content}])))
                run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
                assert run.returncode == 0, (source, provider, run.stderr)
                encoded.clear()
                scan(json.loads(run.stdout))
                assert not encoded, (source, provider, '助手映射不应编码')
        (root / 'body').write_text(json.dumps(body))
script = f"""source '{root}/library.sh'\nAWK_DIR='{repo}/src/awk'\nstore_session_get_dir() {{ printf '%s' '{root}'; }}\nutil_body_convert() {{ cat; }}\n{read_and_send}\n"""
for content in [[{'type': 'text', 'text': text}], str(images[0]), text.replace(str(images[0]), str(root / '../images/1.png')), text.replace('/images/1.png', '/images/99.png')]:
    (root / 'body').write_text(json.dumps(dict(body, messages=[{'role': 'user', 'content': content}])))
    run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
    if isinstance(content, list):
        assert run.returncode == 0, run.stderr
        assert [b['type'] for b in json.loads(run.stdout)['messages'][0]['content']] == ['image'] * len(images)
    elif content == str(images[0]):
        assert json.loads(run.stdout)['messages'][0]['content'] == content
    else:
        assert run.returncode != 0
plain = '[Image #1] [Image #2] 图片内容是什么？'
other = {'type': 'image', 'source': {'type': 'url', 'url': 'https://example.com/image.png'}}
untouched = '<attached-images>\n没有有效映射\n</attached-images>'
for content, expected in [
    (plain + '\n\n' + text, [{'type': 'text', 'text': plain}]),
    ([{'type': 'text', 'text': plain + '\n\n' + text, 'extra': '保留'}, other,
      {'type': 'text', 'text': '后文'}],
     [{'type': 'text', 'text': plain, 'extra': '保留'}, other, {'type': 'text', 'text': '后文'}]),
    (plain + '\n\n' + text + '\n后文\n' + untouched,
     [{'type': 'text', 'text': plain + '\n后文\n' + untouched}]),
    ([{'type': 'text', 'text': plain}, {'type': 'text', 'text': text}],
     [{'type': 'text', 'text': plain}]),
    ([{'type': 'text', 'text': text}, {'type': 'text', 'text': plain}],
     [{'type': 'text', 'text': plain}]),
    (text, []),
]:
    original_body = json.dumps(dict(body, messages=[{'role': 'user', 'content': content}]))
    (root / 'body').write_text(original_body)
    run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
    assert run.returncode == 0, run.stderr
    converted = json.loads(run.stdout)['messages'][0]['content']
    assert converted[:-len(images)] == expected, converted
    assert [base64.b64decode(b['source']['data']) for b in converted[-len(images):]] == [p.read_bytes() for p in images]
    assert (root / 'body').read_text() == original_body
print('附件区块清理、正文与其他块保留、多图顺序及输入不回写：通过')
# 文件读取和显式输入应一致；开关不得改写历史，失败不得进入发送。
for source in ['src/agent.sh', 'dist/agent.sh']:
    (root / 'library.sh').write_text((repo / source).read_text().rsplit('main "$@"', 1)[0])
    for history in [[], [{'role': 'user', 'content': '你好'}, {'role': 'assistant', 'content': '请继续'}]]:
        records = history + [{'role': 'user', 'content': text}]
        original_conv = ''.join(json.dumps(m, ensure_ascii=False) + '\n' for m in records)
        (root / 'conv.jsonl').write_text(original_conv)
        setup = f"""source '{root}/library.sh'
AWK_DIR='{repo}/src/awk'
CONV_FILE='{root}/conv.jsonl'
store_session_get_dir() {{ printf '%s' '{root}'; }}
"""
        for mode in ['on', 'off']:
            outputs = []
            for invocation in ['store_conv_get_messages', 'store_conv_get_messages "$(cat "$CONV_FILE")"', 'store_conv_get_messages ""']:
                run = subprocess.run(['bash', '-c', setup + f'AGENT_VISION={mode}\n' + invocation], capture_output=True, timeout=40)
                assert run.returncode == 0, run.stderr
                outputs.append(json.loads(run.stdout))
            assert outputs[0] == outputs[1] == outputs[2]
            assert outputs[0][:-1] == history
            if mode == 'off':
                assert outputs[0] == records
            else:
                assert [base64.b64decode(b['source']['data']) for b in outputs[0][-1]['content']] == [p.read_bytes() for p in images]
            assert (root / 'conv.jsonl').read_text() == original_conv
        (root / 'conv.jsonl').write_text(original_conv.replace('/images/1.png', '/images/99.png'))
        run = subprocess.run(['bash', '-c', setup + '''AGENT_VISION=on
llm_call() { printf '不应发送'; }
messages=$(store_conv_get_messages) && llm_call "$messages"
'''], capture_output=True, timeout=40)
        assert run.returncode != 0 and run.stdout == b'', run
    for raw, expected in [('', []), ('\n', []), ('\n{"role":"user","content":"空行"}\n\n', [{'role': 'user', 'content': '空行'}])]:
        (root / 'conv.jsonl').write_text(raw)
        run = subprocess.run(['bash', '-c', setup + 'AGENT_VISION=off\nstore_conv_get_messages'], capture_output=True, timeout=20)
        assert run.returncode == 0 and json.loads(run.stdout) == expected
    records = [{'role': 'user', 'content': text}, {'role': 'assistant', 'content': '继续'}, {'role': 'user', 'content': text}]
    original_conv = '\n'.join(json.dumps(m) for m in records)  # 最后一行无换行
    (root / 'conv.jsonl').write_text(original_conv)
    run = subprocess.run(['bash', '-c', setup + 'AGENT_VISION=on\nstore_conv_get_messages'], capture_output=True, timeout=40)
    assert run.returncode == 0, run.stderr
    result = json.loads(run.stdout)
    assert result[1] == records[1]
    for message in [result[0], result[2]]:
        assert [base64.b64decode(b['source']['data']) for b in message['content']] == [p.read_bytes() for p in images]
    assert (root / 'conv.jsonl').read_text() == original_conv
print('直接图片、多轮多图、空行、无末尾换行、显式读取、开关及失败阻止发送：通过')
(root / 's/images/3.png').symlink_to(images[0])
(root / 's/images/4.png').write_bytes(b'not a PNG')
(root / 'linked').symlink_to(root / 's', target_is_directory=True)
(root / 'linked-images').mkdir()
(root / 'linked-images/images').symlink_to(root / 's/images', target_is_directory=True)
for path in [root / 's/images/3.png', root / 's/images/4.png', root / 'linked/images/1.png', root / 'linked-images/images/1.png']:
    (root / 'body').write_text(json.dumps(dict(body, messages=[{'role': 'user', 'content': text.replace(str(images[0]), str(path))}])))
    run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
    assert run.returncode != 0, path
print('数组保留、普通路径忽略、非法附件及符号链接拒绝：通过')
# 合法目录名含命令替换语法时仍只能作为数据读取，不能触发 shell 执行。
injection_path = root / '$(touch injected)' / 'images' / '1.png'
injection_path.parent.mkdir(parents=True)
injection_path.write_bytes(images[0].read_bytes())
(root / 'body').write_text(json.dumps(dict(body, messages=[{'role': 'user', 'content': text.replace(str(images[0]), str(injection_path))}])))
run = subprocess.run(['bash', '-c', script], cwd=root, capture_output=True, timeout=20)
assert run.returncode == 0, run.stderr
assert not (root / 'injected').exists()
assert base64.b64decode(json.loads(run.stdout)['messages'][0]['content'][0]['source']['data']) == images[0].read_bytes()
print('附件路径与命令隔离：通过')
# 使用真实转换器验证工具回复不会被图片打断。
image = {'type': 'image', 'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'aGVsbG8='}}
mixed = [{'type': 'tool_result', 'tool_use_id': 'a', 'content': 'first'}, image,
         {'type': 'tool_result', 'tool_use_id': 'b', 'content': 'second'}, image]
for source in ['src/agent.sh', 'dist/agent.sh']:
    (root / 'library.sh').write_text((repo / source).read_text().rsplit('main "$@"', 1)[0])
    script = f"source '{root}/library.sh'\nAWK_DIR='{repo}/src/awk'\nPROVIDER=openai\nAPI_KEY=test\nvalidate_config\nutil_body_convert on"
    run = subprocess.run(['bash', '-c', script], input=json.dumps(dict(body, messages=[{'role': 'user', 'content': mixed}])), capture_output=True, text=True, timeout=20)
    assert run.returncode == 0, run.stderr
    messages = json.loads(run.stdout)['messages']
    assert [m['role'] for m in messages] == ['tool', 'tool', 'user'], messages
    assert [m['tool_call_id'] for m in messages[:2]] == ['a', 'b']
    assert len(messages[2]['content']) == 2
print('真实转换器混合数组顺序：通过')
cases = [body, dict(body, messages=[{'role': 'user', 'content': [{'type': 'text', 'text': text}]}]), dict(body, messages=[{'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't', 'content': 'ok'}]}])]
baseline = '6cf4b90d8915c45befcd086d363c68ccb1d1f187'
original = subprocess.check_output(['git', 'show', f'{baseline}:src/agent.sh'], cwd=repo).decode()
historical_awk = root / 'historical-awk'
historical_awk.mkdir()
for name in subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', baseline, 'src/awk'], cwd=repo).decode().splitlines():
    (historical_awk / pathlib.Path(name).name).write_bytes(subprocess.check_output(['git', 'show', f'{baseline}:{name}'], cwd=repo))
for provider in ['claude', 'openai', 'responses']:
    for case in cases:
        (root / 'messages').write_text(json.dumps(case['messages']))
        outputs = []
        for code, awk_dir in [(original, historical_awk), ((repo / 'src/agent.sh').read_text(), repo / 'src/awk'), ((repo / 'dist/agent.sh').read_text(), repo / 'src/awk')]:
            (root / 'library.sh').write_text(code.rsplit('main "$@"', 1)[0])
            script = f"""source '{root}/library.sh'\nAWK_DIR='{awk_dir}'\nPROVIDER={provider}\nAPI_KEY=test\nvalidate_config\nAGENT_VISION=off\nTOOL_DEF_JSON='[]'\nagent_build_prompt() {{ printf '固定提示'; }}\nllm_stream_curl() {{ cat; }}\nsse_convert() {{ cat; }}\nsse_parse() {{ cat; }}\nstore_conv_encode_image() {{ echo '关闭路径错误' >&2; return 99; }}\nllm_call "$(cat '{root}/messages')"\n"""
            run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
            assert run.returncode == 0, run.stderr
            outputs.append(run.stdout)
        assert outputs[0] == outputs[1] == outputs[2], provider
    print(provider, '关闭路径逐字节一致')
temporary.cleanup()
