# Changelog

所有重要变更均记录在此文件中。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [Unreleased]

---

## [4.0.2] - 2026-05-27

> **Bugfix 版本**：降低长 session replay 内存占用，补齐 system prompt 字节级一致性测试，并修复 Go 版 Ctrl+C 中断时的 channel panic。

### Fixed

- C/Go/Rust replay 改为从最近事件 offset 按行流式读取，避免进入长 session 时把完整 `events.jsonl` 加载到内存
- Go SSE stream 中断兜底事件发送顺序修复，避免 Ctrl+C 或连接提前结束时出现 `panic: send on closed channel`
- Go SIGINT 处理改为 `atomic.Bool` + 退出信号，避免交互多轮后遗留信号 goroutine 和数据竞争
- C/Go/Rust section append/wrap 统一裁剪尾部 CR/LF，避免 instruction file / selected skill 末尾多余空行导致 system prompt 漂移
- Rust `plan-lifecycle-guidance` 缩进修复，与 Bash/C/Go 逐字一致
- Go instruction file section 构造改为复用 `UtilAppendSection`，与其它 prompt section 使用同一格式化路径

### Tests

- 新增 system prompt byte-exact golden 测试，直接比较请求体 top-level `system`
- 覆盖 `en_US` 和 `zh_CN` 两种 locale，验证多语言 system prompt 构造一致性
- golden 中的 home、project path、project key、platform、shell 均参数化，避免机器相关路径导致误报
- 新增 Go SSE 中断流回归测试，覆盖无 `message_stop` 的提前结束路径

---

## [4.0.1] - 2026-05-27

> **Bugfix 版本**：修复 cagent 统计/缓存/显示相关问题，并统一 C/Go/Rust display queue 层级。

### Fixed

- 修复 cagent stats 缓存统计计算错误
- 对齐 linenoise 和 stats 行为
- 对齐 cagent replay 工具显示
- 对齐 cagent 流式事件输出
- 统一 C/Go/Rust 为长期 display queue + flush barrier，避免 linenoise 提示符在异步 display 输出前重绘导致错位
- Rust 执行和 replay 统一映射为 `DisplayEvent`，复用同一 display renderer；`events.jsonl` / `stream-json` 仍在 event append 层同步处理，display queue 只负责人类可读输出

---

## [4.0.0] - 2026-05-26

> **重大版本升级**：新增 C 语言运行时，项目从三语言（Bash/Go/Rust）扩展为四语言。
> system prompt 升级为 P0 协议面，四版本逐字一致性保证跨版本 KV cache 复用。

### Added

- **C 语言运行时（cagent）**：完整的第四个运行时实现，~6,000 行纯 C 代码
  - `c/agent.c` — 主循环、工具分发、compact、sub-agent、prompt builder（2,337 行）
  - `c/transport.c` — libcurl 流式 SSE、重试、Ctrl+C 中断（624 行）
  - `c/store.c` — JSONL conversation、stats.json、session 管理（613 行）
  - `c/tools.c` — Read/Write/Edit/Bash/Glob/Grep/SubAgent/TodoWrite/Plan（877 行）
  - `c/protocol.c` — LLM 响应解析、tool_use 提取、stream event（137 行）
  - `c/display.c` — 终端输出、千位分隔、流式 text/thinking（270 行）
  - `c/json.c` — 零依赖 JSON 解析器、surrogate pair 修复（455 行）
  - `c/msgqueue.c` — sub-agent 异步结果传递（90 行）
  - `c/util.c` — 字符串、文件、JSON escape 等辅助函数（259 行）
  - `c/cagent.c` — 入口、命令行解析、REPL、信号处理（394 行）
  - 二进制 ~176KB（动态链接 libcurl），依赖极小
- **linenoise 统一 readline 方案**：Go/Rust/C 三端统一使用 `vendor/linenoise/`
  - Go：从 go-prompt 迁移到 linenoise CGo 嵌入（`go/linenoise/`）
  - Rust：从 rustyline 迁移到 linenoise FFI（`rust/src/ffi/`）
  - C：内建 linenoise，UTF-8 安全截断、Ctrl+C/D 支持
  - 消除三个不同的 readline 依赖，共享同一份源码
- **cagent 多平台 CI 构建**：GitHub Actions 支持 linux amd64/arm64 + darwin arm64/amd64
- **tools.json 单一来源**：统一 `src/tools.json`，Go/Rust/C 通过 symlink 或 embed 引用，消除 drift
- **DP compact 决策（C 版）**：5 项 DP 公式完整实现，与 Bash/Go/Rust 一致

### Changed

- **system prompt 升级为 P0 协议面**：system prompt 是 KV cache 的前缀协议面，
  任何 section 顺序、标签包装、空行、尾部换行、`name` 属性转义或静态文案漂移都会导致
  跨版本切换 cache miss。以下差异已全部修复，四版本现在逐字一致：
  - name 属性转义统一为 JSON-style（`\"` `\\` `\n` 等），之前 Rust 用 XML-escape，C 不转义
  - Go `selected-skills` 恢复外层 `<selected-skills>` 包装
  - Rust `sub-agent-guidance` 中 Fork mode 从末尾移至第 3 条
  - Rust skill 前缀 `Base directory for this skill:` → `Base directory:`
  - Rust 空白过滤 `trim().is_empty()` → `is_empty()`
- **`pathToProjectKey` 完整规范化**：Go/C 重写为 Bash 版完整规则（去非字母数字、压缩连续 `-`、
  去首尾 `-`），修复同一路径不同 key 导致 session 无法跨版本复用
- **Go tool_result 写入时序对齐**：从循环内逐条写入改为循环外批量写入，与 Bash/Rust/C 一致
- **Go Read/Write conversation 内容对齐**：display/event 保留 file summary 前缀，
  conversation 保存原始工具结果；Edit 工具 conversation 只保存首行
- **Go compact token 统计对齐**：`SummaryCall` 返回 usage，compact 后累加到 stats 并追加
  compact usage event
- **AGENT.md 更新**：四版本一致性检查清单，system prompt 列为最高优先级

### Fixed

- **C 版 28 项行为差异修复**：session key 计算、SSE 解析、stats 记录、plan trigger 名称、
  plan_clear/plan_confirm 守卫绕过、UTF-8 安全截断等
- **C 版 sub_agent_result 重复展示 + thinking/text/token 缺失**
- **C 版 json.c surrogate pair + iter key 泄漏、store.c 双换行**
- **Rust `current_context_tokens` 仅在 > 0 时写入**，与 bash/c/go 对齐
- **Go stats.json 缺失字段**：`sub_agent_request_count` 等初始值补齐

### Tests

- `tests/test.sh` 扩展至 526 行，覆盖工具函数、SubAgent、JSON 解析、compact 决策、stats.awk
- Go 新增 `TestPathToProjectKeyMatchesBash`、`TestFileStoreToolResultConvOutput`、
  `TestFileStoreCompactStats`
- Go e2e 10 项跨版本一致性测试
- 四版本 e2e 测试全部通过（118 pass / 0 fail）

### Removed

- `scripts/patch-go-prompt.sh` — Go linenoise 迁移后不再需要
- `go/go.mod` / `go/go.sum` 中 rustyline / go-prompt 相关依赖

---

## [3.0.7] - 2026-05-24

### Fixed

- **compact_dp ⑤ 符号修正**：第五项从减项（quality_cost 绝对衰减）改为加项（quality_savings 增量收益）
  - 旧：`① - ② - ③ - ④ - ⑤`，⑤ = QP×P_input×(V+K)²/(M×1e6)
  - 新：`① - ② - ③ - ④ + ⑤`，⑤ = QP×P_input×[(V+T)²-(V+K)²]/(M×1e6)
  - 修正物理语义：压缩缩短上下文→改善质量→应为正收益
  - QP 越大越促进压缩（旧逻辑方向相反）
  - Bash/Go/Rust 三端同步 + 测试断言翻转 + 文档/README/README.en 更新

---

## [3.0.6] - 2026-05-23

### Added

- **DP 第 5 项质量衰减惩罚**：当上下文过长时模型回答质量下降，新增惩罚项
  `Q × p_input × M/1e6 × ((V+K)/M)²`，与现有 4 项 DP 公式统一。
  - Bash/Go/Rust 三端实现，公式一致
  - 系数 `DP_QUALITY_PENALTY` 默认 0.2，基于 "Lost in the Middle" 论文数据
  - 配置参数：`DP_QUALITY_PENALTY`（默认 0.2）
  - 文档同步更新 README / compact-analysis.md

### Fixed

- **Go SubAgent fork 竞态条件**：Fork 从 goroutine 移至 LaunchSubAgent
  同步执行，避免因复制含 tool_result 的对话导致子 agent 误走正常流程
- **Go SubAgent fork 目录路径**：Fork 从项目目录改为 session 子目录
- **Rust list_sessions preview 截断**：`.len()` → `.chars().count()`，
  修复中文等多字节字符被截断问题

### Tests

- **Bash** tests/test.sh: 新增 37h quality_penalty 测试
- **Go** agent_test.go: 5 个 CompactDPDecision 单元测试
- **Rust** lib.rs: compact_dp::tests 5 个单元测试

## [3.0.5] - 2026-05-22

### Added

- **tcode — tmux Chat UI 包装器**：三栏 TMUX 界面（watch sidebar + agent + 输入框），支持
  bash-agent/goagent/rustagent。第一个参数可选（默认 rustagent），支持透传参数。创建 session
  时同步终端尺寸并使用百分比分割消除闪烁。退出打印 resume 信息，支持 Ctrl+C 中断/Ctrl+D 干净
  退出。CI 发布时自动包含 `dist/tcode`。Makefile 新增 `build-tcode` target（`feat/tmux-chat-ui`）

---

## [3.0.4] - 2026-05-21

### Added

- **DEEPSEEK_API_KEY 自动检测（Bash/Go/Rust）**：当 `ANTHROPIC_API_KEY` 未设置时，自动检测
  `DEEPSEEK_API_KEY` 并配置 DeepSeek Anthropic 兼容端点（`https://api.deepseek.com/anthropic`）
  和 `deepseek-v4-flash` 模型。三端同步实现：`src/agent.sh`、`go/cmd/goagent/main.go`、
  `rust/src/lib.rs`（`3aa1f39`）
- **MODEL 环境变量**：三个版本均支持通过 `MODEL` 环境变量覆盖模型名称，优先级高于内置默认值
  （`3aa1f39`）
- **install.sh 安装脚本**：一键安装脚本，支持 macOS（Homebrew）和 Linux（自动检测包管理器）
  （`73e1194`）
- **Homebrew / AUR 安装支持**：添加 Homebrew Formula 和 Arch Linux AUR 安装文档（`73e1194`, `1d8ba15`）

### Changed

- **README 文档更新**：新增 DeepSeek 兼容小节、官网链接、AUR/Homebrew 安装说明；重构 LaTeX 公式
  格式（`db8aad8`, `48381be`, `253e02a`）
- **docs/ARCHITECTURE.md → docs/architecture.md**：文件名小写化（`0191e14`）

---

## [3.0.3] - 2026-05-19

### Fixed

- **WebFetch 调用方式修正（Bash/Go/Rust）**：Jina Reader API (`r.jina.ai`) 不再支持 `?url=` 查询参数（返回 400），改为路径拼接 `r.jina.ai/<url>`（返回 200）。三端同步修改：`src/agent.sh`、`go/tools.go`、`rust/src/tools.rs`（`7c3f919`）
- **Go stream-json 输出污染**：`--output-format stream-json` / `--print` 模式下 `TermDisplay.ShowEvent()` 无条件输出 ANSI 颜色码和人类可读文本，与 JSON 行混在一起。`TermDisplay` 新增 `silent` 标志，stream-json 模式下抑制人类可读输出，仅输出纯 JSON 行（`13a5425`）

---

## [3.0.2] - 2026-05-17

### Fixed

- **Rust Ctrl+C CPU 飙升且无法恢复**：重构 Rust HTTP 架构，`reqwest::blocking` + 独立
  `spawn_reader` 线程 → `reqwest` async + `bytes_stream()`。旧架构下 Ctrl+C 后 spawn_reader
  线程仍在全速读取 HTTP 响应写入无界 channel，CPU 100%。新架构使用 `tokio::select!` 协作式
  中断，async 任务内同时检查 `cancel` / `interrupted` / `CTRLC_FLAG` 三个 AtomicBool 标志，
  LlmStream drop 时取消当前流。`CancellationToken` 被移除（单次信号不可重置，导致后续所有
  HTTP 请求立即中断）（`74728d5`）

### Changed

- **system prompt 三端统一**：以 bash `agent_build_prompt` 为基准，对齐 Go `BuildPrompt` 和
  Rust `build_system_prompt`。Go 多个 section 补全（sub-agent/todo/plan 从截断版恢复完整内容）、
  section 顺序改为 output-language 最后、节间分隔符 `\n\n`→`\n`、current-plan 加 name 属性。
  Rust 补齐 using-your-tools 中的 SubAgent 段落、plan-lifecycle-guidance 对齐 Drafting phase
  格式。platform 字符串三端统一为 `uname -s` 格式（Darwin/Linux）（`7ab6153`）
- **tools.json 三端同步**：`rust/src/tools.json` 覆盖为 `src/tools.json` 副本，`go/tools.json`
  新增副本，SHA256 完全一致（`04cb174`）
- **Go tools.json 编译时嵌入**：使用 `//go:embed` 内置到二进制，运行时不再依赖外部文件；
  `UtilLoadToolDefs` 简化去 error 返回（`53bcb0d`, `a3447fe`, `1cae904`）
- **Go SessionStore**：新增 `PlanPath()` / `PlanDraftPath()` 方法暴露文件路径（`7ab6153`）

### Docs

- AGENT.md 新增「版本一致性要求」章节，包含检查清单（`98fcdf3`）

---

## [3.0.1] - 2026-07-15

> **注意**: v3.0.x 与 v2.5.x 为并行维护线。v3.0.0 基于 v2.5.2 做了大规模 Pipeline 架构重写和代码重组，
> v2.5.3 则在 v2.5.2 的原有架构上做增量修复和特性增强。两条线在可预见的未来将同时存在。

### Fixed

- **display_stream 子进程渲染管道 (bash)**: RESP 消息通过 FD 7 管道发往独立子进程渲染，消除父子进程竞争终端 stdout 导致的文字交叠错位。子 Agent 关闭继承的 FD 7/8/9，防止意外写入父进程 display pipe（`5a90910`, `8827cc1`, `f52b58e`）
- **Ctrl+C 中断机制 (bash/Go/Rust)**: 
  - bash: `trap` 信号处理器中确保 `kill "$(cat /tmp/agent_curl_pid.$$)"` 生效（`bb15d6f`）
  - Go: `RunLoop` 中用 `context.WithCancel` 包装 ctx，Ctrl+C 立即取消 HTTP 请求（`b4a4d3e`）
  - Rust: `static CTRLC_FLAG` 全局标志 + handler 设在 `agent_run` 一次初始化，防止各 agent 相互覆盖 handler；`is_interrupted()` 同时检查 per-agent flag + 全局 flag；HTTP Client `.timeout(300s)` 防止 `spawn_reader` 线程无限阻塞（`448bec1`）
- **SSE 解析兜底 (Go/Rust)**: 流异常中断（无 `message_stop`）时发射 `ERROR` + `STOP` 事件，对标 awk `END` 块。Go `parseSSEStream` 新增 `stopEmitted` 标志 + `defer` 兜底；Rust `claude::parse` / `openai::parse` 读流结束后 `pending_stop` 为空时发射 `ErrorEvent` + `StopEvent{reason:"error"}`（`ddce0c8`）
- **usage `input_tokens` 被 `message_delta` 错误覆盖 (bash/Go/Rust)**: `message_start.usage.input_tokens` 为总 prompt token 数，但 `message_delta.usage.input_tokens` 为结算后计费值（远小于总数）。SSE 解析器中 `message_delta` 覆盖了 `message_start` 的值，导致 usage 事件记录的 `input_tokens` 异常偏小且波动（23~4204）。修复后 `input_tokens` 以 `message_start` 优先，`message_delta` 仅在未设置时补充（兼容 OpenAI 路径）（`ff72d76`）
- **summary 调用 Ctrl+C 无保护 (Rust)**: `run_summary_call` 的 HTTP 响应包装 `CancelReader`，对标 bash trap 保护所有 LLM 调用（`448bec1`）
- **构建脚本 FD 搜索模式未同步 (bash)**: `build.sh` 中 `http_stream.awk` 搜索模式写死 `<&6`，源码已改为 `<&9` 导致 `AWK_DIR` 未被替换为内联变量，`dist/agent.sh` 出现 `AWK_DIR: unbound variable` 错误（`193e0e3`）
- **交互模式双提示符**: display_stream 子进程统一提示符控制，消除子 Agent 和主进程同时输出的重复提示符（`8827cc1`）
- **stdout 输出竞态**: `agent_handle_sub_result` 直写 stdout 改为经 fd 7 通过 display_stream 渲染（`67c9768`）
- **终端清行冲突**: 移除和 display_stream 子进程争终端的 `\r\033[K`（`098a698`）
- **子 Agent FD 隔离**: `cleanup_all_pipes` 和子 Agent 中移除无效的 FD 关闭（`fb915ed`）

### Changed

- **全局 FD 规约**: 父进程使用 FD 3/4/5/6，子进程使用 FD 7/8/9，明确每层职责（`1f127ae`）
- **util_read_msg 性能优化**: `dd` → `read -d "" -n N`，消除两次 fork（`cbe3d3c`, `3337944`）
- **store_ 系列函数一行化**: 精简代码行数（`652be78`）
- **display_stream 子进程渲染重构**: display_stream/display_term_title 一行 + replay 复用 display_stream + store_conv_add_user 一行（`4a12cc6`）
- **subshell >&7 替代 pipe + cat**: 减少一次 fork（`2ecdd3d`）

### Removed

- **废弃 display.rs (Rust)**: 清理已废弃的 `Display` trait 实现（`448bec1`）

### Docs

- ARCHITECTURE.md: display_stream 子进程管道模型、FD 分配规约更新（`15a20ee`）
- refactor-7class.md: 设计文档更新
- sessions.md: 移除过时内容

---

## [3.0.0] - 2026-05-15

### Added

- **Pipeline 架构重写 (bash)**：`agent_loop_stream` 统一 RESP 协议管道，解耦 LLM 调用、工具执行、事件记录和显示渲染；`display_message` 单消息渲染代替跨进程管道，消除 bash stdio 全缓冲导致的多轮 LLM 输出丢失（`5202d12`）
- **display_stream 子进程管道 (bash)**：RESP 消息通过 fd 7 管道从父进程发往子进程 `display_stream` 渲染，消除父子进程竞争终端 stdout 导致的文字交叠错位。子 Agent 关闭继承的 FD 3-9，防止意外写入父进程 display pipe（`f52b58e`）
- **Go 扁平包结构**：删除 `go/internal/` 下 15 个散包子包，合并为 8 个顶层文件 `agent.go` / `store.go` / `tools.go` / `transport.go` / `types.go` / `util.go` / `display.go` / `agent_test.go`（`252150c`）
- **Rust 替换为 rust2**：用 flatter 架构替换旧多文件拆分，`agent.rs` 作为主模块，新增 `display.rs` / `sse.rs` / `store.rs` / `util.rs`（`5dce3e8`）
- **`--thinking` / `--effort` 自适应思考模式**：替代 `THINKING_BUDGET`，支持 low/medium/high/xhigh/max 五级 effort（`f04e2bc`）
- **终端标题实时更新**：`term_title.awk` 在每次 LLM 调用后同步显示模型名、请求数和 token 统计（`b3064f4`）
- **对话压缩策略 (`compact_turn_keep.awk`)**：基于 turn 比例的行保留策略，配合 DP 算法做二次压缩（`1365b80`）
- **交互模式事件回放**：`event_replay.awk` 支持重入会话的历史对话回显（`a6d9cd0`）
- **SubAgent fork 会话隔离**：`store_session_fork()` 提取为独立函数，fork 时只复制 conversation/summary/plan（`a032bda`）
- **`cleanup_all_pipes` 统一清理**：按 FD 级联顺序关闭 curl/llm/agent_loop/INPUT_FIFO 管道（`5202d12`）
- **`llm_stream_curl` FD 6 管道替代 pipefail**：避免 `set -o pipefail` + SIGPIPE 导致脚本退出（`5202d12`）
- **测试扩展到 91+ 用例**：新增 SubAgent 故障传播 / fork / 隔离等测试（`tests/test.sh`）
- **`store_conv_get_messages` 空文件安全**：增加 `[[ -f "$CONV_FILE" ]]` 检查，避免 awk 报错（`778afdb`）

### Changed

- **`display_event` → `display_message` + `display_stream`**：拆分流式渲染和单消息渲染，`display_stream` 最终内联到 `agent_main_loop`（`5202d12`, `14c9e45`）
- **`agent_event` 内联到 `agent_loop`**：消除 `> >(display_event)` 跨进程管道及其 stdio 缓冲问题，`ACTIVE_SUB_COUNT` 改为 `agent_main_loop` 的 `local active_sub_count`，通过 bash 动态作用域在 `agent_loop` 中自增（`5202d12`）
- **compact 层合并到 agent 层**：7 层架构简化为 6 层（`1365b80`）
- **session 存储隔离**：7 类前缀重命名 + `TOOL_CALL` 分支重构（`4e11143`）
- **build.sh AWK_DIR 替换规则更新**：适配 `llm_stream_curl` FD 6 模式，修复 `dist/agent.sh` 中 `AWK_DIR: unbound variable` 错误（`14c9e45`）
- **文档同步**：`README.md` 移除已废弃的 `THINKING_BUDGET` 环境变量；`docs/ARCHITECTURE.md` 更新函数名和代码路径；`docs/sessions.md` 更新 replay 描述（`7354543`）

### Removed

- 旧 `rust/src/` 多文件包结构（config.rs/conversation.rs/httpclient.rs/...）
- 旧 `go/internal/` 多包结构（app/config/httpclient/sse/transport/tools/...）
- `rust2_backup/` 目录
- 全局 `ACTIVE_SUB_COUNT` 变量

### Security

- `scripts/build.sh` 内联 awk 文件时使用变量拼接替代 `-f "$AWK_DIR/"` 路径引用，避免 dist 构建后路径暴露

---

## [2.5.3] - 2026-06-01

> **注意**: v2.5.x 与 v3.0.x 为并行维护线。v2.5.3 在 v2.5.2 原有架构上做增量修复，
> 不包含 v3.0.0 的 Pipeline 架构重写。

### Changed

- **`THINKING_BUDGET` → `--thinking` / `--effort`**: 替代固定 budget 参数，改为自适应思考模式。
  支持 low/medium/high/xhigh/max 五级 effort，自动映射为适合各模型的 budget 值。
  新增 `THINKING` 和 `EFFORT` 环境变量，兼容变长思考预算（`be4a26e`）

---

### Added

- **Pipeline 架构重写 (bash)**：`agent_loop_stream` 统一 RESP 协议管道，解耦 LLM 调用、工具执行、事件记录和显示渲染；`display_message` 单消息渲染代替跨进程管道，消除 bash stdio 全缓冲导致的多轮 LLM 输出丢失（`5202d12`）
- **display_stream 子进程管道 (bash)**：RESP 消息通过 fd 7 管道从父进程发往子进程 `display_stream` 渲染，消除父子进程竞争终端 stdout 导致的文字交叠错位。子 Agent 关闭继承的 FD 3-9，防止意外写入父进程 display pipe（`f52b58e`）
- **Go 扁平包结构**：删除 `go/internal/` 下 15 个散包子包，合并为 8 个顶层文件 `agent.go` / `store.go` / `tools.go` / `transport.go` / `types.go` / `util.go` / `display.go` / `agent_test.go`（`252150c`）
- **Rust 替换为 rust2**：用 flatter 架构替换旧多文件拆分，`agent.rs` 作为主模块，新增 `display.rs` / `sse.rs` / `store.rs` / `util.rs`（`5dce3e8`）
- **`--thinking` / `--effort` 自适应思考模式**：替代 `THINKING_BUDGET`，支持 low/medium/high/xhigh/max 五级 effort（`f04e2bc`）
- **终端标题实时更新**：`term_title.awk` 在每次 LLM 调用后同步显示模型名、请求数和 token 统计（`b3064f4`）
- **对话压缩策略 (`compact_turn_keep.awk`)**：基于 turn 比例的行保留策略，配合 DP 算法做二次压缩（`1365b80`）
- **交互模式事件回放**：`event_replay.awk` 支持重入会话的历史对话回显（`a6d9cd0`）
- **SubAgent fork 会话隔离**：`store_session_fork()` 提取为独立函数，fork 时只复制 conversation/summary/plan（`a032bda`）
- **`cleanup_all_pipes` 统一清理**：按 FD 级联顺序关闭 curl/llm/agent_loop/INPUT_FIFO 管道（`5202d12`）
- **`llm_stream_curl` FD 6 管道替代 pipefail**：避免 `set -o pipefail` + SIGPIPE 导致脚本退出（`5202d12`）
- **测试扩展到 91+ 用例**：新增 SubAgent 故障传播 / fork / 隔离等测试（`tests/test.sh`）
- **`store_conv_get_messages` 空文件安全**：增加 `[[ -f "$CONV_FILE" ]]` 检查，避免 awk 报错（`778afdb`）

### Changed

- **`display_event` → `display_message` + `display_stream`**：拆分流式渲染和单消息渲染，`display_stream` 最终内联到 `agent_main_loop`（`5202d12`, `14c9e45`）
- **`agent_event` 内联到 `agent_loop`**：消除 `> >(display_event)` 跨进程管道及其 stdio 缓冲问题，`ACTIVE_SUB_COUNT` 改为 `agent_main_loop` 的 `local active_sub_count`，通过 bash 动态作用域在 `agent_loop` 中自增（`5202d12`）
- **compact 层合并到 agent 层**：7 层架构简化为 6 层（`1365b80`）
- **session 存储隔离**：7 类前缀重命名 + `TOOL_CALL` 分支重构（`4e11143`）
- **build.sh AWK_DIR 替换规则更新**：适配 `llm_stream_curl` FD 6 模式，修复 `dist/agent.sh` 中 `AWK_DIR: unbound variable` 错误（`14c9e45`）
- **文档同步**：`README.md` 移除已废弃的 `THINKING_BUDGET` 环境变量；`docs/ARCHITECTURE.md` 更新函数名和代码路径；`docs/sessions.md` 更新 replay 描述（`7354543`）

### Removed

- 旧 `rust/src/` 多文件包结构（config.rs/conversation.rs/httpclient.rs/...）
- 旧 `go/internal/` 多包结构（app/config/httpclient/sse/transport/tools/...）
- `rust2_backup/` 目录
- 全局 `ACTIVE_SUB_COUNT` 变量

### Security

- `scripts/build.sh` 内联 awk 文件时使用变量拼接替代 `-f "$AWK_DIR/"` 路径引用，避免 dist 构建后路径暴露

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
- **文档同步**：`docs/tools.md` SubAgent 结果注入格式更新（`[sub-agent <id>] <status> ...`）+ 并行异步说明 + 累加 `agent_request_count` 说明；`AGENTS.md`/`README.md`/`README.en.md` 补充 Go/Rust 集成测试命令；`Makefile` 新增 `test-go-e2e` / `test-rust-e2e` target

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

[Unreleased]: https://github.com/lloydzhou/bash-agent/compare/v4.0.2...HEAD
[4.0.2]: https://github.com/lloydzhou/bash-agent/compare/v4.0.1...v4.0.2
[4.0.1]: https://github.com/lloydzhou/bash-agent/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/lloydzhou/bash-agent/compare/v3.0.7...v4.0.0
[3.0.7]: https://github.com/lloydzhou/bash-agent/compare/v3.0.6...v3.0.7
[3.0.4]: https://github.com/lloydzhou/bash-agent/compare/v3.0.3...v3.0.4
[3.0.3]: https://github.com/lloydzhou/bash-agent/compare/v3.0.2...v3.0.3
[3.0.2]: https://github.com/lloydzhou/bash-agent/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/lloydzhou/bash-agent/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/lloydzhou/bash-agent/compare/v2.5.2...v3.0.0
[2.5.3]: https://github.com/lloydzhou/bash-agent/compare/v2.5.2...v2.5.3
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
