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
