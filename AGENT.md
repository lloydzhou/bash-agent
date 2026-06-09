# Agents Guide

## 编译与测试

### 快速命令

```bash
# 编译所有版本
make build

# 运行所有测试
make test

# 清理构建产物
make clean
```

### 分项命令

| 命令 | 说明 |
|------|------|
| `make build-bash` | 编译 Bash 版本到 dist/agent.sh |
| `make build-go` | 编译 Go 版本到 dist/goagent |
| `make build-rust` | 编译 Rust 版本到 dist/rustagent |
| `make test-bash` | 运行 Bash 测试 (tests/test.sh) |
| `make test-go` | 运行 Go 单元测试 |
| `make test-go-e2e` | 运行 Go 版本集成测试 (build + test.sh) |
| `make test-rust` | 运行 Rust 编译检查 |
| `make test-rust-e2e` | 运行 Rust 版本集成测试 (build + test.sh) |

### 测试覆盖

- **tests/test.sh** — 主要的集成测试，覆盖：
  - 工具函数 (agent.sh 中的辅助函数)
  - SubAgent 正常/失败/fork/隔离场景
  - JSON 解析、配置解析
  - 压缩决策 (compact_dp)
  - 统计更新 (stats.awk)

- **go/** — Go 版本单元测试：
  - app_test.go — 核心应用逻辑测试

- **rust/** — Rust 版本检查：
  - cargo check — 编译验证 + 类型检查

### 日常开发测试

修改某个版本时，只需运行该版本的 e2e 测试，无需每次都跑 `make test`（会触发较慢的 Bash 测试）。

| 改动范围 | 推荐命令 | 说明 |
|----------|----------|------|
| 仅 Go | `make test-go-e2e` | 编译 + 集成测试 |
| 仅 Rust | `make test-rust-e2e` | 编译 + 集成测试 |
| 仅 C | `make build-c && AGENT=./dist/cagent bash tests/test.sh` | 编译 + 集成测试 |
| 仅 Bash | `make test-bash` | Bash 单元/集成测试 |
| 全部版本 | `make test` | 跑所有版本测试 |

> **提示**：`make test-bash` 是最慢的（涉及 agent.sh 源码级测试）。如果只改了 Go/Rust/C，直接用对应 e2e 命令即可，节省时间。

### CI 推荐流程

```bash
# 完整检查
make build && make test
```

## 版本一致性要求

Bash / Go / Rust / C 四个版本的 **system prompt** 和 **tools.json** 必须完全一致。不一致会导致同一 session 切换版本时 LLM KV cache 失效（system prompt 不同 → 请求体前缀不同 → cache miss），浪费 token。

**最高优先级**: system prompt 是协议面的一部分。任何会改变 section 顺序、标签包装、空行、尾部换行、`name` 属性转义、静态文案或动态 section 拼接规则的改动，都必须同步所有 runtime 后才能合入。

### 关键文件

| 文件 | 作用 | 同步说明 |
|------|------|----------|
| `src/tools.json` | 工具定义 JSON | **基准文件**，修改后必须同步到 `rust/src/tools.json` 和 `go/tools.json` |
| `src/agent.sh` | Bash 版 system prompt (`agent_build_prompt`) | **基准**，Go/Rust/C 的 prompt builder 必须逐字对齐 |
| `go/agent.go` | Go 版 system prompt (`BuildPrompt`) | 内容、顺序、格式必须与 bash 一致 |
| `rust/src/lib.rs` | Rust 版 system prompt (`build_system_prompt`) | 同上 |
| `c/agent.c` | C 版 system prompt (`agent_build_prompt`) | 同上 |

### 检查清单（修改任一 prompt 区域时）

- [ ] `rust/src/lib.rs` 的 `build_system_prompt` 是否同步？
- [ ] `go/agent.go` 的 `BuildPrompt` 是否同步？
- [ ] `c/agent.c` 的 `agent_build_prompt` 是否同步？
- [ ] section 包装、空行、尾部换行和 `name` 属性转义是否逐字一致？
- [ ] `go/`、`rust/src/`、`c/`、`src/` 四处的 `tools.json` SHA256 是否一致？(`sha256sum src/tools.json rust/src/tools.json go/tools.json c/tools.json`)

> **经验**: 同一 session 在三个版本间切换是正常的开发/调试流程。system prompt 不同直接导致缓存失效，每次切换都相当于冷启动。保持一致性就是省钱。

### 请求体一致性（最高优先级）

所有发往 LLM API 的请求（包括正常 agent 调用、compact summary 调用、SubAgent 调用），其请求体的构建方式 **必须与 Bash 版本逐字段对齐**。请求体前缀的一致性直接决定 KV cache 命中率，任何字段缺失或顺序不同都会导致 cache miss，每次多花数十万 token。

**核心规则**：
1. **Port 版本不得自行决定"优化掉"某些字段**。即使 compact summary 不需要 tools，Bash 版带了 tools，所有 Port 版就必须带。前缀一致比省几个 input token 重要得多（cache_creation 费用远高于 input 费用）
2. **必须复用同一个请求构建函数**。C 版本用 `build_claude_request`，Go 版本用 `buildClaudeBody`/`Call`，Rust 版本用 `build_claude_request`。任何类型的请求都走同一条构建路径，不允许手动拼 JSON
3. **请求体字段顺序必须一致**：`model → max_tokens → stream → thinking → output_config → system → tools → messages`

**检查清单（修改任何请求构建逻辑时）**：
- [ ] Bash 版 `llm_call` / `llm_summary_call` 的请求体结构是什么？
- [ ] C / Go / Rust 的 compact/summary 调用是否复用了正常请求的构建函数？
- [ ] 对比正常请求和 summary 请求：model、max_tokens、stream、system、tools 字段是否全部一致？
- [ ] 唯一允许的差异：messages 内容、thinking 可以为 "disabled"

> **教训**: C 版本曾手动拼 compact 请求体，缺少 system/tools/stream 字段；Go 版本 SummaryCall 传了空 system 和空 tools。两者都导致 cache_read=0，每次 compact 多花大量 token。这种问题必须在代码审查阶段通过"与 Bash 版逐字段对比"来杜绝。

### 操作顺序与缓存利用（最高优先级）

Bash 版中多处操作的执行顺序是**精心设计的**，目的是最大限度利用 KV cache 前缀匹配。Port 版本必须完全复刻这些顺序，任何调换都会导致额外的冷启动（每次多花数十万 token）。

#### 1. PlanConfirm / PlanClear：先 compact 再写 plan 文件

```
# Bash 版 tool_plan_confirm() 和 tool_plan_clear()
agent_compact_context(plan_confirm)   # ① 先 compact — 此时 plan 文件未变，system prompt 前缀不变，复用旧缓存
store_plan_confirm()                   # ② 再 mv draft→plan — 之后 system prompt 才变化，下一次 LLM call 走新前缀
```

**为什么这个顺序重要**：compact 调用 `llm_call` 发起一次 LLM 请求，该请求的 system prompt 包含旧的 plan 内容。如果先写 plan 再 compact，compact 的 system prompt 就变了，这次请求无法复用之前的 KV cache（cache miss）。先 compact 可以让这次请求走旧前缀命中 cache，compact 结束后再更新 plan，下一轮正常请求走新前缀——总共只有一次冷启动。

**PlanClear 同理**：先 compact（旧 plan 仍在前缀里），再清空 plan 文件（新前缀生效）。

#### 2. Compact 内部：先 summary 再 trim conversation

```
summary_response=$(llm_summary_call "$dropped_messages")   # ① 先调 LLM 生成 summary
store_summary_set "$summary_response"                       # ② 写 summary 到文件
store_conv_trim_tail "$keep_lines"                           # ③ 最后才裁剪 conversation
```

**为什么这个顺序重要**：summary 调用也是一次 LLM 请求。在 summary 调用时，conversation 文件尚未裁剪，构建的 messages 完整包含所有旧消息。这保证了请求体前缀（system + tools + messages 前半段）与之前的正常请求尽可能一致，最大化 cache 命中。如果先 trim 再 summary，messages 前缀变了，cache 全部失效。

#### 3. 主循环：每轮 LLM call 之前先 compact

```
while (( turn < MAX_TURNS )); do
    agent_compact_context auto                              # ① 先检查是否需要 compact
    llm_call "$(store_conv_get_messages)"                   # ② 再发起 LLM 请求
    # ... 处理响应 ...
    store_conv_add_assistant "$text" "$thinking" ...         # ③ 最后才写 conversation
    store_stats_update current_context_tokens=...            # ④ 更新 token 统计
done
```

**为什么 compact 在 LLM call 之前**：compact 会裁剪 conversation 并更新 summary，这些变更反映到下一次 `store_conv_get_messages` 调用中。如果在 LLM call 之后 compact，那么当前请求发送的是旧 conversation（可能已超过 token 限制），而 compact 的结果白白浪费——因为下一次 LLM call 又会重新读取 conversation。

**为什么 store_conv 和 stats 在最后**：必须等 LLM 返回结果（包括 USAGE 中的 token 数）后再写入。这样保证写入的数据是完整、准确的。如果中途写入不完整数据，下次 compact 的决策会基于错误信息。

#### 4. Plan 的两文件设计：draft 不触发缓存失效，plan 才触发

System prompt 中的 `current-plan` section 读取自 `PLAN_FILE`。`PLAN_DRAFT_FILE` 是外部文件，不在 system prompt 中。

| 文件 | 在 system prompt 中？ | 写入后缓存是否失效 |
|------|-----------------------|-------------------|
| `PLAN_DRAFT_FILE` (plan.draft) | ❌ 不在 | ✅ 不失效（可随意编辑） |
| `PLAN_FILE` (plan.md) | ✅ 在 `current-plan` section | ⚠️ 立即失效（下次 LLM call 重建 prompt） |

**设计意图**：用户在规划阶段频繁修改 plan，每次都写 PLAN_FILE 会导致每次 LLM call 的 system prompt 都不同，KV cache 全部浪费。用 PLAN_DRAFT_FILE 作为草稿缓冲，只在 PlanConfirm 时一次性写入 PLAN_FILE，确保规划阶段零额外缓存开销。

#### 5. Summary 调用复用 llm_call 函数

```bash
# llm_summary_call 内部直接调用 llm_call：
llm_call "$messages" "" disabled    # "" = max_tokens 默认值，disabled = 关闭 thinking
```

Summary 调用不复用独立函数，而是直接调用 `llm_call`，传入 `disabled` 关闭 thinking。这保证了请求体的 `model → max_tokens → stream → system → tools → messages` 结构与正常请求完全一致（仅 thinking 字段省略），最大化 KV cache 前缀匹配。

#### 检查清单（修改任何操作顺序时）

- [ ] PlanConfirm / PlanClear 是否先 compact 再写 plan 文件？
- [ ] Compact 是否先 summary LLM 调用再 trim conversation？
- [ ] 主循环是否先 compact 再 LLM call，最后才写 conversation 和 stats？
- [ ] Summary 调用是否复用了正常请求构建函数（不手动拼 JSON）？
- [ ] 任何新增加的"写文件"操作，是否会影响 system prompt 的某个 section？如果是，是否有对应的缓存策略？

> **原则**：凡是会改变下一次 LLM 请求前缀的操作（写 plan、写 summary、trim conversation），都必须在**正确的时机**执行。过早写入 = 前缀提前变化 = cache miss；过晚写入 = 数据不一致。顺序即缓存，缓存即成本。

### 架构逻辑一致性

C / Go / Rust 是 Bash 版的 **Port 版本**，整体架构必须完全复刻 Bash 版。Bash 版是主线，所有架构决策以 Bash 版为准。三个 Port 版本在 Bash 版因语言限制做不到的地方可以超越（如多线程、原子操作等），但 **Port 版本之间的差异也必须保持一致**——不允许某个 Port 版本有独有行为而其他版本没有。

**规则**:
1. 以 Bash 版为主线，任何运行时行为改动先改 Bash 版，再同步到 C / Go / Rust
2. C / Go / Rust 三个版本之间必须完全一致，不得出现某个版本独有的行为或缺失
3. 如果 Bash 版因语言限制无法实现某个功能，三个 Port 版本仍须保持一致
4. **所有核心逻辑（请求构建、compact 流程、SubAgent 隔离、tool dispatch 等）必须与 Bash 版逐行对比验证，不允许 Port 版本自作主张的"优化"或"简化"**
