# bash-agent

[🌐 官网](https://lloydzhou.github.io/bash-agent/) · [English](README.en.md)

极简 AI coding agent runtime。纯 `bash + awk`，零运行时依赖。

同时提供 Go (`goagent`) 和 Rust (`rustagent`) 原生 port，保持相同语义。

## 特点

- **零依赖** — 只需要 bash、awk、curl、rg
- **三 port 对齐** — bash/go/rust 保持相同的 agent loop、tool、session 语义
- **异步子 Agent** — 内建 `SubAgent` 工具，委托子任务给独立会话并行执行，结果自动回注主对话。支持 `fork` 模式继承上下文、会话隔离、故障传播
- **缓存感知压缩** — 基于经济学的 DP 算法自动决策是否压缩、保留多少
- **Session 持久化** — 按项目隔离，支持恢复、续接、compact
- **机器友好** — `stream-json` 输出结构化事件，可被上层客户端消费
- **技能系统** — 按需加载 skill，不污染后续 prompt

## 快速开始

```bash
# macOS — 通过 Homebrew 安装（包含 bash/go/rust 三个版本）
brew install lloydzhou/tap/bash-agent

# 或手动安装 Bash 版（单文件）
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent

# 设置 API key（DeepSeek / Claude 二选一）
export DEEPSEEK_API_KEY="sk-..."
# export ANTHROPIC_API_KEY="sk-ant-..."

# 运行
bash-agent "scan this repo and summarize"
bash-agent -i                    # 交互模式
bash-agent --print "inspect"     # stream-json 输出
```

### DeepSeek 兼容（Anthropic 协议）

```bash
export DEEPSEEK_API_KEY="sk-..."
bash-agent "hello"   # 自动检测，使用 deepseek-v4-flash
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

### macOS（推荐）
```bash
brew install lloydzhou/tap/bash-agent
```
安装后包含 `bash-agent`、`goagent`、`rustagent` 三个二进制。

### Arch Linux（AUR）
```bash
# 使用 yay
yay -S bash-agent

# 或使用 paru
paru -S bash-agent
```
详见 [AUR 包页面](https://aur.archlinux.org/packages/bash-agent)。

### 手动安装 Bash 版
```bash
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent
```

### 从源码构建
```bash
# Go
go -C go build -o ~/.local/bin/goagent ./cmd/goagent

# Rust
cd rust && cargo build --release && cp target/release/rustagent ~/.local/bin/rustagent
```

预构建产物下载（Go / Rust）见 [Releases](https://github.com/lloydzhou/bash-agent/releases)。

## CLI

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-p, --provider` | `claude` 或 `openai` | `claude` |
| `-m, --model` | 模型名 | `claude-sonnet-4-20250514` |
| `--base-url` | 覆盖 API base URL | - |
| `--api-key` | 覆盖 API key | - |
| `--skill NAME` | 加载 skill | - |
| `--max-tokens` | 最大输出 token | `4096` |
| `--max-turns` | 最大 agent loop turn 数 | `40` |
| `--max-context` | context 预算（`100k`/`1m`/`1g`） | `200000` |
| `--tool-timeout N` | tool 超时秒数 | `600` |
| `--session [NAME]` | 创建或使用 session | - |
| `--continue` | 继续最近 session | - |
| `--list-sessions` | 列出当前项目 session | - |
| `-i` | 交互模式 | - |
| `--print` | stream-json 输出 | - |
| `-v` | 详细日志 | - |

## tcode — tmux Chat UI 包装器

<details>
<summary>tmux 三栏界面包装器，点开查看详情</summary>

`tcode` 是 agent 的 tmux 三栏界面包装器，提供 watch sidebar + agent 对话 + 输入框的布局。

```bash
# 启动（默认 rustagent）
tcode

# 指定 agent 并透传参数
tcode goagent
tcode rustagent --session my-session
tcode goagent -p openai -m gpt-4o

# 从 release 下载后直接运行
./tcode
```

支持 readline 输入、退出后打印 resume 信息、Ctrl+C 中断、Ctrl+D 干净退出。

</details>

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `DEEPSEEK_API_KEY` | DeepSeek API key（自动检测，使用 Anthropic 兼容端点） |
| `ANTHROPIC_API_KEY` | Claude API key |
| `MODEL` | 覆盖模型名（默认见 CLI 表格） |
| `OPENAI_API_KEY` | OpenAI API key |
| `ANTHROPIC_BASE_URL` | Claude API base URL |
| `OPENAI_BASE_URL` | OpenAI API base URL |
| `JINA_API_KEY` | Jina AI API key（WebSearch/WebFetch 工具需要） |
| `BASH_AGENT_HOME` | 覆盖 session 存储目录（默认 `$HOME`） |

DP 算法相关环境变量：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DP_P_INPUT` | `3.0` | $/MTok，未命中缓存的输入价格 |
| `DP_P_CACHE` | `0.30` | $/MTok，命中缓存的输入价格 |
| `DP_P_OUT` | `15.0` | $/MTok，输出价格 |
| `DP_V` | `5000` | 固定前缀 token 数 |
| `DP_S` | `500` | 固定摘要长度 token 数 |
| `DP_L` | `5` | 每轮用户输入平均 LLM 调用次数（0=自动计算） |
| `DP_BASELINE_E` | `8` | 预期剩余用户输入轮数 |
| `DP_R` | `0.8` | 单次摘要信息保留率 |
| `DP_BETA` | `0.03` | 信息损失惩罚系数 |
| `DP_MAX_CONTEXT` | `200000` | 模型最大上下文 token 数 |
| `DP_QUALITY_PENALTY` | `0` | 质量衰减惩罚系数（0=关闭，推荐 0.1~0.2） |
| `DP_MIN_KEEP_RATIO` | `0.12` | 最少保留消息比例 |

## Context 压缩

压缩使用基于缓存经济学的 DP 算法，在每一步计算 5 项净收益：

$$
\begin{aligned}
\text{NetBenefit}(k) &=
  \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{后续节省}} \\
&\quad -\underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{缓存失效}} \\
&\quad -\underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{压缩成本}} \\
&\quad -\underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{信息失真}} \\
&\quad -\underbrace{\texttt{DP\_QUALITY\_PENALTY} \cdot P_{\text{input}} \cdot \frac{(V + K)^2}{M \cdot 10^6}}_{⑤\;\text{质量衰减}}
\end{aligned}
$$

其中 ⑤ 质量衰减项的物理含义：

$$
⑤ = (\texttt{DP\_QUALITY\_PENALTY} \times P_{\text{input}} \times M / 10^6) \times ((V + K) / M)^2
$$

- **基准价格** = `DP_QUALITY_PENALTY` × `P_input` × `M / 1e6`：满上下文时的惩罚金额
- **比例平方** = `((V+K)/M)²`：上下文占比的平方，0~1 之间随比例加速上升

- 所有参数支持环境变量覆盖（`DP_P_INPUT`、`DP_L`、`DP_BETA` 等）
- 安全阀：context > 90% 上限时强制压缩

### 缓存对齐摘要

摘要请求（summary call）与普通对话保持**完全相同的前缀**，最大化 API 缓存命中：

```
[System prompt + Tools + Old summary]  ← 缓存命中，按 P_cache 计费
[被丢弃的旧消息 H]                     ← 缓存命中，按 P_cache 计费
[Summary 指令]                         ← 仅此处缓存未命中
```

以 Claude Sonnet 4 为例（compact 45K tokens of history）：

| Tokens | Without cache alignment | With cache alignment |
|--------|------------------------|---------------------|
| System prompt ~2K | Full: $0.006 | Cached: $0.0006 |
| Tools ~3K | Full: $0.009 | Cached: $0.0009 |
| Dropped messages ~40K | Full: $0.120 | Cached: $0.012 |
| Summary instruction ~200 | Full: $0.0006 | Full: $0.0006 |
| **Total ~45.2K** | **$0.136** | **$0.014** |
| | | **节省 ~90%** |

> 完整推导见 [`docs/compact-analysis.md`](docs/compact-analysis.md)。

## 内置工具

`Read` · `Write` · `Edit` · `Bash` · `Glob` · `Grep` · `TodoWrite` · `Skill` · `SubAgent` · `WebSearch` · `WebFetch`

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
| [`docs/tools.md`](docs/tools.md) | 11 个内置工具详细说明 |
| [`docs/compact-analysis.md`](docs/compact-analysis.md) | 压缩算法完整推导 |
| [`docs/sessions.md`](docs/sessions.md) | Session 文件结构与恢复 |

## 开发

```bash
make test                            # 运行所有测试 (bash + go 单元 + rust check)
make test-go-e2e                     # Go 版本集成测试 (build + test.sh)
make test-rust-e2e                   # Rust 版本集成测试 (build + test.sh)
```

## 许可

MIT
