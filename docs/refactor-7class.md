# 架构重构计划：6 类抽象

> 临时设计文档，记录三端（bash/Go/Rust）统一抽象方案

## 1. 设计原则

- **bash 先行**：bash 函数名 = Go interface 方法名 = Rust trait 方法名，一比一对应
- **最小接口**：只有需要可替换的层才用 interface/trait（store/tool/display/transport）
- **合而不拆**：4 个存储模块合并为 1 个 SessionStore，不按职责再拆
- **source 即策略模式**：bash 通过 `source store_file.sh`（默认）/ `source store_memory.sh`（测试）切换实现，后加载覆盖前加载

## 2. 6 个类总览

| 前缀 | 类名 | 需要接口？ | 函数数 | 职责 |
|---|---|---|---|---|
| `store_` | SessionStore | ✅ | 18 | 对话/事件/统计/摘要/计划/session路径 |
| `tool_` | ToolDispatcher | ✅ | 19 | 工具分发 + 各工具实现 + 参数解析 + 结果格式化 |
| `agent_` | Agent | ❌ | 8 | 核心循环、usage 记录、prompt 构建、sub agent、上下文压缩 |
| `display_` | Display | ✅ | 4 | 终端输出（终端颜色 / stream-json / 测试 sink） |
| `llm_` | Transport | ✅ | 3 | API 通信：普通调用、流式 curl、摘要调用 |
| `util_` | util | ❌ | 19 | JSON/IO/AWK/stream/协议读写/skill/JSON 构建 |

无前缀的 CLI 入口函数（5 个）：`main`、`parse_args`、`usage`、`interactive_mode`、`validate_config`

## 3. 依赖关系

```
Agent（编排层）
 ├── SessionStore    (store_*)       ← 可替换
 ├── ToolDispatcher  (tool_*)        ← 可替换，依赖 SubAgentRunner 回调
 │     └── SubAgentRunner            ← Agent 实现，注入到 ToolDispatcher
 ├── Display         (display_*)     ← 可替换
 ├── Transport       (llm_*)         ← 可替换
 └── util functions

依赖方向：Agent → Transport → SessionStore → util（全单向向下，无循环）
```

Agent 的上下文压缩（`agent_compact_context`）直接调用 `store_conv_*` 做数据操作、`llm_summary_call` 做摘要请求，不存在独立 Compactor 层。

### 3.1 数据流图

这张图描述的是运行时“控制面”和“数据面”的分工。它适合先放在这里，等重构完成后再迁到 `ARCHITECTURE.md`。

```text
控制面: FIFO
========================

[stdin / prompt / sub-agent result]
                │
                ▼
         agent_main_loop
         ├─ USER_INPUT  ───────────────► agent_turn_begin
         │                               ├─ store_event_append(user_input)
         │                               └─ store_stats_update(current_turn_count++)
         │
         └─ AGENT_RESULT ───────────────► agent_handle_sub_result
                                         ├─ store_event_append(usage)
                                         ├─ store_stats_update(...)
                                         ├─ store_event_append(sub_agent_end)
                                         └─ agent_run_loop(...)
```

```text
数据面: LLM 事件流
========================

agent_run_loop
   │
   ▼
agent_loop
   │
   ▼
agent_loop_stream
   ├─ llm_call
   │   └─ provider SSE
   │       └─ parsed events
   │
   ├─ TEXT / THINKING / TOOL_CALL / USAGE / STOP / ERROR / RETRY
   │
   ├─ tool_use -> tool_dispatch
   ├─ decide continue vs stop
   │
   └─ 交给 agent_event
        ├─ store_event_append(event json)
        ├─ store_stats_update(...)
        └─ 透传给 agent_loop
             ├─ display_event
             └─ 或 stream-json stdout
```

```text
回放面: replay
========================

events.jsonl
   │
   ▼
store_event_lines / store_recent_event
   │
   ▼
display_event
```

```text
事件类型对应
========================

控制面 FIFO:
- USER_INPUT
- AGENT_RESULT

数据面 LLM:
- TEXT
- THINKING
- TOOL_CALL
- USAGE
- STOP
- ERROR
- RETRY

持久化副作用:
- events.jsonl
- stats.json
- summary.txt
- plan.md
- plan.draft
- conversation.jsonl
```

## 4. SessionStore（18 个函数）

bash 通过 `source` 切换实现；Go 用 interface；Rust 用 trait。

### 函数清单

| # | bash 旧名 | bash 新名 | Go 方法 | Rust 方法 | 说明 |
|---|---|---|---|---|---|
| 1 | `conv_init` | `store_init` | `Init()` | `init()` | 初始化 session 目录和文件 |
| 2 | `conv_add_user` | `store_add_user` | `AddUser(msg)` | `add_user(msg)` | 追加用户消息 |
| 3 | `conv_add_assistant` | `store_add_assistant` | `AddAssistant(msg)` | `add_assistant(msg)` | 追加助手消息 |
| 4 | `conv_add_tool_results` | `store_add_tool_results` | `AddToolResults(msg)` | `add_tool_results(msg)` | 追加工具结果 |
| 5 | `conv_get_messages` | `store_get_messages` | `GetMessages()` | `get_messages()` | 读取完整对话列表 |
| 6 | `session_append_line` | `store_append_event` | `AppendEvent(json)` | `append_event(json)` | 追加事件到 session.log |
| 7 | `stats_inc` | `store_stats_inc` | `StatsInc(key, delta)` | `stats_inc(key, delta)` | 累加统计值 |
| 8 | `stats_set` | `store_stats_set` | `StatsSet(key, val)` | `stats_set(key, val)` | 设置统计值 |
| 9 | `stats_get` | `store_stats_get` | `StatsGet(key)` | `stats_get(key)` | 读取统计值 |
| 10 | `context_append_summary` | `store_set_summary` | `SetSummary(text)` | `set_summary(text)` | 写入摘要 |
| 11 | （补） | `store_get_summary` | `GetSummary()` | `get_summary()` | 读取摘要 |
| 12 | （补） | `store_set_plan` | `SetPlan(text)` | `set_plan(text)` | 写入 plan.md |
| 13 | （补） | `store_get_plan` | `GetPlan()` | `get_plan()` | 读取 plan.md |
| 14 | （补） | `store_set_plan_draft` | `SetPlanDraft(text)` | `set_plan_draft(text)` | 写入 plan.draft |
| 15 | （补） | `store_get_plan_draft` | `GetPlanDraft()` | `get_plan_draft()` | 读取 plan.draft |
| 16 | `get_session_dir` | `store_get_dir` | `GetDir(sessionID)` | `get_dir(session_id)` | 获取 session 目录路径 |
| 17 | `get_latest_session_dir` | `store_get_latest_dir` | `GetLatestDir()` | `get_latest_dir()` | 获取最新 session 目录 |
| 18 | `resolve_continue_session_id` | `store_resolve_continue` | `ResolveContinue(id)` | `resolve_continue(id)` | 解析 continue 的 session ID |

### bash 实现策略

**不拆文件**。agent.sh 保持单文件，store_* 函数内联定义。

在所有 store_* 函数定义之后预留覆盖口子：

```bash
# agent.sh 中，store_* 函数全部定义完毕后
[[ -n "${STORE_OVERRIDE:-}" && -f "$STORE_OVERRIDE" ]] && source "$STORE_OVERRIDE"
```

使用方式：

```bash
# 正常运行（文件存储，默认行为）
./agent.sh "hello"

# 测试覆盖（内存存储）
STORE_OVERRIDE=./store_memory.sh ./agent.sh "hello"
```

`store_memory.sh` 作为独立可选文件存在，不参与正常构建，仅在需要时 source 覆盖。

**当前 e2e 测试全走文件检查**（检查 conversation.jsonl、stats.txt 等文件内容），memory store 的 e2e 测试暂不实际使用。口子先预留，后续按需启用。

### ⚠️ 子进程约束

bash 子进程（`( ... ) &`、`$(...)`、管道右侧）修改的变量不会传播到父进程。

当前所有子进程场景：

| 位置 | 形式 | store 调用 | 需要回传父进程？ |
|---|---|---|---|
| `tool_sub_agent` 的 `( ... ) &` | subshell 后台 | 大量（独立的 SESSION_ID） | ❌ 结果通过 FIFO 回传 |
| `tool_bash` 的 `run_with_timeout` | 子进程 fallback | 无 | ❌ |
| 非交互输入写入 FIFO | subshell 后台 | 无 | ❌ |

**关键结论**：

- `store_file.sh`（当前实现）：无此问题。子进程写文件，父进程读文件，天然跨进程共享。
- `store_memory.sh`（规划中）：**有此问题**。子进程写变量，父进程看不到。

**store_memory.sh 的安全条件**：

1. `tool_sub_agent` 子进程使用独立的内存 store 实例（不同变量/命名空间）
2. 子进程结束前，将 stats 序列化通过 FIFO 传回父进程
3. 父进程的 `handle_sub_agent_result` 从 FIFO 消息中反序列化 stats，在父进程中调用 `store_stats_inc`
4. 实际上当前文件方案也是这个流程（AWK 读 stats_file → FIFO → 父进程累加），memory 方案只是把"文件"换成"变量"

**结论**：只要遵循"子进程结果通过消息回传、父进程做最终写入"的原则，`store_memory.sh` 是可行的。但需要确保所有跨进程数据传递都走 FIFO 消息，不能依赖变量共享。

## 5. ToolDispatcher（19 个函数）

### 函数清单

| # | bash 旧名 | bash 新名 | Go 方法 | Rust 方法 | 说明 |
|---|---|---|---|---|---|
| 1 | `dispatch_tool` | `tool_dispatch` | `Dispatch(name, args)` | `dispatch(name, args)` | 工具分发入口 |
| 2 | `tool_param_keys` | `tool_param_keys` | `ParamKeys(name)` | `param_keys(name)` | 返回工具的参数名列表 |
| 3 | `tool_args_from_msg` | `tool_args_from_msg` | `ArgsFromMsg(msg)` | `args_from_msg(msg)` | 从消息中提取工具参数 |
| 4 | `tool_call_summary` | `tool_call_summary` | `CallSummary(name, args)` | `call_summary(name, args)` | 生成工具调用摘要 |
| 5 | `tool_file_summary` | `tool_file_summary` | `FileSummary(path)` | `file_summary(path)` | 文件内容摘要 |
| 6 | `format_tool_result` | `tool_format_result` | `FormatResult(result)` | `format_result(result)` | 格式化工具结果 |
| 7 | `tool_read` | `tool_read` | `Read(path, opts)` | `read(path, opts)` | 读文件 |
| 8 | `tool_write` | `tool_write` | `Write(path, content)` | `write(path, content)` | 写文件 |
| 9 | `tool_edit` | `tool_edit` | `Edit(path, old, new)` | `edit(path, old, new)` | 编辑文件 |
| 10 | `tool_bash` | `tool_bash` | `Bash(cmd, timeout)` | `bash(cmd, timeout)` | 执行 shell 命令 |
| 11 | `tool_glob` | `tool_glob` | `Glob(pattern)` | `glob(pattern)` | 文件搜索 |
| 12 | `tool_grep` | `tool_grep` | `Grep(pattern, opts)` | `grep(pattern, opts)` | 内容搜索 |
| 13 | `tool_skill` | `tool_skill` | `Skill(name)` | `skill(name)` | 加载 skill |
| 14 | `tool_plan_confirm` | `tool_plan_confirm` | `PlanConfirm()` | `plan_confirm()` | 确认计划 |
| 15 | `tool_plan_clear` | `tool_plan_clear` | `PlanClear()` | `plan_clear()` | 清除计划 |
| 16 | `tool_web_search` | `tool_web_search` | `WebSearch(query)` | `web_search(query)` | 网页搜索 |
| 17 | `tool_web_fetch` | `tool_web_fetch` | `WebFetch(url)` | `web_fetch(url)` | 网页抓取 |
| 18 | `tool_sub_agent` | `tool_sub_agent` | `SubAgent(prompt, desc, fork)` | `sub_agent(prompt, desc, fork)` | 子代理（特殊，见 §12） |
| 19 | `deny_bash_command_reason` | `tool_deny_bash_reason` | `DenyBashReason(cmd)` | `deny_bash_reason(cmd)` | 检查禁止命令 |

### SubAgent 特殊说明

`tool_sub_agent` 内部需要调用 Agent 的能力（`agent_loop`、`conv_init` 等）。
bash 端直接调用全局函数；Go/Rust 端通过注入 `SubAgentRunner` 回调实现，不反向依赖 Agent 具体类型。

## 6. Agent（8 个函数）

核心编排层，依赖上述接口，自身不需要是接口。

| # | bash 旧名 | bash 新名 | Go 方法 | Rust 方法 | 说明 |
|---|---|---|---|---|---|
| 1 | `main_loop` | `agent_main_loop` | `MainLoop()` | `main_loop()` | 主循环（读 FIFO、分发消息） |
| 2 | `agent_loop` | `agent_loop` | `AgentLoop(prompt)` | `agent_loop(prompt)` | 单轮对话循环 |
| 3 | `agent_loop_stream` | `agent_loop_stream` | `AgentLoopStream()` | `agent_loop_stream()` | 流式对话循环 |
| 4 | `_run_agent_loop` | `agent_run_loop` | `RunLoop(prompt)` | `run_loop(prompt)` | agent_loop 入口（选 stream/普通） |
| 5 | `record_usage` | `agent_record_usage` | `RecordUsage(usage)` | `record_usage(usage)` | 记录 usage（组合 store_append_event + store_stats_inc） |
| 6 | `build_system_prompt` | `agent_build_prompt` | `BuildPrompt()` | `build_prompt()` | 构建 system prompt |
| 7 | `handle_sub_agent_result` | `agent_handle_sub_result` | `HandleSubResult(msg)` | `handle_sub_result(msg)` | 处理子代理返回结果 |
| 8 | `compact_context_window` | `agent_compact_context` | `CompactContext(trigger)` | `compact_context(trigger)` | 上下文压缩（DP 决策 + turn 保留 + 摘要 + 修剪） |

## 7. Display（4 个函数）

| # | bash 旧名 | bash 新名 | Go 方法 | Rust 方法 | 说明 |
|---|---|---|---|---|---|
| 1 | `display_ensure_newline` | `display_ensure_newline` | `EnsureNewline()` | `ensure_newline()` | 确保换行 |
| 2 | `display_human_text` | `display_human_text` | `HumanText(text)` | `human_text(text)` | 显示用户文本 |
| 3 | `display_event` | `display_event` | `Event(msg)` | `event(msg)` | 显示事件消息 |
| 4 | `stats_show_osc` | `display_term_title` | `TermTitle(text)` | `term_title(text)` | 设置终端标题 |

## 8. Transport / LLM（3 个函数）

| # | bash 旧名 | bash 新名 | Go 方法 | Rust 方法 | 说明 |
|---|---|---|---|---|---|
| 1 | `llm_call` | `llm_call` | `Call(req)` | `call(req)` | 普通 API 调用 |
| 2 | `_stream_curl` | `llm_stream_curl` | `StreamCurl(req)` | `stream_curl(req)` | 流式 SSE 调用 |
| 3 | `run_summary_call` | `llm_summary_call` | `SummaryCall(req)` | `summary_call(req)` | 摘要生成调用 |

## 9. Util（19 个函数）

通用工具函数，不需要封装为类。bash 端为全局函数，Go 端为包级函数，Rust 端为模块级函数。

| # | bash 旧名 | bash 新名 | 说明 |
|---|---|---|
| 1 | `json_escape` | `util_json_escape` | JSON 字符串转义 |
| 2 | `awk_run` | `util_awk_run` | 执行 AWK 脚本 |
| 3 | `find_awk_dir` | `util_find_awk_dir` | 查找 AWK 脚本目录 |
| 4 | `die` | `util_die` | 错误退出 |
| 5 | `run_with_timeout` | `util_run_with_timeout` | 带超时执行命令 |
| 6 | `parse_size_bytes` | `util_parse_size` | 解析大小字符串为字节数 |
| 7 | `new_session_id` | `util_new_session_id` | 生成 session ID |
| 8 | `read_optional_file` | `util_read_file` | 读取可选文件 |
| 9 | `is_stream_json_mode` | `util_is_stream_json` | 判断是否 stream-json 模式 |
| 10 | `read_message` | `util_read_msg` | 从 FIFO 读取消息 |
| 11 | `write_message` | `util_write_msg` | 向 FIFO 写入消息 |
| 12 | `msg_to_stream_event` | `util_msg_to_stream` | 消息转 stream-json 事件 |
| 13 | `body_convert` | `util_body_convert` | LLM 请求体转换 |
| 14 | `build_assistant_content_json` | `util_build_assistant_json` | 构建助手内容 JSON |
| 15 | `build_tool_call_json_object` | `util_build_tool_call_json` | 构建工具调用 JSON |
| 16 | `build_tool_result_json_object` | `util_build_tool_result_json` | 构建工具结果 JSON |
| 17 | `wrap_section` | `util_wrap_section` | stream-json 包裹 section |
| 18 | `append_section` | `util_append_section` | stream-json 追加 section |
| 19 | `load_tool_defs` | `util_load_tool_defs` | 加载工具定义（tools.json） |

### Skill 相关（归入 util）

| # | bash 旧名 | bash 新名 | 说明 |
|---|---|---|
| — | `find_skill_base_dirs` | `util_find_skill_dirs` | 查找 skill 目录 |
| — | `load_skill_content` | `util_load_skill` | 加载 skill 内容 |
| — | `build_skill_index_section` | `util_build_skill_index` | 构建 skill 索引 |
| — | `build_selected_skills_section` | `util_build_skill_selected` | 构建选中 skill |
| — | `find_instruction_file_in_dir` | `util_find_instruction` | 查找 instruction 文件 |
| — | `build_instruction_files_section` | `util_build_instructions` | 构建 instruction 段 |

## 10. CLI 入口（5 个函数，无前缀）

这些是程序的 main 入口和参数解析，不属于任何类，保持无前缀。

| # | bash 函数名 | 说明 |
|---|---|---|
| 1 | `main` | 程序入口 |
| 2 | `parse_args` | 解析命令行参数 |
| 3 | `usage` | 显示帮助信息 |
| 4 | `interactive_mode` | 交互模式主循环 |
| 5 | `validate_config` | 校验配置 |

## 11. SubAgent 的特殊处理

### 问题
`tool_sub_agent` 是一个"工具"，但它内部需要调用 Agent 的能力：
- 创建子 session（`conv_init`）
- 运行 agent_loop（`agent_loop`）
- 通过 FIFO 回传结果（`write_message`）

这造成 ToolDispatcher 反向依赖 Agent。

### 解决方案：SubAgentRunner 回调

```
ToolDispatcher
  ├── tool_read/write/edit/...  → 纯函数，直接返回
  └── tool_sub_agent           → 调用 SubAgentRunner 回调

Agent 实现 SubAgentRunner 接口，注入到 ToolDispatcher
```

### 三端实现

**bash**（全局函数，无需接口）：
```bash
tool_sub_agent() {
    # 直接调用 agent_loop、conv_init、write_message 等全局函数
    # bash 没有 OOP 依赖问题
}
```

**Go**（接口注入）：
```go
type SubAgentRunner interface {
    RunSubAgent(prompt string, fork bool) (sessionID string, err error)
}

type ToolDispatcher struct {
    subAgentRunner SubAgentRunner  // Agent 实现并注入
}
```

**Rust**（trait 注入）：
```rust
trait SubAgentRunner {
    fn run_sub_agent(&self, prompt: &str, fork: bool) -> Result<String>;
}

struct ToolDispatcher<R: SubAgentRunner> {
    sub_agent_runner: R,
}
```

## 12. bash 端实现：source 切换

bash 没有 interface/trait，通过 `source` 的"后加载覆盖"机制实现策略模式。

### 目录结构（保持单文件）

```
src/
├── agent.sh           # 主文件（所有 store_*/agent_*/util_* 等函数内联）
├── store_memory.sh    # 可选：测试用内存 store 覆盖（不参与构建）
├── tools.json         # 工具定义
└── awk/               # AWK 脚本
```

不拆文件，不建子目录。agent.sh 一个文件包含全部实现。
预留 `STORE_OVERRIDE` 口子，测试时可选覆盖 store_* 函数。

### 切换方式

```bash
# agent.sh 中默认加载
source store_file.sh

# 测试中覆盖
source agent.sh        # 加载默认实现
source store_memory.sh # 内存实现覆盖 store_* 函数
```

### 优先级

只在需要时可替换的层拆分文件：
- **store_** → 拆文件（File/Memory 实现）
- **display_** → 拆文件（term/stream-json 实现）
- 其余保持在 agent.sh 中（不拆）

## 13. Go 端实现：interface

```go
package agent

// SessionStore - 可替换存储
type SessionStore interface {
    Init() error
    AddUser(msg string)
    AddAssistant(msg string)
    AddToolResults(msg string)
    GetMessages() []Message
    AppendEvent(event string)
    StatsInc(key string, delta int)
    StatsSet(key string, val int)
    StatsGet(key string) int
    SetSummary(text string)
    GetSummary() string
    SetPlan(text string)
    GetPlan() string
    SetPlanDraft(text string)
    GetPlanDraft() string
    GetDir(sessionID string) string
    GetLatestDir() string
    ResolveContinue(id string) string
}

// ToolDispatcher - 可替换工具分发
type ToolDispatcher interface {
    Dispatch(name string, args map[string]interface{}) string
    ParamKeys(name string) []string
    // ... 各工具方法
}

// Display - 可替换输出
type Display interface {
    EnsureNewline()
    HumanText(text string)
    Event(msg string)
    TermTitle(text string)
}

// Transport - 可替换 API 通信
type Transport interface {
    Call(req Request) Response
    StreamCurl(req Request) <-chan Event
    SummaryCall(req Request) Response
}

// SubAgentRunner - SubAgent 回调
type SubAgentRunner interface {
    RunSubAgent(prompt string, fork bool) (sessionID string, err error)
}

// Agent - 核心编排（不需要接口）
type Agent struct {
    Store    SessionStore
    Tools    ToolDispatcher
    Display  Display
    Transport Transport
}
```

## 14. Rust 端实现：trait

```rust
// SessionStore - 可替换存储
trait SessionStore {
    fn init(&mut self) -> Result<()>;
    fn add_user(&mut self, msg: &str);
    fn add_assistant(&mut self, msg: &str);
    fn add_tool_results(&mut self, msg: &str);
    fn get_messages(&self) -> Vec<Message>;
    fn append_event(&mut self, event: &str);
    fn stats_inc(&mut self, key: &str, delta: i64);
    fn stats_set(&mut self, key: &str, val: i64);
    fn stats_get(&self, key: &str) -> i64;
    fn set_summary(&mut self, text: &str);
    fn get_summary(&self) -> String;
    fn set_plan(&mut self, text: &str);
    fn get_plan(&self) -> String;
    fn set_plan_draft(&mut self, text: &str);
    fn get_plan_draft(&self) -> String;
    fn get_dir(&self, session_id: &str) -> String;
    fn get_latest_dir(&self) -> String;
    fn resolve_continue(&self, id: &str) -> String;
}

// SubAgentRunner - SubAgent 回调
trait SubAgentRunner {
    fn run_sub_agent(&self, prompt: &str, fork: bool) -> Result<String>;
}

// ToolDispatcher - 泛型，注入 SubAgentRunner
struct ToolDispatcher<R: SubAgentRunner> {
    sub_agent_runner: R,
}

// Agent - 核心编排
struct Agent<S: SessionStore, T: ToolDispatcher, D: Display, L: Transport> {
    store: S,
    tools: T,
    display: D,
    transport: L,
}
```

## 15. 迁移步骤

### Phase 1：bash 端重命名（纯重命名，不改逻辑）

1. `store_*` 函数重命名（18 个）
2. `tool_*` 函数重命名（新增 3 个：dispatch/format_result/deny_bash）
3. `agent_*` 函数重命名（7 个）
4. `display_*` 函数重命名（stats_show_osc → display_term_title）
5. `llm_*` 函数重命名（3 个）
6. `util_*` 函数重命名（19 个 + 6 个 skill）
7. 全局搜索替换旧名 → 新名
8. 预留 STORE_OVERRIDE 口子（在 store_* 定义末尾加一行 source 判断）
9. 运行 `bash -n src/agent.sh` + `make test` 验证

### Phase 2：Go/Rust 端同步

1. Go 端定义 interface（SessionStore / ToolDispatcher / Display / Transport / SubAgentRunner）
2. Rust 端定义 trait（同上）
3. Go/Rust 各自内联 prompt section 文本（与 bash 保持一致），三端 prompt 内容相同但各自维护在代码中
4. 逐步对齐方法名与 bash 函数名
5. store_memory.sh 作为可选实现（不阻塞主流程）

## 16. System Prompt：保持现状

system prompt 保持 `agent_build_prompt` 内部按 section 变量构建的方式，不引入外部模板文件。

每个 section 是函数内的一个局部变量，通过 `append_section` 组装输出。当前方式已足够清晰，模板化会增加不必要的复杂度。

1. Go 端定义 interface（SessionStore / ToolDispatcher / Display / Transport / SubAgentRunner）
2. Rust 端定义 trait（同上）
3. 逐步对齐方法名与 bash 函数名
4. store_memory.sh 作为可选实现（不阻塞主流程）
