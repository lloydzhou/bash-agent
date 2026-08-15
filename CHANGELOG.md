# Changelog

所有重要变更均记录在此文件中。格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)。

---

## [Unreleased]

---

## [4.3.4] - 2026-08-15

> **webagent 浏览器网关发布**：新增 `webagent` —— WebSocket 桥接进程，在浏览器/手机上操作本地 agent 子进程；前端按 DeepSeek Harness 对话样式构建并支持零依赖数学公式渲染。同时修复 OpenAI 兼容 provider 流式 usage 全零问题与 APT 仓库体积膨胀。

### Added

- **`webagent` 网关**：独立进程，每条浏览器输入 spawn 一个 agent 子进程（参数原样透传，仅追加 `--output-format stream-json`），stdout stream-json 逐行转发给所有 WebSocket 客户端，stderr 套事件外壳；`--bind`/`--port` 控制监听地址（默认 127.0.0.1:8686），`--agent` 指定 agent 二进制（默认按 dist/ 与 PATH 解析）。
- **会话回放**：客户端连接时从 events.jsonl 回放最近 500 条（配合 agent 侧 `--session`/`--continue`，旧会话首连即可见历史）；页面刷新/断线重连自动清空重建，不重复堆积。
- **DSH 风格前端**：单文件 `index.html` 经 `include_str!` 内嵌进二进制，零构建链、零外部资源、不引入前端框架。设计令牌取自 DeepSeek Harness Web GUI（neutral-bluish 色板 + deepseek 品牌蓝），深/浅双主题（跟随系统、可手动切换、持久化）；用户右侧气泡（radius 22px）、助手 Markdown 正文（748px 居中列）、思考/工具折叠行（运行态扫光动画、完成后自动折叠）、工具 IO 卡片（输入/输出分节、tool_call 与 tool_result 合并同卡、运行中/完成/失败状态）、turnStatus shimmer 状态行、StatsLine 统计行（含缓存命中率）、Hero 空态、toBottom 悬浮按钮、composer 圆角输入卡（自动增高）。
- **前端 Markdown 渲染器**：手写极简实现（纯 DOM 构建 + textContent 赋值，天然防 XSS），支持标题/列表/表格/代码块/引用/链接/加粗斜体/行内代码。
- **零依赖数学公式渲染**：不引入 KaTeX/MathJax，以 Unicode 数学符号 + 浏览器原生 `<sup>`/`<sub>` 实现词法级 LaTeX 转换。行内 `$...$` 与块级 `$$...$$`（居中 serif）；~120 个常用命令映射（希腊字母、关系/集合算子、大算子 ∑∫∏、箭头、函数名、`\mathbb` 黑板粗体、`\hat`/`\vec` 组合字符重音）；上下标支持嵌套；`\frac` 降级 `(a)/(b)`（单 token 不加括号）、`\sqrt` 智能括号；货币守卫防 `$100` 误判；未识别命令原样保留文本（安全降级不丢内容）。
- **PWA 支持**：内嵌 manifest 与 icon，支持安装到桌面/Home Screen；`window.innerHeight` + `visualViewport` 驱动布局高度，键盘弹出/系统导航栏出现时 header 固定、输入框不被遮挡。
- **发布产物**：CI 新增 webagent 四平台构建（linux amd64/arm64 于 Debian 11 容器、macOS arm64/amd64），纳入 `.deb` 安装包（安装到 `/usr/bin/webagent`）、checksums 与 Release 资产；GLIBC 2.31 基线门禁覆盖 webagent Linux 产物。

### Fixed

- **OpenAI 兼容 provider 流式 usage 全零**：四运行时（Bash/Go/Rust/C）chat completions 请求体补 `stream_options.include_usage=true`。Kimi/Moonshot 等仅在最终 SSE chunk 携带 usage 且需显式开启该选项的 provider，此前所有 usage 事件均为零。
- **WS 握手首帧丢失**：webagent 手动握手时 `BufReader` 可能预读 `\r\n\r\n` 之后的 WS 帧并随 reader 销毁而丢失；改为裸 `read` + `PrefixedRead` 回放已读字节交给 `tungstenite::accept`，不丢任何字节。
- **慢客户端内存积压**：webagent 广播通道由无界改为有界（256），队列满/失效的连接自动移除，防止内存无限增长。
- **`--session` 无名称时误解析**：`--session` 后紧跟的 `--output-format` 不再被误当作 session 名，仅在下一参数不以 `-` 开头时视为 session 名。
- **replay 密集事件丢消息**：前端 rAF 合并渲染在事件同步密集到达（会话回放）时会被流重置提前取消，整条 text 消息丢失；改为重置前同步 flush 落地。
- **折叠行 chevron 裁切**：`.rowline` 的 `overflow:hidden`（扫光动画用）会切掉旋转 45° 后超出布局盒约 1.66px 的箭头尖端；改为仅运行态裁切并增加边距余量。
- **APT 仓库体积膨胀**：此前每次发版向 gh-pages 提交 `.deb` blob（~3.5MB×2），累积拖慢 clone（历史 blob 已 34MB）。改为 Packages 索引 Filename 直接指向 GitHub Releases 下载 URL，`.deb` 不再经过 gh-pages；并清理历史中已积累的 blob。

---

## [4.3.3] - 2026-08-11

> **Responses API provider 落地**：Bash、Go、Rust、C 四个运行时新增 `responses` provider（默认面向 DeepSeek Responses 兼容接口），统一实现请求转换、流式解析与终态语义的安全兼容子集，并明确文档化支持边界。

### Added

- **`responses` provider**：四运行时支持将本地会话（文本历史、`tool_use`/`tool_result`、工具定义、thinking 配置）转换为 Responses `create` 请求；流式侧处理 `response.output_text.delta`、`response.reasoning_text.delta`、函数调用 item 与参数增量，并映射到本地 tool loop。
- **终态与用量统一语义**：四运行时一致处理 `response.completed`、`response.failed`、`response.incomplete`、顶层 `event: error`、SSE 重试与 usage；cached tokens 优先读取 `input_tokens_details.cached_tokens`，无有效值时回退 `cached_tokens`；异常 EOF 未收到终态时统一发出中断错误和 `STOP:error`。
- **兼容性文档**：新增 `docs/responses-compatibility.md`，明确已支持的安全子集与不支持的 Responses 能力（托管工具、reasoning 回放、`previous_response_id` 等）及判定原则。

### Changed

- **OpenAI 兼容 provider 配置合并**：Bash 版合并 OpenAI 系 provider 配置并共享请求头构建；User-Agent 通用化，不再按 provider 特判。

### Fixed

- **四端流终止行为对齐**：统一顶层 `error` 事件为终态、嵌套 `cached_tokens` 读取与异常 EOF 兜底；无 message 字段的顶层 `error` 事件改用中性文案 `Stream error`，不再误报为 `Response failed`。

---

## [4.3.2] - 2026-08-03

> **C 版超长会话记录压缩修复**：修复压缩 `conversation.jsonl` 时将超过 64 KiB 的单条 JSONL 记录误拆为多行、导致会话内容损坏的问题。

### Fixed

- **C 版超长 JSONL 会话记录被拆分**：会话记录计数改为按真实换行符读取完整记录，不再受固定 64 KiB 缓冲限制；压缩并保留尾部记录时不会再向单条 JSON 中插入换行，避免上下文丢失或后续会话解析失败。

---

## [4.3.1] - 2026-07-31

> **Debian 安装包发布支持与 GLIBC 兼容性修复**：新增 Debian 安装包构建流水线，发布时自动生成架构无关、AMD64 和 ARM64 三类安装包，并随 GitHub Release 提供校验和；同时修复安装包内 Linux 原生运行时在较旧发行版上因 GLIBC 版本过高而无法运行的问题。

### Added

- **三类 Debian 安装包**：新增 `bash-agent_<version>_all.deb`、`bash-agent_<version>_amd64.deb` 和 `bash-agent_<version>_arm64.deb` 构建支持，分别提供 Bash 版及对应架构的 Go、Rust、C 运行时与 `tcode`。
- **发布流水线**：标签构建自动验证三个 `.deb` 文件，生成 `checksums.txt`，并将安装包与校验和上传到 GitHub Release。

### Changed

- **Linux 原生运行时最低系统基线固定为 GLIBC 2.31（Debian 11）**：`goagent`、`rustagent`、`cagent` 的 Linux amd64/arm64 发布产物统一在 Debian 11 容器中构建，可在 Debian 11/12/13、Ubuntu 20.04/22.04/24.04 及更新发行版上运行。持续集成新增 GLIBC 符号版本门禁，防止构建环境升级后静默回归。
- **Debian 架构包声明 `libc6 (>= 2.31)`**：在更老的系统上安装时会由包管理器直接拒绝，避免安装成功但运行失败。

### Fixed

- **早期 4.3.1 安装包在 GLIBC 低于构建机版本的发行版上运行报 `GLIBC_2.38/2.39 not found`**：根因是发布产物在滚动更新的 `ubuntu-latest` 构建机上编译，固化了过高的 GLIBC 符号版本。本版本改用 Debian 11 基线构建并受符号版本门禁保护；已下载早期 4.3.1 安装包的用户请重新下载本版本安装包。

---

## [4.3.0] - 2026-07-28

> **网络与视觉能力解耦及异步交互稳定性升级**：四运行时移除内置网络搜索、网页读取和图片自动描述，统一改由外部 Skill 按需提供；同时修复后台任务跨回合生命周期、交互输入调度与子智能体递归限制。

### Removed

- **内置网络与视觉调用**：Bash、Go、Rust、C 不再暴露 `WebSearch` / `WebFetch`，不再读取 `JINA_API_KEY` 或图片描述 API 配置，也不再自动调用视觉模型。需要网络搜索、网页读取或视觉理解时，由模型从 `skill-index` 选择外部 Skill。

### Changed

- **图片占位符改为本地路径映射**：保留 Ctrl+V 图片粘贴和 `[Image #N]` 占位符；发送时维持占位符原位置，并在 conversation 末尾追加 `<attached-images>` 本地绝对路径映射，供视觉 Skill 使用。
- **工具指引按实际能力生成**：四运行时 system prompt 仅描述当前存在的工具，避免移除内置网络与视觉工具后仍引导模型调用不存在的能力。
- **异步任务交互调度**：交互模式不再因后台 SubAgent 或 Bash 任务未完成而阻塞普通用户输入；后台结果到达后独立唤醒并注入后续回合。

### Fixed

- **Go 后台 SubAgent 跨回合生命周期**：后台上下文与任务计数保持到结果完成，避免 agent 回合结束后提前取消子智能体或丢失结果。
- **禁止嵌套 SubAgent**：Bash、Go、Rust、C 统一限制子智能体再次启动 SubAgent，防止递归会话扩散和后台资源失控。
- **异步结果回收与失败传播**：补充交互输入、并行子智能体、失败结果、fork 上下文、图片路径映射及中英文 system prompt 字节一致性测试。

---

## [4.2.21] - 2026-07-22

> **自动续聊隔离与 Go 思考配置修复**：自动选择最近会话时不再误入 SubAgent 子会话，同时保留显式进入子会话的能力；修复 Go 运行时覆盖 `THINKING` / `EFFORT` 环境变量的问题，并简化 API key 配置文档。

### Fixed

- **自动续聊跳过 SubAgent 会话**：Bash、Go、Rust、C 的 `--continue` 自动选择最近会话时忽略 `sub_*` 子代理会话；未显式指定源会话的 `--fork` 同样复用该过滤规则。显式使用 `--session sub_xxx` 时仍可进入对应子会话。
- **Go 思考配置环境变量覆盖**：Go 运行时默认配置读取 `THINKING` 与 `EFFORT` 环境变量，命令行仅在显式传值时覆盖，避免参数默认值意外抹除环境配置。

### Changed

- **API key 配置文档**：精简中英文 README 中的 API key 设置说明，使环境变量配置步骤更直接。

---

## [4.2.20] - 2026-07-14

> **Provider 配置优先级统一与 Bash 稳定性修复**：统一 Bash、C、Go、Rust 四个运行时的 provider 显式配置、环境变量与 DeepSeek 自动回退顺序；同时修复 Bash 在 `set -u` 模式下的未绑定变量崩溃，并使用跨平台方式识别最新会话。

### Fixed

- **跨运行时 Provider 配置优先级**：显式参数优先于当前 provider 的环境变量；未选中 provider 的环境变量不再干扰配置解析或 DeepSeek 自动回退。DeepSeek 回退统一采用 Claude 兼容端点与 `deepseek-v4-flash` 默认模型，最终 provider 确定后才设置模型、认证和传输格式。
- **Bash `set -u` 未绑定变量崩溃**：为 `validate_config` 中的环境变量读取提供安全的空值默认值，修复未设置 API key 时的异常退出。
- **最新会话时间戳跨平台兼容性**：`store_session_get_latest_dir` 启动时检测系统支持的 `stat` 参数，并只查询存在的事件文件或会话目录，避免 macOS / GNU 环境回退链不兼容导致的错误。

---

## [4.2.19] - 2026-07-14

> **本地文件工具 Bash 权限模式与稳定性修复**：为 Bash / Read / Write / Edit 提供统一的路径权限策略，封堵受信任目录的路径穿越绕过；同时恢复 Go / C 崩溃后的终端状态，并修复 awk 转义解析问题。

### Added

- **本地文件工具 Bash 权限模式**：为 `Read`、`Write`、`Edit` 引入与 Bash 命令一致的权限守卫与路径分类，覆盖用户目录、项目目录和内部临时目录；四个运行时同步实现并补充测试。

### Fixed

- **受信任路径穿越绕过**：对已获信任的用户、项目及内部目录，路径规范化后重新验证边界，阻止通过 `..` 访问受限位置。
- **Go / C 崩溃后的终端恢复**：Go 增加 panic recovery 与崩溃信号处理，C 修复 SubAgent 显示队列和空 JSON 根节点导致的 SIGSEGV，避免 raw mode 终端在异常退出后无法恢复。
- **awk 转义解析**：将 awk 内联终端控制字符改为通过 `sprintf` 构造，避免 PEBKAC 解析器误判转义序列。

---

## [4.2.18] - 2026-07-11

> **跨运行时架构一致性修复**：以 Bash 版为基准，修复 C / Go / Rust 三版本在缓存策略、HTTP 传输层韧性、工具输出格式和压缩守卫逻辑上的 6 项不一致。确保四运行时行为完全对齐，同一 session 在不同版本间切换时不再产生差异。

### Fixed — 高危

- **C PlanClear 缓存顺序**（C 独有）：`tool_plan_clear()` 此前在工具分发阶段直接清空 `plan.md`，后续 compact 的 summary 请求因 system prompt 已不含旧计划而无法命中 KV cache 前缀，每次 PlanClear 额外产生一次完整冷启动。修复为先 `agent_compact_context("plan_clear")` 再 `store_plan_clear()`，对齐 Bash / Go / Rust。
- **Go / C HTTP 传输层重试缺失**：Bash 使用 `curl --retry 2 --retry-delay 1 --retry-max-time 20`，Rust 有 `StreamClient` 应用层重试。Go 的 `client.Do(req)` 和 C 的 `curl_easy_perform()` 均为单次请求，遇到临时连接故障或 5xx 直接终止。已实现的 `SSE_RETRY` / `EventRetry` 累积器重置代码因无重试路径而成为不可达死代码。修复为添加重试循环（最多 2 次，延迟 1s，总窗口 20s），C 重试前发送 `SSE_RETRY` 重置累积器。

### Fixed — 中危

- **C / Go tool_read 行号不一致**：Bash（`sed -n`）和 Rust 不加行号输出原始文本；C 用 `%6d + 两空格`、Go 用 `%6d + Tab`——三版本输出互不相同。统一为 Bash / Rust 的原始文本输出（无行号）。
- **C agent_wait_for_sub_agents 错误返回处理**：`mq_pop` 失败或收到无法处理的消息时函数直接 `return -1`，调用者忽略返回值后进入销毁流程，可能释放仍被 detached 线程使用的队列（use-after-free 风险）。修复为 `mq_pop` 失败时 `break`，`processed==0` 时 `continue`。

### Fixed — 低危

- **Go CompactContext plan 守卫对齐**：`plan_clear` / `plan_confirm` 时 `keepLines >= totalLines` 不再提前返回 `false`，对齐 Bash / C / Rust 的"plan 操作绕过守卫"行为。
- **Rust update_stats_from_usage 守卫对齐**：移除 `if self.last_input_tokens > 0` 外层守卫，`agent_request_count` 和 token totals 无条件更新（对齐 Bash / Go），`current_context_tokens` 仍保留 `> 0` 守卫。

### Changed

- C `transport.c` 提取 `process_residual_json()` 辅助函数，消除非 SSE 响应解析的重复代码。
- Go `transport.go` 新增 `time` 包导入。

---

## [4.2.17] - 2026-07-10

> **C 版并发子代理结果队列生命周期修复**：修复非交互模式下主循环提前结束后错误等待输入队列、未回收子代理结果即销毁队列的问题，避免多个并发子代理完成时进程因未定义行为直接退出。

### Fixed

- **C SubAgent / 后台 Bash 结果回收**：新增统一的异步结果处理与等待逻辑，所有收尾路径均从 `sub_result_queue` 消费结果，直至活跃任务计数归零。
- **C 队列生命周期**：确保销毁 Agent 和消息队列前，所有 detached 异步工作线程均已完成并回收结果，避免向已释放队列写入。
- **C 异步结果处理一致性**：子代理、后台 Bash 和用户通知复用统一处理逻辑，统一事件、统计、显示、conversation 注入及后续 agent 回合触发行为。

---

## [4.2.16] - 2026-07-07

> **SubAgent 与后台 Bash 进程隔离修复**：全面修复 C/Go/Rust 三版本在 SubAgent 和 `Bash(background=true)` 中的进程隔离、配置继承和结果处理不一致问题。以 Bash 版为基准，统一了子 agent `max_turns` 继承策略、end_turn 后子 agent 结果的嵌套处理模型、子进程 stdin/进程组隔离、以及 `handleSubAgentResult` 的职责边界。

### Fixed — Bash 工具进程隔离（三版本）

- **C 同步 Bash**：子进程 `stdin` 重定向到 `/dev/null`，不再继承主终端（修复与 readline 抢输入导致交互卡住）；设置独立进程组（`setpgid`）；timeout 时 kill 整个进程组；`waitpid` 处理 `EINTR`。
- **C 后台 Bash**：移除 `system("bash -lc '%s' ...")`，改为 `fork/exec`，命令通过 argv 传递，消除 shell quoting 风险；子进程 `stdin` 接 `/dev/null`，设置独立进程组；输出增加 UTF-8 sanitize。
- **C 后台 Bash / SubAgent 线程**：`pthread_create` 失败时正确回滚计数器和释放资源。
- **Go 同步 / 后台 Bash**：显式 `Stdin = nil`；后台 Bash 设置 `Setpgid: true`。
- **Rust 同步 / 后台 Bash**：设置 `stdin(Stdio::null())` 和 `process_group(0)`；cancel/timeout 改用 `libc::kill(-pid, SIGKILL)` 替代 spawn `kill` 命令。

### Fixed — SubAgent 配置继承与结果处理一致性

- **子 agent `max_turns`**：C/Go 此前硬编码为 10，修正为继承父 agent 的 `max_turns`（对齐 Bash 版子 shell 继承环境变量 `MAX_TURNS`）。
- **Go RunLoop 重构**：end_turn 后到达的子 agent 结果此前用平铺 `for` 循环 `continue` 处理（共享 turn 预算），重构为外层 `for {}` + 内层 `TurnLoop`，每个 phase 获得独立 `max_turns` 预算（对齐 Bash/C/Rust 的嵌套调用模型）。
- **Go `handleSubAgentResult` / `handleAsyncTaskResult` / `handleUserNotify`**：不再直接写 conversation，改为返回 context 字符串由调用方写入；`drainSubAgentResults`（turn loop 内，共享预算）和 RunLoop 外层循环（post-end_turn，独立预算）分别处理。
- **Go `runSubAgent`**：从 `os.Executable()` + `exec.Command` 改为 goroutine 内创建独立 child agent；home/cwd 从父 agent store 继承，不再用 `os.Getenv`；增加 panic recover。
- **Rust 子 agent**：`stdout/stderr` 从 `io::empty()` 修正为 `io::sink()`。
- **C SubAgent 输出隔离**：为 `Agent` 增加 `out`/`err` 专属句柄，子 agent 指向 `/dev/null`；verbose、compact 错误、title 状态写 agent 专属 `err`。

### Changed

- Go `SessionStore` 接口新增 `GetHomeDir()` / `GetCwd()` 方法。
- Go `ToolDispatcher` 结构体字段对齐（gofmt）。

---

## [4.2.15] - 2026-07-07

> **终端标题 / iTerm2 loading 一致性修复**：修复主 agent 等待 SubAgent 或后台 Bash 任务结果时，`idle` 状态过早清除 loading 的问题；统一 Bash / C / Go / Rust 四版本终端标题格式与 cache 百分比显示；新增 async Bash e2e 覆盖完整 title + progress 控制序列。同时精简 Bash 辅助函数并新增 live session monitor 脚本。

### Added

- 新增 `scripts/watch.sh`：实时观察 session 目录、conversation/events/stats 等运行状态，便于调试长会话和异步任务。
- 新增 async Bash e2e 断言：检查完整终端标题格式（`⏳ model T/R/I/O/C`）和 iTerm2 progress loading 控制序列。

### Fixed

- **Bash / Rust**：当仍有活跃 SubAgent 或后台 Bash 任务时，run loop 结束进入 `idle` 不再清除 iTerm2 loading，只有 `idle && active_task_count == 0` 才清空 progress。
- **C**：非交互 e2e 模式也输出终端 title/progress，避免与 Bash 基准不一致。
- **C / Go / Rust**：终端标题 cache 百分比对齐 Bash：`input + cache_read == 0` 显示 `—`，有输入时显示四舍五入百分比（包括 `0%`）。
- 四版本统一终端标题可见格式：`⏳ model T:<turn> R:<request> I:<input+cache>(<cache_pct>) O:<output> C:<context>`。

### Changed

- Bash 删除未使用的 `store_plan_draft_read()`。
- Bash 删除单调用点的 `util_msg_to_stream()`，在 `agent_loop()` 内联 stream event 转换逻辑。
- Bash 优化 `util_parse_size()`：改为纯 shell suffix 解析，减少子进程和重复校验，保持原有 `k/K`、`m/M`、`g/G` 语义。

---

## [4.2.14] - 2026-07-04

> **Ctrl+O 用户输入注入**：agent 运行中或空闲时，用户按 Ctrl+O 可将当前编辑行内容作为追加指令注入 conversation，不中断当前 LLM turn。输入通过 notify/sub_result channel 在安全边界（LLM call 前 / end_turn 后）统一 flush，复用既有 SubAgent/bg-bash 的 pending 通道。删除了 Bash 版的 `AGENT_RUNNING_FLAG` 文件标记，改为 notify reader 统一发送 wakeup + main loop 过滤 stale wakeup。

### Added — Ctrl+O 输入注入（四版本）

- **linenoise**：枚举新增 `CTRL_O = 15`，`case CTRL_O` 调用 `injectCallback`，返回 0 则清空 edit buffer；新增 `linenoiseSetInjectCallback` API
- **Bash**：`bind -x '"\C-o"'` 绑定 `agent_user_inject_readline`，通过 fd9（NOTIFY_FIFO）发送 `USER_NOTIFY` 消息
- **C**：新增 `inject_callback`（readline.c）、`MSG_USER_NOTIFY` / `MSG_NOTIFY_PENDING` 消息类型、`DISPLAY_USER_NOTIFY` 渲染
- **Go**：新增 `SetInjectCallback`、`EnqueueUserNotify`、`EventUserNotify`、`notifyWakeupInput` 哨兵值
- **Rust**：新增 `MainLoopMessage::UserNotify` / `NotifyPending`、`DisplayEvent::UserNotify`、`register_inject_callback` FFI
- **conversation 原文注入**：`USER_NOTIFY` 写 conversation 使用原始用户文本（不加 `[user inject]` 前缀），显示层才加黄色 `[user inject]`

### Changed — 删除 AGENT_RUNNING_FLAG（Bash）

- **notify reader 统一发送 NOTIFY_PENDING**：不再判断 agent 是否运行中；main loop 收到后通过 `[[ -s "$NOTIFY_BUF" ]]` 检查 pending 是否为空，空则忽略（stale wakeup 过滤）
- **active count 递减合并**：从 `AGENT_RESULT` / `ASYNC_TASK_RESULT` 两个分支各自处理，改为 case 后统一（`USER_NOTIFY` 不递减）
- **notify reader case 重构**：新增 `USER_NOTIFY` 分支 + `*) continue ;;`（未知消息不发 wakeup）

### Fixed

- **C SubAgent 偶发崩溃**：SubAgent 子线程通过 curl 发 HTTP 请求时，未忽略 SIGPIPE 且未设 `CURLOPT_NOSIGNAL`，连接关闭或 pipe 写入触发 SIGPIPE 直接杀死整个进程。修复：进程启动时 `signal(SIGPIPE, SIG_IGN)` + 所有 curl 调用设 `CURLOPT_NOSIGNAL`
- **Bash 提示符不显示**：`exec 9> "$NOTIFY_FIFO" 2>/dev/null` 中的 `2>/dev/null` 是 exec 级永久重定向，把子 shell stderr 吞掉，导致 `read -e -p '>'` 的提示符（写到 stderr）不显示。修复：改为 `exec 9<> "$NOTIFY_FIFO"`（O_RDWR 不阻塞 + 不重定向 stderr）
- **Bash unbound variable**：`[[ -z "$READLINE_LINE" ]]` 在 `set -u` 模式下 READLINE_LINE 未设置时报错。修复：改为 `[[ -n "${READLINE_LINE:-}" ]]`

### Docs

- `BASH_ARCHITECTURE.md` / `architecture.md`：删除全部 `AGENT_RUNNING_FLAG` 引用（架构图节点、流程判断分支、代码示例、行为说明），更新为统一 NOTIFY_PENDING + stale wakeup 过滤逻辑
- 所有注释中 `Ctrl+Enter / ESC+CR` → `Ctrl+O`

---

## [4.2.13] - 2026-07-03

> **Bash 工具异步执行 + 架构文档大修**：Bash 工具新增 `background=true` 参数，长时间运行的命令可后台执行，完成后通过 SubAgent 的 notify 通道异步返回结果（四版本同步实现）；架构文档全面更新（mermaid 通道图、四版本对比、DP 决策公式），清理 4 个过时文档。

### Added — Bash 工具 `background=true` 异步执行（四版本）

长时间运行的命令（builds, tests, servers）可以后台执行，立即返回 task_id，完成后通过 SubAgent 的双 FIFO / 消息队列架构异步返回结果。

- **tools.json**：Bash 工具新增 `background` 参数（boolean）
- **机制**：复用 SubAgent 的 notify 通道，新增 `ASYNC_TASK_RESULT` 消息类型
- **事件**：仅新增一个 `async_task_result` 事件（不冗余，`tool_call` + `tool_result` 已记录启动信息）
- **命名统一**：task ID 格式 `task_YYYYMMDD-HHMMSS-XXXX`（与 SubAgent `sub_xxx` 一致）；display 前缀 `[bg-bash]`
- **计数器 rename**：`active_sub_count` / `ACTIVE_SUB_FILE` → `active_task_count` / `ACTIVE_TASK_FILE`（同时跟踪 SubAgent 和 bg-bash）

### Changed — SubAgent 结果处理顺序对齐（Go + Rust）

审查四版本实现时发现 Go 和 Rust 的 SubAgent 结果处理顺序与 Bash 基准不一致。

- **Go**：`handleSubAgentResult` 中 display 和 stats 顺序互换（stats → counter → display）
- **Rust** `handle_sub_agent_result`：stats 从事件之前移到之后

### Fixed

- **Bash `agent_drain_notify_buf`**：drain 改为写 stdout（走 agent_loop 管道），替代直接写 FD 4。修复 bg-bash 结果在 TEXT 之前显示的顺序错乱（管道缓冲 vs 直接写入竞态）。
- **C**：drain 中空的 `store_event_append("")`（写入空事件到 events.jsonl）
- **C/Go**：删除 async bash 的 timeout 和 output 截断（对齐 Bash 基准——Bash 版无 timeout、无截断）
- **C**：async bash 用 `mkstemp` 替代 session 目录路径（修复 `No such file or directory`）
- **Go display**：`handleAsyncTaskResult` 复用 `EventSubAgentResult` 导致渲染为 `[sub-agent] failed`。修复：display.go 区分 `ASYNC_TASK_RESULT` 字段。

### Docs — 架构文档大修

- **BASH_ARCHITECTURE.md**：进程模型图改为 mermaid（补全 `AGENT_RUNNING_FLAG` / `stdin_reader`）；新增 §11A 四版本通道架构对比（Bash/C/Go/Rust 各一张 mermaid 图）；§6.3 DP 决策公式从参数列表补全为完整公式
- **architecture.md**：项目定位从"纯 bash/awk"更新为四版本
- **sessions.md**：补充运行时文件
- 删除 4 个过时文档：`COMPARISON_ALL.md`、`DIFF_CHECKLIST.md`、`refactor-7class.md`、`ROADMAP.md`

### Tests

- 新增 `test_agent_async_bash` e2e 测试（`ASYNC_BASH_MARKER` mock）
- 新增 `test_agent_openai_sensenova_style` 测试（v4.2.12 遗漏）
- 四版本 181/181 通过。

---

## [4.2.12] - 2026-07-01

> **OpenAI SSE 兼容性修复 + agent error 退出后 SubAgent 结果处理**：修复 C/Rust 在接入 sensenova 等非标准 OpenAI 兼容 API 时 tool_call 解析失败的问题；修复 Bash/Go 在主 agent LLM 调用失败后 SubAgent 结果无法触发新 agent_loop 的问题。

### Fixed — OpenAI SSE 非标准空字符串字段（C + Rust）

部分 OpenAI 兼容 API（如 sensenova）在流式 SSE 中使用空字符串 `""` 代替标准省略/`null`：
- `finish_reason: ""`（每个 chunk 都有，标准是仅在最后一帧为 `null` 或具体值）
- 后续 tool_call chunk 中 `id: ""` / `name: ""`（标准是省略这些字段）

这导致 C/Rust 的 `if (id)` / `if (finish)`（非 NULL 检查）被空字符串满足，触发提前 STOP 并用空字符串覆盖第一个 chunk 设置的正确 tool name，表现为 `Unknown tool:` 错误。

- **C**（`c/transport.c`）：`if (id)` → `if (id && id[0])`，`if (finish)` → `if (finish && finish[0])`
- **Rust**（`rust/src/sse.rs`）：`if let Some(v)` → `if !v.is_empty()`
- Bash/Go 已有 `!= ""` 检查，无需修改

### Fixed — agent error 退出后 SubAgent 结果无法触发新 loop（Bash + Go）

主 agent 的 LLM 调用失败（如 curl timeout）后，agent 进入 idle 状态。此时后台 SubAgent 结果到达后无法自动处理，用户必须手动输入才能看到结果。

- **Bash**（`src/agent.sh`）：`agent_loop_stream` 在 `stop=error` 时 `return 1` 跳过了 `rm -f "$AGENT_RUNNING_FLAG"`。flag 残留导致 notify reader 不发 `NOTIFY_PENDING`，SubAgent 结果无法触发新 loop。修复：`return 1` 前加 `rm -f "$AGENT_RUNNING_FLAG"`。
- **Go**（`go/agent.go`）：`RunLoop` 在 `stopReason=error` 时直接 `return`，跳过了 pending SubAgent 检查。C/Rust 的 SubAgent 消费在 `main_loop` 层（`while active_sub_count > 0`），独立于退出原因，故无此 bug。修复：error `return` 前加 pending SubAgent 检查。

### Tests

- 新增 `SENSENOVA_STYLE_MARKER` mock 测试：模拟非标准 SSE 格式（`finish_reason:""` + 后续 chunk `name:""`/`id:""`），验证 tool name 不被覆盖。
- 四版本 180/180 通过。

---

## [4.2.11] - 2026-06-30

> **JSON escape 性能优化 + SubAgent 双 FIFO 通知架构重构**：`util_json_escape` 从纯 Bash 全局替换改为 awk 管道（~1000x 加速）；SubAgent 通知从单 FIFO 改为双 FIFO 架构（NOTIFY_FIFO + NOTIFY_BUF），结果消费时统一 display（不打断流式输出），四版本（Bash/Go/C/Rust）架构对齐。

### Performance

- **`util_json_escape` awk 化**：从纯 Bash `${_s//\\/\\\\}` 多轮全局替换改为复用已有的 `json.awk` + `json_cli.awk` 的 `escape_json_string` 函数。28KB system prompt escape 从 ~9.2s/次降到 ~8ms/次（~1070x），单轮 mock 请求从 ~9.3s 降到 ~0.36s（~26x），完整 `make test-bash` 从 ~1200s 降到 ~180s（~7x）。

### Changed — SubAgent 双 FIFO 通知架构

- **双 FIFO 设计**：SubAgent 结果不再走 INPUT_FIFO（与用户输入共用），改为独立的 NOTIFY_FIFO + NOTIFY_BUF 缓冲。notify reader 后台子 shell 阻塞读 NOTIFY_FIFO，`agent_drain_notify_buf` 在每轮 LLM 调用前 + end_turn 后消费。
- **display 移到消费时**：SubAgent 结果的 display 不再在到达时立即输出（打断流式 text delta），而是在 `agent_drain_notify_buf` 消费时统一渲染（LLM 调用间隙）。
- **计数器移到 `tool_sub_agent`**：`ACTIVE_SUB_FILE` 计数器从 `agent_loop`（管道转发的消息）移到 `tool_sub_agent`（子进程创建前），消除管道延迟导致的竞态。
- **`AGENT_RUNNING_FLAG`**：标记 `agent_loop_stream` 运行状态。运行中时 notify reader 不发 NOTIFY_PENDING，靠 drain 在下一轮迭代消费。
- **非交互退出判断**：`cat "$ACTIVE_SUB_FILE"` ≤ 0 **且** `NOTIFY_BUF` 空 → SESSION_END。用 `cat` 而非 `$(<file)` 避免 Bash 特殊语法陷阱。

### Fixed

- **`$(<file 2>/dev/null || echo 0)` 对已存在文件返回空字符串**：Bash 的 `$(<file)` 特殊语法被 `|| echo 0` 破坏，变成空命令+重定向，成功退出但不产生输出。改用 `cat "$file" 2>/dev/null || echo 0`。
- **`RS="\0"` 在 macOS BWK awk 中不生效**：`"\0"` 被当作空字符串，触发段落模式按空行分割记录，大输入被截断。恢复 `getline` 循环读取完整 stdin。
- **SubAgent fork 默认值为空字符串**：`fork="${3:-}"` 改为 `fork="${3:-false}"` + `[[ "$fork" == "true" ]] || fork=false` 归一化。
- **`store_session_fork` 缺少 `create_dir_all`**（Rust）：目标目录不存在时 `fs::copy` 静默失败，fork 模式下子 agent conversation 未继承父内容。
- **Rust title 与 display 交织**：`update_term_title` 在主线程写 stderr，display worker 在子线程写 stdout，终端输出交织。改为通过 `DisplayEvent::Title` 走 display worker channel 序列化输出。

### Architecture Alignment — 四版本对齐

- **Go**：新增 `drainSubAgentResults()` + fork 归一化 + `SUB_AGENT_RESULT` → `AGENT_RESULT`
- **C**：新增 `sub_result_queue`（独立队列）+ `mq_try_pop`（非阻塞出队）+ `agent_drain_sub_results()` + end_turn 后 drain + 清理 main switch 死代码
- **Rust**：新增 `sub_result_rx/tx` 独立 channel + `drain_sub_results()` + end_turn 后 drain + 清理 main match 死代码
- **四版本统一 SubAgent 结果处理顺序**：`usage event → sub_agent_result event → sub_agent_end event → stats update → counter decrement → display → conversation injection`

### Tests

- **新增 `SUB_MULTI_MARKER` 测试**：mock server 同一响应返回两个 SubAgent tool_call，验证并行 SubAgent 结果都被正确处理。
- **四版本全部 179/179 通过**。
- `tests/test.sh` 新增 per-test 计时显示。

### Docs

- `docs/BASH_ARCHITECTURE.md` 更新 10 个 section：进程模型、FD 分配、消息类型、agent_main_loop、agent_loop_stream、tool_sub_agent、目录结构、SubAgent 机制（完全重写）、util_json_escape。

---

## [4.2.10] - 2026-06-29

> **SubAgent worktree 委派指导**：在 `SubAgent` 工具描述中补充 child-managed git worktree 协作规则，用于并行或隔离代码任务，避免污染主工作区。

### Changed

- **SubAgent child-managed worktree guidance**：明确 git worktree 是可选隔离机制，不是默认要求；仅在父 agent 的 `SubAgent.prompt` 中显式要求时，由子 agent 自行判断、创建、使用、报告，并在安全条件下清理。
- **最小化 runtime 行为变更**：不新增 Worktree 工具、脚本或配置；不支持 parent-managed；父 agent 不自动创建或清理 worktree，worktree 状态仅通过 prompt/messages/todos 传递。
- **C 版嵌入链路说明**：四处 `tools.json` 仍共享同一份内容；C 版编译时继续由 `c/Makefile` 从 `c/tools.json` 动态生成 `tools_embed.h` 嵌入到二进制。

---

## [4.2.9] - 2026-06-25

> **Go 会话与入口行为一致性修复**：修复 Go 版本在 session 目录、`--session`/`--list-sessions` 入口参数和终端标题输出上与 Bash/C/Rust 不一致的问题。

### Fixed

- **Go session 存储目录对齐**：会话目录计算时解析符号链接，macOS 下 `/tmp` 会落到 `/private/tmp`，与 Bash `pwd -P`、C `getcwd` 和 Rust 行为一致。
- **Go project key 对齐**：移除 Go 独有的 200 字符截断，避免长路径 session key 与其他版本不一致。
- **Go `--list-sessions` 无 API key 行为**：将 `--list-sessions` 提前到 API key 校验前执行，无 API key 时也能列出本地 session。
- **Go `--session` 参数行为**：支持裸 `--session` 自动创建新 session；修复 `--session <id>` 后续参数被误当 prompt 的问题。
- **Go 终端标题输出**：OSC 0 title 与 OSC 9;4 progress 分别独立输出，避免 progress 序列嵌入 title；请求数 `R` 改为千分位格式化。

---

## [4.2.8] - 2025-06-19

> **交互模式输入修复**：修复 C/Rust/Go 交互模式下中文输入被 display 输出打断导致乱码的竞态问题。

### Fixed

- **交互模式中文输入乱码**：`linenoiseEditFeed`（readline 线程）处理按键时调用 `refreshLine` 操作终端，但不持有 `g_display_mutex`，与 display 线程的 `linenoiseWrite`（Hide/Show）存在竞态。中文输入法的 UTF-8 多字节序列在逐字节 `read` + `refreshLine` 的间隙被打断，导致终端状态错乱、字节丢失。修复：在 `read()` 之后加锁，所有 return 路径前解锁。`read()` 本身不持锁以避免阻塞 display 线程。一处修复 `linenoise.c`，C/Rust/Go 三版本共享生效。

---

## [4.2.7] - 2025-06-19

> **`--fork` 命令行参数 + C 版 Read 显示修复**：新增从已有 session 派生新 session 的 `--fork` 参数；修复 C 版 Read 工具 offset/limit 不显示。

### Added

- **`--fork` 命令行参数**（Bash/Go/Rust/C）：从已有 session 派生新 session，通过 `store_session_fork` 复制 conversation/summary/plan，生成全新 session ID。与 `--session <id>` 或 `--continue` 配合使用，无源时自动回退到最近 session（等价 `--continue`）。fork 在 `store_session_init` 之前执行（先复制再补全），是静默文件复制，不产生额外事件。C 版 `store_session_fork` 提取为独立函数（从 `store_session_init_sub` 中分离）。

### Fixed

- **C 版 Read 工具 offset/limit 不显示**：`json_get_string` 内部要求 `JSON_STRING` 类型，但 LLM 传的 offset/limit 是 `JSON_NUMBER` → 返回 NULL → 摘要不显示。改用 `json_as_string(json_get(...))`。其他三版本（Bash/Go/Rust）均有正确的 fallback 逻辑。
- **C/Rust SubAgent fork 顺序不一致**：`store_session_init_sub`（C）和 SubAgent 启动（Rust）中 init 在 fork 之前。统一为 fork 先 init 后（先复制源数据，init 再补全 events/stats）。

### Changed

- **精简 usage 文档**（四版本同步）：Environment 从 10 行合并为 4 行（`*_API_KEY`/`*_BASE_URL` 合并，去掉 Options 已覆盖的 `EFFORT`/`THINKING`/`MODEL`），Examples 从 8 个精简为 4 个。
- **Go/Rust bash mode classifier 测试扩展**：补齐与 Bash 版等覆盖度的分类器测试用例。

---

## [4.2.6] - 2025-06-13

> **安全修复 + 四版本一致性版本**：修复 Bash 权限扫描器根目录绕过漏洞；统一四版本 session 功能、请求体字段顺序、默认值；新增 Bash 完整架构文档。

### Security

- **根目录 `/` 和 `/*` 权限绕过**：`tool_bash_add_path()` 中 `/` 和 `/*` 不匹配任何路径正则，被误归类为 workspace scope。攻击者可通过 `rm -rf /*`、`find / -delete` 等命令绕过 system 权限检查。修复：`/` 和 `/*` 归类为 system scope (8)。Bash/C/Go/Rust 四版本同步。
- **`RE_ROOT_DELETE` 正则不匹配 `/*`**：`rm -rf /*` 中 `/` 后跟 `*`（glob）不匹配原有的 `/([[:space:]]|$)` 末尾模式。修复：正则末尾增加 `|[*]`。
- **Bash token 遍历 glob 干扰**：`for tok in $seg` 未禁用 glob 展开，`/*` 被展开为根目录文件列表，导致分类结果依赖文件系统状态。修复：改用 `read -ra` 避免 glob。
- **`sudo`/`su`/`doas` 换行绕过**：`sudo\necho hi` 被分割为两个 segment，单独的 `sudo` 不匹配 `sudo *` 模式。修复：case 匹配增加无参数形式 `sudo|su|doas`。

### Fixed

- **C 版 `--list-sessions` 缺失**：此前输出 "not implemented"。新增 `store_session_list_rows()` 实现。
- **C/Go `--continue` mtime 判定不一致**：直接用目录 mtime 而非 events.jsonl mtime。修复：优先 events.jsonl，fallback 目录 mtime（对齐 Bash/Rust）。
- **Go `--max-turns` 默认值 500**：应为 1000（Bash/C/Rust 均为 1000）。修复 flag 默认值。
- **Go `TOOL_RESULT_MAX_BYTES` 默认 30000**：应为 100000（Bash/C/Rust 均为 100000）。
- **Go `ListSessionRows` preview 截断用字节**：`len(line)` 应为 `utf8.RuneCountInString(line)`，`line[:57]` 应为 `string([]rune(line)[:57])`。
- **Go `SummaryCall` instruction 消息字段顺序**：`map[string]string` 序列化为字母序，手动拼接保持 `role→content`。
- **Bash usage 帮助文本 `--max-turns` 写 500**：实际默认值 1000，修正文档。

### Changed

- **LLM 请求体字段顺序统一**：四版本统一为 Go/Rust 天然的 map/BTreeMap 字母序：`max_tokens → messages → model → output_config → stream → system → thinking → tools`。Bash `llm_call()` 和 C `build_claude_request()` 调整拼接顺序。
- **list-sessions 排序统一为 modified 降序**：Bash（sort 管道）、C（间接索引排序）、Go（sort.Slice）均改为 modified 降序，Rust 已是降序。
- **Rust Config 移除未使用字段**：`max_context_keep_pct` 和 `max_turns_before_compact` 从未被引用，移除。

### Added

- **C 版 `util_truncate_chars()`**：按 UTF-8 字符数截断 + 省略号，与已有的 `util_truncate_str()`（按字节）配对，消除 `store.c` 中的重复逻辑。
- **Bash 架构文档**（`docs/BASH_ARCHITECTURE.md`）：18 个模块的完整实现细节记录，作为 Port 版本对齐基准。
- **四版本对比报告**（`docs/COMPARISON_ALL.md`）：8 项差异的详细记录和修复状态。
- **安全测试用例**：`ls /`、`rm -rf /*`、`find / -delete`、`sudo\necho hi` 等场景，添加到四版本的分类器测试中。

---

## [4.2.5] - 2025-06-10

> **Bugfix + 一致性版本**：修复 bash 权限扫描器将 workspace 绝对路径误判为 external；统一 tool 错误信息格式消除双重 Error 前缀；统一 Edit 成功输出格式；统一 DP_MIN_KEEP_RATIO 默认值为 0.25。

### Fixed

- **Bash 权限扫描器 CWD 误判（核心修复）**：`tool_bash_add_path()` 无 CWD 概念，`TOOL_BASH_RE_EXTERNAL_PATH` 的 `/[A-Za-z0-9._-]` 匹配所有绝对路径，导致 workspace 内路径（如 `/Users/.../src/agent.sh`）全部被判为 external scope=4。修复：`tool_classify_bash_required_mode` 从 `$PWD` 初始化 CWD（转小写），`tool_bash_add_path` 在 external 正则前加 `path == CWD || path.starts_with(CWD+"/")` 判断。Bash/Go/Rust/C 四版本同步。
- **git 命令缺少 exec/write 分类**：`git commit/add/checkout/merge/rebase/stash/cherry-pick` 未被识别为 workspace exec+write，导致权限判断不完整。已加入四版本扫描器的 exec 和 write 列表。
- **双重 Error 前缀**：tool 函数返回 `"Error: xxx"`，agent 层再加 `"Error: tool execution failed: "` → 最终显示 `"Error: tool execution failed: Error: xxx"`。修复：tool 函数返回裸消息（如 `file not found: xxx`），agent 层统一加 `"Error: "` 前缀。四版本同步。
- **Edit 成功输出不统一**：Bash 版输出 `Edit(path) [+N -N lines]`，缺少 `Success:` 前缀，与 Read/Write 风格不一致。统一为 `Success: Edit(path) [+N -N lines]`。四版本同步。
- **Edit Hint 改进**：`old_string not found` 的提示从 "Read the file and copy exact bytes" 改为 "use Grep to locate the target lines, then Read the relevant portion (with offset/limit)"，更具体地引导 LLM 正确操作。
- **DP_MIN_KEEP_RATIO 默认值不一致**：Go (`0.12`)、Rust 测试 (`0.12`)、C force compact 路径 (`0.12`) 与 Bash 基准 (`0.25`) 不一致。统一为 `0.25`，文档同步更新。

### Changed

- **C 版 DP 配置结构体重构**：新增 `DPConfig` struct + `dp_config_init()` 函数，在 `agent_create()` 时初始化一次存入 `agent->dp_cfg`；`compact_dp_decision()` 改为接收 `const DPConfig*` 参数，`agent_compact_context()` 直接使用 `agent->dp_cfg`，消除 3 处散落的环境变量读取。

### Added

- **扫描器单元测试**：Bash (test.sh Test 51, 35 用例)、Go (agent_test.go, 30 用例)、Rust (tools.rs, 25 用例)、C (test_classify.c, 24 用例)，覆盖基本路径、CWD 绝对路径、复合命令（`&&`/`||`/`;`/`|`）、三段复合、heredoc+exec、git push 等场景。

---

## [4.2.4] - 2025-06-08

> **Bugfix + 一致性版本**：修复 compact 错误处理缺失守卫导致全零 usage 事件；Go 版补充 SSE RETRY 事件处理。

### Fixed

- **C compact ConvTrimTail 缺少条件守卫**：`store_conv_trim_tail` 在 `keep >= line_count` 时仍然执行截断（可能清空整个文件）。添加 `if (keep < line_count)` 条件守卫，对齐 Go/Rust/Bash 版本。
- **C compact usage 写入缺少守卫**：compact LLM 调用失败时可能产生全零 token 数据，仍写入 stats 和 usage 事件。添加 `if (compact_in > 0 || compact_out > 0 || compact_cr > 0 || compact_cc > 0)` 条件守卫，对齐 Go 版。
- **C SSE RETRY token 重置不完整**：`sse_accum_callback` 处理 `SSE_RETRY` 时未重置 `in_tokens`/`out_tokens`/`cache_read_tokens`/`cache_creation_tokens`，导致 RETRY 后累积了错误的 token 计数。补充四个字段重置，对齐 `stream_display_callback`。
- **Go SSE 解析器缺少 retry 事件处理**：`parseSSEStream` 未处理 `event: retry` 类型的 SSE 事件。新增 `case "retry":` 重置所有解析层局部状态（blockType/toolName/toolID/partialJSON/stopReason/token 计数），并发送 `EventRetry`。
- **Go Agent 层缺少 EventRetry 处理**：RunLoop 事件循环未处理 `EventRetry` 事件，导致 RETRY 后旧的 text/thinking/toolCalls/toolResults 残留。新增 `case EventRetry:` 清空所有累积状态，对齐 Rust 版。

---

## [4.2.3] - 2026-06-07

> **Bugfix + DP 优化版本**：修复 summary 调用硬编码 max_tokens；DP 压缩添加 max_keep 上限防止无效压缩；统一默认配置值。

### Changed

- **默认配置值统一**：四版本 `MAX_TOKENS` 从 `4096` 调整为 `16384`，`MAX_TURNS` 从 `40`/`500` 统一为 `1000`。

### Fixed

- **Go summary 调用 max_tokens 硬编码**：`transport.go` 中 summary LLM 调用的 `max_tokens` 硬编码为 `4096`，改为使用配置值 `t.cfg.MaxTokens`。
- **C summary 调用 max_tokens 硬编码**：`agent.c` 中 summary 调用的 `max_tokens` 硬编码为 `1024`，改为使用配置值 `agent->max_tokens`。

### Added

- **DP 压缩 max_keep 上限**：为 DP 压缩决策算法添加 `max_keep` 上限（`NR × (1 - min_keep_ratio)`），当保留行数超过上限时压缩收益太低，不值得消耗一次 LLM summary 调用。防止 turn-alignment 将实际保留率膨胀到 80%+。当 `min_keep_ratio > 0.5` 时自动退回无上限，尊重用户保守偏好。四版本（AWK/Go/Rust/C）同步实现。

---

## [4.2.2] - 2026-06-06

> **Bugfix + UX 版本**：iTerm2 进度波纹指示器；修复 Edit diff 颜色行计数；修复 linenoise 光标延迟折行覆盖。

### Added

- **iTerm2 进度波纹**：busy 时在标题栏下方显示波纹动画（`OSC 9;4;3`），idle 时清除（`OSC 9;4;0`）。与 OSC 0 标题在同一次 write 输出，非 iTerm2 终端静默忽略。

### Fixed

- **Edit diff 颜色**：C/Go 版 Edit 工具调用 `diff -u --color=always`，输出带颜色高亮的统一格式 diff。
- **Edit diff 行计数**：`diff --color=always` 可能输出多个连续 ANSI escape（如 `\x1b[01m\x1b[32m`），改为循环跳过所有连续 escape 再统计 `+`/`-` 行数。修复 `[+0 -N lines]` 导致 AI 误判编辑失败而重试。
- **Read 工具行计数**：统一四版本行计数为 awk NR 语义（`\n` 计数，末尾无 `\n` 则 +1），修复 `[0 lines]` 显示。
- **linenoise 延迟折行覆盖**：当输出恰好填满终端宽度时，终端进入 delayed wrap 状态。`simulateCursorColEx` 检测 `at_margin` 标志，在 OPOST 仍开着时输出空格触发实际换行，避免后续光标恢复到错误位置覆盖已有内容。
- **linenoisePrintf 内存**：256KB 栈缓冲改为 4KB 栈缓冲 + 堆分配回退，避免大格式化输出的栈浪费。
- **idle 标题时机**：将 `display_term_title("idle")` 从调用者移入 `agent_run_loop` wrapper 内部（对齐 Bash 版），确保所有退出路径（正常、中断、错误、子 agent 结果）都清除 iTerm2 进度波纹。

---

## [4.2.1] - 2026-06-05

> **UX 版本**：终端标题增加 ⏳ 沙漏状态指示，直观显示 agent 处理状态；新增版本架构一致性规则。

### Changed

- **终端标题 busy/idle 指示**：OSC 标题增加 ⏳ 前缀，处理中显示 `⏳ model T:...`，空闲显示 `model T:...`。title 刷新由 stats update 驱动（默认 busy），agent_loop 结束后显式设 idle。Bash/Go/Rust/C 四版本同步实现。
- **版本架构一致性规则**：AGENT.md 新增架构逻辑一致性要求，明确 Bash 版为主线、C/Go/Rust 为 Port 版本必须复刻主线，三个 Port 版本之间差异也必须保持一致。

---

## [4.2.0] - 2026-06-05

> **Architecture 版本**：统一 linenoiseWrite 原子显示输出，C/Go/Rust 三版本共用同一套 Hide→OPOST→Write→Show 同步机制；新增 Ctrl+C 中断 agent 能力；修复 Rust 段错误和 Ctrl+V 粘贴。

### Changed

- **统一 linenoiseWrite 原子显示架构**：在 `vendor/linenoise/linenoise.c` 中新增 `linenoiseWrite`/`linenoisePrintf`，单次调用原子完成 Lock→Hide→恢复光标→OPOST 开→写入→OPOST 关→光标跟踪→Show→Unlock。上层 display 代码不再需要手动管理 begin/end、列跟踪或 Hide/Show 配对。C/Go/Rust 三版本统一使用此接口。
- **CJK 光标跟踪**：新增 `simulateCursorCol` 逐字符模拟终端折行，正确处理宽字符放不下时的换行和恰好填满行的延迟折行，替代原来有 bug 的 `linenoiseNormalizeOutputCol`。
- **Ctrl+C 中断 agent**：readline 线程检测 Ctrl+C（linenoise 返回 EAGAIN），通过 `running` 标志判断是否正在执行 agent，若是则设置 `interrupted` 中断正在进行的 SSE/HTTP 请求；空闲状态仅重新显示提示符。
- **Go linenoiseState C 分配**：`LinenoiseState` 改为通过 `C.malloc` 分配，避免 cgo 指针传递给 C 代码存储的违规问题。
- **Thinking 颜色原子性**：Go 版 thinking 流式输出的 `\033[90m` + content + `\033[0m` 合并为单次 `linenoiseWrite` 调用，防止 Show 重绘 prompt 时 `\033[0m` 重置终端颜色。
- **图片描述提示词统一**：C/Rust 版本同步 bash/go 版本的 describe 提示词，增加"separated by a blank line between images"等细节。
- **移除未使用的 vendor 函数**：`readline_display_begin/end`、`linenoiseEditLock/Unlock`、`linenoiseNormalizeOutputCol`、`linenoiseUtf8StrWidth`。

### Fixed

- **Rust 段错误（exit 退出）**：`LinenoiseState` 声明为 `[u8; 0]`（零大小），导致栈分配不足，C 函数写入无效内存。修复为 `[u64; 64]`（512 字节）。
- **Rust Ctrl+V 粘贴失效**：AppleScript 中 `coaccess theFile` 拼写错误，应为 `close access theFile`，导致 osascript 执行失败。
- **Go ToolCall 名称重复**：`CallSummary` 已返回 `name(args)` 格式，display 层又包了一层变成 `name(name(args))`。

---

## [4.1.1] - 2026-06-03

> **Bugfix + Refactor 版本**：重构 linenoise 交互为 Hide/Show 架构替代 done 信号阻塞方案，彻底解决 display 与 readline 的终端竞争；修复缓存命中率 / token 计数溢出；image expand 流程精简。

### Changed

- **linenoise Hide/Show 架构替代 done 信号阻塞**：readline 线程不再阻塞等待 done，改为 EditStart/EditFeed/EditStop 循环；display worker 每个 chunk 输出时加锁 → Hide → 写 stdout → Show → 解锁；去掉 doneCh / done channel / done_mutex+cond 同步机制。SSE chunk 间（~50ms）微秒级 hide→write→show，不阻塞 readline，Ctrl+C 更响应（`928e76a`）
- **image expand 流程精简**：从外层移入 agent_loop 内部，简化代码逻辑，修复截断和细节问题（`0bf9126`, `541cb78`, `995c8a4`, `d1d30b9`, `42b8071`）
- **同步 bash 调整到 C/Go/Rust**：e2e 测试增加 events 校验（`f4b0d92`）
- **简化 replay 逻辑**：移除累积量计算（`d6e9d5f`）

### Fixed

- **C/Rust display 排版错乱**：修复 linenoise 提示符与 display 输出竞争导致的文字交叠（`9a2b9d7`）
- **Rust sub-agent 结果渲染竞争**：防止 sub-agent 结果渲染时 linenoise 和 display worker 竞争 stdout（`aa9d5ca`）
- **C 版 replay 后 flush display**：防止 replay 后 display 残留与 readline 竞争终端；清行后重置 last_char（`8e6f9c0`）
- **C 版缓存命中率 int 溢出**：缓存命中率计算使用 int 导致溢出，大 session 显示 -1%，改用 long long（`c5fffa7`）
- **token 计数溢出**：token 计数改用 long long 防止大 session 溢出（`7c90d08`）
- **IMAGE_DESCRIBE display 不截断描述**：修复图片描述内容被错误截断的问题（`42b8071`）

---

## [4.1.0] - 2026-06-03

> **Feature 版本**：新增图片粘贴支持 — Ctrl+V 贴图，自动调用 GLM-4V-Flash 转录/描述，四版本同步实现。

### Added

- **图片粘贴支持**：终端交互模式下 **Ctrl+V** 从剪贴板粘贴图片，自动插入 `[Image #N]` 占位符并保存到 session 缓存。跨平台支持 macOS (osascript)、Wayland (wl-paste)、X11 (xclip)
- **自动图片描述**：发送消息时收集所有 `[Image #N]` 图片，一次性调用 **GLM-4V-Flash**（免费视觉模型）获取文本转录/描述，以 `<attached-images>` XML 标签追加到用户输入末尾
- **新增环境变量**：`DESCRIBE_API_KEY` / `DESCRIBE_MODEL`（默认 `glm-4v-flash`） / `DESCRIBE_BASE_URL`（默认 `https://open.bigmodel.cn/api/paas/v4`），统一前缀配置图片描述 API
- **linenoise 新增 `linenoiseSetImagePasteCallback()` API**：三个版本共享同一份 `vendor/linenoise` 源码，支持 Ctrl+V 自定义回调解耦

### Fixed

- C 版本非交互模式（`prompt`/stdin）未调用 `agent_main_loop`，导致图片占位符未展开。重构为统一走 `agent_main_loop`，与 Bash 结构对齐

### Tests

- Test 50 重构为 e2e 测试：创建 session 图片 → 运行 agent → 检查 conversation.jsonl 中 `<attached-images>` 标签，所有代理版本均可覆盖
- C/Go/Rust 三版本编译零警告通过

---

## [4.0.7] - 2026-06-03

> **Bugfix + Chore 版本**：修复 DP 成本模型默认 pricing 值、SubAgent 结果显示格式、C/Go Bash 调用摘要缺失换行替换；tool_file_summary 新增 offset/limit 范围信息并同步四版本；tools.json 统一为 go/tools.json symlink，新增 golden 验证脚本确保系统提示词一致性。

### Fixed

- 修复 compact_dp.awk 默认 DP_P_INPUT/DP_P_OUT pricing 值，使压缩决策在未显式配置时使用合理经济模型
- 修复 SubAgent 结果显示格式，补全 `in=` / `out=` 统计信息
- 修复 C/Go 版本 Bash 调用摘要缺少替换（`\n` → `\\n`）和截断，与 Bash/Rust 版本对齐
- 修复 `tool_file_summary` 未显示 offset/limit 范围信息的问题，四版本（Bash/C/Go/Rust）同步增强

### Changed

- `go/tools.json` 设为权威源，`src/tools.json`、`rust/src/tools.json`、`c/tools.json` 改为 symlink，消除 drift 风险
- 新增 `scripts/update-system-prompt-golden.sh`（193 行），参数化 home/path/platform/shell，支持 `en_US` 和 `zh_CN` 双 locale
- 新增 `make update-system-prompt-golden` target，将 Golden 验证纳入 CI 可重复流程
- `Makefile` 删除冗余的 `test-tools-json` 等目标，简化构建配置

### Tests

- Golden 模板 `tests/fixtures/system_prompt_expected.txt` / `.zh_CN` 各 92 行，`make test-bash` 130/130 通过，golden 可复现零 diff
- `tools.json` SHA256 四版本一致验证通过

## [4.0.6] - 2026-06-02

> **Bugfix 版本**：修复 C 版本 Edit 工具 diff 行数统计、对齐三版本 DP compact 实现、修复 Go 版本统计计算 bug、修复 compact 后 current_turn_count 被错误重置的问题。同时更新默认 Bash 工具网络权限为读写模式。

### Fixed

- 修复 C 版本 Edit 工具先写文件再生成 diff 导致统计错误的问题（`c/tools.c`）
- 对齐 C/Go/Rust 三版本 DP compact 实现（`isRealUserLine` / `compact_turn_keep` / DP 参数）
- 修复 Go 版本 avg input tokens 计算使用 `TurnCount` 而非 `TotalRequests` 的 bug（`go/store.go`）
- 统一 `tool_call_summary` 输出格式（无参数工具显示 `name()` 而非 `name`）
- 修复 Bash/Go/Rust/C 四版本 compact 后 `current_turn_count` 被错误重置的问题（应为 session 全局累计计数）

### Changed

- C/Go/Rust 三版本 `isRealUserLine` 统一使用 JSON 解析识别真实用户行
- C/Go/Rust 三版本 `compact_turn_keep` 统一使用 turn 比例保留策略，避免截断 tool_result
- C/Go/Rust 三版本 DP 参数对齐（V=5000, S=500, R=0.8, Beta=0.03, L calculated）
- **默认 BASH_AGENT_BASH_MODE 从 0447 更新为 0467**（network 权限从 read-only 改为 read+write），四版本默认值同步更新（`src/agent.sh` / `rust/src/tools.rs` / `go/tools.go` / `c/tools.c`）
- 更新四版本 CLI 帮助文本与文档（README/README.en/docs/bash-tool-policy.md/docs/tools.md）中的默认权限说明
- 测试 fixture 保持 0447 以验证旧模式兼容性

### Tests

- 新增测试验证压缩边界不对齐到 `tool_result` 数组行
- C/Go/Rust e2e 回归验证通过：`130 passed, 0 failed`

---

## [4.0.5] - 2026-05-29

> **Bugfix 版本**：修复 C 版本 OpenAI 工具调用链、工具结果处理与交互首屏显示问题；同时修复 Bash 版本 OpenAI tools 描述的 JSON 转义错误。

### Fixed

- 修复 C 版本 OpenAI Chat Completions 路径下的工具调用兼容链，补齐 `tool_calls` 聚合与统一事件转换
- 修复 C 版本 OpenAI body conversion 中的 JSON 构造错误，避免真实兼容端下工具调用失效
- 修复 C 版本 `Glob` / `Grep` 空结果时的空指针解引用崩溃
- 修复 C 版本 `Edit` 写回失败后仍返回成功的问题，写文件失败时现在直接报错
- 修复 C 版本交互模式 fresh session 首屏多余空行，仅在真正 replay 历史内容后追加分隔换行
- 修复 C 版本 `Glob` / `Grep` 的 shell 参数 quoting，避免 `popen()` 路径下参数展开与注入风险
- 修复 Bash 版本 OpenAI tool request body 中 `description` 未正确 JSON 转义的问题

### Changed

- C 版本 `assistant(tool_use)` 与 `tool_result` 的 conversation 持久化顺序对齐 Bash / Go / Rust
- Go 版本 OpenAI 多 tool call 分片聚合改为按 `index` 处理，与 Rust / C 保持一致
- `Glob` / `Grep` no-match 结果统一对齐为返回空字符串，不再使用额外占位文案
- `Test 11a` 改为结构化检查 OpenAI request body，失败时不再打印超长原始请求体

### Tests

- mock server 补强 OpenAI `delta.tool_calls` 分片与多工具同轮调用场景
- 新增 OpenAI tool-call e2e、`Glob/Grep` no-match、tool_result 持久化顺序等回归测试
- C / Go / Rust e2e 回归验证通过：`130 passed, 0 failed`

## [4.0.4] - 2026-05-29

> **Bugfix + Docs 版本**：修复 C 版本在 OpenAI Chat Completions 接口下的请求体转换问题，补齐工具调用语义；同时同步更新主文档、wiki 与 gh-pages 中的 Bash 权限模型说明。

### Fixed

- 修复 C 版本在 `--provider openai` 下仍向 `/chat/completions` 发送 Claude 风格请求体的问题
- C 版本 OpenAI body conversion 现正确转换 `system`、`messages`、`tools`、assistant `tool_use`、user `tool_result`
- 修复 C 版本长会话 compact / summary 请求在 OpenAI 模式下未走 body conversion 的问题
- 对齐 C 版本 OpenAI 请求头，不再额外发送仅 Claude 路径使用的 `x-app` header

### Added

- 新增 C 版 OpenAI request body 回归测试，直接检查 mock `/last-request` 中的 `tools[].type=function` / `parameters`
- 新增 `docs/bash-tool-policy.md`，集中说明 Bash 工具权限模型、scope 分类与推荐配置
- wiki 新增中英文 Bash 工具权限模式设计页，并在首页加入入口

### Changed

- README / README.en 同步更新为四运行时描述（bash/c/go/rust）、5 个安装命令说明与 13 个内置工具列表
- `docs/tools.md` 补充 Bash 工具权限模式说明与统一阻断报错格式
- gh-pages 工具区将 Bash 单独拆成一张卡片，并改为以 4 个 scope + 3 个权限位解释权限模型

### Tests

- C 版 e2e 回归验证通过：`125 passed, 0 failed`

## [4.0.3] - 2026-05-29

> **Feature + Bugfix 版本**：为 Bash 工具引入 `BASH_AGENT_BASH_MODE` 权限模式，并同步对齐 C/Go/Rust；同时将测试 mock server 提取为独立 Python 文件，修复 CI 中 `Argument list too long`。

### Added

- 新增 `BASH_AGENT_BASH_MODE` 环境变量，使用 4 位八进制描述 `system/external/network/workspace` 的 `read/write/execute` 权限
- README / README.en 与 Go/C/Rust CLI help 补充 `BASH_AGENT_BASH_MODE` 说明
- Go/Rust 新增 Bash mode classifier / allows 单测
- e2e 新增更细粒度的 12-bit 权限覆盖，直接断言 `required=` / `allowed=` 组合

### Changed

- Bash 主版本将 Bash 工具安全策略从旧的 deny-reason 规则切换为 mode-based 判定
- C/Go/Rust Bash 工具安全策略同步切换为与 Bash 主版本一致的 mode classifier / allows 逻辑
- 测试中的 mock server 从 `tests/test.sh` 内嵌 Python 改为独立文件 `tests/fixtures/mock_server.py`

### Fixed

- 无效 `BASH_AGENT_BASH_MODE` 统一 fail-closed 为 `0000`
- C/Go/Rust 的 Bash 工具阻断报错文案统一为 `required=... allowed=...`
- 修复 CI 中 `python3 -c "<超长 mock server>"` 触发的 `Argument list too long`

### Tests

- 覆盖 `system read`、`network execute`、`external write`、invalid mode fail-closed、custom mode allow system read
- 主 Bash 版 e2e 回归验证通过：`124 passed, 0 failed`
- Go e2e / C e2e 均通过：`124 passed, 0 failed`

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

[Unreleased]: https://github.com/lloydzhou/bash-agent/compare/v4.3.3...HEAD
[4.3.3]: https://github.com/lloydzhou/bash-agent/compare/v4.3.2...v4.3.3
[4.3.2]: https://github.com/lloydzhou/bash-agent/compare/v4.3.1...v4.3.2
[4.3.1]: https://github.com/lloydzhou/bash-agent/compare/v4.3.0...v4.3.1
[4.3.0]: https://github.com/lloydzhou/bash-agent/compare/v4.2.21...v4.3.0
[4.2.21]: https://github.com/lloydzhou/bash-agent/compare/v4.2.20...v4.2.21
[4.2.20]: https://github.com/lloydzhou/bash-agent/compare/v4.2.19...v4.2.20
[4.2.19]: https://github.com/lloydzhou/bash-agent/compare/v4.2.18...v4.2.19
[4.2.18]: https://github.com/lloydzhou/bash-agent/compare/v4.2.17...v4.2.18
[4.2.17]: https://github.com/lloydzhou/bash-agent/compare/v4.2.16...v4.2.17
[4.2.16]: https://github.com/lloydzhou/bash-agent/compare/v4.2.15...v4.2.16
[4.2.15]: https://github.com/lloydzhou/bash-agent/compare/v4.2.14...v4.2.15
[4.2.14]: https://github.com/lloydzhou/bash-agent/compare/v4.2.13...v4.2.14
[4.2.13]: https://github.com/lloydzhou/bash-agent/compare/v4.2.12...v4.2.13
[4.2.12]: https://github.com/lloydzhou/bash-agent/compare/v4.2.11...v4.2.12
[4.2.11]: https://github.com/lloydzhou/bash-agent/compare/v4.2.10...v4.2.11
[4.2.10]: https://github.com/lloydzhou/bash-agent/compare/v4.2.9...v4.2.10
[4.2.9]: https://github.com/lloydzhou/bash-agent/compare/v4.2.8...v4.2.9
[4.2.8]: https://github.com/lloydzhou/bash-agent/compare/v4.2.7...v4.2.8
[4.2.7]: https://github.com/lloydzhou/bash-agent/compare/v4.2.6...v4.2.7
[4.2.6]: https://github.com/lloydzhou/bash-agent/compare/v4.2.5...v4.2.6
[4.2.5]: https://github.com/lloydzhou/bash-agent/compare/v4.2.4...v4.2.5
[4.2.4]: https://github.com/lloydzhou/bash-agent/compare/v4.2.3...v4.2.4
[4.2.3]: https://github.com/lloydzhou/bash-agent/compare/v4.2.2...v4.2.3
[4.2.2]: https://github.com/lloydzhou/bash-agent/compare/v4.2.1...v4.2.2
[4.2.1]: https://github.com/lloydzhou/bash-agent/compare/v4.2.0...v4.2.1
[4.2.0]: https://github.com/lloydzhou/bash-agent/compare/v4.1.1...v4.2.0
[4.1.1]: https://github.com/lloydzhou/bash-agent/compare/v4.1.0...v4.1.1
[4.1.0]: https://github.com/lloydzhou/bash-agent/compare/v4.0.7...v4.1.0
[4.0.7]: https://github.com/lloydzhou/bash-agent/compare/v4.0.6...v4.0.7
[4.0.6]: https://github.com/lloydzhou/bash-agent/compare/v4.0.5...v4.0.6
[4.0.5]: https://github.com/lloydzhou/bash-agent/compare/v4.0.4...v4.0.5
[4.0.4]: https://github.com/lloydzhou/bash-agent/compare/v4.0.3...v4.0.4
[4.0.3]: https://github.com/lloydzhou/bash-agent/compare/v4.0.2...v4.0.3
[4.0.2]: https://github.com/lloydzhou/bash-agent/compare/v4.0.1...v4.0.2
[4.0.1]: https://github.com/lloydzhou/bash-agent/compare/v4.0.0...v4.0.1
[4.0.0]: https://github.com/lloydzhou/bash-agent/compare/v3.0.7...v4.0.0
[3.0.7]: https://github.com/lloydzhou/bash-agent/compare/v3.0.6...v3.0.7
[3.0.6]: https://github.com/lloydzhou/bash-agent/compare/v3.0.5...v3.0.6
[3.0.5]: https://github.com/lloydzhou/bash-agent/compare/v3.0.4...v3.0.5
[3.0.4]: https://github.com/lloydzhou/bash-agent/compare/v3.0.3...v3.0.4
[3.0.3]: https://github.com/lloydzhou/bash-agent/compare/v3.0.2...v3.0.3
[3.0.2]: https://github.com/lloydzhou/bash-agent/compare/v3.0.1...v3.0.2
[3.0.1]: https://github.com/lloydzhou/bash-agent/compare/v3.0.0...v3.0.1
[3.0.0]: https://github.com/lloydzhou/bash-agent/compare/v2.5.2...v3.0.0
[2.5.3]: https://github.com/lloydzhou/bash-agent/compare/v2.5.2...v2.5.3
[2.5.2]: https://github.com/lloydzhou/bash-agent/compare/v2.5.1...v2.5.2
[2.5.1]: https://github.com/lloydzhou/bash-agent/compare/v2.5.0...v2.5.1
[2.5.0]: https://github.com/lloydzhou/bash-agent/compare/v2.4.1...v2.5.0
[2.4.1]: https://github.com/lloydzhou/bash-agent/compare/v2.4.0...v2.4.1
[2.4.0]: https://github.com/lloydzhou/bash-agent/compare/v2.3.2...v2.4.0
[2.3.2]: https://github.com/lloydzhou/bash-agent/compare/v2.3.1...v2.3.2
[2.3.1]: https://github.com/lloydzhou/bash-agent/compare/v2.3.0...v2.3.1
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
