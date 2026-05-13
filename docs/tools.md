# 内置工具

## `Read`

读取文件内容。

| 参数 | 类型 | 说明 |
|---|---|---|
| `path` | string | 文件路径 |
| `offset` | int | 起始行号（可选） |
| `limit` | int | 读取行数（可选） |

- 默认结果上限 50KB，超出截断
- 支持多文件读取（多次调用）
- 编辑前先用 `offset`/`limit` 定位目标行

## `Write`

写入文件内容。

| 参数 | 类型 | 说明 |
|---|---|---|
| `path` | string | 文件路径 |
| `content` | string | 写入内容 |

- 自动创建父目录
- 默认写入上限 1MB
- 覆盖写入，不是追加

## `Edit`

精确字符串替换。

| 参数 | 类型 | 说明 |
|---|---|---|
| `path` | string | 文件路径 |
| `old_string` | string | 要替换的文本（必须精确匹配） |
| `new_string` | string | 替换后的文本 |

- 匹配时包括空白符、缩进、换行，必须 byte-for-byte
- 默认写入上限 1MB
- 不支持正则，只做精确字符串替换
- 适合精确的小范围修改

## `Bash`

执行 shell 命令。

| 参数 | 类型 | 说明 |
|---|---|---|
| `command` | string | shell 命令 |
| `timeout` | int | 单条命令超时秒数（可选） |

- 默认超时 600s（可通过 `--tool-timeout` 全局设置）
- 大输出自动截断
- 返回 stdout + stderr

## `Glob`

文件匹配发现。

| 参数 | 类型 | 说明 |
|---|---|---|
| `pattern` | string | glob 模式 |
| `path` | string | 搜索目录（可选） |

- 基于 `rg --files -g`
- 依赖 `rg`（ripgrep）

## `Grep`

内容搜索。

| 参数 | 类型 | 说明 |
|---|---|---|
| `pattern` | string | 正则表达式 |
| `path` | string | 搜索路径（可选） |
| `glob` | string | 文件过滤（可选） |
| `context` | int | 匹配行前后 N 行（可选） |

- 基于 `rg -n`
- `context` 显示匹配行前后 N 行，便于直接定位编辑位置
- 依赖 `rg`（ripgrep）

## `TodoWrite`

维护 session 级 todo checklist。

| 参数 | 类型 | 说明 |
|---|---|---|
| `todos` | array | todo 列表，每项含 `content` 和 `status` |

- 面向复杂多步任务
- 状态保存在 session 目录的 `todo.md`
- `status` 取值：`pending` / `in_progress` / `completed`

## `PlanConfirm`

确认并锁定当前 plan draft。

无参数。

- 仅在用户明确确认 plan 时调用
- 将 `plan.draft` 移至 `plan.md` 并触发上下文压缩
- 不要在规划阶段或用户要求修改时调用

## `PlanClear`

清空当前 plan。

无参数。

- 在 plan 执行完毕、所有任务完成后调用
- 调用后 system prompt 中不再包含 plan section

## `SubAgent`

启动子代理执行任务。

| 参数 | 类型 | 说明 |
|---|---|---|
| `prompt` | string | 子代理执行的任务描述（必需） |
| `description` | string | 简短任务描述，用于日志记录（可选） |
| `fork` | boolean | 设为 `true` 启用 fork 模式，继承父会话上下文（可选） |

**两种模式**：

| 模式 | 触发方式 | 上下文 | 适用场景 |
|------|---------|--------|---------|
| 独立模式（默认） | 不设置 `fork` | 全新会话，无法看到父会话对话历史 | 独立文件调查、聚焦搜索、隔离假设验证等不需要父会话上下文的任务 |
| Fork 模式 | `fork=true` | 继承父会话的对话历史、计划、技能 | 需要父会话上下文的子任务（如延续当前对话中已建立的推理链） |

- 独立模式下 prompt 必须自包含：包含所有文件路径、函数名、错误信息、约束条件
- Fork 模式下 prompt 可引用父会话上下文，无需重复提供已有信息
- **返回启动确认**：立即返回 `Sub-agent started: session_id=...`，表示子 agent 已启动
- **实际结果注入**：子 agent 完成后，结果以 user message 注入父会话，格式为 `[Sub-agent result | session_id=... | status=ok|failed | tokens_in=... tokens_out=...]`
- 同一轮中的多个 `SubAgent` 调用**并发**执行
- 失败时（`status=failed`）结果可能部分或为空，不要自动重试
- 子 agent 的 token 用量会累加到父会话的 `total_input_tokens` / `total_output_tokens`

## `Skill`

按需加载 skill。

| 参数 | 类型 | 说明 |
|---|---|---|
| `name` | string | skill 名称（从 skill-index 中选择） |

- 先从 prompt 的 `skill-index` 匹配名称
- 再读取对应的 `SKILL.md`
- 不修改后续轮次的 system prompt

## `WebSearch`

网络搜索。

| 参数 | 类型 | 说明 |
|---|---|---|
| `query` | string | 搜索关键词 |

- 基于 Jina AI Search API
- 依赖 `JINA_API_KEY` 环境变量
- 默认超时 30s
- 返回结果包含标题和 URL

## `WebFetch`

获取网页内容。

| 参数 | 类型 | 说明 |
|---|---|---|
| `url` | string | 网页 URL |

- 基于 Jina AI Reader API
- 依赖 `JINA_API_KEY` 环境变量
- 默认超时 60s
- 返回 markdown 格式内容
- 无法访问需要认证的私有 URL
