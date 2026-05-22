# bash-agent

[🌐 Website](https://lloydzhou.github.io/bash-agent/) · [中文说明](README.md)

A minimal AI coding agent runtime. Pure `bash + awk`, zero runtime dependencies.

Go (`goagent`) and Rust (`rustagent`) ports maintain the same semantics.

## Highlights

- **Zero dependencies** — only bash, awk, curl, rg
- **Three aligned ports** — bash/go/rust share the same agent loop, tool, and session semantics
- **Async SubAgent** — built-in `SubAgent` tool delegates subtasks to independent sessions running in parallel, results auto-injected back. Supports `fork` mode for context inheritance, session isolation, and failure propagation
- **Cache-aware compaction** — DP economics algorithm decides whether and how much to compact
- **Session persistence** — project-scoped, resumable, compactable
- **Machine-friendly** — `stream-json` outputs structured events for client consumption
- **Skill system** — on-demand skill loading without polluting future prompts

## Quick Start

```bash
# macOS — install via Homebrew (all three editions: bash/go/rust)
brew install lloydzhou/tap/bash-agent

# Or install bash-only manually (single file)
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent

# Set API key (DeepSeek / Claude — pick one)
export DEEPSEEK_API_KEY="sk-..."
# export ANTHROPIC_API_KEY="sk-ant-..."

# Run
bash-agent "scan this repo and summarize"
bash-agent -i                    # interactive mode
bash-agent --print "inspect"     # stream-json output
```

### DeepSeek (Anthropic-compatible)

```bash
export DEEPSEEK_API_KEY="sk-..."
bash-agent "hello"   # auto-detected, uses deepseek-v4-flash
```

### OpenAI-compatible APIs

```bash
export OPENAI_API_KEY="sk-..."
bash-agent -p openai -m gpt-4o "hello"
```

### Third-party endpoints

```bash
OPENAI_BASE_URL=http://localhost:11434/v1 bash-agent -p openai -m llama3 "hello"
```

## Install

### macOS (recommended)
```bash
brew install lloydzhou/tap/bash-agent
```
Installs three binaries: `bash-agent`, `goagent`, `rustagent`.

### Arch Linux (AUR)
```bash
# Using yay
yay -S bash-agent

# Or using paru
paru -S bash-agent
```
See [AUR package page](https://aur.archlinux.org/packages/bash-agent) for details.

### Manual (bash only)
```bash
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent
```

### Build from source
```bash
# Go
go -C go build -o ~/.local/bin/goagent ./cmd/goagent

# Rust
cd rust && cargo build --release && cp target/release/rustagent ~/.local/bin/rustagent
```

Pre-built binaries (Go / Rust) are available on [Releases](https://github.com/lloydzhou/bash-agent/releases).

## CLI

| Flag | Description | Default |
| --- | --- | --- |
| `-p, --provider` | `claude` or `openai` | `claude` |
| `-m, --model` | model name | `claude-sonnet-4-20250514` |
| `--base-url` | override API base URL | - |
| `--api-key` | override API key | - |
| `--skill NAME` | load a skill | - |
| `--max-tokens` | max output tokens | `4096` |
| `--max-turns` | max agent loop turns | `40` |
| `--max-context` | context budget (`100k`/`1m`/`1g`) | `200000` |
| `--tool-timeout N` | tool timeout in seconds | `600` |
| `--session [NAME]` | create or resume a session | - |
| `--continue` | continue the latest session | - |
| `--list-sessions` | list sessions for the current project | - |
| `-i` | interactive mode | - |
| `--print` | stream-json output | - |
| `-v` | verbose logging | - |

## tcode — tmux Chat UI Wrapper

<details>
<summary>tmux 3-pane wrapper for the agent, click to expand</summary>

`tcode` is a tmux 3-pane wrapper for the agent, with watch sidebar, agent chat, and input pane.

```bash
# Start (defaults to rustagent)
tcode

# Specify agent and passthrough args
tcode goagent
tcode rustagent --session my-session
tcode goagent -p openai -m gpt-4o

# Run directly from release download
./tcode
```

Supports readline input, resume info on exit, Ctrl+C to interrupt, Ctrl+D to cleanly exit.

</details>

## Environment Variables

| Variable | Description |
| --- | --- |
| `DEEPSEEK_API_KEY` | DeepSeek API key (auto-detected, uses Anthropic-compatible endpoint) |
| `ANTHROPIC_API_KEY` | API key for Claude |
| `MODEL` | Override model name (defaults per CLI table) |
| `OPENAI_API_KEY` | API key for OpenAI |
| `ANTHROPIC_BASE_URL` | Claude API base URL |
| `OPENAI_BASE_URL` | OpenAI API base URL |
| `JINA_API_KEY` | Jina AI API key (required for WebSearch/WebFetch tools) |
| `BASH_AGENT_HOME` | Override session storage directory (default: `$HOME`) |
| `THINKING_BUDGET` | Thinking token budget (default: `2048`) |

DP algorithm environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `DP_P_INPUT` | `3.0` | $/MTok, input price without cache |
| `DP_P_CACHE` | `0.30` | $/MTok, input price with cache |
| `DP_P_OUT` | `15.0` | $/MTok, output price |
| `DP_V` | `5000` | Fixed prefix token count |
| `DP_S` | `500` | Fixed summary length in tokens |
| `DP_L` | `5` | Avg LLM calls per user input (0=auto) |
| `DP_BASELINE_E` | `8` | Expected remaining user input turns |
| `DP_R` | `0.8` | Single summary info retention rate |
| `DP_BETA` | `0.03` | Info loss penalty coefficient |
| `DP_MIN_KEEP_RATIO` | `0.12` | Minimum message keep ratio |

## Context Compaction

Compaction uses a cache-aware DP economics algorithm that computes a 4-term net benefit:

$$
\begin{aligned}
\text{NetBenefit}(k) &=
  \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{savings}} \\
&\quad -\underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{cache miss}} \\
&\quad -\underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{compact cost}} \\
&\quad -\underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{info loss}}
\end{aligned}
$$

- All parameters overridable via env vars (`DP_P_INPUT`, `DP_L`, `DP_BETA`, etc.)
- Safety valve: force compact when context exceeds 90% of limit

### Cache-Aligned Summary

The summary request uses the **same prefix** as normal conversation requests, maximizing API cache hits:

```
[System prompt + Tools + Old summary]  ← cache hit, billed at P_cache
[Dropped old messages H]               ← cache hit, billed at P_cache
[Summary instruction]                  ← only this part is cache-miss
```

With Claude Sonnet 4 (compacting 45K tokens of history):

| Tokens | Without cache alignment | With cache alignment |
|--------|------------------------|---------------------|
| System prompt ~2K | Full: $0.006 | Cached: $0.0006 |
| Tools ~3K | Full: $0.009 | Cached: $0.0009 |
| Dropped messages ~40K | Full: $0.120 | Cached: $0.012 |
| Summary instruction ~200 | Full: $0.0006 | Full: $0.0006 |
| **Total ~45.2K** | **$0.136** | **$0.014** |
| | | **Saves ~90%** |

> Full derivation: [`docs/compact-analysis.md`](docs/compact-analysis.md).

## Built-in Tools

`Read` · `Write` · `Edit` · `Bash` · `Glob` · `Grep` · `TodoWrite` · `Skill` · `SubAgent` · `WebSearch` · `WebFetch`

> See [`docs/tools.md`](docs/tools.md) for details.

## Skills

Loaded from these locations (highest priority first):

```text
.claude/skills/<name>/SKILL.md
./skills/<name>/SKILL.md
~/.claude/skills/<name>/SKILL.md
```

Three-layer mechanism: `skill-index` (summary) → `selected-skills` (full load) → `Skill` tool (on-demand read).

## Instruction Files

Per scope, loads the highest-priority file: `AGENTS.md` > `AGENT.md` > `CLAUDE.md` > `.claude/CLAUDE.md`

Scopes: global (`~/.bash-agent/`) and project (current directory).

## Documentation

| Document | Description |
| --- | --- |
| [`docs/architecture.md`](docs/architecture.md) | Architecture, layering, protocols |
| [`docs/tools.md`](docs/tools.md) | 11 built-in tool references |
| [`docs/compact-analysis.md`](docs/compact-analysis.md) | Compaction algorithm derivation |
| [`docs/sessions.md`](docs/sessions.md) | Session files and recovery |

## Development

```bash
make test                            # run all tests (bash + go unit + rust check)
make test-go-e2e                     # Go integration tests (build + test.sh)
make test-rust-e2e                   # Rust integration tests (build + test.sh)
```

## License

MIT
