# bash-agent

A minimal AI coding agent runtime.

This repository contains two aligned implementations:

- `bash-agent`: the current stable `bash + awk` runtime
- `goagent`: a Go port that keeps the same agent loop / tool / session semantics while using native Go structs and channels internally

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
- `awk` handles JSON/SSE parsing, text extraction, normalization, and small protocol transforms

The `goagent` line keeps the same behavior model, but rewrites:

- JSON/SSE parsing
- internal event flow
- tool dispatch
- session/compact flow

in native Go.

The goal is not “few files at any cost”. The goal is:

- minimal runtime dependencies
- clear protocol boundaries
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
curl -fsSL https://raw.githubusercontent.com/lloydzhou/bash-agent/main/dist/agent.sh -o ~/.local/bin/bash-agent && chmod +x ~/.local/bin/bash-agent
```

Build and install the Go port locally:

```bash
mkdir -p go/.gocache go/.gomodcache && GOCACHE=$(pwd)/go/.gocache GOMODCACHE=$(pwd)/go/.gomodcache go -C go build -o ~/.local/bin/goagent ./cmd/goagent
```

Or download the built artifact directly:

```bash
curl -fsSL https://raw.githubusercontent.com/lloydzhou/bash-agent/main/dist/goagent -o ~/.local/bin/goagent && chmod +x ~/.local/bin/goagent
```

Go port help:

```bash
goagent -h
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
~/.bash-agent/goagent.history
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
- default timeout: `600s`
- captures and truncates large output

### `Glob`

- file discovery using `rg --files -g`
- requires `rg`

### `Grep`

- content search using `rg -n`
- requires `rg`

### `TodoWrite`

- writes the session todo checklist
- intended for complex multi-step tasks
- stores checklist state in `*.todo.md`

## Sessions and State

State is stored per project under:

```text
~/.bash-agent/projects/<project_key>/
```

Per-session files:

```text
<session_id>.jsonl
<session_id>.events.jsonl
<session_id>.summary.txt
<session_id>.todo.md
```

Meaning:

- `jsonl`: current conversation window actually sent to the model
- `events.jsonl`: internal session event log
- `summary.txt`: compacted history summary
- `todo.md`: current session todo checklist

Without `--session`, conversation state is temporary and cleaned up when the process exits.

## Context Compaction

Compaction is based on actual context size, not message count.

- `--max-context` is a byte budget
- accepts values like `100k`, `1m`, `100000`
- when over budget, old messages are compacted into `summary.txt`
- retained history is aligned to a full user-turn boundary

This avoids invalid tails such as:

- orphaned `tool_result`
- preserved `assistant.tool_use` without the corresponding user turn

## Skills

Skills are loaded only from:

```text
.claude/skills/<name>/SKILL.md
```

The runtime uses two layers:

1. `skill-index`
   - lightweight summaries from `.claude/skills/*/SKILL.md`
2. `selected-skills`
   - full `SKILL.md` content only when `--skill NAME` is specified

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

Internally, SSE output is normalized into a lightweight line protocol:

```text
TEXT:Hello
TOOL_CALL:Bash\tcall_123\t{"command":"pwd"}\tcommand\tpwd
USAGE:25\t42\t8
STOP:end_turn
```

`stream-json` exposes machine-readable events such as:

- `text`
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

- compact uses real context size, not message count
- session state is project-scoped
- tool protocol is structured and machine-readable
- `TodoWrite` maintains session-scoped todo state
- source and dist builds both pass the test suite
- the Go port builds successfully and preserves the main agent loop / tool / session / compact semantics

## Documentation

- [README.md](README.md) Chinese
- [ARCHITECTURE.md](ARCHITECTURE.md)
