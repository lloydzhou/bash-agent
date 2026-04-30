# Session 与状态文件

## 存储位置

所有会话数据按项目保存：

```text
~/.bash-agent/projects/<project_key>/
```

`<project_key>` 由项目目录路径生成。

## Session 文件

每个 session 目录包含：

```text
<session_id>/
  conversation.jsonl   当前对话窗口（发给模型的消息）
  events.jsonl         内部事件日志
  summary.txt          compact 后的历史摘要
  todo.md              当前 session 的 todo 状态
  plan.md              当前 session 的计划文档
```

### conversation.jsonl

当前真正发给模型的消息窗口。NDJSON 格式，每行一条消息：

```json
{"role":"user","content":"fix the bug"}
{"role":"assistant","content":"I'll analyze..."}
```

compact 后，旧消息被摘要替代，此文件只保留最新窗口。

### events.jsonl

内部事件日志，记录 session 的完整操作历史。用于：
- 交互模式恢复时回放最近 10 轮对话
- 调试和审计

### summary.txt

compact 后的历史摘要。由 LLM 生成，替代被丢弃的旧消息。

设计约束：
- 新旧摘要长度固定为 S = 500 token
- 摘要位于 system prompt 固定前缀中，每次请求都发送

### todo.md

由 `TodoWrite` 工具维护的 session 级待办清单。

### plan.md

由 `plan-lifecycle-guidance` 机制维护的当前计划文档。

## 恢复与持久化

- 所有会话都持久化，即使不传 `--session` 也会生成 session_id 并保存
- `--session NAME` 创建或恢复指定 session
- `--continue` 恢复当前项目最近一次 session
- `--list-sessions` 列出当前项目的所有 session

## Session Replay

恢复 session 时（`--continue` 或 `--session`），交互模式会回放最近 10 轮对话：

- 读取 `events.jsonl`，按 `user_input`/`user_message` 事件标记 turn 边界
- 使用 `event_replay.awk`（bash）或 `display_replay_event()`（Go/Rust）转为 REPL 输出
- `session_start`/`usage`/`retry` 事件不回放
- 回放完成后输出空行分隔，再接交互提示符
