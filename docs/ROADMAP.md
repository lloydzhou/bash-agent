# 长期优化路线图

> 本文档记录 bash-agent 的长期优化方向和优先级排序。
> 标注适用范围：**bash** / **go/rust** / **三端**。

---

## P0 — 关键体验

### 1. 进程隔离输入与 Agent 循环

**适用范围**：go / rust

**现状**：`interactive_mode` 中读取输入和 `agent_loop` 在同一个主进程，agent 执行工具或等待 API 时整个进程阻塞，无法接收新输入。

**方案**：
- ~~**bash**：用 `coproc` 将输入监听放到独立进程，通过管道与主循环通信。~~ 放弃 — bash 3.2 不支持 coproc；named pipe 替代方案在多行输入、scroll region 溢出、readline 兼容性等方面问题多，得不偿失。
- **go**：独立 goroutine 读取 stdin，通过 channel 将输入发送到 agent 主循环。
- **rust**：`tokio::spawn` 独立任务读取 stdin，通过 `mpsc` channel 通信。

**状态**：❌ bash 放弃；go/rust ⬚ 待开始

---

### 2. ~~trap 信号代替轮询 ESC 监听~~

**适用范围**：bash

**状态**：✅ 已完成（`c86cd36`）— 已用 Ctrl+C (SIGINT) 替代后台子进程 ESC 轮询。

---

## P1 — 性能与可靠性

### 3. 流式解析性能（bash-only）

**适用范围**：bash

**现状**：`read_message` 使用 `dd bs=1 count=$((_len + 2))` 逐字节读取，性能低下，且容易因网络波动或缓冲区问题导致解析错误。go/rust 使用 `json.Unmarshal` / `serde_json` 不存在此问题。

**方案**：批量读取到缓冲区，再用索引定位，避免逐字节 `dd`。

**状态**：✅ 已完成（`read -r -d '' -n` 批量读取替代 `dd bs=1`）

---

### 4. API 重试与错误恢复

**适用范围**：三端

**现状**：
- bash: `curl --retry 2`，缺少延迟退避（429 限流、5xx）。
- go/rust: 有基本重试但未解析 `Retry-After` 头。
- 工具执行失败后错误信息直接拼入上下文，可能导致 agent 混乱。

**方案**：
- 实现指数退避重试，解析 `Retry-After` 头。
- 区分工具错误类型（超时 / 权限 / 其他），对可恢复错误自动重试。

**状态**：⬚ 待开始

---

## P2 — 大会话与用户体验

### 5. 上下文压缩效率

**适用范围**：三端

**现状**：
- bash: `compact_context_window` 每次压缩需创建临时文件、读取全部对话历史并重写，大会话性能差。
- go/rust: 已有内存缓冲区，但压缩时仍需全量重写会话文件。

**方案**：
- bash: 分段文件存储，压缩时只替换需要替换的段。
- go/rust: 用内存环状缓冲区维护最近 N 轮对话，减少磁盘 I/O。

**状态**：⬚ 待开始

---

### 6. 配置文件支持

**适用范围**：三端

**现状**：所有配置通过命令行参数或环境变量，没有配置文件。对固定工作流不友好。

**方案**：支持 `~/.bash-agent/config` 和项目级 `.bash-agent/config`，分层配置覆盖（环境变量 > 项目配置 > 全局配置 > 默认值）。

**状态**：⬚ 待开始

---

## P3 — 扩展性与安全

### 7. 工具插件化

**适用范围**：三端

**现状**：`dispatch_tool` 使用 `case` 硬编码，新增工具需修改多处代码。

**方案**：实现工具插件机制，支持从配置文件或独立脚本动态加载工具，类似 MCP 协议子集。

**状态**：⬚ 待开始

---

### 8. 安全沙箱增强

**适用范围**：三端

**现状**：`deny_bash_command_reason` 只做模式匹配的危险命令拦截。

**方案**：支持可选的 Docker/容器隔离执行，或使用 bubblewrap/firejail 沙箱化。

**状态**：⬚ 待开始

---

### 9. 状态持久化原子性（bash-only）

**适用范围**：bash

**现状**：`conv_add_user` 等函数直接 append 到文件，无锁机制，多进程并发写会损坏。go/rust 有文件锁机制。

**方案**：使用 `flock` 对会话文件加排他锁，确保写操作原子性。

**状态**：⬚ 待开始

---

## P4 — 测试与可观测性

### 10. 测试与日志

**适用范围**：三端

**现状**：核心路径有 bats 集成测试（47 个），但缺少单元测试和性能基准。调试仅靠 `VERBOSE` 打印。

**方案**：
- bash: 核心函数（`json_escape`、`tool_read`、`compact_dp_decision`）添加 bats 测试。
- go/rust: 添加 table-driven 单元测试和基准测试。
- 结构化日志，支持按级别过滤。

**状态**：⬚ 待开始

---

## 已完成

### SubAgent 内置工具

**适用范围**：bash

**状态**：✅ 已完成（`000d11e`）

- `SubAgent` 工具：启动独立子 agent 会话，子 agent 拥有独立 conversation context
- 子 agent 完成后结果以 user message 注入父会话
- 同一轮多个 SubAgent 并发执行
- 系统提示词新增 `sub-agent-guidance` section，指导何时使用/不使用、prompt 设计、结果处理
- 全量测试通过（73 passed）

### FIFO 会话子目录隔离

**适用范围**：bash

**状态**：✅ 已完成（`ce66b4d`）

- 对话历史存储路径从 `~/.bash-agent/projects/<key>/` 迁移至 `~/.bash-agent/projects/<key>/<session_id>/`
- 每个会话独立子目录，避免多会话互相覆盖
- 统一 FIFO 架构（`bc78082`）

### history 文件写入修复

**适用范围**：bash

**状态**：✅ 已完成（`000d11e`）

- 子 shell 中 `history -s/-a/-w` 无效，改用 `printf >>` 追加写入
- `history -w` 是覆盖写入，父 shell 退出时会覆盖子 shell 的追加内容，已修复为正确的追加策略

### C 运行时

**适用范围**：c

**状态**：✅ 已完成

- 纯 C 实现（`c/agent.c`），使用 `vendor/linenoise/linenoise.c` 作为交互输入库
- 支持 SSE 流式解析、所有 13 个内置工具、compact 压缩、SubAgent、Plan/Todo 等
- 四版本（Bash/Go/Rust/C）system prompt 和 tools.json 完全一致

### 统一 linenoise 输入体验

**适用范围**：c / go / rust

**状态**：✅ 已完成（v4.2.0）

- 统一 `linenoiseWrite`/`linenoisePrintf` 原子显示架构，C/Go/Rust 共用
- 支持 Ctrl+V 图片粘贴、Ctrl+C 中断 agent、iTerm2 进度波纹指示器
- 修复 delayed wrap 覆盖、栈内存浪费等问题

### 图片粘贴

**适用范围**：三端

**状态**：✅ 已完成

- 交互模式下 Ctrl+V 从剪贴板粘贴图片，自动插入 `[Image #N]` 占位符
- 调用 GLM-4V-Flash（免费）转录文字描述，支持 macOS/Linux
- 无 API key 时仍可粘贴（跳过描述步骤）

### 终端状态指示

**适用范围**：三端

**状态**：✅ 已完成（v4.2.1 / v4.2.2）

- OSC 标题 ⏳ busy / idle 指示
- iTerm2 进度波纹（`OSC 9;4;3`），非 iTerm2 终端静默忽略

### 默认配置统一

**适用范围**：三端

**状态**：✅ 已完成（v4.2.3）

- `MAX_TOKENS` 从 `4096` 统一为 `16384`
- `MAX_TURNS` 从 `40`/`500` 统一为 `1000`
