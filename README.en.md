# bash-agent

A minimal AI coding agent runtime.

This repository contains three aligned implementations:

- `bash-agent`: the current stable `bash + awk` runtime
- `goagent`: a Go port that keeps the same agent loop / tool / session semantics
- `rustagent`: a Rust port with the same behavior model using native Rust JSON/SSE/dispatch

It is designed to stay small at runtime while still exposing the core pieces an agent needs:

- streaming model I/O
- structured tool calls
- session persistence
- context compaction
- machine-friendly event output

`bash-agent` is not trying to be a full platform. It is a compact agent core that can run in a terminal or be embedded behind another client.

## Why This Exists

Most agent runtimes grow by adding layers:

- SDKs
- background services
- state stores
- protocol adapters
- orchestration frameworks

The `bash-agent` line takes the opposite path:

- `bash` handles orchestration, files, processes, HTTP calls, and session lifecycle
- `awk` handles JSON/SSE parsing, text extraction, normalization, and RESP-like protocol output

The `goagent` line keeps the same behavior model, but rewrites:

- JSON/SSE parsing
- internal event flow
- tool dispatch
- session/compact flow

in native Go.

The `rustagent` line keeps the same behavior model, but rewrites:

- interactive input/output
- JSON/SSE parsing
- internal event flow
- tool dispatch
- session/compact flow

in native Rust.

The goal is not “few files at any cost”. The goal is:

- minimal runtime dependencies
- clear protocol boundaries (RESP-like wire format between awk and bash)
- predictable state
- enough functionality to do real work

## Current Capabilities

- Providers:
  - `claude`
  - `openai` chat-completions compatible APIs
- Output modes:
  - `human`
  - `stream-json`
- Session state:
  - persisted per project and per session
  - resumable
  - compactable
- Built-in tools:
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
- Prompt layers:
  - instruction files
  - skill index
  - selected skills
  - compact summary
  - current todo

## Quick Start

```bash
# Default provider is claude
export ANTHROPIC_API_KEY="sk-ant-..."
./src/agent.sh -m claude-sonnet-4-20250514 "say hello"

# OpenAI chat-completions compatible endpoint
export OPENAI_API_KEY="sk-..."
./src/agent.sh -p openai -m gpt-4o "say hello"

# Interactive mode
./src/agent.sh -i

# No arguments also enters interactive mode
./src/agent.sh

# Machine-readable stream output
./src/agent.sh --print "scan this repo"
```

## Install

```bash
curl -fsSL https://github.com/lloydzhou/bash-agent/releases/latest/download/agent.sh -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent
```

Build and install the Go port locally:

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go build -o ~/.local/bin/goagent ./cmd/goagent
```

Build and install the Rust port locally (release):

```bash
cd rust && cargo build --release && cp target/release/rustagent ~/.local/bin/rustagent
```

Or download the built artifact directly:

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ] && ARCH=arm64; curl -fsSL "https://github.com/lloydzhou/bash-agent/releases/latest/download/goagent-${OS}-${ARCH}" -o ~/.local/bin/goagent && chmod +x ~/.local/bin/goagent
```

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]'); ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH=amd64; [ "$ARCH" = "arm64" ] || [ "$ARCH" = "aarch64" ] && ARCH=arm64; case "$OS" in linux|darwin) SUFFIX="${OS}-${ARCH}" ;; *) echo "No prebuilt rustagent for $OS/$ARCH, build locally with: cd rust && cargo build --release"; exit 1 ;; esac; curl -fsSL "https://github.com/lloydzhou/bash-agent/releases/latest/download/rustagent-${SUFFIX}" -o ~/.local/bin/rustagent && chmod +x ~/.local/bin/rustagent
```

Go port help:

```bash
goagent -h
```

Rust port help:

```bash
rustagent -h
```

Rust interactive mode supports:

- history
- arrow-key navigation

History is stored in:

```text
~/.bash-agent/history
```

Third-party compatible endpoints are supported through `--base-url` or environment variables:

```bash
OPENAI_BASE_URL=http://localhost:11434/v1 \
./src/agent.sh -p openai -m llama3 "hello"
```

## Example Workflows

### Human Mode

```bash
./src/agent.sh -p openai -m gpt-4o "run the tests and summarize failures"
```

### Stream JSON

```bash
./src/agent.sh -p claude --output-format stream-json "inspect this repository" | jq -c .
```

### Persistent Session

```bash
./src/agent.sh --session demo "run the tests"
./src/agent.sh --session demo "fix the first failure"
./src/agent.sh --continue "what changed so far?"
```

### Skills

```bash
./src/agent.sh --skill shell-safety "inspect /tmp safely"
```

### Go Port

```bash
goagent "run the tests and summarize failures"
goagent --print "inspect this repository"
goagent --session demo "run the tests"
goagent -i
```

The Go interactive mode supports:

- history
- arrow-key navigation

History is stored in:

```text
~/.bash-agent/history
```

## CLI

| Flag | Description |
| --- | --- |
| `-p, --provider` | `claude` or `openai` (default: `claude`) |
| `-m, --model` | model name |
| `--base-url` | override API base URL |
| `--api-key` | override API key |
| `--skill NAME` | load `.claude/skills/NAME/SKILL.md` |
| `--max-tokens` | max output tokens |
| `--max-turns` | max agent loop turns |
| `--max-context` | context size budget, supports `100k`, `1m`, `1g` |
| `--tool-timeout N` | tool timeout in seconds |
| `--session [NAME]` | create/use a persistent session |
| `--continue` | continue the latest session in the current project |
| `--list-sessions` | list sessions for the current project |
| `--output-format` | `human` or `stream-json` |
| `--print` | alias for `--output-format stream-json` |
| `-i, --interactive` | interactive mode |
| `-v, --verbose` | verbose logging |
| `compact` | compact the current session |

## Built-in Tools

### `Read`

- reads file content as text
- supports `offset` (starting line number) and `limit` (number of lines) for reading specific line ranges
- default result cap: `50KB`
- returns truncated content when the file is larger

### `Write`

- writes file content
- creates parent directories when needed
- default write cap: `1MB`

### `Edit`

- exact string replacement
- intended for precise edits, including multi-line replacements
- default write cap: `1MB`

### `Bash`

- runs shell commands
- supports per-command `timeout` parameter (in seconds)
- default timeout: `600s` (configurable globally via `--tool-timeout`)
- captures and truncates large output

### `Glob`

- file discovery using `rg --files -g`
- requires `rg`

### `Grep`

- content search using `rg -n`, supports regex patterns
- supports `path` (search directory), `glob` (file filter), and `context` (surrounding lines)
- `context` shows N lines before/after each match, useful for direct editing
- requires `rg`

### `TodoWrite`

- writes the session todo checklist
- intended for complex multi-step tasks
- stores checklist state in `todo.md` in the session directory

### `Skill`

- first select a skill name from the prompt's `skill-index`
- then use `Skill(name)` to read the matching `SKILL.md`
- when the user asks to use a skill, prefer this over reading skill files directly with `Read`

### `WebSearch`

- searches the web using the Jina AI Search API
- requires `curl` and the `JINA_API_KEY` environment variable
- default timeout: `30s`

### `WebFetch`

- fetches web page content using the Jina AI Reader API
- requires `curl` and the `JINA_API_KEY` environment variable
- default timeout: `60s`

## Sessions and State

State is stored per project under:

```text
~/.bash-agent/projects/<project_key>/
```

Per-session files (inside each session directory):

```text
<session_id>/conversation.jsonl
<session_id>/events.jsonl
<session_id>/summary.txt
<session_id>/todo.md
<session_id>/plan.md
<session_id>/stats.json
```

Meaning:

- `conversation.jsonl`: current conversation window actually sent to the model
- `events.jsonl`: internal session event log
- `summary.txt`: compacted history summary
- `todo.md`: current session todo checklist
- `plan.md`: current session plan document
- `stats.json`: session statistics (LLM call count, total input tokens, compaction count, current turn, etc.)

All sessions are persisted under `~/.bash-agent/projects/<project_key>/`, even without `--session` (a session ID is auto-generated). Use `--continue` to resume the most recent session.

## Context Compaction

### Cache-Aligned Summarization

Compaction uses a **cache-aware dynamic programming algorithm** that computes the net economic benefit of each compaction decision — whether to compact and how many messages to retain — rather than simple threshold triggering. The summary call reuses the main agent's prefix for cache alignment, saving ~85% input token cost per compaction.

### Decision Formula

For each candidate retention count $k$, compute the net benefit:

$$
\begin{aligned}
\text{NetBenefit}(k) &= \underbrace{\frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6}}_{①\;\text{savings}} \\
&- \underbrace{\frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6}}_{②\;\text{cache miss}} \\
&- \underbrace{\frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6}}_{③\;\text{compact cost}} \\
&- \underbrace{\frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}}_{④\;\text{info loss}}
\end{aligned}
$$

- If $\max_k \text{NetBenefit}(k) > 0$, compact with the optimal $k$
- Otherwise, skip compaction

| Term | Meaning |
|---|---|
| ① | After compaction, the next `R-1` LLM calls each save `H` tokens at cache price |
| ② | Summary content change breaks prefix cache: `S+K` tokens shift from cache to full price |
| ③ | Compaction request API cost (cached prefix + instruction + output) |
| ④ | Cumulative information distortion penalty, `r_t = r^(c+1)` (floor 0.37) |

### Key Variables

| Variable | Meaning | Default |
|---|---|---|
| $R = E \times L$ | Expected remaining LLM calls | — |
| $E$ | Expected remaining user-input rounds | $\max(8 - t,\; 4)$, monotonically non-increasing |
| $L$ | Avg LLM calls per user input | 5 (empirical) |
| $H$ | Dropped old message tokens | $T_{\text{total}} - K$ |
| $K$ | Retained message tokens | Computed per $k$ |
| $S$ | Fixed summary length | 500 tokens |
| $V$ | Fixed prefix (system prompt + tools + old summary) | 5000 tokens |

### Price Parameters (override per provider)

| Env Var | Default | Description |
|---|---|---|
| `DP_P_INPUT` | 3.00 | $/MTok, uncached input price |
| `DP_P_CACHE` | 0.30 | $/MTok, cached input price |
| `DP_P_OUT` | 15.00 | $/MTok, output price |
| `DP_L` | 5 | Avg LLM calls per user input (`0` = auto from stats) |
| `DP_BASELINE_E` | 8 | Expected remaining user-input rounds baseline |
| `DP_R` | 0.8 | Per-compaction info retention rate |
| `DP_BETA` | 0.03 | Info loss penalty coefficient |
| `DP_MIN_KEEP_RATIO` | 0.12 | Minimum messages to retain |

### Cache-Aligned Summarization

The summary call uses the **same prefix** (system prompt + tools + cache-control markers) as normal conversation requests, so the summarization agent achieves a prefix-cache hit:

```
[System prompt + Tools + Old summary]     ← cache hit, billed at P_cache
[Dropped old messages H]                  ← cache hit, billed at P_cache
[Summary instruction L_instr]             ← cache miss, billed at P_input
```

Output is a fixed-length $S$ new summary, replacing the old one in `summary.txt`.

With Claude Sonnet 4, a typical 45k-token compact request drops from ~$0.143 to ~$0.021 compared to a traditional summary without prefix caching — **~85% savings** per compaction.

### Safety Valve

When the DP formula says "don't compact" but `current_context > max_context × 90%`, compaction is forced:

```
keep_lines = max(3, total_lines × DP_MIN_KEEP_RATIO)
```

### Retention Window Alignment

The cut point is always aligned to a **real user message** (`"role":"user","content":"..."`), never at a tool result boundary. This avoids:

- orphaned `tool_result`
- preserved `assistant.tool_use` without the corresponding user turn

### Provider Price Comparison

| Provider | $P_{\text{input}}$ | $P_{\text{cache}}$ | $P_{\text{out}}$ | Savings/MTok | Preference |
|----------|-----|-----|-----|-----|------|
| Claude Sonnet 4 | 3.00 | 0.30 | 15.00 | 2.70 | Aggressive |
| GPT-4o | 2.50 | 1.25 | 10.00 | 1.25 | Moderate |
| DeepSeek v4 flash | 1.00 | 0.02 | 3.00 | 0.98 | Conservative |

Override via environment: `DP_P_INPUT=1.00 DP_P_CACHE=0.02 DP_P_OUT=3.00 ./src/agent.sh ...`

> Full derivation: [`docs/dp-compact-analysis.md`](docs/dp-compact-analysis.md).

## Skills

Skills are loaded primarily from:

```text
./.claude/skills/<name>/SKILL.md
./skills/<name>/SKILL.md
~/.claude/skills/<name>/SKILL.md
```

The runtime uses three layers:

1. `skill-index`
   - lightweight summaries from all visible skill directories
2. `selected-skills`
   - full `SKILL.md` content only when `--skill NAME` is specified
3. `Skill` tool
   - consults `skill-index` first at runtime
   - then reads the full `SKILL.md` by skill name
   - does not change future-turn system prompt state

During full skill loading, `${BASH_AGENT_SKILL_DIR}` is available for referencing sibling scripts or templates.

## Instruction Files

The runtime supports generic instruction file naming while remaining compatible with `CLAUDE.md`.

Per scope, it loads the highest-priority file from:

1. `AGENTS.md`
2. `AGENT.md`
3. `CLAUDE.md`
4. `.claude/CLAUDE.md`

Scopes:

- global: `~/.bash-agent/`
- project: current working directory

These are injected into the stable prompt prefix.

## Event Protocol

Internally, SSE output is normalized into a RESP-like protocol (awk → bash), using CRLF line endings and length-prefix encoding:

```text
*2\r\n$4\r\nTEXT\r\n$5\r\nHello\r\n
*2\r\n$8\r\nTHINKING\r\n$22\r\nLet me analyze this...\r\n
*6\r\n$9\r\nTOOL_CALL\r\n$4\r\nBash\r\n$8\r\ncall_123\r\n$17\r\n{"command":"pwd"}\r\n$7\r\ncommand\r\n$3\r\npwd\r\n
*4\r\n$5\r\nUSAGE\r\n$2\r\n25\r\n$2\r\n42\r\n$1\r\n8\r\n
*2\r\n$4\r\nSTOP\r\n$8\r\nend_turn\r\n
```

`stream-json` exposes machine-readable events such as:

- `text`
- `thinking`
- `tool_call`
- `todo_update`
- `tool_result`
- `usage`
- `stop`
- `error`
- `context_update`

Example:

```json
{"type":"tool_call","name":"Bash","id":"call_123","input":{"command":"pwd"}}
{"type":"usage","input_tokens":25,"output_tokens":42,"cache_input_tokens":8}
```

## Repository Layout

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

## Development

Run tests:

```bash
bash tests/test.sh
```

Build single-file distribution:

```bash
bash scripts/build.sh
```

Run tests against the built artifact:

```bash
AGENT=./dist/agent.sh bash tests/test.sh
```

Run Go tests:

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go test ./...
```

Build the Go binary:

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go build -o ../dist/goagent ./cmd/goagent
```

## Status

Current status:

- compact uses cache-aligned summarization with a DP economics algorithm for optimal compaction decisions
- session state is project-scoped
- tool protocol is structured and binary-safe (RESP-like length-prefix), suitable for machine consumption
- `TodoWrite` maintains session-scoped todo state
- CI builds and uploads `agent.sh` / `goagent` / `rustagent` artifacts (with tests run before publishing `dist/agent.sh`)
- the Go port builds successfully and preserves the main agent loop / tool / session / compact semantics

## Documentation

- [README.md](README.md) Chinese
- [ARCHITECTURE.md](docs/ARCHITECTURE.md)
