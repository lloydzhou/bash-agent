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
script = f"""source '{root}/library.sh'\nAWK_DIR='{repo}/src/awk'\nstore_session_get_dir() {{ printf '%s' '{root}'; }}\nutil_body_convert() {{ cat; }}\nllm_vision_body "$(cat '{root}/body')"\n"""
for content in [[{'type': 'text', 'text': text}], str(images[0]), text.replace(str(images[0]), str(root / '../images/1.png')), text.replace('/images/1.png', '/images/99.png')]:
    (root / 'body').write_text(json.dumps(dict(body, messages=[{'role': 'user', 'content': content}])))
    run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
    if isinstance(content, list):
        assert run.returncode == 0, run.stderr
        assert json.loads(run.stdout)['messages'][0]['content'][:1] == content
    elif content == str(images[0]):
        assert json.loads(run.stdout)['messages'][0]['content'] == content
    else:
        assert run.returncode != 0
print('数组保留、普通路径忽略、非法附件拒绝：通过')
cases = [body, dict(body, messages=[{'role': 'user', 'content': [{'type': 'text', 'text': text}]}]), dict(body, messages=[{'role': 'user', 'content': [{'type': 'tool_result', 'tool_use_id': 't', 'content': 'ok'}]}])]
original = subprocess.check_output(['git', 'show', '6cf4b90d8915c45befcd086d363c68ccb1d1f187:src/agent.sh'], cwd=repo).decode()
for provider in ['claude', 'openai', 'responses']:
    for case in cases:
        (root / 'messages').write_text(json.dumps(case['messages']))
        outputs = []
        for code in [original, (repo / 'src/agent.sh').read_text(), (repo / 'dist/agent.sh').read_text()]:
            (root / 'library.sh').write_text(code.rsplit('main "$@"', 1)[0])
            script = f"""source '{root}/library.sh'\nAWK_DIR='{repo}/src/awk'\nPROVIDER={provider}\nAPI_KEY=test\nvalidate_config\nAGENT_VISION=off\nTOOL_DEF_JSON='[]'\nagent_build_prompt() {{ printf '固定提示'; }}\nllm_stream_curl() {{ cat; }}\nsse_convert() {{ cat; }}\nsse_parse() {{ cat; }}\nllm_vision_body() {{ echo '关闭路径错误' >&2; return 99; }}\nllm_call "$(cat '{root}/messages')"\n"""
            run = subprocess.run(['bash', '-c', script], capture_output=True, timeout=20)
            assert run.returncode == 0, run.stderr
            outputs.append(run.stdout)
        assert outputs[0] == outputs[1] == outputs[2], provider
    print(provider, '关闭路径逐字节一致')
temporary.cleanup()
