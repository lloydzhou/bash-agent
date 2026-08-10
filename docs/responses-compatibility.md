# Responses API 兼容边界

## 基准与范围

本项目以 OpenAI Responses `create` 的公开类型与事件模型为参考；当前 `responses` provider 的默认端点面向 DeepSeek Responses 兼容接口。四个运行时（Bash、Go、Rust、C）只实现可映射到本地流式函数工具循环的安全交集，而不是宣称完整实现任何服务端的 Responses API。

## 已支持的安全子集

| 能力 | 状态 | 说明 |
| --- | --- | --- |
| 请求基本字段 | 支持 | `model`、`input`、`instructions`、`max_output_tokens`、`stream`。 |
| 推理强度 | 支持 | 在运行时已有 thinking 配置时映射为 `reasoning.effort`。 |
| 本地函数工具 | 支持 | 本地 tool 定义映射为 `type: "function"`。 |
| 文本历史 | 支持 | 用户和助手文本转换为 Responses 输入项。 |
| 函数调用历史 | 支持 | 助手 `tool_use` 转换为 `function_call`。 |
| 函数结果历史 | 支持 | 用户 `tool_result` 转换为 `function_call_output`。 |
| 文本与推理流 | 支持 | 处理 `response.output_text.delta` 与 `response.reasoning_text.delta`。 |
| 函数调用流 | 支持 | 处理 function item、参数增量和完成事件，并映射到本地 tool loop。 |
| 终态与用量 | 支持 | 处理 completed、failed、incomplete、顶层 error、重试和 usage；优先读取 `input_tokens_details.cached_tokens`，无有效值时回退 `cached_tokens`。 |
| 异常 EOF | 支持 | 未收到终态时统一发出中断错误和 `STOP:error`。 |

## 明确不支持

以下能力不能在当前本地 agent 会话模型中安全等价，不能透传或伪装支持：

| 能力 | 原因 |
| --- | --- |
| 托管工具 | `web_search`、文件搜索、代码解释器、计算机控制、图像生成等由服务端执行；本地 tool loop 不具备对应生命周期与结果项持久化。 |
| MCP、custom、shell、apply_patch 等工具 | 不具备跨服务端工具协议、调用语义和安全模型。 |
| 原始 reasoning 项回放 | 当前只消费推理文本供显示，不保存可重放的 provider 原始 item。 |
| 多模态输入或输出 | 当前会话和本地工具协议只覆盖文本与 JSON 函数参数。 |
| `previous_response_id`、`conversation`、`store`、`background` | 本地 session 是唯一会话状态来源，不能与服务端状态混用。 |
| `parallel_tool_calls` | 本地工具调度语义仍为顺序执行，尚未定义并行调用的状态、失败与结果排序规则。 |
| `tool_choice` | 尚未定义对本地工具的 auto、none、required 或指定函数约束映射。 |
| function `strict` | 内部工具定义尚无对应 schema 约束模型。 |

## 兼容性原则

- Bash 是行为基准；Go、Rust、C 必须保持相同的请求转换、SSE 终态和 usage 语义。
- 不支持的 Responses 能力必须显式保持未实现，不能只因其 JSON 结构可透传就启用。
- 后续若要支持托管工具或 reasoning 连续上下文，必须先设计原始 provider item 的持久化、回放和跨运行时测试。
