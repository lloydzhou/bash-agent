# 架构说明

## 项目定位

`bash-agent` 是一个纯 `bash`/`awk` 的轻量 agent 内核。

目标不是做完整平台，而是做一个：

- 可在终端独立运行的 agent
- 可被其他程序嵌入和编排的命令行内核
- 运行时依赖尽量少
- 协议和状态边界清楚

当前核心方向是：

- `bash` 负责流程、文件、进程、会话、请求调度
- `awk` 负责 JSON/SSE 解析、字符串变换、文本抽取
- 三个 runtime 都保持同样的交互分层：
  - stream 层负责状态机、事件消费、tool 执行
  - display 层负责终端输出
  - history 统一写入 `~/.bash-agent/history`

## 核心原则

- 保持单 agent、单进程主循环
- 机器协议优先，human 输出只是薄包装
- session 是一等公民
- context budget 是硬约束
- tool 边界必须可预测
- 扩展能力尽量不破坏主循环
- 优先减少重复，而不是追求“函数更少”

## 运行时分层

```text
stdin / args / env
        |
        v
src/agent.sh
├─ 配置与 CLI
├─ session/context 管理
├─ prompt 组装
├─ agent loop
├─ tool runtime
├─ API 请求
└─ stream-json / human 输出
        |
        v
src/awk/*
├─ JSON helper library
├─ JSON helper CLI entrypoints
├─ SSE parser
├─ 格式转换
├─ 协议 flatten / 文本抽取
└─ tool 专用变换
```

### `bash` 负责什么

- CLI 参数解析
- provider/model 选择
- session 初始化与恢复
- context 文件、summary、todo 文件管理
- prompt section 组装
- tool 分发与文件/进程控制
- API 请求
- main loop
- interactive history 读写

### `src/agent.sh` 当前停点

`src/agent.sh` 仍然是单文件主控脚本，但当前已经到一个合理停点：

- `compact_context_window()`
  - 可以保留少量真正有独立语义的 helper
  - 例如“按预算和 turn 边界计算保留窗口”
- `agent_loop_stream()`
  - 主循环内联执行 tool 调用，不再有独立的 `execute_tool_calls*` 函数
  - tool 调用、结果收集、conv 写入都在流解析过程中完成
  - 只有在未来出现新的稳定职责边界时才值得继续拆

这意味着后续优化应遵循：

- 只在拆分能形成稳定职责边界时才抽 helper
- 不为“函数更短”而拆
- 不把流程状态通过一堆薄壳函数来回传递

### `goagent` / `rustagent` 当前停点

Go 和 Rust 版本当前也保持和 bash 一致的两层结构：

- `agentLoopStream()`
  - 负责读取模型流、消费事件、执行 tool、维护会话状态
- `displayEvent()`
  - 负责把事件渲染到终端，或输出成 `stream-json`

这样做的目的不是复制同样的代码行数，而是让三端的职责边界一致：

- 交互状态只在 display 层处理
- 原始事件和会话状态只在 stream 层处理
- interactive history 统一使用 `~/.bash-agent/history`

### `awk` 负责什么

- JSON 字段提取
- JSON string escape/unescape
- `\uXXXX` 解码
- 轻量 tokenizer-style value reader
- SSE 事件解析
- OpenAI/Claude 消息格式转换
- `Edit` / `TodoWrite` 等需要文本变换的 tool 逻辑

## 当前核心能力

### 1. Session

session 数据按当前项目目录归档：

```text
~/.bash-agent/projects/<project_key>/<session_id>.jsonl
~/.bash-agent/projects/<project_key>/<session_id>.events.jsonl
~/.bash-agent/projects/<project_key>/<session_id>.summary.txt
~/.bash-agent/projects/<project_key>/<session_id>.todo.md
```

职责分工：

- `*.jsonl`
  - 当前真正发给模型的消息窗口
- `*.events.jsonl`
  - session 内部事件日志
- `*.summary.txt`
  - compact 后留下的历史摘要
- `*.todo.md`
  - 当前 session 的待办清单，由 `TodoWrite` 维护

### 2. Context / compact

compact 现在按 **context 实际大小** 触发，而不是按消息条数：

- `--max-context` 表示字节预算
- 支持 `100k` / `1m` 这类写法
- 超预算后会从旧消息中裁剪
- 但保留部分必须对齐到**完整 user turn 起点**

这条规则很重要：

- compact 不能把会话裁成孤立的 `tool_result`
- 不能只剩 `assistant.tool_use` 而丢掉对应用户请求
- 必须保留完整一轮消息的语义边界

当前默认策略：

- 总大小超预算时 compact
- 保留最新的预算后缀
- 但对齐到最近的完整 `user` 文本消息起点

当前 compact 也有一条明确约束：

- 自动 compact 不应重复做 provider/API 初始化检查
- 手动 compact 入口已移除，compact 仅在主循环内自动触发

### 3. Prompt 组装

system prompt 采用稳定 section 顺序拼装，而不是重型模板系统。

当前顺序：

1. `agent-identity`
2. `rules`
3. `todo-guidance`
4. `instruction-files`
5. `skill-index`
6. `selected-skills`
7. `context-summary`
8. `current-todo`
9. `instructions`

实现策略：

- `wrap_section()` 负责包裹 section
- `append_section()` 负责按顺序累加
- 稳定内容尽量前置
- 动态内容尽量后置

### 4. Skills

skills 当前优先读取：

```text
./.claude/skills/<name>/SKILL.md
./skills/<name>/SKILL.md
~/.claude/skills/<name>/SKILL.md
```

策略分两层：

- `skill-index`
  - 默认扫描所有可见 skill 目录的 `SKILL.md`
  - 只抽取简短摘要
- `selected-skills`
  - 只有显式 `--skill NAME` 时，才加载完整 `SKILL.md`
- `Skill` tool
  - 运行时先参考 `skill-index`
  - 再按 skill 名读取完整 `SKILL.md`
  - 只影响当前轮，不写回后续 system prompt

`SKILL.md` 支持：

- `${BASH_AGENT_SKILL_DIR}` 占位符

也就是说，目录内其他脚本/模板文件是“按需引用”的，不会自动递归注入。

### 5. Todo

现在的设计是：

- 使用内置 tool：`TodoWrite`
- `todo.md` 是 session 级状态
- 模型通过 tool 显式更新 checklist
- host 只负责保存状态

这种方式更接近 Claude Code 的做法，也更适合结构化维护 session 级待办状态。

### 6. Tools

当前传给模型的内置 tools：

- `Read`
- `Write`
- `Edit`
- `Bash`
- `Glob`
- `Grep`
- `TodoWrite`
- `Skill`

设计原则：

- 先做高频基础能力
- tool 输入结构化
- tool 输出尽量纯文本
- `tool_result` 写回前先清理 ANSI 控制字符

`Glob` / `Grep` 当前是最小 `rg` 版：

- `Glob`
  - 用 `rg --files -g`
- `Grep`
  - 用 `rg -n`
- 没有 `rg` 就报错，不做复杂 fallback

### 后续不该做什么

- 不要再让 bash 回去解析 JSON object
- 不要把 `json.awk` 再变回杂物间
- 不要为“更通用”引入更重的多行协议
- 不要把 `run_with_timeout()` 做成长 supervisor
- 不要继续为了缩短函数机械拆分 `agent_loop_stream()`

## Provider 与请求构造

当前 provider：

- `claude`
- `openai`

其中：

- `claude`
  - Anthropic Messages 兼容格式
- `openai`
  - Chat Completions 兼容格式

当前没有继续保留 `openai-responses`。

请求构造策略：

- source 中保留统一 `build_request()`
- provider-specific builder 只做必要差异
- 错误流通过 `http_stream.awk` 统一处理

## 中间协议

运行时内部和 `stream-json` 输出共用一套轻量事件边界。

### 内部 line protocol

内部 SSE 解析结果会先转成单行协议，例如：

- `TEXT:...`
- `TOOL_CALL:<tool>\t<id>\t<raw_input_json>\t<key>\t<value>...`
- `USAGE:<input_tokens>\t<output_tokens>\t<cache_input_tokens>`
- `STOP:...`
- `ERROR:...`

规则：

- 文本类事件先编码成单行
- 消费端再做反转义

当前已经统一的点：

- `TOOL_CALL` 保留原始 input JSON，同时由 awk 展平出 tool-specific args
- `USAGE` 走固定顺序的 typed fields
- `TEXT` 仍然走转义后的单行文本

### `stream-json`

`stream-json` 是对外机器协议。

当前事件类型：

- `text`
- `tool_call`
- `todo_update`
- `tool_result`
- `usage`
- `stop`
- `error`
- `context_update`

语义：

- 每行一个 JSON 事件
- 不混入 human 文本
- 不把 session 内部事件直接混入 stdout

`usage` 当前字段：

- `input_tokens`
- `output_tokens`
- `cache_input_tokens`

## 当前重要实现细节

### JSON 转义

`json_escape()` 现在已经收回 `awk/json.awk` / `awk/json_cli.awk`：

- 避免 bash 逐字节处理 UTF-8
- 正确处理中文、多行、引号
- 减少 `\u...` 错误转义问题

### HTTP 错误

`http_stream.awk` 现在会保留 `HTTP 4xx/5xx` 的 body：

- 不再只输出 `HTTP 400`
- 会透传错误体
- 便于定位兼容层问题

### `Read`

`Read` 和 `Bash` 现在共用 `TOOL_RESULT_MAX_BYTES`，默认是 `50KB`：

- 大文件仍然可能显著放大单轮请求体
- 如果文件更大，会返回截断提示

## 当前代码边界判断

### 应继续留在 `bash`

- `build_system_prompt()`
- session / compact 主流程
- tool 调度
- `curl` 调用
- 主循环

### 更适合继续留在 `awk`

- JSON 提取
- Unicode 解码
- SSE parser
- `protocol.awk` 负责中间协议 flatten
- `todo_protocol.awk` 负责 `TodoWrite` 规范化
- `Edit` 内容替换
- `skill`/plan 这类文本抽取逻辑

## 当前项目状态

当前主线已经稳定：

- session 持久化
- compact
- TodoWrite
- skills
- stream-json
- source/dist build
- 主要测试覆盖

目前测试状态：

- source 和 dist 都能跑通过测试

## 后续优先级

### P0

- 保持 tool / compact / session 语义稳定
- 继续修正 provider 兼容性问题
- 继续减少重复序列化逻辑

### P1

- 补强 `glob` / `grep` 的真实使用覆盖
- 继续审视 bash/awk 边界
- 必要时增加轻量配置项，例如 context keep 百分比、Read 上限
- 如果 provider 对输入大小更敏感，再考虑按模型侧限制进一步收紧 `Read`

### P2

- 如果确实需要，再评估：
  - skill tool 化
  - 更丰富的搜索工具
  - memory
  - worktree / subagent

## 不做什么

这些不属于当前 core：

- UI-first 设计
- 重型 TUI
- dashboard
- 分布式 agent 平台
- MCP/插件平台优先扩张
- 复杂多代理编排

核心优先级始终是：

- 纯 bash
- 0 额外运行时依赖
- 功能完备前提下的精简与可维护性
