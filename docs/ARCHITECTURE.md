# 架构说明

## 项目定位

`bash-agent` 是一个纯 `bash`/`awk` 的轻量 agent 内核。

目标不是做完整平台，而是做一个：

- 可在终端独立运行的 agent
- 可被其他程序嵌入和编排的命令行内核
- 运行时依赖尽量少
- 协议和状态边界清楚（awk → bash 使用 RESP-like 二进制安全协议）

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
- awk → bash 通信使用 RESP-like length-prefix 协议（CRLF 行结尾，二进制安全）
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
├─ RESP-like 协议输出 / 文本抽取
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
~/.bash-agent/projects/<project_key>/<session_id>/
    conversation.jsonl
    events.jsonl
    summary.txt
    todo.md
    plan.md
    stats.json
```

职责分工：

- `conversation.jsonl`
  - 当前真正发给模型的消息窗口
- `events.jsonl`
  - session 内部事件日志
- `summary.txt`
  - compact 后留下的历史摘要
- `todo.md`
  - 当前 session 的待办清单，由 `TodoWrite` 维护
- `plan.md`
  - 当前 session 的计划文档，由 `plan-lifecycle-guidance` 机制维护
- `stats.json`
  - session 统计数据（LLM 调用次数、输入 token 总量、compact 次数、当前 turn 等）

### 2. Context / compact

compact 使用**基于缓存经济学的动态规划算法**，在每一步计算压缩的净收益，自动决定是否压缩和保留多少消息。

#### 决策公式

$$
\begin{aligned}
\text{NetBenefit}(k) &= \frac{(R - 1) \cdot P_{\text{cache}} \cdot H}{10^6} \\
&- \frac{(S + K) \cdot (P_{\text{input}} - P_{\text{cache}})}{10^6} \\
&- \frac{P_{\text{cache}}(V + H) + P_{\text{input}} \cdot L_{\text{instr}} + P_{\text{out}} \cdot S}{10^6} \\
&- \frac{\beta \cdot (1 - r^{c+1}) \cdot R \cdot \text{avg} \cdot P_{\text{input}}}{10^6}
\end{aligned}
$$

- 若 $\max_k \text{NetBenefit}(k) > 0$，选择最优 $k$ 执行压缩
- 否则不压缩
- 安全阀：当 DP 说不压缩但 `current_context > max_context × 90%` 时，强制压缩

| 项 | 含义 |
|---|---|
| ① | 压缩后后续 $R-1$ 次 LLM 调用每次少发送 $H$ token，按缓存价节省 |
| ② | 摘要内容变化导致前缀缓存断裂，$S+K$ 个 token 从缓存价变为全价 |
| ③ | 压缩请求本身的 API 成本（缓存复用前缀 + 指令 + 输出） |
| ④ | 多次压缩的信息累积损失，$r_t = r^{c+1}$（下限 0.37） |

#### 核心变量

| 变量 | 含义 | 默认 |
|---|---|---|
| $R = E \times L$ | 预期剩余 LLM 调用总次数 | — |
| $E$ | 预期剩余用户输入轮数 | `max(DP_BASELINE_E - t, baseline/2)`，单调非递增 |
| $L$ | 每轮用户输入平均 LLM 调用次数 | 5（`DP_L=0` 时从 stats 自动计算） |
| $H = T_{\text{total}} - K$ | 被丢弃的旧消息 token 数 | 遍历 $k$ 计算 |
| $S$ | 固定摘要长度 | 500 token |
| $V$ | 固定前缀（system prompt + tools + old summary） | 5000 token |

#### Summary 调用的缓存复用

summary 调用（`run_summary_call`）采用与正常请求**完全相同的前缀结构**，以最大化 API 缓存命中：

```
正常请求：  [System prompt + Tools + Summary] + [全部消息]
summary请求：[System prompt + Tools + Summary] + [dropped 消息 H] + [summary 指令]
            ←────── 缓存命中，按 P_cache 计费 ──────→  ← P_input →
```

由于 dropped 消息是 CONV_FILE 开头的行，它们与之前请求中的前缀完全一致。summary 请求只追加了一条 user 消息作为总结指令，不影响前缀匹配。

以 Claude Sonnet 为例（无缓存 $3.00/MTok，缓存命中 $0.30/MTok），典型场景：system+tools+summary 5k tokens，dropped messages 30k tokens，summary 输出 500 tokens：

- **旧方案**：35k tokens 全部无缓存 → 输入 $0.105 + 输出 $0.0075 = **$0.1125**
- **新方案**：35k tokens 全部缓存命中 → 输入 $0.0105 + 输出 $0.0075 = **$0.018**

单次 compact 节省约 **84%**，复杂任务中多次触发时累积效应显著。

#### 保留窗口对齐

切分点始终对齐到**真实用户输入**（`"role":"user","content":"..."`），不会在工具结果处切断：

- 不能把会话裁成孤立的 `tool_result`
- 不能只剩 `assistant.tool_use` 而丢掉对应用户请求

> 完整推导见 [`dp-compact-analysis.md`](dp-compact-analysis.md)。

### 3. Session Replay

当恢复已有 session（`--continue` 或 `--session`）时，交互模式会回放最近 10 轮对话。

实现机制：

- 读取 `events.jsonl`，按 `user_input` / `user_message` 事件标记 turn 边界
- 取最后 10 个 turn 的事件序列
- 使用 `display_replay_event()`（Go/Rust）或 `event_replay.awk`（bash）将事件转为 REPL 兼容的 RESP 协议输出
- 回放文本/思考内容时累计延迟 flush，保证 thinking→text 边界处正确插入换行
- bash 版使用独立的 `src/awk/event_replay.awk` 文件，build 时内联到单文件发布版
- event_replay 依赖 TOOL_RESULT 事件中已附带的 file_summary 前缀（Read/Write 工具结果），因此回放时不需访问原始文件
- `session_start` / `usage` / `retry` 事件不回放

回放完成后输出一个空行分隔，再接交互提示符。

### 3. Prompt 组装

system prompt 采用稳定 section 顺序拼装，而不是重型模板系统。

当前顺序：

1. `agent-identity`
2. `rules`
3. `using-your-tools`
4. `todo-guidance`
5. `plan-lifecycle-guidance`
6. `instruction-files`
7. `skill-index`
8. `selected-skills`
9. `current-plan`
10. `context-summary`
11. `current-todo`

实现策略：

- `wrap_section()` 负责包裹 section
- `append_section()` 负责按顺序累加
- 稳定内容尽量前置
- 动态内容尽量后置

`using-your-tools` 指导模型如何正确使用各内置 tool。

`plan-lifecycle-guidance` 为复杂多步任务提供规划工作流（写 PLAN_FILE → 确认 → TodoWrite checklist → 执行 → 清空 plan），由 `PLAN_FILE` 环境变量标识当前 session 的 plan 路径。

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
- `WebSearch`
- `WebFetch`

设计原则：

- 先做高频基础能力
- tool 输入结构化
- tool 输出尽量纯文本
- `tool_result` 写回前先清理 ANSI 控制字符

`Glob` / `Grep` 当前是最小 `rg` 版：

- `Glob`
  - 用 `rg --files -g`
  - 支持 `path` 参数指定搜索目录
- `Grep`
  - 用 `rg -n`
  - 支持 `path`（搜索路径）、`glob`（文件过滤）、`context`（上下文行数）
  - `context` 可显示匹配行前后 N 行
- 没有 `rg` 就报错，不做复杂 fallback

`Read` 支持通过 `offset` 和 `limit` 参数读取文件指定行范围，避免大文件整文件读取。

`Bash` 支持通过 `timeout` 参数为单条命令设置独立超时，覆盖全局 `--tool-timeout`。

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

### Thinking / Reasoning

通过环境变量 `THINKING_BUDGET` 控制（默认 `2048`）：

- `claude`：发送 `thinking.type=enabled, budget_tokens=N`
- `openai`：发送 `reasoning_effort=high`（统一值，不按模型名分支）
- summary 调用复用 `THINKING_BUDGET` 以保持 API 缓存前缀一致性

消息转换时，assistant 的 `thinking` content block 会被跳过（OpenAI 格式不支持 thinking block）。

SSE 流中：
- Claude 的 `content_block_delta` + `type=thinking` → `THINKING` 协议事件
- OpenAI 的 `reasoning_content` / `reasoning` delta → `THINKING` 协议事件

human 模式下 thinking 文本以灰色（`\033[90m`）显示，thinking→text 转换时自动插入换行。

## 中间协议

运行时内部和 `stream-json` 输出共用一套轻量事件边界。

### 内部 RESP-like 协议

`awk` 解析 SSE 后通过 RESP-like 协议传递给 `bash`，格式：

- `*N\r\n` — 数组标记 + 字段数 + CRLF
- `$len\r\ndata\r\n` — 每个字段：`$` + 字节长度 + CRLF + 数据 + CRLF
- 二进制安全：不需要转义，每个字段用 length-prefix 标定边界
- 第一个字段总是事件类型

事件类型：

- `TEXT` — 文本内容（1 字段：文本）
- `THINKING` — 思考内容（1 字段：文本）
- `TOOL_CALL` — 工具调用（≥3 字段：name, id, raw_input_json, key/value pairs...）
- `USAGE` — 用量统计（3 字段：input_tokens, output_tokens, cache_input_tokens）
- `STOP` — 结束原因（1 字段：reason）
- `ERROR` — 错误（1 字段：message）
- `RETRY` — 重试（0 附加字段）

示例（TOOL_CALL）：

```text
*6\r\n$9\r\nTOOL_CALL\r\n$4\r\nBash\r\n$8\r\ncall_123\r\n$17\r\n{"command":"pwd"}\r\n$7\r\ncommand\r\n$3\r\npwd\r\n
```

awk 端使用 `emit1()`/`emit()`/`emit_flush()` 三个函数构建消息；bash 端使用 `read_message()` 消费。

### `stream-json`

`stream-json` 是对外机器协议。

当前事件类型：

- `session_start`
- `text`
- `thinking`
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
- `protocol.awk` 负责 RESP-like 协议输出（emit/emit_flush）
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
