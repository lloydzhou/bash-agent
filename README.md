# bash-agent

[English README](README.en.md)

一个极简 AI coding agent runtime。

仓库中同时包含一个正在对齐行为的 Go 版本：

- `bash-agent`：当前稳定主线，`bash + awk`
- `goagent`：Go port，内部使用 struct/channel，但保持相同的 agent loop、tool/event/session 语义
- `rustagent`：Rust port，保持相同语义，使用 Rust 原生 JSON/SSE/dispatch

它不是一个完整平台，而是一个尽量小、边界清晰、可以真正执行工作的 agent core。目标是：

- 运行时依赖尽量少
- 协议边界明确
- 状态可预测
- 在终端里可直接使用
- 也可以作为上层客户端后面的执行内核

## 项目定位

大多数 agent runtime 会逐渐叠加这些层：

- SDK
- 后台服务
- 状态存储
- 协议适配器
- 编排框架

`bash-agent` 主线反过来做：

- `bash` 负责流程编排、文件、进程、HTTP 请求、session 生命周期
- `awk` 负责 JSON/SSE 解析、文本抽取、规范化和轻量协议转换

`goagent` 则保留同样的行为模型，但把：

- JSON/SSE 解析
- 内部事件流
- tool dispatch
- session/compact 流程

改成 Go 原生实现。

重点不是“文件越少越好”，而是：

- 功能完备前提下尽量精简
- 字符串解析和变换收敛到 `awk`
- orchestration 保持在 `bash`

## 当前能力

- Provider：
  - `claude`
  - `openai` chat-completions 兼容接口
- 输出模式：
  - `human`
  - `stream-json`
- Session：
  - 按项目、按 session 持久化
  - 支持恢复
  - 支持 compact
- 内置工具：
  - `Read`
  - `Write`
  - `Edit`
  - `Bash`
  - `Glob`
  - `Grep`
  - `TodoWrite`
- Prompt 分层：
  - instruction files
  - skill index
  - selected skills
  - compact summary
  - current todo

## 快速开始

```bash
# 默认 provider 是 claude
export ANTHROPIC_API_KEY="sk-ant-..."
./src/agent.sh -m claude-sonnet-4-20250514 "say hello"

# OpenAI chat-completions 兼容接口
export OPENAI_API_KEY="sk-..."
./src/agent.sh -p openai -m gpt-4o "say hello"

# 交互模式
./src/agent.sh -i

# 不带参数也会进入交互模式
./src/agent.sh

# 结构化事件输出
./src/agent.sh --print "scan this repo"
```

## 安装

```bash
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent
```

Go 版本本地构建并安装：

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go build -o ~/.local/bin/goagent ./cmd/goagent
```

Rust 版本本地构建并安装（release）：

```bash
cd rust && cargo build --release && cp target/release/rustagent ~/.local/bin/rustagent
```

也可以直接下载预构建产物：

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ] && ARCH=arm64; curl -fsSL "https://github.com/lloydzhou/bash-agent/releases/latest/download/goagent-${OS}-${ARCH}" -o ~/.local/bin/goagent && chmod +x ~/.local/bin/goagent
```

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ] && ARCH=arm64; case "$OS" in linux) SUFFIX="linux-${ARCH}" ;; *) echo "No prebuilt rustagent for $OS/$ARCH, build locally with: cd rust && cargo build --release"; exit 1 ;; esac; curl -fsSL "https://github.com/lloydzhou/bash-agent/releases/latest/download/rustagent-${SUFFIX}" -o ~/.local/bin/rustagent && chmod +x ~/.local/bin/rustagent
```

Go 版本 help：

```bash
goagent -h
```

Rust 版本 help：

```bash
rustagent -h
```

Rust 版 `-i` 模式支持：

- history
- 上下箭头

history 文件保存在：

```text
~/.bash-agent/rustagent.history
```

也支持第三方兼容端点：

```bash
OPENAI_BASE_URL=http://localhost:11434/v1 \
./src/agent.sh -p openai -m llama3 "hello"
```

## 常见用法

### 普通终端模式

```bash
./src/agent.sh -p openai -m gpt-4o "run the tests and summarize failures"
```

### Go 版本

```bash
goagent "run the tests and summarize failures"
goagent --print "inspect this repository"
goagent --session demo "run the tests"
goagent -i
```

Go 版 `-i` 模式支持：

- history
- 上下箭头

history 文件保存在：

```text
~/.bash-agent/goagent.history
```

### `stream-json`

```bash
./src/agent.sh -p claude --output-format stream-json "inspect this repository" | jq -c .
```

### 持久化 session

```bash
./src/agent.sh --session demo "run the tests"
./src/agent.sh --session demo "fix the first failure"
./src/agent.sh --continue "what changed so far?"
```

### 使用 skills

```bash
./src/agent.sh --skill shell-safety "inspect /tmp safely"
```

## CLI 参数

| 参数 | 说明 |
| --- | --- |
| `-p, --provider` | `claude` 或 `openai`，默认 `claude` |
| `-m, --model` | 模型名 |
| `--base-url` | 覆盖 API base URL |
| `--api-key` | 覆盖 API key |
| `--skill NAME` | 加载 `.claude/skills/NAME/SKILL.md` |
| `--max-tokens` | 最大输出 token |
| `--max-turns` | 最大 agent loop turn 数 |
| `--max-context` | context 大小预算，支持 `100k`、`1m`、`1g` |
| `--tool-timeout N` | tool 超时时间，单位秒 |
| `--session [NAME]` | 创建或使用持久化 session |
| `--continue` | 继续当前项目下最近一次 session |
| `--list-sessions` | 列出当前项目的 session |
| `--output-format` | `human` 或 `stream-json` |
| `--print` | `--output-format stream-json` 的别名 |
| `-i, --interactive` | 交互模式 |
| `-v, --verbose` | 输出详细日志 |
| `compact` | 对当前 session 执行 compact |

## 内置工具

### `Read`

- 读取文本文件内容
- 默认结果上限：`50KB`
- 超过上限时返回截断结果

### `Write`

- 写入文件内容
- 必要时自动创建父目录
- 默认写入上限：`1MB`

### `Edit`

- 精确字符串替换
- 支持多行替换
- 默认写入上限：`1MB`

### `Bash`

- 执行 shell 命令
- 默认超时：`600s`
- 大输出会被截断

### `Glob`

- 基于 `rg --files -g` 做文件匹配
- 依赖 `rg`

### `Grep`

- 基于 `rg -n` 做内容搜索
- 依赖 `rg`

### `TodoWrite`

- 维护当前 session 的 todo checklist
- 面向复杂多步任务
- 状态保存在 `*.todo.md`

## Session 与状态文件

状态按项目保存到：

```text
~/.bash-agent/projects/<project_key>/
```

每个 session 的主要文件：

```text
<session_id>.jsonl
<session_id>.events.jsonl
<session_id>.summary.txt
<session_id>.todo.md
```

含义：

- `jsonl`：真正发给模型的当前会话窗口
- `events.jsonl`：内部 session 事件日志
- `summary.txt`：compact 后的历史摘要
- `todo.md`：当前 session 的 todo 状态

如果不传 `--session`，会话状态只在当前进程内临时存在，退出后清理。

## Context Compact

compact 依据真实 context 大小，而不是消息条数。

- `--max-context` 表示字节预算
- 支持：
  - `100k`
  - `1m`
  - `100000`
- 超预算时，旧消息会被压缩写入 `summary.txt`
- 保留窗口会对齐到完整 user turn 边界

这样可以避免保留出非法尾部，例如：

- 孤立的 `tool_result`
- 保留了 `assistant.tool_use`，却丢掉对应 user turn

## Skills

skills 只从这里加载：

```text
.claude/skills/<name>/SKILL.md
```

运行时分两层：

1. `skill-index`
   - 从 `.claude/skills/*/SKILL.md` 提取轻量摘要
2. `selected-skills`
   - 只有显式传 `--skill NAME` 时才注入完整 `SKILL.md`

完整 skill 加载时，可使用 `${BASH_AGENT_SKILL_DIR}` 引用同目录脚本或模板。

## Instruction Files

支持通用 instruction file 命名，同时兼容 `CLAUDE.md`。

每个作用域按优先级只加载一个：

1. `AGENTS.md`
2. `AGENT.md`
3. `CLAUDE.md`
4. `.claude/CLAUDE.md`

作用域：

- 全局：`~/.bash-agent/`
- 项目：当前工作目录

这些内容会进入稳定 prompt 前缀。

## 事件协议

内部会先把 SSE 归一化成一层轻量 line protocol：

```text
TEXT:Hello
TOOL_CALL:Bash\tcall_123\t{"command":"pwd"}\tcommand\tpwd
USAGE:25\t42\t8
STOP:end_turn
```

对外的 `stream-json` 会输出这些结构化事件：

- `text`
- `tool_call`
- `todo_update`
- `tool_result`
- `usage`
- `stop`
- `error`
- `context_update`

示例：

```json
{"type":"tool_call","name":"Bash","id":"call_123","input":{"command":"pwd"}}
{"type":"usage","input_tokens":25,"output_tokens":42,"cache_input_tokens":8}
```

## 仓库结构

```text
src/
  agent.sh
  tools.json
  awk/
    json.awk
    json_cli.awk
    protocol.awk
    todo_protocol.awk
    http_stream.awk
    claude_sse.awk
    openai_sse.awk
    convert_messages.awk
    convert_tools.awk
    edit_file.awk
    skill_summary.awk
scripts/
  build.sh
tests/
  test.sh
dist/
  agent.sh
  goagent
go/
  cmd/
    goagent/
  internal/
    app/
    assets/
    config/
    conversation/
    httpclient/
    prompt/
    protocol/
    provider/
    safety/
    session/
    sse/
    tools/
  go.mod
  go.sum
```

## 开发

运行测试：

```bash
bash tests/test.sh
```

构建单文件发行版：

```bash
bash scripts/build.sh
```

对构建产物跑测试：

```bash
AGENT=./dist/agent.sh bash tests/test.sh
```

运行 Go 测试：

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go test ./...
```

构建 Go 版本：

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go build -o ../dist/goagent ./cmd/goagent
```

## 当前状态

- compact 已按真实 context 大小处理，不再按消息条数
- session 状态按项目隔离
- tool 协议已经结构化，适合机器消费
- `TodoWrite` 负责维护 session 级 todo 状态
- CI 会构建并上传 `agent.sh` / `goagent` / `rustagent` 产物（`dist/agent.sh` 会先跑测试）
- Go 版可以编译运行，并保留当前主线的 agent loop / tool / session / compact 语义

## 文档

- [README.en.md](README.en.md) English
- [ARCHITECTURE.md](ARCHITECTURE.md)
