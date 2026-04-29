# bash-agent

[English README](README.en.md)

一个极简 AI coding agent runtime。

仓库中同时包含两个正在对齐行为的原生版本：

- `bash-agent`：当前稳定主线，`bash + awk`
- `goagent`：Go port，保持相同的 agent loop、tool/event/session 语义
- `rustagent`：Rust port，保持相同语义，使用 Rust 原生 JSON/SSE/dispatch

它不是一个完整平台，而是一个尽量小、边界清晰、可以真正执行工作的 agent core。目标是：

- 运行时依赖尽量少
- 协议边界明确（awk → bash 使用 RESP-like 二进制安全协议）
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
- `awk` 负责 JSON/SSE 解析、文本抽取、规范化和 RESP-like 协议输出

`goagent` 则保留同样的行为模型，但把：

- JSON/SSE 解析
- 内部事件流
- tool dispatch
- session/compact 流程

改成 Go 原生实现。

`rustagent` 也保留同样的行为模型，并把交互、事件流、tool dispatch 改成 Rust 原生实现。

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
  - `Skill`
  - `WebSearch`
  - `WebFetch`
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
OS=$(uname -s | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ] && ARCH=arm64; case "$OS" in linux|darwin) SUFFIX="${OS}-${ARCH}" ;; *) echo "No prebuilt rustagent for $OS/$ARCH, build locally with: cd rust && cargo build --release"; exit 1 ;; esac; curl -fsSL "https://github.com/lloydzhou/bash-agent/releases/latest/download/rustagent-${SUFFIX}" -o ~/.local/bin/rustagent && chmod +x ~/.local/bin/rustagent
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
~/.bash-agent/history
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
~/.bash-agent/history
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
- 支持通过 `offset`（起始行号）和 `limit`（行数）读取指定行范围
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
- 支持通过 `timeout` 参数为单条命令设置超时（秒）
- 默认超时：`600s`（可通过 `--tool-timeout` 全局设置）
- 大输出会被截断

### `Glob`

- 基于 `rg --files -g` 做文件匹配
- 依赖 `rg`

### `Grep`

- 基于 `rg -n` 做内容搜索，支持正则
- 支持 `path`（搜索路径）、`glob`（文件过滤）、`context`（上下文行数）
- `context` 可显示匹配行前后 N 行，便于直接定位编辑位置
- 依赖 `rg`

### `TodoWrite`

- 维护当前 session 的 todo checklist
- 面向复杂多步任务
- 状态保存在 session 目录下的 `todo.md`

### `Skill`

- 先从 prompt 里的 `skill-index` 选择 skill 名
- 再用 `Skill(name)` 读取对应 `SKILL.md`
- 用户要求使用某个 skill 时，优先用它而不是直接 `Read` skill 文件

### `WebSearch`

- 基于 Jina AI Search API 进行网络搜索
- 依赖 `curl` 和 `JINA_API_KEY` 环境变量
- 默认超时：`30s`

### `WebFetch`

- 基于 Jina AI Reader API 获取网页内容
- 依赖 `curl` 和 `JINA_API_KEY` 环境变量
- 默认超时：`60s`

## Session 与状态文件

状态按项目保存到：

```text
~/.bash-agent/projects/<project_key>/
```

每个 session 的主要文件存在其目录下：

```text
<session_id>/conversation.jsonl
<session_id>/events.jsonl
<session_id>/summary.txt
<session_id>/todo.md
<session_id>/plan.md
<session_id>/stats.json
```

含义：

- `conversation.jsonl`：真正发给模型的当前会话窗口
- `events.jsonl`：内部 session 事件日志
- `summary.txt`：compact 后的历史摘要
- `todo.md`：当前 session 的 todo 状态
- `plan.md`：当前 session 的计划文档
- `stats.json`：session 统计数据（LLM 调用次数、输入 token 总量、compact 次数、当前 turn 等）

所有会话都会持久化到 `~/.bash-agent/projects/<project_key>/` 目录中，即使不传 `--session` 也会生成一个 session_id 并保存。可以使用 `--continue` 恢复最近一次会话。

## Context Compact

compact 使用基于缓存经济学的动态规划算法决定**是否压缩**和**保留多少消息**，而非简单的阈值触发。

### 决策公式

对每个候选保留条数 $k$，计算净收益：

$$
\begin{aligned}
\text{NetBenefit}(k) &= \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{后续节省}} \\
&- \underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{缓存失效损失}} \\
&- \underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{压缩请求成本}} \\
&- \underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{信息失真惩罚}}
\end{aligned}
$$

- 若 $\max_k \text{NetBenefit}(k) > 0$，选择最优 $k$ 执行压缩
- 否则不压缩

| 项 | 含义 |
|---|---|
| ① | 压缩后后续 `R-1` 次 LLM 调用每次少发送 `H` token，按缓存价节省 |
| ② | 摘要内容变化导致前缀缓存断裂，`S+K` 个 token 从缓存价变为全价 |
| ③ | 压缩请求本身的 API 成本（缓存复用前缀 + 指令 + 输出） |
| ④ | 多次压缩的信息累积损失，`β=0.03`，`r=0.8` |

### 核心变量

| 变量 | 含义 | 默认 |
|---|---|---|
| $R = E \times L$ | 预期剩余 LLM 调用总次数 | — |
| $E$ | 预期剩余用户输入轮数 | $\max(8 - t,\; 4)$，单调非递增 |
| $L$ | 每轮用户输入平均 LLM 调用次数 | 5（经验值） |
| $H$ | 被丢弃的旧消息 token 数 | $T_{\text{total}} - K$ |
| $K$ | 保留消息 token 数 | 遍历 $k$ 计算 |
| $S$ | 固定摘要长度 | 500 token |
| $V$ | 固定前缀（system prompt + tools + old summary） | 5000 token |

### 价格参数（按 provider 覆盖）

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DP_P_INPUT` | 3.00 | $/MTok，未命中缓存输入价格 |
| `DP_P_CACHE` | 0.30 | $/MTok，缓存命中输入价格 |
| `DP_P_OUT` | 15.00 | $/MTok，输出价格 |
| `DP_L` | 5 | 每轮平均 LLM 调用次数（`0` = 从 stats 自动计算） |
| `DP_BASELINE_E` | 8 | 预期剩余用户输入轮数基线 |
| `DP_R` | 0.8 | 单次摘要信息保留率 |
| `DP_BETA` | 0.03 | 信息损失折算系数 |
| `DP_MIN_KEEP_RATIO` | 0.12 | 最少保留消息比例 |

### 缓存复用策略

压缩请求（summary call）的消息序列与普通对话保持**相同前缀**：

```
[System prompt + Tools + Old summary]     ← 缓存命中，按 P_cache 计费
[被丢弃的旧消息 H]                        ← 缓存命中，按 P_cache 计费
[Summary 指令 L_instr]                    ← 缓存未命中，按 P_input 计费
```

输出固定长度 $S$ 的新摘要，替代旧摘要写入 `summary.txt`。

### 安全阀

当 DP 公式判断不压缩，但 `current_context > max_context × 90%` 时，强制压缩：

```
keep_lines = max(3, total_lines × DP_MIN_KEEP_RATIO)
```

### 保留窗口对齐

切分点始终对齐到**真实用户输入**（`"role":"user","content":"..."`），不会在工具结果处切断。避免：

- 孤立的 `tool_result`
- 保留了 `assistant.tool_use` 却丢掉对应 user turn

### 不同 provider 的压缩偏好

| Provider | $P_{\text{input}}$ | $P_{\text{cache}}$ | $P_{\text{out}}$ | 节省/MTok | 偏好 |
|----------|-----|-----|-----|-----|------|
| Claude Sonnet 4 | 3.00 | 0.30 | 15.00 | 2.70 | 激进 |
| GPT-4o | 2.50 | 1.25 | 10.00 | 1.25 | 中等 |
| DeepSeek v4 flash | 1.00 | 0.02 | 3.00 | 0.98 | 保守 |

通过环境变量覆盖：`DP_P_INPUT=1.00 DP_P_CACHE=0.02 DP_P_OUT=3.00 ./src/agent.sh ...`

> 完整推导见 [`docs/dp-compact-analysis.md`](docs/dp-compact-analysis.md)。

## Skills

skills 主要从这些位置加载：

```text
./.claude/skills/<name>/SKILL.md
./skills/<name>/SKILL.md
~/.claude/skills/<name>/SKILL.md
```

运行时分三层：

1. `skill-index`
   - 从所有可见 skill 目录里的 `SKILL.md` 提取轻量摘要
2. `selected-skills`
   - 只有显式传 `--skill NAME` 时才注入完整 `SKILL.md`
3. `Skill` tool
   - 运行时先参考 `skill-index`
   - 再按 skill 名读取完整 `SKILL.md`
   - 不修改后续轮次的 system prompt

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

内部 SSE 解析结果通过 RESP-like 协议传递（`awk → bash`），使用 `CRLF` 行结尾、`length-prefix` 编码：

```text
*2\r\n$4\r\nTEXT\r\n$5\r\nHello\r\n
*2\r\n$8\r\nTHINKING\r\n$22\r\nLet me analyze this...\r\n
*6\r\n$9\r\nTOOL_CALL\r\n$4\r\nBash\r\n$8\r\ncall_123\r\n$17\r\n{"command":"pwd"}\r\n$7\r\ncommand\r\n$3\r\npwd\r\n
*4\r\n$5\r\nUSAGE\r\n$2\r\n25\r\n$2\r\n42\r\n$1\r\n8\r\n
*2\r\n$4\r\nSTOP\r\n$8\r\nend_turn\r\n
```

对外的 `stream-json` 会输出这些结构化事件：

- `text`
- `thinking`
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
    transport_openai_body.awk
    transport_openai_sse.awk
    edit_file.awk
    skill_summary.awk
    event_replay.awk
    compact_dp.awk
    stats.awk
docs/
  ARCHITECTURE.md
  dp-compact-analysis.md
scripts/
  build.sh
tests/
  test.sh
dist/
  agent.sh
  goagent
  rustagent
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
rust/
  src/
    main.rs
    app.rs
    config.rs
    conversation.rs
    httpclient.rs
    prompt.rs
    protocol.rs
    provider.rs
    session.rs
    sse.rs
    tools.rs
    assets.rs
  Cargo.toml
  Cargo.lock
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

- compact 使用基于缓存经济学的 DP 算法，自动决策是否压缩和保留量
- session 状态按项目隔离
- tool 协议已经结构化，二进制安全（RESP-like length-prefix），适合机器消费
- `TodoWrite` 负责维护 session 级 todo 状态
- CI 会构建并上传 `agent.sh` / `goagent` / `rustagent` 产物（`dist/agent.sh` 会先跑测试）
- Go 版可以编译运行，并保留当前主线的 agent loop / tool / session / compact 语义

## 文档

- [README.en.md](README.en.md) English
- [ARCHITECTURE.md](docs/ARCHITECTURE.md)
