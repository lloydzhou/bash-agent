# 架构说明

这个项目是一个轻量级 agent 内核。
核心目标不是 UI。
核心目标是一个稳定的命令行执行器，它可以：

- 独立运行
- 通过 stdout 输出结构化事件
- 持久化和恢复 session
- 作为其他工具的嵌入式组件

## 设计目标

保持运行时足够小、足够可组合。
凡是不属于内核自身必需的能力，都尽量放在 core 之外。

最重要的接口是 `stream-json`。
文本模式是给人看的。
`stream-json` 是给机器、远程客户端、持久化和编排系统用的。
协议细节见 [STREAM_JSON.md](STREAM_JSON.md)。

## 核心原则

- 先做单 agent
- 工具循环要可预测
- stdout 必须是结构化协议
- session 是一等公民
- context budget 是硬约束
- 扩展能力尽量不改主循环

## 系统概览

```text
stdin / args / env
        |
        v
src/agent.sh
├─ 配置和 provider 选择
├─ session 管理
├─ prompt 组装
├─ context 管理
├─ agent loop
├─ tool 运行时
├─ 权限门
├─ stream-json 输出
└─ SSE / API 适配器
        |
        v
src/awk/*
├─ JSON 辅助函数
├─ provider SSE 解析器
├─ 消息格式转换
└─ tool 格式转换
```

## 运行时分层

### 1. 入口层

负责：

- 解析 CLI 参数
- 读取环境变量
- 选择 provider 和 model
- 选择输出模式

### 2. Session 层

负责：

- 创建 session id
- 恢复历史 session
- 持久化事件历史
- 列出 session

Session 存储应该可以重放。
也就是说，持久化记录最好是事件流，而不是只存最终文本。

### 3. Context 层

负责：

- 根据运行时状态组装 prompt
- 按稳定前缀 + 动态后缀的顺序拼接
- 用轻量 section/tag 包住多行段落
- 裁剪过长的历史消息
- 控制 tool 输出长度
- 必要时压缩旧上下文
- 把被裁掉的内容整理成任务级快照，而不是简单流水账
- `compact` 是独立入口，loop 内也会在超预算时自动触发同一套压缩逻辑
- session 级 planning state 单独保存在 `todo.md`，由正常对话轮次里的 `Current plan:` 更新

只要 session 变长，这一层就是必需的。

prompt 组装不要做成重型模板引擎。
更合适的是少量占位符替换 + section 化拼接。
稳定内容尽量前置，动态内容尽量后置，这样更接近 Claude Code 的缓存友好实践。

skills 也是这一层的一部分。
它们应该按名称从项目目录加载，作为独立 section 注入 prompt，而不是改写 session 存储或主循环。
默认推荐路径是 `.claude/skills/<name>/SKILL.md`，也可以兼容 `skills/<name>/SKILL.md`。

`summary.txt` 和 `todo.md` 不同。
`summary.txt` 服务于 compact，是历史摘要。
`todo.md` 服务于 planning，是当前 session 的执行计划。

### 4. Agent Loop

核心执行循环是：

```text
调用模型 -> 解析流 -> 输出事件 -> 执行工具 -> 写回结果 -> 继续循环
```

这个循环应该简单、稳定、可预测。

### 5. Tool 层

当前核心工具：

- `read_file`
- `write_file`
- `edit_file`
- `bash`

这已经足够支撑一个最小编码 agent。

### 6. 输出层

两种输出模式已经足够：

- 人类可读文本
- `stream-json`

`stream-json` 是重点，因为它让这个内核可嵌入、可编排、可远程接入。

建议把 `stream-json` 当作机器协议，而不是 UI 协议。
session 持久化可以消费这个协议，但 session 数据本身不要和 context 混在一起。

## Prompt 组装

当前推荐的 prompt 顺序是：

1. agent identity
2. core rules
3. skills
4. stable context
5. current plan
6. task instructions

实现上可以用少量 XML-like tag 来标记段落边界，例如：

```text
<agent-identity>...</agent-identity>
<rules>...</rules>
<context-summary>...</context-summary>
<current-plan>...</current-plan>
<instructions>...</instructions>
```

这里的重点是结构清晰，而不是完整 XML 语法。

## 事件协议

建议保留的事件类型：

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

## 扩展边界

这些能力最好放在 core 之外，除非以后证明它们变成了硬需求：

- UI
- TUI
- web dashboard
- 多 agent 编排
- 重型插件管理器
- 远程传输实现细节

它们是适配器或上层能力，不是 agent 内核本身。

## 需要保持的小体积

- 主循环
- tool 运行时
- JSON 协议
- session 存储
- context budget 逻辑

这些部分保持小，项目才会一直轻量。

## 建议的模块边界

- `src/agent.sh`
  - CLI
  - session
  - prompt 组装
  - loop
  - tool 执行
- `src/awk/json.awk`
  - JSON 辅助函数
- `src/awk/*_sse.awk`
  - provider 流解析
- `src/awk/convert_*.awk`
  - 格式转换
