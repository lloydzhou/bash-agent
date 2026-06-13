# 四版本一致性对比报告

> 基准：Bash 版 `src/agent.sh`（1693 行）
> 对比：C (`c/`)、Go (`go/`)、Rust (`rust/src/`)
> 生成时间：2026-06-13

---

## 汇总

| 严重度 | 数量 | 影响 |
|--------|------|------|
| 🔴 CRITICAL | 1 | 请求体字段顺序不一致 → KV cache 全部失效 |
| 🟠 HIGH | 2 | Go 默认值偏差 |
| 🟡 MEDIUM | 3 | 格式/行为细节差异 |
| ⚪ LOW | 2 | 边界差异 |
| **合计** | **8** | |

---

## 🔴 CRITICAL

### DIFF-1: 请求体 JSON 字段顺序四版本不一致

**影响**：Anthropic API 的 prompt caching 基于请求体字节前缀。字段顺序不同 → 前缀不同 → cache miss → 每次切换版本相当于冷启动 → 浪费数十万 token。

| 版本 | 实际字段顺序 | 根因 |
|------|-------------|------|
| **Bash** | `model→max_tokens→stream→thinking→output_config→system→tools→messages` | 手动字符串拼接 |
| **C** | `model→max_tokens→stream→`**`system`**`→thinking→output_config→tools→messages` | 手动拼接，但 system 在 thinking **之前** |
| **Go** | **字母序**：`max_tokens,messages,model,output_config,stream,system,thinking,tools` | `map[string]interface{}` + `json.Marshal`（Go map 按字母序） |
| **Rust** | **字母序**：同 Go | `serde_json::json!` + `serde_json::to_vec`（`BTreeMap` 按字母序，未启用 `preserve_order`） |

**修复方案**：
- **Bash 顺序为基准**（手动拼接保证顺序）
- **C**：将 system 移到 thinking/output_config 之后（调整 `build_claude_request` 中的拼接顺序）
- **Go**：改用有序方式构建 JSON（如 `bytes.Buffer` 手动拼接，或定义 struct with json tags）
- **Rust**：启用 `serde_json` 的 `preserve_order` feature（`serde_json = { version = "1", features = ["preserve_order"] }`），或改用手动拼接

**代码位置**：
- Bash: `src/agent.sh:624-631` (`llm_call`)
- C: `c/transport.c:806-852` (`build_claude_request`)
- Go: `go/transport.go:547-569` (`buildClaudeBody`)
- Rust: `rust/src/util.rs:90-119` (`build_claude_request`)

---

## 🟠 HIGH

### DIFF-2: Go MAX_TURNS 默认值 = 500（应为 1000）

**Bash**: `MAX_TURNS=1000` (`src/agent.sh:15`)
**C**: `a->max_turns = 1000` (`c/agent.c:247`)
**Rust**: `max_turns: 1000` (`rust/src/lib.rs:73`)
**Go**: `flag.IntVar(&maxTurns, "max-turns", 500, ...)` (`go/cmd/goagent/main.go:44`)

虽然 `go/types.go:59` 有 `MaxTurns: 1000`，但被 flag 默认值 500 覆盖。

**修复**：`go/cmd/goagent/main.go:44` 改 `500` 为 `1000`。

### DIFF-3: Go TOOL_RESULT_MAX_BYTES 默认 = 30000（应为 100000）

**Bash**: `TOOL_RESULT_MAX_BYTES=100000` (`src/agent.sh:20`)
**C**: `a->tool_result_max_bytes = 100000` (`c/agent.c:250`)
**Rust**: `tool_result_max_bytes: 100_000` (`rust/src/lib.rs:66`)
**Go**: `const defaultToolResultMaxBytes = 30000` (`go/tools.go:20`)

**修复**：`go/tools.go:20` 改 `30000` 为 `100000`。

---

## 🟡 MEDIUM

### DIFF-4: JSON escape — <0x20 控制字符处理不一致

| 版本 | 处理方式 |
|------|----------|
| **Bash** | 只转义 `\ " \n \r \t \b \f`，**不转义其他 <0x20 控制字符** |
| **C** | 额外转义 <0x20 为 `\u00xx` |
| **Go** | 额外转义 <0x20 为 `\u00xx` |
| **Rust** | serde_json 自动转义 <0x20 |

**说明**：C/Go/Rust 的做法更符合 JSON 规范（RFC 8259 要求 <0x20 必须转义）。Bash 版的 `util_json_escape` 不处理这些字符。实际影响很小（工具输出不太可能包含这些字符），但严格来说不一致。

**建议**：暂不修改（C/Go/Rust 的做法更正确）。如果需要严格对齐 Bash，可以移除 <0x20 转义逻辑。

### DIFF-5: Rust list-sessions 排序方式不同

| 版本 | 排序方式 |
|------|----------|
| **Bash** | glob 遍历，字母升序 |
| **C** | `scandir` + `alphasort`，字母升序 |
| **Go** | `os.ReadDir`，字母升序 |
| **Rust** | **按 modified 降序** (`rows.sort_by(|a, b| b.modified.cmp(&a.modified))`) |

**代码位置**：`rust/src/store.rs:456`

**修复**：移除 Rust 的 sort 或改为字母排序（与 Bash 对齐）。

### DIFF-6: Go SummaryCall instruction 消息字段顺序

Go 使用 `map[string]string` 构建 instruction 消息，JSON 序列化为 `{"content":"...","role":"user"}`（字母序）。Bash 输出 `{"role":"user","content":"..."}`。

**代码位置**：`go/transport.go` SummaryCall 中 `json.Marshal(map[string]string{...})`

**影响**：低（instruction 消息在 messages 末尾，不在 cache 前缀中）。但如果要严格对齐，应改用有序构建。

---

## ⚪ LOW

### DIFF-7: Go usage 文档中 --max-turns 默认值写 500

Bash `usage()` 中写 `default: 500`（与实际默认值 1000 不符）。Go flag 描述也写 500。

**Bash**: `src/agent.sh:1468` — `--max-turns N (default: 500)` 但实际 `MAX_TURNS=1000`
**Go**: `go/cmd/goagent/main.go:44` — `"Max agent turns"` flag 默认 500

### DIFF-8: Rust 有额外 DP 配置字段

Rust 的 Config 结构包含 `max_context_keep_pct`, `max_turns_before_compact`, `dp_p_input`, `dp_p_cache`, `dp_p_out`, `dp_v`, `dp_s`, `dp_l`, `dp_baseline_e`, `dp_e_fixed`, `dp_r`, `dp_beta`, `dp_quality_penalty`, `dp_min_keep_ratio` 等字段。

Bash 版这些参数通过环境变量 `DP_*` 传入，在 `store_conv_dp_decision` 调用时才使用。Rust 将它们放在 Config 结构中。这是语言特性的可接受差异，不影响行为。

---

## 已验证一致的项

以下模块经检查四版本一致或差异可接受：

| 模块 | 状态 | 说明 |
|------|------|------|
| tools.json SHA256 | ✅ 一致 | 四版本完全相同 |
| System Prompt section 顺序 | ✅ 一致 | 13 个 section 顺序相同 |
| summary instruction 文本 | ✅ 一致 | compact 用的指令文本逐字相同 |
| MAX_TOKENS 默认值 | ✅ 一致 | 四版本均 16384 |
| MAX_CONTEXT_TOKENS 默认值 | ✅ 一致 | 四版本均 200000 |
| TOOL_TIMEOUT_SECS 默认值 | ✅ 一致 | 四版本均 600 |
| EFFORT 默认值 | ✅ 一致 | 四版本均 "high" |
| THINKING 默认值 | ✅ 一致 | 四版本均 "adaptive" |
| SSE RETRY 处理 | ✅ 一致 | 三 Port 版本均重置累积状态 |
| compact 操作顺序 | ✅ 一致 | 先 summary → set_summary → trim_tail |
| assistant 消息格式 | ✅ 一致 | 总是包含 thinking block |
| Bash 安全分类器 | ✅ 基本一致 | 正则和 scope 映射对齐 |
| Provider 配置 | ✅ 一致 | Claude/OpenAI/DeepSeek 配置对齐 |
| plan 操作 | ✅ 一致 | confirm/clear/read/draft 对齐 |
| RETRY token 重置 | ✅ 一致 | in/out/cache_read/cache_creation 均重置 |
