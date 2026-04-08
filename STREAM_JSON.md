# `stream-json` 协议

这个文档定义 `bash-agent` 的机器输出协议。
目标是：

- 让外部程序稳定消费 stdout
- 让 session 持久化可重放
- 让 human 输出和机器输出严格分离
- 让协议保持轻量、可扩展

## 总原则

- `human` 用给人看
- `stream-json` 用给机器看
- 每个事件一行 JSON
- 不输出协议外的杂质文本
- 不把 session 日志和 context 请求混在一起

## 数据边界

这三个概念必须分开：

- `session`
  - 完整会话历史
  - 用于持久化、回放、审计
- `context`
  - 真正发给 LLM 的消息窗口
  - 只保留当前轮需要的内容
- `stream-json`
  - stdout 事件流
  - 外部程序消费的协议

`session` 可以包含比 `context` 更多的历史。
`stream-json` 只是事件出口，不等于 session，也不等于 context。

## 事件类型

当前保留的事件类型如下：

- `session_start`
- `text`
- `tool_start`
- `tool_input`
- `tool_result`
- `usage`
- `stop`
- `error`
- `context_update`
- `debug`

## 事件语义

### `session_start`

会话启动时输出。

字段：

- `type`: `"session_start"`
- `session_id`: 会话 id

### `text`

模型输出的正文片段。

字段：

- `type`: `"text"`
- `content`: 文本片段

### `tool_start`

模型请求调用工具时输出。

字段：

- `type`: `"tool_start"`
- `name`: 工具名
- `id`: tool call id

### `tool_input`

工具输入内容的增量或最终输入。

字段：

- `type`: `"tool_input"`
- `content`: 工具输入

### `tool_result`

工具执行完成后输出。

字段：

- `type`: `"tool_result"`
- `tool_use_id`: 对应 tool call id
- `content`: 工具结果

### `usage`

可选的 token 使用信息。

字段：

- `type`: `"usage"`
- `input_tokens`: 输入 token
- `output_tokens`: 输出 token

### `stop`

模型结束原因。

字段：

- `type`: `"stop"`
- `reason`: 结束原因

### `error`

错误事件。

字段：

- `type`: `"error"`
- `message`: 错误信息

### `context_update`

上下文发生结构性变化时输出。

当前主要用于：

- 自动 compact
- 手动 compact

字段：

- `type`: `"context_update"`
- `kind`: 例如 `"compact"`
- `trigger`: `"auto"` 或 `"manual"`

### `debug`

调试事件，默认可以不输出。

字段：

- `type`: `"debug"`
- `message`: 调试信息

## 顺序原则

事件顺序应该尽量稳定：

1. `session_start`
2. `text` / `tool_start` / `tool_input`
3. `tool_result`
4. `usage`
5. `stop`
6. `context_update`
7. `error`

注意：

- `context_update` 不是模型输出的一部分
- 它是对上下文状态变化的通知
- 外部消费者可以忽略它，也可以据此刷新缓存

## human 和 stream-json

这两种输出模式的边界如下：

- `human`
  - 适合终端交互
  - 可以带轻量提示
  - 可以有换行和简单格式
- `stream-json`
  - 适合脚本、管道、远程消费
  - 每行一个 JSON 事件
  - 不输出额外说明文字

## 稳定性要求

为了保证协议长期可用：

- 字段名尽量不变
- 事件类型尽量不乱改
- 新增字段可以兼容旧消费者
- 不要把 session 内部实现细节直接混进 stdout

## 兼容性建议

如果后面要扩展协议，优先：

- 新增事件类型
- 新增字段
- 保持旧字段仍然可用

不要：

- 直接重命名现有字段
- 改变已有事件的基本语义
- 把 human 输出塞回 stream-json

