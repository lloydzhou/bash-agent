# bash-agent

[English](README.en.md)

极简 AI coding agent runtime。纯 `bash + awk`，零运行时依赖。

同时提供 Go (`goagent`) 和 Rust (`rustagent`) 原生 port，保持相同语义。

## 特点

- **零依赖** — 只需要 bash、awk、curl、rg
- **三 port 对齐** — bash/go/rust 保持相同的 agent loop、tool、session 语义
- **缓存感知压缩** — 基于经济学的 DP 算法自动决策是否压缩、保留多少
- **Session 持久化** — 按项目隔离，支持恢复、续接、compact
- **机器友好** — `stream-json` 输出结构化事件，可被上层客户端消费
- **技能系统** — 按需加载 skill，不污染后续 prompt

## 快速开始

```bash
# 安装
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent

# 设置 API key
export ANTHROPIC_API_KEY="sk-ant-..."

# 运行
bash-agent "scan this repo and summarize"
bash-agent -i                    # 交互模式
bash-agent --print "inspect"     # stream-json 输出
```

### OpenAI 兼容接口

```bash
export OPENAI_API_KEY="sk-..."
bash-agent -p openai -m gpt-4o "hello"
```

### 第三方端点

```bash
OPENAI_BASE_URL=http://localhost:11434/v1 bash-agent -p openai -m llama3 "hello"
```

## 安装

```bash
# bash（单文件）
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent

# Go
go -C go build -o ~/.local/bin/goagent ./cmd/goagent

# Rust
cd rust && cargo build --release && cp target/release/rustagent ~/.local/bin/rustagent
```

预构建产物下载（Go / Rust）见 [Releases](https://github.com/lloydzhou/bash-agent/releases)。

## CLI

| 参数 | 说明 |
| --- | --- |
| `-p, --provider` | `claude` 或 `openai`，默认 `claude` |
| `-m, --model` | 模型名 |
| `--base-url` | 覆盖 API base URL |
| `--api-key` | 覆盖 API key |
| `--skill NAME` | 加载 skill |
| `--max-tokens` | 最大输出 token |
| `--max-turns` | 最大 agent loop turn 数 |
| `--max-context` | context 预算（`100k`/`1m`/`1g`） |
| `--tool-timeout N` | tool 超时秒数 |
| `--session [NAME]` | 创建或使用 session |
| `--continue` | 继续最近 session |
| `--list-sessions` | 列出当前项目 session |
| `-i` | 交互模式 |
| `--print` | stream-json 输出 |
| `-v` | 详细日志 |

## Context 压缩

压缩使用基于缓存经济学的 DP 算法，在每一步计算 4 项净收益：

$$
\text{NetBenefit}(k) = \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{后续节省}} - \underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{缓存失效}} - \underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{压缩成本}} - \underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{信息失真}}
$$

- 所有参数支持环境变量覆盖（`DP_P_INPUT`、`DP_L`、`DP_BETA` 等）
- 安全阀：context > 90% 上限时强制压缩

### 缓存对齐摘要

摘要请求（summary call）与普通对话保持**完全相同的前缀**，最大化 API 缓存命中：

```
[System prompt + Tools + Old summary]  ← 缓存命中，按 P_cache 计费
[被丢弃的旧消息 H]                     ← 缓存命中，按 P_cache 计费
[Summary 指令]                         ← 仅此处缓存未命中
```

以 Claude Sonnet 为例（P_input $3.00/MTok, P_cache $0.30/MTok），35k tokens 的压缩请求：

- 无缓存复用：$0.105 → **缓存对齐后：$0.018**（节省 **83%**）

> 完整推导见 [`docs/compact-analysis.md`](docs/compact-analysis.md)。

## 内置工具

`Read` · `Write` · `Edit` · `Bash` · `Glob` · `Grep` · `TodoWrite` · `Skill` · `WebSearch` · `WebFetch`

> 详细说明见 [`docs/tools.md`](docs/tools.md)。

## Skills

从这些位置按优先级加载：

```text
.claude/skills/<name>/SKILL.md
./skills/<name>/SKILL.md
~/.claude/skills/<name>/SKILL.md
```

三层机制：`skill-index`（摘要）→ `selected-skills`（完整加载）→ `Skill` tool（按需读取）。

## Instruction Files

每个作用域加载优先级最高的一个：`AGENTS.md` > `AGENT.md` > `CLAUDE.md` > `.claude/CLAUDE.md`

作用域：全局（`~/.bash-agent/`）和项目（当前目录）。

## 文档

| 文档 | 说明 |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | 架构设计、分层、协议 |
| [`docs/tools.md`](docs/tools.md) | 10 个内置工具详细说明 |
| [`docs/compact-analysis.md`](docs/compact-analysis.md) | 压缩算法完整推导 |
| [`docs/sessions.md`](docs/sessions.md) | Session 文件结构与恢复 |

## 开发

```bash
bash tests/test.sh                                          # 测试
bash scripts/build.sh                                       # 构建单文件发行版
AGENT=./dist/agent.sh bash tests/test.sh                    # 测试构建产物
go -C go test ./...                                         # Go 测试
```

## 许可

MIT
