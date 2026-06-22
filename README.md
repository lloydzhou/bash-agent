<p align="center">
  <img src="docs/assets/logo.svg" alt="bash-agent logo" width="96" height="96">
</p>

# bash-agent

<p align="center">
  <img alt="bash 5.0+" src="https://img.shields.io/badge/bash-5.0%2B-4EAA25?logo=gnubash&logoColor=white">
  <img alt="platform Linux | macOS | WSL" src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20WSL-blue">
  <img alt="lines 1,690" src="https://img.shields.io/badge/lines-1%2C690-informational">
  <img alt="functions 107" src="https://img.shields.io/badge/functions-107-informational">
  <img alt="license MIT" src="https://img.shields.io/badge/license-MIT-green">
  <img alt="status preview" src="https://img.shields.io/badge/status-preview-orange">
</p>

[🌐 官网](https://lloydzhou.github.io/bash-agent/) · [English](README.en.md)

极简 AI coding agent runtime。纯 `bash + awk`，零运行时依赖。

同时提供 C (`cagent`)、Go (`goagent`) 和 Rust (`rustagent`) 原生 port，保持相同语义。

## 特点

- **零依赖** — 只需要 bash、awk、curl、rg
- **四运行时对齐** — bash/c/go/rust 保持相同的 agent loop、tool、session 语义
- **异步子 Agent** — 内建 `SubAgent` 工具，委托子任务给独立会话并行执行，结果自动回注主对话。支持 `fork` 模式继承上下文、会话隔离、故障传播
- **缓存感知压缩** — 基于经济学的 DP 算法自动决策是否压缩、保留多少
- **Session 持久化** — 按项目隔离，支持恢复、续接、fork 派生、compact
- **机器友好** — `stream-json` 输出结构化事件，可被上层客户端消费
- **技能系统** — 按需加载 skill，不污染后续 prompt

## 快速开始

```bash
# macOS — 通过 Homebrew 安装（包含 bash/c/go/rust 四个版本）
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
bash-agent --output-format stream-json "inspect"
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
安装后包含 `bash-agent`、`cagent`、`ccagent`、`goagent`、`rustagent` 五个命令。

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

预构建产物下载（C / Go / Rust）见 [Releases](https://github.com/lloydzhou/bash-agent/releases)。

## CLI

| 参数 | 说明 | 默认值 |
| --- | --- | --- |
| `-p, --provider` | `claude` 或 `openai` | `claude` |
| `-m, --model` | 模型名 | `claude-sonnet-4-20250514` |
| `--base-url` | 覆盖 API base URL | - |
| `--api-key` | 覆盖 API key | - |
| `--skill NAME` | 加载 skill | - |
| `--max-tokens` | 最大输出 token | `16384` |
| `--max-turns` | 最大 agent loop turn 数 | `1000` |
| `--thinking` | 思考模式：`enabled` / `disabled` | `enabled` |
| `--effort` | 思考力度：`low` / `medium` / `high` | - |
| `--print` | 非交互：读取 stdin 提示，输出到 stdout | - |
| `--max-context` | context 预算（`100k`/`1m`/`1g`） | `200000` |
| `--tool-timeout N` | tool 超时秒数 | `600` |
| `--session [NAME]` | 创建或使用 session | - |
| `--continue` | 继续最近 session | - |
| `--fork` | 从源 session 派生新 session（配合 `--session` 或 `--continue`） | - |
| `--list-sessions` | 列出当前项目 session | - |
| `-i` | 交互模式 | - |
| `--output-format FMT` | 输出格式：`human` 或 `stream-json` | `human` |
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

## 图片粘贴

终端交互模式下 **Ctrl+V** 从剪贴板粘贴图片，自动插入 `[Image #N]` 占位符并缓存到 session。发送消息时自动收集所有图片，调用 GLM-4V-Flash（免费）转录文字并追加 `<attached-images>` 描述。

支持平台：
- **macOS**: `osascript`（内置）
- **Linux Wayland**: `wl-paste`
- **Linux X11**: `xclip`

无需 API key 时仍可粘贴图片（生成 `[Image #N]`），仅跳过描述步骤。

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
| `BASH_AGENT_BASH_MODE` | Bash 工具权限，4 位八进制 `system/external/network/workspace`；每位 `4=read,2=write,1=execute`（默认 `0467`） |
| `DESCRIBE_API_KEY` | 图片描述 API key（默认使用 GLM-4V-Flash，免费） |
| `DESCRIBE_MODEL` | 图片描述模型名（默认 `glm-4v-flash`） |
| `DESCRIBE_BASE_URL` | 图片描述 API 基础地址（默认 `https://open.bigmodel.cn/api/paas/v4`） |
| `THINKING` | 覆盖思考模式：`enabled` / `disabled`（CLI `--thinking`） |
| `EFFORT` | 覆盖思考力度：`low` / `medium` / `high`（CLI `--effort`） |

## Bash 工具权限模式

`BASH_AGENT_BASH_MODE` 控制 `Bash` 工具允许访问的范围。它是一个 4 位八进制字符串：

```text
system external network workspace
```

每一位使用 `4=read`、`2=write`、`1=execute`。

默认值：

```text
0467
```

表示：

- `system=0`：默认不允许系统范围读写执行
- `external=4`：允许读取工作区外普通路径
- `network=6`：允许网络读写
- `workspace=7`：允许工作区内读写执行

常见示例：

```bash
export BASH_AGENT_BASH_MODE=0467  # 默认
export BASH_AGENT_BASH_MODE=4447  # 允许 system read
export BASH_AGENT_BASH_MODE=0457  # 允许 network execute
export BASH_AGENT_BASH_MODE=7777  # 全开，仅建议受信环境
```

如果值非法，会 fail-closed 为 `0000`。这个模型的表达方式类似 Linux 文件权限的 `rwx` 位。更完整的分类规则、推荐配置和错误文案见 [`docs/bash-tool-policy.md`](docs/bash-tool-policy.md)。

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
| `DP_QUALITY_PENALTY` | `0.2` | 质量衰减惩罚系数（基于"Lost in the Middle"等研究） |
| `DP_MIN_KEEP_RATIO` | `0.25` | 最少保留消息比例 |

## Context 压缩

压缩使用基于缓存经济学的 DP 算法，在每一步计算 5 项净收益：

$$
\begin{aligned}
\text{NetBenefit}(k) &=
  \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{后续节省}} \\
&\quad -\underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{缓存失效}} \\
&\quad -\underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{压缩成本}} \\
&\quad -\underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{信息失真}} \\
&\quad +\underbrace{Q \cdot P_{\text{input}} \cdot \frac{(V + T)^2 - (V + K)^2}{M \cdot 10^6}}_{⑤\;\text{质量改善收益}}
\end{aligned}
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

`Read` · `Write` · `Edit` · `Bash` · `Glob` · `Grep` · `TodoWrite` · `PlanConfirm` · `PlanClear` · `Skill` · `SubAgent` · `WebSearch` · `WebFetch`

> 详细说明见 [`docs/tools.md`](docs/tools.md)。`Bash` 工具的权限模型见 [`docs/bash-tool-policy.md`](docs/bash-tool-policy.md)。

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
| [`docs/bash-tool-policy.md`](docs/bash-tool-policy.md) | Bash 工具权限模式、分类规则、推荐配置 |
| [`docs/tools.md`](docs/tools.md) | 13 个内置工具详细说明 |
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
