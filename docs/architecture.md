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
- context 文件、summary 文件管理
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

## 消息通道架构

整个运行时涉及多个通道，不同语言实现有不同选择：

### bash 版本的通道

```
┌─────────────────────────────────────────────────────────────────────┐
│                           主进程                                     │
│  ┌──────────────┐    RESP-like     ┌──────────────────┐            │
│  │   agent_loop  │ ←──── fd 7/8 ───│ agent_loop_stream│            │
│  │   (外层)      │                  │     (内层)        │            │
│  └──────┬───────┘                  └────────┬─────────┘            │
│         │                                    │                      │
│         │                                    │ RESP-like            │
│         │                                    │ (fd)                 │
│         │                                    ↓                      │
│         │                           ┌─────────────────┐            │
│         │                           │  awk SSE 解析    │            │
│         │                           └────────┬────────┘            │
│         │                                    │ HTTP stream          │
│         │                                    ↓                      │
│         │                              ┌──────────┐                │
│         │                              │ API 服务  │                │
│         │                              └──────────┘                │
│         │                                                          │
│         │ RESP via fd 4 pipe                                       │
│         ↓                                                          │
│  ┌──────────────┐                                                  │
│  │ display_stream│ ←── fd 4 ──── agent_loop                        │
│  │ (子进程)      │     display_message → display_human_text        │
│  └──────────────┘     display_ensure_newline / display_term_title   │
│         │ stderr                                                    │
│         ↓                                                          │
│     [终端]                                                         │
│                                                                    │
│  ┌──────────────┐                                                  │
│  │ stdin_reader  │ ── FIFO ──── agent_main_loop                     │
│  │ (后台进程)    │     read -p "> " < /dev/tty                      │
│  └──────────────┘     → USER_INPUT / SESSION_END                    │
│                                                                    │
│  ┌──────────────┐                                                  │
│  │ 子 agent      │ ←── FIFO (启动) ─── agent_loop_stream           │
│  │ (子进程)      │ ── FIFO (结果) ──→ agent_main_loop               │
│  │ FD 3-9 关闭，不与主进程争管道                                     │
│  └──────────────┘                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

**通道说明**：

| 通道 | 方向 | 用途 | 同步机制 |
|------|------|------|---------|
| RESP-like fd | awk → bash | SSE 解析结果传递给 agent_loop_stream | read 阻塞 |
| RESP-like fd 8 | agent_loop_stream → agent_loop | 内层消息传递给外层（llm_call 管道） | write_message / read_message |
| RESP fd 7 | agent_loop_stream → agent_loop | agent_loop_stream stdout → agent_loop | write_message / read_message |
| RESP fd 4 | agent_loop → display_stream | 渲染消息传递给子进程显示 | write_message / read_message |
| FIFO fd 5 | stdin_reader → agent_main_loop | 用户输入传递（INPUT_FIFO 写入端） | write 后非阻塞，read 阻塞 |
| FIFO fd 3 | agent_main_loop | INPUT_FIFO 读取端 | read 阻塞 |
| FIFO | 主 → 子 | 启动子 agent | 写入后非阻塞 |
| FIFO | 子 → 主 | 子 agent 结果回传 | read 阻塞 |
| stdin | 用户 → stdin_reader | 交互模式输入（后台进程） | read 阻塞 |

### 文件描述符分层约定

FD 按所在进程层级分配，全局可见的 FD 用连续小数字（3-6），子进程临时 FD 使用大数字（7-9）。

| FD | 层级 | 用途 | 所在进程 |
|----|------|------|---------|
| 3  | 全局 | INPUT_FIFO 读取端 | agent_main_loop |
| 4  | 全局 | display pipe 写入端 | agent_main_loop |
| 5  | 全局 | INPUT_FIFO 写入端 | agent_main_loop / stdin_reader |
| 6  | 全局 | （预留） | — |
| 7  | 子进程 | agent_loop_stream stdout 读取端 | agent_loop |
| 8  | 子进程 | llm_call 管道读取端 | agent_loop_stream |
| 9  | 子进程 | curl 管道读取端 | llm_stream_curl |

### Go/Rust 版本的通道

```
┌─────────────────────────────────────────────────────────────────────┐
│                           主 goroutine/task                          │
│  ┌──────────────┐        msgChan        ┌──────────────────┐       │
│  │   agent_loop  │ ←────────────────────│ agent_loop_stream│       │
│  │   (外层)      │                       │     (内层)        │       │
│  └──────┬───────┘                       └────────┬─────────┘       │
│         │                                        │                 │
│         │                                        │ HTTP stream     │
│         │                                        ↓                 │
│         │                                  ┌──────────┐            │
│         │                                  │ API 服务  │            │
│         │                                  └──────────┘            │
│         │                                                          │
│         │ msgChan (AGENT_RESULT)                                   │
│         ↓                                                          │
│  ┌──────────────┐                                                  │
│  │ 子 agent      │ ←── goroutine/task 启动                         │
│  │ (异步执行)    │                                                  │
│  └──────────────┘                                                  │
│                                                                    │
│  ┌──────────────┐                                                  │
│  │ interactive   │ ←── done channel (同步等待)                      │
│  │ mode          │                                                  │
│  └──────────────┘                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

**通道说明**：

| 通道 | 类型 | 方向 | 用途 | 同步机制 |
|------|------|------|------|---------|
| msgChan | `chan MainLoopMessage` | stream → loop | 内层消息传递给外层 | channel 阻塞 |
| msgChan | `chan MainLoopMessage` | 子 → 主 | 子 agent 结果回传 | channel 阻塞 |
| done | `chan struct{}` | mainLoop → interactive | 交互模式同步 | channel 阻塞 |
| HTTP stream | `io.Reader` | API → stream | SSE 流式读取 | read 阻塞 |

### 关键差异

| 方面 | bash | Go/Rust |
|------|------|---------|
| API 解析层 | 独立 awk 进程 | 内嵌在 agent_loop_stream |
| stream → loop 通道 | RESP-like fd 7/8 | msgChan |
| 子 agent 结果回传 | FIFO | msgChan |
| 交互模式同步 | read 阻塞 | done channel |
| 子 agent 计数回收 | FIFO 消息触发 | msgChan 消息触发 |

### 消息格式

**bash RESP-like 协议**：
```
*N\r\n$len\r\ndata\r\n...
```

**Go/Rust MainLoopMessage**：
```go
type MainLoopMessage struct {
    Type      string // "USER_INPUT" or "AGENT_RESULT"
    Input     string
    SessionID string
    Status    string // "ok" or "failed"
    Result    string
    InTokens  int
    OutTokens int
    Done      chan<- struct{} // 交互模式同步
}
```

## 当前核心能力

### 1. Session

session 数据按当前项目目录归档：

```text
~/.bash-agent/projects/<project_key>/<session_id>/
    conversation.jsonl
    events.jsonl
    summary.txt
    plan.md
    plan.draft
    stats.json
```

职责分工：

- `conversation.jsonl`
  - 当前真正发给模型的消息窗口
- `events.jsonl`
  - session 内部事件日志
- `summary.txt`
  - compact 后留下的历史摘要
- `plan.md`
  - 当前 session 的已确认计划文档，由 `plan-lifecycle-guidance` 机制维护
- `plan.draft`
  - 规划阶段的工作草稿，确认后通过 `PlanConfirm` 工具移至 `plan.md`
- `stats.json`
  - session 统计数据（LLM 调用次数、输入 token 总量、compact 次数、当前 turn 等）
  - bash 版**不使用内存缓存**，每次 `stats_inc`/`stats_set`/`stats_get` 直接通过 `stats.awk action=update` 对文件做 read-modify-write。原因是 bash 的 `agent_loop_stream` 运行在 `<(…)` 子进程中，`$()` 命令替换会创建额外子 shell，bash 没有进程间共享变量的 IPC 机制——内存缓存在任何子进程场景下都无法同步，会导致数据丢失/归零。
  - Go/Rust 版使用全局 `StatsCache` 结构体是合理的：它们运行在单进程多 goroutine/task 模型下，共享内存天然可用，配合读写锁即可安全并发。

### 2. Context / compact

compact 使用**缓存对齐摘要（Cache-Aligned Summarization）**和基于缓存经济学的动态规划算法，自动决定是否压缩和保留多少消息。

#### 触发时机

compact 在 `agent_loop_stream()` 的 **每次 LLM 调用前** 执行：

```text
while turn < MAX_TURNS:
    ① compact_context_window auto     ← 使用上一轮 USAGE 记录的 ctx_tokens
    ② llm_call()
    ③ 流式处理：TEXT / THINKING / TOOL_CALL / USAGE / STOP
    ④ 持久化 assistant + tool_results
    ⑤ stats_set current_context_tokens = _ctx_tokens   ← 供下一轮 compact 使用
```

数据流时序：

1. LLM 流中收到 `USAGE` 事件 → `record_usage()` 解析 input_tokens 并返回 → 赋值给 `_ctx_tokens`
2. 流结束后，`_ctx_tokens > 0` 时写入 `stats.current_context_tokens`
3. **下一轮循环迭代**开头的 `compact_context_window` 读取该值做 DP 决策和安全阀判断

这意味着首次 LLM 调用前 `current_context_tokens` 为 0，compact 不会触发（DP 和安全阀都跳过）。这是正确行为——首轮没有历史需要压缩。

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

#### Force Compact / PlanConfirm / PlanClear

Plan 相关的两个工具都会跳过 DP 决策，以 `DP_MIN_KEEP_RATIO`（默认 0.3）计算 turn-aligned 保留行数，执行缓存对齐摘要 + 裁切：

- **`PlanConfirm`** — 用户确认 plan 时调用：先 force compact（复用旧缓存前缀），再将 `plan.draft` 移至 `plan.md`（此时才触发缓存失效），总共只产生一次冷启动
- **`PlanClear`** — plan 执行完毕时调用：先 force compact，再清空 `plan.md`

执行顺序（以 `PlanConfirm` 为例）：

1. **`compact_turn_keep()`** — 扫描 conversation 中的 user 消息（匹配 `{"role":"user","content":"`），从末尾按 ratio 保留完整 turn
2. **`compact_context_window(plan_confirm)`** — 用 turn keep 结果执行缓存对齐摘要 + 裁切（此时 system prompt 前缀未变，cache 命中）
3. **`mv plan.draft → plan.md`** + 重建空 draft（compact 后才移动，确保 compact 阶段前缀缓存命中）

关键：compact 在 mv 之前执行。因为 compact 的 summary 调用需要前缀缓存命中来降低成本，如果先 mv 导致 `plan.md` 内容变化、system prompt 前缀改变，compact 就会失去缓存对齐的优势。

Safety valve 也改用 `compact_turn_keep()` 实现 turn 对齐（替换原简单比例计算），确保 tool_result 不会被误算为 user turn。

| 项 | 含义 |
|---|---|
| ① | 压缩后后续 `R-1` 次 LLM 调用每次少发送 `H` token，按缓存价节省 |
| ② | 摘要内容变化导致前缀缓存断裂，`S+K` 个 token 从缓存价变为全价 |
| ③ | 压缩请求本身的 API 成本（缓存复用前缀 + 指令 + 输出） |
| ④ | 多次压缩的信息累积损失，`r_t = r^(c+1)`（下限 0.37） |

#### 核心变量

| 变量 | 含义 | 默认 |
|---|---|---|
| $R = E \times L$ | 预期剩余 LLM 调用总次数 | — |
| $E$ | 预期剩余用户输入轮数 | `max(DP_BASELINE_E - t, baseline/2)`，单调非递增 |
| $L$ | 每轮用户输入平均 LLM 调用次数 | 5（`DP_L=0` 时从 stats 自动计算） |
| $H = T_{\text{total}} - K$ | 被丢弃的旧消息 token 数 | 遍历 $k$ 计算 |
| $S$ | 固定摘要长度 | 500 token |
| $V$ | 固定前缀（system prompt + tools + old summary） | 5000 token |

#### Cache-Aligned Summarization

summary 调用（`run_summary_call`）采用与正常请求**完全相同的前缀结构**，实现前缀缓存命中：

```
正常请求：  [System prompt + Tools + Summary] + [全部消息]
summary请求：[System prompt + Tools + Summary] + [dropped 消息 H] + [summary 指令]
            ←────── 缓存命中，按 P_cache 计费 ──────→  ← P_input →
```

由于 dropped 消息是 CONV_FILE 开头的行，它们与之前请求中的前缀完全一致。summary 请求只追加了一条 user 消息作为总结指令，不影响前缀匹配。这就是 **Cache-Aligned Summarization**：摘要 agent 的前缀与主 agent 对齐，确保前缀缓存命中。

以 Claude Sonnet 4 为例（compact 45K tokens of history）：

| Tokens | Without cache alignment | With cache alignment |
|--------|------------------------|---------------------|
| System prompt ~2K | Full: $0.006 | Cached: $0.0006 |
| Tools ~3K | Full: $0.009 | Cached: $0.0009 |
| Dropped messages ~40K | Full: $0.120 | Cached: $0.012 |
| Summary instruction ~200 | Full: $0.0006 | Full: $0.0006 |
| **Total ~45.2K** | **$0.136** | **$0.014** |
| | | **节省 ~90%** |

单次 compact 相比不使用前缀缓存的传统 summary 方式节省约 **90%**，复杂任务中多次触发时累积效应显著。这一技术已被移植到 [Crush](https://github.com/charmbracelet/crush) 的 Go 实现中。

#### 保留窗口对齐

切分点始终对齐到**真实用户输入**（`"role":"user","content":"..."`），不会在工具结果处切断：

- 不能把会话裁成孤立的 `tool_result`
- 不能只剩 `assistant.tool_use` 而丢掉对应用户请求

> 完整推导见 [`compact-analysis.md`](compact-analysis.md)。

### 3. Session Replay

当恢复已有 session（`--continue` 或 `--session`）时，交互模式会回放最近 10 轮对话。

实现机制：

- 读取 `events.jsonl`，按 `user_input` / `user_message` 事件标记 turn 边界
- 取最后 10 个 turn 的事件序列
- 使用 `display_message()`（bash/Go/Rust）或 `event_replay.awk`（bash）将事件转为 REPL 兼容的 RESP 协议输出
- 回放文本/思考内容时累计延迟 flush，保证 thinking→text 边界处正确插入换行
- bash 版使用独立的 `src/awk/event_replay.awk` 文件，build 时内联到单文件发布版
- event_replay 依赖 TOOL_RESULT 事件中已附带的 file_summary 前缀（Read/Write 工具结果），因此回放时不需访问原始文件
- `session_start` / `usage` / `retry` 事件不回放

回放完成后输出一个空行分隔，再进入交互模式。

### 3. Prompt 组装

system prompt 采用稳定 section 顺序拼装，而不是重型模板系统。

当前顺序：

1. `agent-identity`（按 locale 翻译，提供语言启动——头部锚定）
2. `environment`
3. `rules`
4. `using-your-tools`
5. `todo-guidance`
6. `plan-lifecycle-guidance`
7. `instruction-files`
8. `skill-index`
9. `selected-skills`
10. `current-plan`
11. `context-snapshot`
12. `output-language`（尾部重申，语言约束作为 system prompt 的最后内容——近因锚定）

system prompt 首尾都是语言约束，中间内容无论多长、是否变化，语言锚定效应始终被两端强化。

实现策略：

- `wrap_section()` 负责包裹 section
- `append_section()` 负责按顺序累加
- 稳定内容尽量前置
- 动态内容尽量后置
- `current-todo` 已移除，见 §Todo 设计演进

`using-your-tools` 指导模型如何正确使用各内置 tool。

`plan-lifecycle-guidance` 为复杂多步任务提供规划工作流，采用状态机模型：用户回复必须归类为 REVISE（更新 draft 并继续规划）、CONFIRM（调用 PlanConfirm 确认并进入执行）、CANCEL（清空 draft 并退出规划）之一。规划阶段写入 `plan.draft`（不进入 system prompt，不影响缓存）→ 用户确认后通过 `PlanConfirm` 工具先执行 force compact（复用旧缓存前缀）再将 draft 移至 `plan.md`（此时缓存才失效，正好 compact 已回收了上下文窗口）→ TodoWrite checklist → 执行 → `PlanClear` 清空 plan 并 compact。由 `PLAN_DRAFT_FILE` 和 `PLAN_FILE` 环境变量标识路径。`PlanClear` 后，system prompt 中的 plan section 会消失。

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
- 模型通过 tool 显式更新完整 checklist
- TodoWrite 输出直接作为 tool result 返回，不持久化到文件
- 模型从对话历史中的 tool result 获取最新 todo 状态
- 不再有 `current-todo` system prompt section（避免每次 todo 更新导致前缀缓存失效）

#### 设计演进：从 system prompt section 到 tool result

早期版本在 system prompt 末尾有 `current-todo` section，每次 `TodoWrite` 写入 `todo.md` 文件后，下一轮请求的 system prompt 会从 `current-todo` 段开始变化，导致**从该位置起的所有内容（包括后续整个对话历史）前缀缓存断裂**。

以一段典型任务（10 轮对话，5 次 `TodoWrite`，上下文累积到 ~100K tokens）为例：

| 轮次 | 事件 | 缓存影响 |
|------|------|---------|
| 1-2 | — | 正常缓存 |
| 3 | TodoWrite #1 (~20K 上下文) | `current-todo` 段之后 20.1K 全价计费 |
| 5 | TodoWrite #2 (~55K) | 55.1K 全价 |
| 7 | TodoWrite #3 (~75K) | 75.1K 全价 |
| 8 | TodoWrite #4 (~85K) | 85.1K 全价 |
| 10 | TodoWrite #5 (~95K) | 95.1K 全价 |

每次断裂，`current-todo` 段（~100 tokens）和之后所有对话消息从缓存价跌回全价，累积到**第 5 次时一次断裂就损失 95K 的缓存差价**。

**成本对比（DeepSeek V4 Flash 价格为例）：**

| | 之前（有 current-todo） | 之后（tool result 仅） |
|---|---|---|
| system prompt | 每轮首轮之后全部命中 | 全程命中（首轮后不变） |
| 缓存断裂 | ~5 次 × 累积上下文 | **0 次** |
| 每任务成本 | 基准 | **~1/28** |

移除后行为完全等价——模型从工具调用的 tool result 中获取 todo 状态，效果一致，成本降低约 **28 倍**（取决于对话深度和 TodoWrite 频率）。

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
- `PlanConfirm` — 确认 plan draft：先 force compact（复用旧缓存前缀），再 mv draft → plan.md（触发缓存失效），总共一次冷启动
- `PlanClear` — 清空 plan：先 force compact（跳过 DP 决策，保留最后 `DP_MIN_KEEP_RATIO` 比例的完整 turn），再清空 plan.md
- `Skill`
- `WebSearch`
- `WebFetch`
- `SubAgent` — 启动子代理会话，支持独立模式和 fork 模式（`fork=true` 继承父会话上下文），支持并发执行

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

`WebSearch` 和 `WebFetch` 基于 Jina AI API，需要 `JINA_API_KEY` 环境变量。

#### SubAgent 架构约束

SubAgent 的核心设计原则是**隔离输出**：子 agent 的执行过程不应污染主 agent 的终端。

**两种运行模式**：

| 模式 | 参数 | 上下文 | 适用场景 |
|------|------|--------|---------|
| 独立模式（默认） | 不设置 `fork` | 全新会话，无法看到父会话对话历史 | 独立文件调查、聚焦搜索、隔离假设验证 |
| Fork 模式 | `fork=true` | 继承父会话的对话历史、计划、技能 | 需要父会话上下文的子任务 |

- **独立模式**：prompt 必须自包含，包含所有文件路径、函数名、错误信息、约束条件
- **Fork 模式**：prompt 可引用父会话上下文，无需重复提供已有信息

**职责分工**：

| 组件 | 职责 |
|------|------|
| 主 agent 的 `agentLoop` | 负责写入 events.jsonl + 根据模式（human/stream-json）输出到 stdout |
| SubAgent 的工具执行 | 只按格式传递结果，不直接输出到 stdout |
| SubAgent 的 `agent_loop_stream` | 只记录 events.jsonl |
|- **bash 版本**：SubAgent 关闭继承的 fd 4（display pipe），`util_write_msg >&4` 静默失败，LLM 流不显示。子 Agent 结果通过 FIFO 回传。|

**启动流程**：

1. SubAgent 启动时返回启动提示文案（给主 agent）
2. SubAgent 执行过程中只记录 events.jsonl，不输出到 stdout
3. SubAgent 结束时通过 FIFO 传递结果给主 agent
4. 主 agent 的 `handleSubAgentResult` 负责输出结果

**关键实现细节**：

- **bash 版本**：SubAgent 启动时设置 `export INTERACTIVE=false`，然后 `exec </dev/null >/dev/null 2>&1` 静默 stdout/stderr，最后关闭继承的 FD 3、4、5、8（INPUT_FIFO 读取/display pipe/INPUT_FIFO 写入/llm_call 管道）防止意外写入父进程管道。子 Agent 的 `agent_loop` 中 `( util_write_msg ... ) >&4 2>/dev/null` 因 fd 4 已关闭而静默失败，子 Agent 运行过程中的 LLM 流不显示在终端。子 Agent 的结果通过 `store_sub_send_result` 写入父 FIFO 回传。
- **Go/Rust 版本**：SubAgent 启动时设置 `sub_cfg.interactive = false`，然后在 `display_message` 中检查 `!self.is_stream_json_mode() && self.cfg.interactive` 条件，只有在交互模式下才输出到 stdout

**⚠️ 常见错误**（已通过架构修复）：

- **bash 不通过条件判断隔离 SubAgent 输出**：SubAgent 启动时关闭 fd 4（display pipe），`util_write_msg >&4` 静默失败，LLM 事件不会抵达 `display_stream`。不存在通过 `display_message` 条件判断跳过的风险。
- **继承的 FD 导致输出串道**：SubAgent 若未关闭 fd 4，其 `agent_loop` 的 `util_write_msg >&4` 会写入父进程的 display pipe，与父进程 RESP 交错。现已在 `tool_sub_agent` 中 `exec 3<&-; exec 4<&-; exec 5<&-; exec 8<&-` 关闭所有继承 FD。fd 7（agent_loop_stream stdout）和 fd 9（curl 管道）位于更深层子进程，子 agent 不继承。

**代码位置**：

- bash: `src/agent.sh`（`tool_sub_agent` 函数内 `agent_loop "$prompt" >/dev/null`）
- Go: `go/agent.go`（`display_message` 中的 `if !rt.isStreamJsonMode() && rt.cfg.Interactive` 检查）
- Rust: `rust/src/agent.rs`（`display_message` 中的 `if !self.is_stream_json_mode() && self.cfg.interactive` 检查）

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

通过 `--thinking`/`--effort` 控制：

- `claude`：`thinking.type=adaptive`（自适应）/ `enabled` / `disabled`，`thinking.budget_tokens` 由 `--effort` 映射
- `openai`：固定 `reasoning_effort` 由 `--effort` 映射（high/low/medium）
- summary 调用复用相同的 thinking/effort 配置以保持前缀缓存一致性（Cache-Aligned Summarization）

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

`record_usage(key, counter, verbose)` 内部处理流程：

1. 从 RESP-like `USAGE` 事件中提取 `input_tokens`
2. 计算 `ctx_tokens = input_tokens`（含 cache tokens 的原始值，直接反映当前请求的上下文窗口大小）
3. 累加到 `total_input_tokens` / `total_output_tokens`
4. 递增 `counter`（如 `agent_request_count` / `compact_request_count`）
5. 返回 `ctx_tokens` 字符串（供调用方缓存到 `_ctx_tokens`，循环末尾写入 `stats.current_context_tokens`）

注意：`record_usage` 只更新累加字段，不直接写入 `current_context_tokens`。该值由 `agent_loop_stream` 在流结束后显式设置，确保 compact 决策使用的是**上一轮**的完整上下文大小。

`context_update` 事件：当 `compact_context_window` 实际执行压缩时，通过 `write_message "CONTEXT_UPDATE" "compact" "auto"` 发出，通知 display 层上下文已被压缩。

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
  - worktree

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
