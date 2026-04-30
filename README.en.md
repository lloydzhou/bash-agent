# bash-agent

[中文说明](README.md)

A minimal AI coding agent runtime. Pure `bash + awk`, zero runtime dependencies.

Go (`goagent`) and Rust (`rustagent`) ports maintain the same semantics.

## Highlights

- **Zero dependencies** — only bash, awk, curl, rg
- **Three aligned ports** — bash/go/rust share the same agent loop, tool, and session semantics
- **Cache-aware compaction** — DP economics algorithm decides whether and how much to compact
- **Session persistence** — project-scoped, resumable, compactable
- **Machine-friendly** — `stream-json` outputs structured events for client consumption
- **Skill system** — on-demand skill loading without polluting future prompts

## Quick Start

```bash
# Install
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent

# Set API key
export ANTHROPIC_API_KEY="sk-ant-..."

# Run
bash-agent "scan this repo and summarize"
bash-agent -i                    # interactive mode
bash-agent --print "inspect"     # stream-json output
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

```bash
# bash (single file)
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh \
  -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent

# Go
go -C go build -o ~/.local/bin/goagent ./cmd/goagent

# Rust
cd rust && cargo build --release && cp target/release/rustagent ~/.local/bin/rustagent
```

Pre-built binaries (Go / Rust) are available on [Releases](https://github.com/lloydzhou/bash-agent/releases).

## CLI

| Flag | Description |
| --- | --- |
| `-p, --provider` | `claude` or `openai` (default: `claude`) |
| `-m, --model` | model name |
| `--base-url` | override API base URL |
| `--api-key` | override API key |
| `--skill NAME` | load a skill |
| `--max-tokens` | max output tokens |
| `--max-turns` | max agent loop turns |
| `--max-context` | context budget (`100k`/`1m`/`1g`) |
| `--tool-timeout N` | tool timeout in seconds |
| `--session [NAME]` | create or resume a session |
| `--continue` | continue the latest session |
| `--list-sessions` | list sessions for the current project |
| `-i` | interactive mode |
| `--print` | stream-json output |
| `-v` | verbose logging |

## Context Compaction

Compaction uses a cache-aware DP economics algorithm that computes a 4-term net benefit:

$$
\text{NetBenefit}(k) = \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{savings}} - \underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{cache miss}} - \underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{compact cost}} - \underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{info loss}}
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

With Claude Sonnet (P_input $3.00/MTok, P_cache $0.30/MTok), a 35k-token compact request:

- Without cache reuse: $0.105 → **With cache alignment: $0.018** (saves **83%**)

> Full derivation: [`docs/compact-analysis.md`](docs/compact-analysis.md).

## Built-in Tools

`Read` · `Write` · `Edit` · `Bash` · `Glob` · `Grep` · `TodoWrite` · `Skill` · `WebSearch` · `WebFetch`

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
| [`docs/tools.md`](docs/tools.md) | 10 built-in tool references |
| [`docs/compact-analysis.md`](docs/compact-analysis.md) | Compaction algorithm derivation |
| [`docs/sessions.md`](docs/sessions.md) | Session files and recovery |

## Development

```bash
bash tests/test.sh                                          # tests
bash scripts/build.sh                                       # build single-file dist
AGENT=./dist/agent.sh bash tests/test.sh                    # test dist artifact
go -C go test ./...                                         # Go tests
```

## License

MIT
