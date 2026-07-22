#!/usr/bin/env python3
"""PTY 冒烟测试：驱动 vim 加载插件并用环境变量配置启动命令。

验证：
1. :AgentToggle! 使用 AGENT_NEW_COMMAND 在右侧启动 terminal
2. 冷启动 :AgentToggle 使用 AGENT_CONTINUE_COMMAND
3. :AgentAsk hello 后 cat 回显 hello（输入行回显 + cat 输出，至少 2 次）
4. :AgentSendBuffer 注入的引用文本不含尖括号、不带回车（cat 不会立刻回显第二行）

用法: python3 vim/test/smoke.py
"""
import os, pty, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # vim/
OUT = "/tmp/agent_vim_smoke.out"
OUT_EXIT = "/tmp/agent_vim_smoke_exit.out"
OUT_TOGGLE = "/tmp/agent_vim_smoke_toggle.out"
OUT_NOLEAK = "/tmp/agent_vim_smoke_noleak.out"
OUT_NEW_COMMAND = "/tmp/agent_vim_smoke_new_command"
OUT_CONTINUE_COMMAND = "/tmp/agent_vim_smoke_continue_command"
OUT_COMMANDS = "/tmp/agent_vim_smoke_commands.out"
OUT_FALLBACK = "/tmp/agent_vim_smoke_fallback.out"
SMOKE_VIM = os.path.join(ROOT, "test", "smoke.vim")
NEW_COMMAND = "/tmp/agent_vim_smoke_new.sh"
CONTINUE_COMMAND = "/tmp/agent_vim_smoke_continue.sh"
FALLBACK_COMMAND = "/tmp/agent_vim_smoke_fallback.sh"

for path in (OUT_NEW_COMMAND, OUT_CONTINUE_COMMAND, OUT_COMMANDS, OUT_FALLBACK):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
with open(NEW_COMMAND, "w") as f:
    f.write("#!/bin/sh\nprintf new-command > /tmp/agent_vim_smoke_new_command\nexec cat\n")
with open(CONTINUE_COMMAND, "w") as f:
    f.write("#!/bin/sh\nprintf continue-command > /tmp/agent_vim_smoke_continue_command\nexec cat\n")
with open(FALLBACK_COMMAND, "w") as f:
    f.write("#!/bin/sh\nprintf '%s' \"$*\" > /tmp/agent_vim_smoke_fallback.out\n")
os.chmod(NEW_COMMAND, 0o700)
os.chmod(CONTINUE_COMMAND, 0o700)
os.chmod(FALLBACK_COMMAND, 0o700)

cmd = ["vim", "-Nu", "NONE", "-n", "-S", SMOKE_VIM]

env = {
    **os.environ,
    "TERM": "xterm-256color",
    "AGENT_NEW_COMMAND": NEW_COMMAND,
    "AGENT_CONTINUE_COMMAND": CONTINUE_COMMAND,
}
master, slave = pty.openpty()
proc = subprocess.Popen(
    cmd, stdin=slave, stdout=slave, stderr=slave,
    env=env, close_fds=True,
)
os.close(slave)

deadline = time.time() + 30
while proc.poll() is None and time.time() < deadline:
    time.sleep(0.2)
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    print("FAIL: vim 未退出")
    sys.exit(1)
os.close(master)

if not os.path.exists(OUT):
    print("FAIL: 未生成终端导出文件（terminal 未启动？）")
    sys.exit(1)

data = open(OUT, encoding="utf-8", errors="replace").read()
fails = []

if data.count("hello-vim-agent") < 2:
    fails.append(f"AgentAsk 回显次数不足（{data.count('hello-vim-agent')} < 2）")

# 终端宽度仅 40 列，注入文本会被折行，先去掉空白再匹配
flat = re.sub(r"\s+", "", data)
m = re.search(r"看(\S+ctx-\d+-\d+\.md)（agent_vim_smoke_buf\.sh:1-2的代码片段）", flat)
if not m:
    fails.append("AgentSendBuffer 注入的引用文本未出现在终端")
else:
    ctx = m.group(1)
    if not os.path.exists(ctx):
        fails.append(f"ctx 文件不存在: {ctx}")
    else:
        body = open(ctx).read()
        if not body.startswith("/tmp/agent_vim_smoke_buf.sh:1-2\n\n```sh\necho one\necho two\n```"):
            fails.append(f"ctx 文件内容不对: {body!r}")

# AgentToggle 应能关闭窗口，且重开时复用同一 buffer
if not os.path.exists(OUT_TOGGLE):
    fails.append("未生成 toggle 状态文件")
elif open(OUT_TOGGLE).read().strip() != "toggle-ok":
    fails.append("AgentToggle 关闭/重开窗口失败")

# 新会话与续聊应分别使用对应环境变量中的完整启动命令。
if not os.path.exists(OUT_COMMANDS):
    fails.append("未生成环境变量启动命令检查文件")
else:
    commands = open(OUT_COMMANDS).read().splitlines()
    if commands != ["new-command", "continue-command"]:
        fails.append(f"环境变量启动命令选择不正确: {commands!r}")

# 环境变量为空时应保持旧行为：g:agent_command 后自动追加 --continue。
if not os.path.exists(OUT_FALLBACK):
    fails.append("未生成旧配置回退检查文件")
elif open(OUT_FALLBACK).read().strip() != "--continue":
    fails.append(f"旧配置回退不正确: {open(OUT_FALLBACK).read()!r}")

# 注入文本首尾不应有多余按键泄漏（feedkeys('i') 竞态会在末尾多一个 i）
if not os.path.exists(OUT_NOLEAK):
    fails.append("未生成按键泄漏检查文件")
elif open(OUT_NOLEAK).read().strip() != "noleak-ok":
    fails.append("注入文本首/尾检测到泄漏按键（多余的 i）")

# 进程退出（Ctrl-D → cat EOF）后窗口应自动关闭
if not os.path.exists(OUT_EXIT):
    fails.append("未生成退出状态文件")
elif open(OUT_EXIT).read().strip() != "closed":
    fails.append("agent 进程退出后窗口未自动关闭")

if fails:
    print("FAIL:")
    for f in fails:
        print(" -", f)
    print("--- 终端导出 ---")
    print(data)
    sys.exit(1)

print("PASS")
