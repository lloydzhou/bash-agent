# C 版 vs Bash 版 差异检查清单

> 生成时间：2025-05-25
> 状态说明：✅ 已修复 | ❌ 待修复 | ⚪ 设计差异无需修复

---

## 1. 已修复项 ✅

### 1.1 agent_update_title 格式
- **问题**：C 版 title 格式与 bash 版 `term_title.awk` 不一致
- **修复**：对齐为 `model T:turn R:req I:in+cr(pct) O:out C:ctx`

### 1.2 USAGE 后 stats 更新 + title 调用
- **问题**：agent_loop 中 USAGE 事件处理只存 accum，不更新 stats.json 和 title
- **修复**：在 USAGE 处理后添加 `store_stats_set_int_file` 累加 + `agent_update_title()`

### 1.3 compact 的 stats 更新后 title 调用
- **问题**：compact 流程更新 stats 后不刷新终端 title
- **修复**：在 compact stats 更新后添加 `agent_update_title()`

### 1.4 current_turn_count 递增
- **问题**：空桩代码，读了 stats 但没写回
- **修复**：用 `store_stats_set_int_file` 实现 +1 写回

### 1.5 max_tokens/length 致命 stop reason 处理
- **问题**：bash 版对 `max_tokens`/`length` stop reason 返回错误码，C 版无处理
- **修复**：return -1 + 发 ERROR 消息

### 1.6 max_turns 超限 ERROR 消息
- **问题**：超限时无 ERROR 事件通知
- **修复**：添加 ERROR 消息推送

### 1.7 sub_agent stats 更新字段
- **问题**：子 agent 结果回传时 stats 更新不完整
- **修复**：6 个字段完整更新（total_input/output_tokens, total_cache_read/creation_tokens, sub_agent_request_count, agent_request_count）

### 1.8 agent_handle_sub_agent_result 签名
- **问题**：缺少 `request_count` 参数
- **修复**：添加参数，更新 3 个调用点（agent.c×2, cagent.c×1）

### 1.9 sub_agent_result 事件记录
- **问题**：缺少 sub_agent_result 事件（bash 版有）
- **修复**：添加事件记录，对齐 bash 版格式

### 1.10 sub_agent_end 事件 timestamp
- **问题**：sub_agent_end 事件无时间戳
- **修复**：添加 `timestamp` 字段

### 1.11 store_stats_set_int_file 值变长时静默丢弃 🔴
- **问题**：`store_stats_set_int_file` 使用"原地覆盖"策略，当新值位数 > 旧值位数时（如 `0`→`13`）直接放弃写入，导致 **所有从 0 开始累加的 token 统计字段全部为 0**
- **修复**：值变长时改用"切分拼接"策略，将 JSON 文本在旧值前后切断，拼上新值后整体写回
- **影响**：这是 stats.json 数据全为 0 的根因

---

## 2. 待修复项 ❌

### 2.1 🔴 Session 初始化：stats.json 缺少 `sub_agent_request_count`
- **Bash**：初始化时包含 `sub_agent_request_count:0`
- **C**：初始化时不包含此字段
- **影响**：首次 sub_agent 结果回传时 `store_stats_get_file_int` 返回 0（因为字段不存在），虽然结果正确（0+1=1），但与其他版本行为不一致

### 2.2 🔴 Session 初始化：新会话判断文件不一致
- **Bash**：检查 `events.jsonl` 是否存在判断新会话
- **C**：检查 `conversation.jsonl` 是否存在
- **影响**：如果 events.jsonl 被删除但 conversation.jsonl 存在（或反之），两边行为不同

### 2.3 🔴 Compact：summary 调用不走 llm_call 抽象层，无 cache
- **Bash**：summary 调用复用 `llm_call`，享受 prompt caching
- **C**：直接 `http_post_sse`，构造全新请求体，**每次全量付费**
- **影响**：严重浪费 token / 成本

### 2.4 🔴 Compact：summary token 不计入 stats
- **Bash**：通过 `agent_record_usage "compact"` 记录 token
- **C**：**完全不计入** summary 调用的 token 开销
- **影响**：成本/用量追踪严重不准

### 2.5 🟡 Compact：turn_keep vs 行数比例截断
- **Bash**：`store_conv_turn_keep 0.12` 按 **turn 边界** 截断
- **C**：`(int)(line_count * 0.12 + 0.5)` 纯按 **行数比例** 截断
- **影响**：可能在消息中间截断，破坏 conversation 完整性

### 2.6 🟡 Compact：summary 失败处理不一致
- **Bash**：`util_die` 终止进程
- **C**：静默继续（conversation 已 trim 但 summary 为空/旧值）
- **影响**：C 版可能在无 summary 的情况下继续运行

### 2.7 ~~🟡 Compact：plan_* 强制压缩可能被 guard 阻止~~ ✅
- **Bash**：plan_clear/plan_confirm 强制执行，即使 keep==0
- **C**：`if (keep >= line_count) return 0` 可能阻止 plan_* 的强制压缩
- **修复**：添加 trigger 检查，plan_clear/plan_confirm 绕过守卫
- **影响**：plan_clear/plan_confirm 现在可以正常工作

### 2.8 🟡 Compact：compact_request_count 无条件 +1
- **Bash**：只有 summary 成功才 +1（通过 `agent_record_usage`）
- **C**：进入 compact 流程就 +1
- **影响**：统计不准

### 2.9 ~~🟡 Compact：trigger 值不一致~~ ✅
- **Bash**：分别传 `plan_clear` / `plan_confirm` / `auto`
- **C**：PlanClear 和 PlanConfirm 统一传 `"store_plan_clear"`
- **修复**：改为与 bash 版一致的 `plan_clear` / `plan_confirm`
- **影响**：trigger 值现在与 bash 版完全一致

### 2.10 🟡 Fork 时 C 版不复制 `summary.txt` 和 `plan.md`
- **Bash**：fork 复制三个文件（summary.txt, plan.md, plan.draft）
- **C**：只复制 `plan.draft`
- **影响**：fork 模式子 agent 缺少 summary 和 plan 上下文

### 2.11 🟡 Read/Write 工具 conversation 保存内容不同
- **Bash**：`result_for_conv` = 原始 output（summary prepend 到 `$output` 在赋值之后）
- **C**：`tr.output` = `summary + "\n" + output`（直接拼入 output）
- **影响**：C 版 conversation 中 Read/Write 结果多了 summary 前缀行

### 2.12 🟡 Read/Write 工具 display 显示不同
- **Bash**：display 显示 `summary + "\n" + 完整 output`
- **C**：display **只显示 summary 行**
- **影响**：C 版用户在终端看不到 Read/Write 的文件内容

### 2.13 🟡 工具执行失败时的错误包装
- **Bash**：`output="Error: tool execution failed: $output"`
- **C**：直接使用 tool_dispatch 返回的原始 output
- **影响**：C 版工具失败时的错误信息格式不同

### 2.14 🟡 缺少 tool_emit_result 中 checklist/summary 透传
- **Bash**：`tool_emit_result` 遍历 REPLY_MESSAGE，将 checklist 和 summary 字段透传到 TOOL_RESULT 消息
- **C**：**无此逻辑**，TOOL_RESULT 消息不含 checklist/summary
- **影响**：display/replay 中的工具结果缺少辅助信息

### 2.15 🟢 CONTEXT_UPDATE 事件缺少 kind 字段
- **Bash**：`{"type":"context_update","kind":"compact","trigger":"auto"}`
- **C**：只有 trigger 字段，缺少 kind 字段
- **影响**：stream-json 输出格式不完整

### 2.16 🟢 C 版多了 DISPLAY_SUB_AGENT_START 类型
- **Bash**：无此消息类型
- **C**：有此枚举但 human 渲染为空实现
- **影响**：无实质影响（行为等价）

### 2.17 🟢 Bash 独有 RETRY 消息类型
- **Bash**：display_message 中不渲染（落入 `*)` 默认分支），仅在 stream-json 中序列化
- **C**：完全无此类型
- **影响**：stream-json 模式下 replay 输出差异

### 2.18 🟢 Bash 独有 USER_MESSAGE 消息类型
- **Bash**：display_message 中渲染用户消息（绿色 `>` 前缀），但 util_msg_to_stream 不序列化
- **C**：完全无此类型
- **影响**：human 模式下显示差异

---

## 3. 设计差异无需修复 ⚪

### 3.1 input.fifo → MsgQueue
- **Bash**：使用 input.fifo (named pipe) 传递消息
- **C**：使用 MsgQueue（线程安全队列）替代
- **说明**：架构差异，C 版的 MsgQueue 更高效，无需对齐

### 3.2 字段复用
- **Bash**：每个消息类型有独立字段名
- **C**：`DisplayMessage` 结构体中 `tool_name`/`tool_exit_code` 被复用来存不同含义的字段
- **说明**：内存布局优化，不影响外部行为

### 3.3 assistant 消息写入时机
- **Bash**：工具执行**之后**写入 assistant 消息
- **C**：工具执行**之前**写入
- **说明**：最终 conversation.jsonl 行序一致，无实质差异

---

## 4. 手动测试检查项

### 4.1 Stats 验证
- [ ] 运行一次完整对话（≥3 轮），检查 `stats.json` 中 `total_input_tokens`、`total_output_tokens` 非零
- [ ] 检查 `cache_read_tokens`、`cache_creation_tokens` 非零（如果模型支持 cache）
- [ ] 检查 `current_context_tokens` 随对话增长
- [ ] 触发 compact，检查 `compact_request_count` 和 token 统计变化

### 4.2 Compact 验证
- [ ] 长对话触发 auto compact，检查 conversation.jsonl 是否被正确截断（按 turn 边界 vs 按行）
- [ ] 手动触发 plan_clear，检查是否强制执行
- [ ] summary 生成失败时的行为（可临时设置无效 API key 测试）

### 4.3 Read/Write 工具验证
- [ ] 执行 Read 工具，检查终端 display 是否显示完整文件内容（vs 只有 summary 行）
- [ ] 检查 conversation.jsonl 中 Read 工具的 tool_result 内容（是否包含 summary 前缀）
- [ ] 执行 Write 工具，同上验证

### 4.4 SubAgent 验证
- [ ] 启动子 agent，检查 `sub_agent_request_count` 是否正确累加
- [ ] fork 模式下检查子 agent 是否能访问 summary.txt 和 plan.md
- [ ] 检查子 agent 的 token 是否正确计入父 agent 的 stats

### 4.5 工具错误验证
- [ ] 触发工具执行失败（如 Read 不存在的文件），检查错误消息格式
- [ ] 检查 display 中是否显示 `Error: tool execution failed: ...` 前缀

---

## 5. 优先级排序

| 优先级 | 编号 | 描述 |
|--------|------|------|
| P0 | 2.3 | Compact summary 不走 cache，浪费 token |
| P0 | 2.4 | Compact summary token 不计入 stats |
| P1 | 2.5 | Compact 按行截断可能破坏消息完整性 |
| P1 | 2.12 | Read/Write display 只显示 summary，用户看不到内容 |
| P1 | 2.11 | Read/Write conversation 多了 summary 前缀 |
| P1 | 2.10 | Fork 缺少 summary.txt 和 plan.md |
| P2 | 2.6 | Compact summary 失败静默继续 |
| P2 | 2.7 | plan_* 强制压缩可能被 guard 阻止 |
| P2 | 2.8 | compact_request_count 无条件 +1 |
| P2 | 2.13 | 工具失败错误包装不一致 |
| P2 | 2.14 | 缺少 checklist/summary 透传 |
| P2 | 2.1 | 初始化缺少 sub_agent_request_count |
| P2 | 2.2 | 新会话判断文件不一致 |
| P3 | 2.9, 2.15 | trigger/kind 字段差异 |
| P3 | 2.16-2.18 | 消息类型覆盖差异 |
