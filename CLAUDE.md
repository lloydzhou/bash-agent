# Project Principles

## Port Conformance

**bash-agent (`src/agent.sh`) is the reference implementation.** All other language ports (pyagent, etc.) must replicate its behavior exactly, with only one exception: inter-layer communication may use idiomatic patterns of the target language instead of stdio/RESP. Every other aspect — CLI flags, session management, display formatting, tool dispatch, safety checks, compaction logic, streaming protocol — must match bash-agent's semantics and output.

When in doubt, read `src/agent.sh` first.

### Checklist for port correctness
- CLI flags: same names, same defaults, same behavior
- Session storage: same directory layout (`~/.bash-agent/projects/<key>/<id>/`)
- Display: same colors, same prompt (`\033[32m> \033[0m`), same tool summaries
- Tools: same names, same parameter schemas, same safety rules
- Compaction: same trigger thresholds, same summarization approach
- Provider: same URL resolution, same header construction, same SSE parsing
