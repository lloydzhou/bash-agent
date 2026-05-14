# Changelog

所有重要变更均记录在此文件中。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [2.5.2] - 2026-05-13

### Changed

- **SubAgent 结果显示重构**：用 `send_sub_result.awk` 替代 `extract_sub_result.awk`，子 agent 完成后在后台直接通过 AWK 提取 thinking/text 并格式化为消息发回 FIFO，简化 bash 端 `handle_sub_agent_result` 逻辑（`364787c`, `0838da7`）
- **SubAgent 恢复使用 `agent_loop`**：回退为 agent_loop 驱动子 agent，不支持嵌套 SubAgent，简化执行路径（`8f7107b`）
- **Rust SubAgent 输出隔离**：子 agent 后台线程 stdout/stderr 重定向，避免与主 agent 输出混淆（`814b2fe`）
- **Go SubAgent goroutine 错误泄漏**：后台 goroutine 内 `rt.error()` 输出不再泄漏到前端（`e5f14fd`）
- **SubAgent thinking/text 分离**：Go/Rust 端同步 bash 端的子 agent 结果 thinking/text 拆分逻辑（`cb7d8b5`, `2ba52c4`）
- **SubAgent 空文本块过滤**：提取子 agent 结果时过滤空 text block（`a58ea7a`）
- **SubAgent 结果预览行去掉多余前导空格**：thinking/text 预览行 `printf` 格式统一，三端(bash/Go/Rust)对齐（`e1045b7`）
- **SubAgent completed/failed 行恢复 ANSI 颜色**：completed 行紫色(`\033[35m`)，failed 行红色(`\033[31m`)，三端(bash/Go/Rust)统一（`fef9747` 移除后由 `8e65e57` 恢复）
- **SubAgent 并行 guidance 增强**：sub-agent-guidance 中 Parallelism 条目新增强调——结果异步逐个返回不会同时完成，收到部分结果时不要重复启动，按 session_id 配对等待（`4583236`）

### Fixed

- **构建脚本 `send_sub_result.awk` 内联替换失败**：`build.sh` 替换模式要求 `awk_run -f` 紧邻，但源码中 `-v` 参数将它们隔开，导致 `dist/agent.sh` 中仍使用 `-f "$AWK_DIR/..."` 而 `AWK_DIR` 已被清空，awk 无法读取文件静默失败；修复为只替换 `-f` 参数部分（`60ea8dd`）
- **统一 SubAgent 结果注入首行格式**：注入 agent_loop 的 content 首行统一为 `[sub-agent <id>] <status> (in=<n>, out=<n>)`，三端(bash/Go/Rust)同步，包括 prompt 中 sub-agent-guidance 的 Result handling 描述（`8794896`）
- **SubAgent-fork 测试 Stage 3/4 匹配条件**：适配新的 AGENT_RESULT content 格式，Stage 3 排除条件改用 `[sub-agent sub_` 前缀，Stage 4 匹配条件同步更新（`1cdf9f6`, `56487db`）

---

## [2.5.1] - 2026-05-12

### Added

- **SubAgent fork 模式**：子 agent 启动时 fork 当前会话的完整会话历史，使子 agent 继承上下文；统一 bash/Go/Rust 三端的 SubAgent schema（`description` 字段改为必填）和系统提示词中的 sub-agent-guidance section（`a883af4`）
- **SubAgent Go 测试**：`app_test.go` 新增 `TestRunSubAgentFork` 等测试用例，覆盖 fork 会话复制、异步执行、结果回传全流程（`a883af4`）
- **SubAgent bash e2e 测试**：`tests/test.sh` 新增 `test_sub_agent_fork` 测试函数（`a883af4`）

### Changed

- **移除 todo.md 持久化**：Go/Rust 端不再在 session 目录创建 `todo.md` 文件，`Paths` 结构体移除 `TodoFile` 字段；bash 端移除 fork 时的 todo 文件复制和 touch 列表逻辑（`5417d13`）
- **SubAgent fork 不再复制 plan.draft**：三端统一，fork 时仅复制 `conversation.jsonl`、`summary.txt`、`plan.md`，不再复制 `plan.draft`（`8f71f81`）

### Added

- **AGENTS.md**：新增项目构建与测试指南文档（`8f71f81`）
- **`make test` / `make test-bash`**：Makefile 新增统一测试目标和 bash 测试目标（`8f71f81`）

---

## [2.5.0] - 2026-05-12

### Added

- **SubAgent 异步子 agent 工具**：新增 `SubAgent` 工具，支持将子任务委托给独立的后台 agent 会话并行执行，完成后通过消息队列将结果注入主 agent 对话。bash/Go/Rust 三端同步实现（`4347a93`, `ce66b4d`）
- **统一 FIFO + 消息队列架构**：interactive 模式引入滚动区域方案，所有输入输出通过 FIFO 和结构化消息（`USER_INPUT` / `AGENT_RESULT`）传递，替代原有的 read/prompt 交互循环。`main_loop` 统一处理用户输入和子 agent 结果（`ce66b4d`, `bc78082`）
- **Go/Rust 子 agent 完整实现**：包括 goroutine 异步执行、消息通道通信、结果统计累加、交互式提示符恢复等（`4347a93`）
- **SubAgent 工具定义**：`src/tools.json`、`go/internal/assets/tools.json`、`rust/src/assets/tools.json` 新增 SubAgent 工具 schema（`48305d0`）
- **`extract_sub_result.awk`**：新增 AWK 脚本用于从子 agent 会话中提取最终文本结果（`4347a93`）
- **SubAgent e2e 测试**：`tests/test.sh` 新增 4 阶段 mock server 测试，覆盖 SubAgent 调用→子 agent 执行→结果回传→主 agent 继续对话全流程（`000d11e`）
- **ARCHITECTURE.md SubAgent 章节**：补充子 agent 架构说明、FIFO 通信机制、session 目录结构等（`c3512fd`, `b4b5ccf`）
- **ROADMAP.md**：新增路线图文档（`b4b5ccf`）

### Changed

- **`_run_agent_loop` 辅助函数**：提取 agent_loop 调用 + 交互式提示符管理为公共函数，消除 `main_loop` 和 `handle_sub_agent_result` 中的重复代码（`000d11e`）
- **中断处理优化**：收紧 SIGINT trap 逻辑，避免中断信号干扰子 agent 执行（`9832a6b`）
- **系统提示词 SubAgent 指导**：`tool_guidance` 中增加 SubAgent 使用建议（`000d11e`）
- **FIFO 写端保持打开**：`main_loop` 中 `exec 4> "$INPUT_FIFO"` 防止所有读取者退出时 FIFO 过早关闭（`bc78082`）

### Fixed

- **agentLoop 错误丢失**：Go 端非交互模式 `Run` 函数未接收 `agentLoop` 返回的错误，导致 API 错误（如 rate limit SSE 事件）被静默吞掉（`d9adfa4`）
- **history file 写入**：修复历史记录文件写入路径和时序问题（`000d11e`）
- **`sub_agent_request_count` 统计**：修复子 agent 请求计数字段未写入 `stats.json` 的问题（`48305d0`）
- **中断 trap 条件**：`_done` 变量判断从直接布尔求值改为 `[[ "$_done" == true ]]` 比较式，避免 `set -u` 下的未绑定变量错误（`000d11e`）

---

## [2.4.1] - 2026-05-11

### Added

- **Summary Reflections 字段**：compact summary 字段列表末尾增加 `Reflections:`，让压缩时显式保留失败教训和策略调整等隐性知识（bash/Go/Rust 三端同步）（`ea793ee`）

### Changed

- **context-summary → context-snapshot**：bash 端 section name 统一为 `context-snapshot`，与 Go/Rust 端一致（`ea793ee`）
- **plan-lifecycle-guidance 精简**：将 8 步线性列表 + 4 条分离规则重写为状态机三分类（REVISE/CONFIRM/CANCEL），渲染后从 ~1650 字节精简至 ~1140 字节；变量引用从行尾移至 Files 行中间，避免字符串闭合错觉（`ea793ee`）

---

## [2.4.0] - 2026-05-10

### Added

- **OSC 标题栏缓存命中率**：终端标题 `I` 后显示缓存命中率百分比，格式 `I:12,345(72%)`，bash/Go/Rust 三端同步（`fc4164a`）

### Changed

- **compact 触发时机**：`compact_context_window` 从循环外移到 `agent_loop_stream` 的每次 LLM 调用前，确保每轮都能基于最新的 `current_context_tokens` 做决策（`a5692d7`）
- **usage → ctx_tokens 数据流**：`record_usage` 返回 `ctx_tokens` 但不再直接写入 `current_context_tokens`；改由主循环在流结束后显式写入，compact 始终使用上一轮的完整上下文大小（`a5692d7`）
- **OSC 标题 I 展示总输入量**：`I` 改为展示 `input + cache_read` 总输入 token 数，而非仅未命中部分（`75751b0`）

### Fixed

- **Edit 工具 `unbound variable`**：`tool_edit` 合并 local 声明时 `label="${path#/}"` 引用了同语句中尚未赋值的 `path`，在 `set -u` 模式下报错；改用 `${1#/}` 直接引用位置参数（`968f5b3`）
- **缓存命中率计算**：修正公式为 `cache_read / (input + cache_read)`，之前误用 `cache_read / input` 导致超过 100%（`8e188f5`）
- **Plan draft 修订循环**：将第3步从被动的 "If user requests changes" 改为主动的 "draft 非空时，任何非确认回复都必须更新 draft"，防止 AI 只回答而不更新计划（`aa9074f`）

---

## [2.3.2] - 2026-05-10

### Fixed

- **summary 空文本响应**：`run_summary_call` 在 bash/Go/Rust 三端缺少必要参数，导致 summary 返回空文本（`2fc6813`, `11a2513`）
- **SUMMARY_MAX_TOKENS 冗余**：移除独立常量，复用全局 `MAX_TOKENS`（`852b4cf`）
- **summary `record_usage` 参数丢失**：`run_summary_call` 中 `record_usage "compact" 2>/dev/null` 缺少空格，`2>/dev/null` 被解析为 stderr 重定向而非传参 `2`（counter_idx），导致 stats 文件损坏（`d281c54`）

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

[Unreleased]: https://github.com/lloydzhou/bash-agent/compare/v2.5.2...HEAD
[2.5.2]: https://github.com/lloydzhou/bash-agent/compare/v2.5.1...v2.5.2
[2.5.1]: https://github.com/lloydzhou/bash-agent/compare/v2.5.0...v2.5.1
[2.4.0]: https://github.com/lloydzhou/bash-agent/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/lloydzhou/bash-agent/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/lloydzhou/bash-agent/compare/v2.3.0...v2.3.1
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
