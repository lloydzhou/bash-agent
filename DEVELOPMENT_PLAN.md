# 开发计划

这个计划按优先级和落地顺序来排。
目标是保持 agent 内核足够小，但机器接口足够强。

## P0：必须优先做

这些是一个可用的最小 agent 所必需的能力。

- session 持久化
- session 恢复和列表
- context budget 控制
- 结构化 system prompt 组装
- `stream-json` 输出模式
- 安全的 tool 执行边界
- 模型和 tool 的错误恢复
- 最小的任务 / todo 机制

## P1：应该做

这些能力会明显增强核心，但不会改变项目形态。

- todo / planning 细化
- skills 加载
- prompt 级 skills 注入
- tool 前后钩子
- 历史上下文压缩
- 稳定事实的 memory
- 更完整的 verbose / debug tracing
- 更丰富的 session 元数据

## P2：可以做

这些有用，但不应该影响 core 的轻量性。

- subagent
- worktree 隔离
- background task runner
- 多通道 remote adapter
- 更细的权限策略
- plugin routing

## P3：后置

这些明确不属于轻量 core 的范围。

- UI-first 设计
- 重型 TUI
- dashboard
- 分布式 agent 平台
- 企业级 policy 系统
- telemetry 平台
- 账号 / 计费系统

## 建议实施顺序

### 阶段 1：机器接口

目标：让 agent 先成为一个好用的 Unix 命令。

- 定义 `stream-json` 协议并冻结核心事件类型
- 输出结构化 session 事件
- 保持 stdout 适合机器消费
- 保留纯文本模式作为薄包装

### 阶段 2：Prompt、Session、Context

目标：让长会话稳定运行。

- 组装结构化 system prompt
- 持久化 transcript
- 按 session id 恢复
- 控制 context 长度
- 用 `compact` 子命令和 loop 自动触发共用同一套摘要压缩逻辑
- 保留最近的 tool 结果和关键状态
- 引入 todo / task state
- 把 planning 状态回灌给模型

### 阶段 3：Skills

目标：按需注入领域知识。

- 按名称加载 `SKILL.md`
- 只在相关场景注入 skills
- 保持 skill 加载是声明式的
- 不改 session 存储，只扩展 prompt assembly

### 阶段 4：扩展能力

目标：在不破坏 core 的前提下开放高级工作流。

- hooks
- memory
- subagent
- remote adapters

## 实际原则

如果某个功能可以放在 core 之外，通过消费 `stream-json` 就能实现，那它就应该尽量放在 core 外面。

这条原则最有利于保持项目轻量。
