# bash-agent

纯 `bash/awk` 的极简 AI Agent。核心目标是保持运行时轻量，同时具备足够稳定的机器接口，可以独立运行，也可以被外部编排。

## 一句话定位

- `human`：给人直接在终端看
- `stream-json`：给脚本、管道、远程客户端消费

## 项目结构

```text
src/
  agent.sh              # 主入口：请求构建、SSE 解析、agent loop、内置 tools
  awk/
    json.awk            # 轻量 JSON 辅助函数
    claude_sse.awk      # Claude SSE 解析器
    openai_sse.awk      # OpenAI Chat SSE 解析器
    openai_responses.awk # OpenAI Responses SSE 解析器
    convert_messages.awk
    convert_tools.awk
scripts/
  build.sh              # 生成 dist/agent.sh 的打包脚本
tests/
  mock-server.sh        # 本地 SSE mock 服务器
  test.sh               # mock + e2e 测试
```

## 核心思路

SSE 是逐行文本流，`awk` 很适合做流式解析。项目把 Claude / OpenAI Chat / OpenAI Responses 的流式输出统一成一套事件，再由 `agent.sh` 负责后续处理。

统一事件示例：

```text
TEXT:Hello, I'll help you with that.
TEXT: Let me think...
TOOL_START:get_weather:call_abc123
TOOL_INPUT:{"location":"San Francisco"}
USAGE:in=25,out=42
STOP:end_turn
```

| 行格式 | 含义 |
| --- | --- |
| `TEXT:<content>` | 文本增量 |
| `TOOL_START:<name>:<call_id>` | 工具调用开始 |
| `TOOL_INPUT:<json>` | 完整工具输入 |
| `USAGE:in=<n>,out=<n>` | token 用量 |
| `STOP:<reason>` | 结束原因 |
| `ERROR:<message>` | 错误信息 |

## 用法

```bash
# Claude
./src/agent.sh -p claude -m claude-sonnet-4-20250514 "Say hello"

# OpenAI Chat
./src/agent.sh -p openai -m gpt-4o "Say hello"

# OpenAI Responses
./src/agent.sh -p openai-responses -m gpt-4o "Say hello"

# 机器输出
./src/agent.sh -p claude --output-format stream-json "Tell me a joke" | jq -c .

# 加载技能
./src/agent.sh --skill shell-safety "List files in /tmp"

# 交互模式
./src/agent.sh -p openai -m gpt-4o -i
```

## 供应商与 Base URL

支持：

- `claude`
- `openai`
- `openai-responses`

可以通过 `--base-url` 或环境变量接入第三方兼容服务，例如 Ollama、DeepSeek、BigModel 等。

```bash
OPENAI_BASE_URL=http://localhost:11434/v1 ./src/agent.sh -p openai -m llama3 "Hello"
```

`BASE_URL` 需要带版本路径，比如 `/v1` 或 `/v4`，程序只会在后面追加具体端点。

## 内置工具

- `read_file`：读取文件，默认最多 100KB
- `write_file`：写文件，自动创建目录
- `edit_file`：按精确字符串替换编辑
- `bash`：执行命令，30 秒超时，最多保留 50KB 输出

## CLI 参数

| 参数 | 说明 |
| --- | --- |
| `-p / --provider` | `claude` \| `openai` \| `openai-responses` |
| `-m / --model` | 模型名 |
| `--max-tokens` | 最大输出 token |
| `--system` | 系统提示词 |
| `--skill NAME` | 从 `.claude/skills/NAME/SKILL.md` 加载技能 |
| `--max-turns` | 最大 agent 循环次数 |
| `--max-context` | context 消息上限 |
| `--api-key` | 手动指定 API key |
| `--base-url` | 覆盖 API base URL |
| `--output-format` | `human` \| `stream-json` |
| `--print` | `--output-format stream-json` 的别名 |
| `--no-stream` | 禁用流式 |
| `--session [NAME]` | 使用/创建持久化会话 |
| `--continue` | 继续最近一次会话 |
| `--list-sessions` | 列出当前 project 下的会话 |
| `compact` | 单独压缩当前 session |
| `-v / --verbose` | 调试输出 |
| `-i / --interactive` | 交互模式 |

## 会话存储

会话数据按当前目录归档到项目命名空间下：

```text
~/.bash-agent/projects/<project_key>/<session_id>.jsonl
~/.bash-agent/projects/<project_key>/<session_id>.events.jsonl
~/.bash-agent/projects/<project_key>/<session_id>.summary.txt
```

- `jsonl`：当前给模型看的 context 窗口
- `events.jsonl`：完整事件日志
- `summary.txt`：压缩后的稳定摘要

## Skills

技能文件按项目目录加载，默认查找顺序是：

- `.claude/skills/<name>/SKILL.md`
- `skills/<name>/SKILL.md`

通过 `--skill NAME` 可以注入一个或多个技能，skills 会作为独立 section 插入 system prompt。
`SKILL.md` 是入口文件，但注入时会附带 skill 根目录，并支持在内容里使用 `${BASH_AGENT_SKILL_DIR}` 引用同目录下的脚本、模板或其他资源文件。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `ANTHROPIC_API_KEY` | Claude key |
| `OPENAI_API_KEY` | OpenAI key |
| `ANTHROPIC_BASE_URL` | Claude base URL |
| `OPENAI_BASE_URL` | OpenAI base URL |
| `LLM_BASE_URL` | 通用 base URL |

## 执行流程

```text
agent.sh
├── 读取参数和环境变量
├── 组装 prompt
├── 构造请求体
├── 调用 curl 发送流式请求
├── 用 awk 解析 SSE 为统一事件
├── 执行内置 tools
└── 继续多轮对话直到结束
```

## 快速开始

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."

./src/agent.sh "What's in the current directory?"
./src/agent.sh -i
./src/agent.sh compact --session demo
```

## 测试

```bash
cd tests
./mock-server.sh 8888 &
./test.sh 8888
kill %1
```

## 当前状态

- 已完成 Claude / OpenAI Chat / OpenAI Responses 的 SSE 解析
- 已完成消息格式和工具格式转换
- 已完成 4 个内置 tools
- 已支持 project-scoped session 存储
- 已支持 `compact` 子命令与自动 compaction
- 已支持 `--skill` skills 注入
- 已通过 10 个 mock / e2e 测试

## 相关文档

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [STREAM_JSON.md](STREAM_JSON.md)
- [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)
