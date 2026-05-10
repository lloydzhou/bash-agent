# Changelog

所有重要变更均记录在此文件中。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [Unreleased]

### Changed

- **compact 触发时机**：`compact_context_window` 从循环外移到 `agent_loop_stream` 的每次 LLM 调用前，确保每轮都能基于最新的 `current_context_tokens` 做决策（`a5692d7`）
- **usage → ctx_tokens 数据流**：`record_usage` 返回 `ctx_tokens` 但不再直接写入 `current_context_tokens`；改由主循环在流结束后显式写入，compact 始终使用上一轮的完整上下文大小（`a5692d7`）

### Fixed

- **summary `record_usage` 参数丢失**：`run_summary_call` 中 `record_usage "compact" 2>/dev/null` 缺少空格，`2>/dev/null` 被解析为 stderr 重定向而非传参 `2`（counter_idx），导致 stats 文件损坏、PlanClear/compact 失败（`d281c54`）
- **Edit 工具 `unbound variable`**：`tool_edit` 合并 local 声明时 `label="${path#/}"` 引用了同语句中尚未赋值的 `path`，在 `set -u` 模式下报错；改用 `${1#/}` 直接引用位置参数（`968f5b3`）

---

## [2.3.1] - 2026-05-09

### Fixed

- **管道破裂静默退出**：Bash 版 `claude_sse.awk` END 块增加兜底——未收到 `message_stop` 时自动输出 `ERROR + STOP`，防止 `agent_loop_stream` 无错误静默退出（`ecf5d9d`）
- **OSC 终端标题**：Go/Rust 入口显示 OSC 终端标题（`f765480`）
- **replay 后标题被覆盖**：三个版本（bash/Go/Rust）将 OSC 标题设置从 replay 前移到 replay 后，防止历史 Bash 工具输出中的 OSC 序列覆盖正确标题（`0d577a7`）

### Docs

- 新增 `CHANGELOG.md`，覆盖 v0.7.0 → v2.3.0 全部 21 个 tag（`efd65fb`）
- 新增 `docs/ROADMAP.md`，标注适用范围与 bash-only 限制（`cff77b6`）

---

## [2.3.0] - 2026-05-09

### Added

- **SIGINT 中断**：用 `Ctrl+C (SIGINT)` 替代后台子进程 ESC 轮听，实现即时中断（Bash/Go/Rust 三端）（`c86cd36`）
- **100KB 截断**：统一三端工具输出上限为 100KB（`426dc2b`）
- **PlanConfirm 两阶段规划**：规划阶段写入 draft 文件，用户确认后才写入正式 PLAN_FILE，避免缓存失效（`8981d88`）

### Changed

- 优化工具描述与 plan 工作流（`974b6bb`）

### Docs

- 更新 PlanConfirm/PlanClear 两阶段文档（`c01957c`）

---

## [2.2.1] - 2026-05-08

### Changed

- Grep 输出使用 `rg --heading` 匹配终端格式（`cd7ab74`）
- Grep 使用相对路径避免重复长路径（`6fa76a0`）
- 移除多余 pipe，保持 rg 原始输出（`8fcc7f0`）

---

## [2.2.0] - 2026-05-07

### Added

- **PlanClear 工具**：计划完成时一步完成「清除计划 + 压缩上下文」（`49a878d`）
- **PlanClear + force compact 移植到 Go/Rust**（`2e04188`）

### Fixed

- safety valve 必须在 DP 返回值无关时触发（`d2deff8`）
- PlanClear 在 DP 返回 >= total_lines 时的 fallback（`b66cc60`）
- 简化 keep>=total guard，避免重复 turn_keep 调用（`cdf698a`）

### Docs

- current-todo 移除成本分析、output-language 位置修复（`c5430ce`, `e11f928`, `99ebfad`）

---

## [2.1.0] - 2026-05-07

### Changed

- 移除 `todo_update` 事件和 `TODO_FILE` 持久化，tool result 自身足够（`0a8d623`, `89a1a49`）
- 精简 prompt：head-tail 语言锚定，移除中间约束（`0468b87`）
- 内联 tool_todo，gofmt/cargo fmt 清理（`f24a5b3`）

---

## [2.0.2] - 2026-05-06

### Added

- **locale 语言检测**：自动检测用户 locale 并注入 system prompt（`7a599c3`）
- 改进 Read/Edit 工具描述，减少冗余 Read 调用（`142f149`）

### Changed

- 通过 agent-identity 实现中文锚定，移除 rules 中的语言规则（`ea6557b`）
- 多轮迭代优化 locale 规则注入位置和强度（`430365e` → `7d87b83`）

---

## [2.0.1] - 2026-05-02

### Added

- **OSC 终端标题**：显示模型名 + 逗号格式化数字（`4133410`）
- 每次 LLM 请求同步显示 OSC 统计（`a99f327`）

### Docs

- 精简 README 至 ~140 行，详细内容移至 `docs/`（`6b448a8`）
- 标准化缓存对齐成本示例（45K tokens, $0.136 → $0.014）

---

## [2.0.0] - 2026-04-30

### Added

- **DP Compact 缓存感知压缩算法**：基于 4 项经济学公式决策保留行数（`8cc7227`）
- **环境变量覆盖**：`DP_V` / `DP_P_INPUT` / `DP_P_OUT` / `DP_BASELINE_E` / `DP_L` 全部可调（`0f5e202`）
- **DP compact 移植到 Go/Rust**（`1234b19`）
- 缓存复用 compact summary，减少重复写入（`415a284`）

### Changed

- 统一 DP compact 调用约定（`159ba61`）
- E = user input count，移除 llm_turn tracking（`99019d3`）
- 参数校准：`DP_V` 20000→5000，`DP_BASELINE_E` 3→8（`6892ace`, `eab225d`）

### Removed

- 移除 pyagent、PLAN_FILE、CLAUDE.md（`1375223`）

---

## [1.7.0] - 2026-04-28

### Added

- **Session-level stats**：内存缓存 + turn-based compact 触发（`29eb40d`）
- **Transport 层抽象**：Go/Rust 提取 Transport 层统一处理 HTTP 流式传输（`1f12465`）
- **Bash timeout**：tool_bash 使用 tmpfile 保留超时时的部分输出（`807d589`）

### Changed

- 统一 transport pipeline，移除 provider 分支函数（`f7e4e85`）

### Fixed

- 对齐 Go/Rust 流式超时行为（`74687dd`）
- 对齐 Rust `RE_BLOCK_DEVICE_WRITE` 正则（`32626d0`）

---

## [1.6.0] - 2026-04-24

### Added

- **Read offset/limit**：支持按行范围读取文件（`f2dc434`）
- **Grep 4 参数**：`pattern` / `path` / `glob` / `context`（`ea9482a`）
- **Bash timeout**：命令执行超时自动终止（`0c3ad2e`）
- **--max-tokens k/m/g 后缀**（`9caf1b8`）

### Changed

- 移除 Go/Rust Read 输出行号，与 bash 对齐（`11f7c38`）

---

## [1.5.1] - 2026-04-24

### Changed

- **Session 存储迁移到目录布局**：每次会话独立目录（`eb83c2d`）
- 转发 thinking blocks 为 `reasoning_content`（`bf5c34e`）

---

## [1.5.0] - 2026-04-23

### Added

- **Turn-aware session replay**：断线恢复（`a42bfcf`）
- Go/Rust 记录 pre-stream HTTP 错误到 `events.jsonl`（`c55ac18`）
- `BASH_AGENT_HOME` 环境变量支持（`b46d928`）

### Changed

- 分离事件记录与显示逻辑（`a42bfcf`）

---

## [1.4.0] - 2026-04-22

### Changed

- 提取 `new_session_id()` 带 random suffix（`77644fa`）
- 移除 tmpdir，统一使用 sessions 目录（`2155236`）

---

## [1.3.0] - 2026-04-21

### Changed

- **Wire Protocol 升级为 RESP 格式**（`e45893f` → `179e4d5`）
- PLAN_FILE 支持和 plan 生命周期引导（`c0b61d5`）

### Fixed

- 二进制安全协议处理 unicode（`4c37c62`）
- Go/Rust `format_tool_result` 与 bash 对齐（`1bf7856`）

---

## [1.2.3] - 2026-04-19

### Fixed

- CI: download dependencies before patching go-prompt（`f70b1f5`）
- Bash: ANSI codes 用 readline ignore markers 包裹（`c79cfb9`）

---

## [1.2.2] - 2026-04-18

### Added

- Go: 替换 readline 为 `joeycumines/go-prompt`（`bb2994d`）
- Go/Rust: curl 级别重试支持（`c0386eb`, `f2d6ff8`）
- Bash: curl `--retry` 跨 awk pipeline（`dd96794`）

### Changed

- 移除 `plain_diff`，内联 awk 调用（`41131c0`）

---

## [1.2.1] - 2026-04-17

### Added

- **WebSearch / WebFetch 工具**：基于 Jina AI API（`f3405a2`）

---

## [1.2.0] - 2026-04-16

### Changed

- 统一流式超时处理和 staged chain（`d8b398e`）

---

## [1.1.1] - 2026-04-16

### Added

- **THINKING/reasoning 支持**：Bash/Go/Rust SSE 解析器（`edd48e1`）

### Fixed

- 错误传播和 curl 流式默认值（`0e11769`）

---

## [1.1.0] - 2026-04-16

### Changed

- 统一三端错误格式 `ERROR:{code}\tHTTP {code}: {body}`（`5bd7223`）
- 内联 tool dispatch，移除 `execute_tool_calls_stream`（`d91e634`）

---

## [1.0.1] - 2026-04-15

### Added

- **Skill 工具**：从 `~/.claude/skills` 加载技能文件（`a78287d`）
- 支持 repo-local skills 目录（`877cf80`）

### Changed

- 统一工具输出：Write 摘要、Edit diff、Read 摘要（`d31b68c`）
- Go/Rust 47/47 测试全部通过（`283d00a`）
- 默认 max turns 提升到 40（`fde708b`）

---

## [1.0.0] - 2026-04-15

### Added

- **Go 完整移植**：`go/` 目录（`dbaa84f`）
- **Rust 完整移植**：`rust/`，rustyline 交互模式（`ff8919d`）
- **CI/CD 多平台 artifact**：Linux/macOS/Windows（`158aadb`）
- `~/.claude/skills` fallback（`1439813`）

### Changed

- 默认交互模式（`c5ab6a8`）
- 默认 claude provider（`2a0381b`）

---

<!-- v1.0.0 之前的初始开发阶段，未打 tag -->

## [0.x] - 2026-04-07 ~ 2026-04-14

纯 bash/awk 实现的 AI Agent 生态初始开发阶段。

### Added

- 核心功能：工具调用、流式输出、上下文压缩
- 工具集：Read / Write / Edit / Bash / Grep / Glob
- Tab-delimited 线协议（后续升级为 RESP）
- 双语文档：README.md（中文）和 README.en.md（英文）
- Skills 机制和 Instruction file 加载
- awk 解析器分层，JSON 提取和 unicode 解码

---

[Unreleased]: https://github.com/lloydzhou/bash-agent/compare/v2.3.0...HEAD
[2.3.0]: https://github.com/lloydzhou/bash-agent/compare/v2.2.1...v2.3.0
[2.2.1]: https://github.com/lloydzhou/bash-agent/compare/v2.2.0...v2.2.1
[2.2.0]: https://github.com/lloydzhou/bash-agent/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/lloydzhou/bash-agent/compare/v2.0.2...v2.1.0
[2.0.2]: https://github.com/lloydzhou/bash-agent/compare/v2.0.1...v2.0.2
[2.0.1]: https://github.com/lloydzhou/bash-agent/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/lloydzhou/bash-agent/compare/v1.7.0...v2.0.0
[1.7.0]: https://github.com/lloydzhou/bash-agent/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/lloydzhou/bash-agent/compare/v1.5.1...v1.6.0
[1.5.1]: https://github.com/lloydzhou/bash-agent/compare/v1.5.0...v1.5.1
[1.5.0]: https://github.com/lloydzhou/bash-agent/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/lloydzhou/bash-agent/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/lloydzhou/bash-agent/compare/v1.2.3...v1.3.0
[1.2.3]: https://github.com/lloydzhou/bash-agent/compare/v1.2.2...v1.2.3
[1.2.2]: https://github.com/lloydzhou/bash-agent/compare/v1.2.1...v1.2.2
[1.2.1]: https://github.com/lloydzhou/bash-agent/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/lloydzhou/bash-agent/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/lloydzhou/bash-agent/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/lloydzhou/bash-agent/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/lloydzhou/bash-agent/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/lloydzhou/bash-agent/releases/tag/v1.0.0
