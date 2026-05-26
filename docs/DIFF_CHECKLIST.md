# C 版本 vs Bash 版本 差异检查清单

> 生成时间: 2026-05-25
> 状态: 待修复

---

## 1. Stats 统计模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| S1 | `sub_agent_request_count` 初始值缺失 | 🔴高 | `store_session_init` 写入的初始 stats.json 无此字段。`store_stats_set_int_file` 用 `strstr` 搜索 key，找不到则静默跳过，导致该字段永远不会被正确更新 |
| S2 | `last_updated` 从不更新 | 🟡低 | 初始化时写入空字符串 `""`，后续所有 `store_stats_set_int_file` 都不触及此字段 |
| S3 | Compact 的 token 统计缺失 | 🔴高 | Bash 版 compact 调用 `agent_record_usage` 累加 compact 的 input/output/cache tokens 到 `total_*` 字段。C 版 `agent_compact_context()` 只更新 `compact_request_count` 和 `current_turn_count`，不累加 compact 的 token 消耗 |
| S4 | 数字格式尾随空格 | 🟡低 | `store_stats_set_int_file` 原地修改时，短值用空格填充（如 `"total_input_tokens":5  `） |
| S5 | 终端标题无千位分隔 | 🟡低 | Bash 版 `fmt()` 函数输出 `1,234`，C 版直接 `%d` 输出 `1234` |

---

## 2. 文件操作工具 (Read/Write/Edit/Bash/Glob/Grep)

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| T1 | `tool_glob` 递归 vs 单层 | 🔴高 | Bash 版 `find` 默认递归搜索子目录，C 版需要确认是否也是递归 |
| T2 | `tool_grep` `--heading` 方向相反 | 🔴高 | 需要确认 C 版 grep 的 heading 参数方向 |
| T3 | `tool_grep` 缺 `--` 分隔符 | 🟠中 | Grep 命令中路径前缺少 `--` 分隔符，可能导致以 `-` 开头的文件名被误解析 |
| T4 | `tool_edit` 缺 diff 输出 | 🟠中 | Bash 版 Edit 工具显示 diff 格式的变更，C 版可能缺少 |
| T5 | `tool_bash` 缺设备写入保护 | 🟠中 | Bash 版禁止写入 `/dev/` 等设备文件，C 版可能缺少此保护 |

---

## 3. 其他工具 (TodoWrite/PlanConfirm/PlanClear/Skill/SubAgent/WebSearch/WebFetch)

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| T6 | TodoWrite 输出格式不一致 | 🟠中 | Bash 版与 C 版的 TodoWrite 输出格式可能不同 |
| T7 | SubAgent fork 模式缺 summary.txt/plan.md 复制 | 🔴高 | fork 模式下需要复制父 session 的 summary.txt 和 plan.md |
| T8 | SubAgent `sub_agent_start` 事件缺 timestamp | 🟡低 | 事件中缺少时间戳字段 |

---

## 4. SSE 解析模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| SSE1 | OpenAI SSE 路径功能严重缺失 | 🔴高 | 不支持 tool_calls 流式增量解析、reasoning/thinking、cached_tokens。通过 OpenAI 兼容 API 使用带工具调用或推理的模型时无法正常工作 |
| SSE2 | 流异常终止无保护 | 🔴高 | Bash 版 END 块保证总是发出 STOP 事件。C 版在 curl 异常中断时静默返回错误码，不发 SSE 事件 |
| SSE3 | tool input JSON 不做 unescape | 🟠中 | Bash 版在 `content_block_stop` 时对 `partial_json` 做 `unescape_json_string()`，C 版不做 |
| SSE4 | 事件发出时序不同 | 🟡低 | Bash 延迟到 `message_stop`(END块)才发 STOP/USAGE，C 在 `message_delta` 时立即发出 |

---

## 5. Session/Store 存储模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| ST1 | 项目 key 计算不一致 | 🔴高 | Bash 版做了完整规范化（去非字母数字、压缩连续 `-` 等），C 版只做 `/ → -` 替换。同一路径可能生成不同 key，导致 session 无法跨版本复用 |
| ST2 | tool_result 追加额外换行 | 🟡低 | Bash 版 tool_result 追加了额外 `\n`，可能在 conversation.jsonl 中产生空行 |

---

## 6. Display 显示模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| D1 | ERROR 输出目标不同 | 🟡中 | Bash 输出到 stderr，C 输出到 stdout |
| D2 | TOOL_RESULT 显示差异 | 🟡低 | Bash 版根据工具名区分显示（Edit=全文，Read/Write=首行summary），C 版统一显示全部内容 |
| D3 | 交互式清行缺失 | 🟡低 | C 版无 `printf '\r\033[K'` 清除提示符残留 |

---

## 7. Protocol 协议模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| P1 | thinking 参数格式不同 | 🟠中 | Bash: `type:"adaptive"` + `output_config.effort`；C: `type:"enabled"` + `budget_tokens` |
| P2 | 缺少 `x-app: cli` header | 🟢低 | C 版少了此 HTTP header |

---

## 8. Plan 功能模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| PL1 | PlanConfirm compact trigger 不同 | 🟠中 | C 版 PlanConfirm 也触发 `plan_clear` 而非 `plan_confirm` |
| PL2 | PlanConfirm 缺 mv 操作 | 🔴高 | Bash 版 `store_plan_confirm` 做了 `mv draft → plan`，C 版 PlanConfirm 工具的执行需要确认是否有对应 mv 操作 |

---

## 9. CLI 参数/启动模块

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| C1 | `--list-sessions` 未实现 | 🟢低 | C 版输出 "not implemented" |
| C2 | `--output-format` 名称不一致 | 🟢低 | Bash: `--output-format`，C: `--output` |
| C3 | `MODEL` 环境变量不支持 | 🟢低 | C 版不读取 `MODEL` 环境变量作为默认模型 |
| C4 | `--max-tokens` 不支持 k/m/g 后缀 | 🟢低 | Bash 版支持 k/m/g 后缀，C 版仅数字 |

---

## 10. System Prompt

| # | 差异 | 严重性 | 说明 |
|---|------|--------|------|
| SP1 | instruction-files 嵌套内容缺少尾部 `\n` 剥离 | 🟡低 | C 版未剥离嵌套内容尾部换行，导致 `</instruction-files>` 前多一个空行 |
| SP2 | selected-skills 嵌套内容缺少尾部 `\n` 剥离 | 🟡低 | 同上，`</selected-skills>` 前多一个空行 |
| SP3 | name 属性缺少转义 | 🟡低 | Bash 版对 name 调用 `util_json_escape()`，C 版不做转义。当前所有 name 值无特殊字符，无实际影响 |

> 静态文本内容：**完全一致** ✅
> 分段顺序（13段）：**完全一致** ✅

---

## 修复优先级排序

### P0 — 必须立即修复（功能错误）
1. **S1** sub_agent_request_count 初始值缺失
2. **S3** Compact 的 token 统计缺失
3. **ST1** 项目 key 计算不一致
4. **SSE2** 流异常终止无保护
5. **PL2** PlanConfirm 缺 mv 操作
6. **T7** SubAgent fork 模式缺文件复制

### P1 — 应该修复（行为不一致）
7. **SSE3** tool input JSON 不做 unescape
8. **T1** tool_glob 递归 vs 单层
9. **T2** tool_grep heading 方向
10. **T4** tool_edit 缺 diff 输出
11. **T5** tool_bash 缺设备写入保护
12. **P1** thinking 参数格式不同
13. **PL1** PlanConfirm compact trigger 不同
14. **SSE1** OpenAI SSE 路径功能缺失

### P2 — 可选修复（格式/低优先级）
15. **S2** last_updated 从不更新
16. **S4** 数字格式尾随空格
17. **S5** 终端标题无千位分隔
18. **T3** tool_grep 缺 `--` 分隔符
19. **T6** TodoWrite 输出格式
20. **T8** SubAgent 事件缺 timestamp
21. **D1-D3** Display 小差异
22. **P2** x-app header
23. **SP1-SP3** System Prompt 尾部换行/name转义
23. **C1-C4** CLI 小差异
