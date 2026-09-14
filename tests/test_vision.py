# 三协议大图、原数组、路径边界及关闭路径回归。
import pathlib, tempfile, subprocess, json, base64, os, struct, zlib
repo = pathlib.Path(__file__).resolve().parents[1]
temporary = tempfile.TemporaryDirectory()
root = pathlib.Path(temporary.name).resolve()
(root / 's/images').mkdir(parents=True)
images = []
for i in range(1, 3):

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = b''.join((b'\x00' + os.urandom(1920) for _ in range(640)))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 640, 640, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')
    p = root / f's/images/{i}.png'
    p.write_bytes(png)
    images.append(p)
text = '<attached-images>\nThese placeholders map to local image files:\n' + '\n'.join((f'[Image #{i}] => {p}' for (i, p) in enumerate(images, 1))) + '\nUse <skill-index>\n</attached-images>'
body = {'model': 'test', 'max_tokens': 100, 'messages': [{'role': 'user', 'content': text}]}
(root / 'body').write_text(json.dumps(body))
for source in ['src/agent.sh', 'dist/agent.sh']:
    for provider in ['claude', 'openai', 'responses']:
        library = root / 'library.sh'
        library.write_text((repo / source).read_text().rsplit('main "$@"', 1)[0])
        script = f"""source '{library}'\nAWK_DIR='{repo}/src/awk'\nstore_session_get_dir() {{ printf '%s' '{root}'; }}\nPROVIDER={provider}\nAPI_KEY=test\nvalidate_config\nllm_vision_body "$(cat '{root}/body')"\n"""
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
        print(source, provider, '通过', len(r.stdout))
        for quoted in [text, text.replace('/images/1.png', '/images/99.png')]:
            for content in [quoted, [{'type': 'text', 'text': quoted}]]:
                (root / 'body').write_text(json.dumps(dict(body, messages=[{'role': 'assistant', 'content': content}])))
                run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
                assert run.returncode == 0, (source, provider, run.stderr)
                encoded.clear()
                scan(json.loads(run.stdout))
                assert not encoded, (source, provider, '助手映射不应编码')
        (root / 'body').write_text(json.dumps(body))
script = f"""source '{root}/library.sh'\nAWK_DIR='{repo}/src/awk'\nstore_session_get_dir() {{ printf '%s' '{root}'; }}\nutil_body_convert() {{ cat; }}\nllm_vision_body "$(cat '{root}/body')"\n"""
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
            script = f"""source '{root}/library.sh'\nAWK_DIR='{awk_dir}'\nPROVIDER={provider}\nAPI_KEY=test\nvalidate_config\nAGENT_VISION=off\nTOOL_DEF_JSON='[]'\nagent_build_prompt() {{ printf '固定提示'; }}\nllm_stream_curl() {{ cat; }}\nsse_convert() {{ cat; }}\nsse_parse() {{ cat; }}\nllm_vision_body() {{ echo '关闭路径错误' >&2; return 99; }}\nllm_call "$(cat '{root}/messages')"\n"""
            run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
            assert run.returncode == 0, run.stderr
            outputs.append(run.stdout)
        assert outputs[0] == outputs[1] == outputs[2], provider
    print(provider, '关闭路径逐字节一致')
temporary.cleanup()
