# bash-llm + bash-agent

纯 bash/awk 的极简 AI Agent 生态系统。零外部依赖（bash, curl, awk 即可）。

## 项目结构

```
llm.sh              # 通用 LLM CLI — awk 解析 SSE，统一输出协议
agent.sh            # AI Agent — 调用 llm.sh，实现 agent loop + tools
tests/
  mock-server.sh    # 测试用 Mock SSE 服务器（Python）
  test.sh           # 自动化测试脚本（8 个 mock 测试）
  test-tool-stop.sh # 真实 API tool_use 测试（需配置 API key）
```

## bash-llm

通用 LLM 命令行工具，支持 Anthropic Claude、OpenAI Chat、OpenAI Responses API，以及任何 OpenAI 兼容的 API（Ollama、DeepSeek、Groq、BigModel 等）。

### 核心设计：awk 解析 SSE

SSE（Server-Sent Events）是逐行文本流 → awk 天然适合处理。

每个 provider 有独立的 awk SSE 解析器，但输出**统一协议**，上层无需关心 API 差异。

### 统一输出协议

所有 provider 的 SSE parser 输出相同的行格式：

```
TEXT:Hello, I'll help you with that.
TEXT: Let me think...
TOOL_START:get_weather:call_abc123
TOOL_INPUT:{"location":"San Francisco"}
USAGE:in=25,out=42
STOP:end_turn
```

| 行格式 | 含义 |
|--------|------|
| `TEXT:<content>` | 文本增量，实时输出 |
| `TOOL_START:<name>:<call_id>` | 工具调用开始 |
| `TOOL_INPUT:<json>` | 完整工具输入（多段 partial 拼接后，已解码为有效 JSON） |
| `USAGE:in=<n>,out=<n>` | token 用量 |
| `STOP:<reason>` | 响应结束。reason: `end_turn`/`tool_use`/`stop`/`tool_calls`/`max_tokens`/`done` |
| `ERROR:<message>` | 错误信息 |

### CLI 用法

```bash
# Claude
./llm.sh -p claude -m claude-sonnet-4-20250514 "Say hello"

# OpenAI
./llm.sh -p openai -m gpt-4o "Say hello"

# 管道输入 messages JSON
echo '[{"role":"user","content":"hello"}]' | ./llm.sh -p openai -m gpt-4o

# 带工具定义
./llm.sh -p claude --tools tools.json "What's the weather?"

# 纯文本输出（不显示协议前缀）
./llm.sh -p claude --raw "Tell me a joke"

# Verbose 调试模式
./llm.sh -p openai -m gpt-4o "Hello" -v
```

### 接入第三方供应商 / Ollama

通过 `--base-url` 或环境变量覆盖 API 地址：

```bash
# Ollama 本地（OpenAI 兼容模式）
./llm.sh -p openai --base-url http://localhost:11434/v1 -m llama3 "Hello"

# DeepSeek
./llm.sh -p openai --base-url https://api.deepseek.com/v1 -m deepseek-chat "Hi"

# BigModel (智谱)
./llm.sh -p openai --base-url https://open.bigmodel.cn/api/coding/paas/v4 -m glm-5 "Hello"

# BigModel (Anthropic 兼容)
./llm.sh -p claude --base-url https://open.bigmodel.cn/api/anthropic -m glm-4.5-air "Hello"
```

> **注意：** `BASE_URL` 应包含版本路径（如 `/v1`、`/v4`），llm.sh 只追加端点路径（`/chat/completions`、`/messages`）。

### CLI 参数

| 参数 | 说明 |
|------|------|
| `-p / --provider` | `claude` \| `openai` \| `openai-responses` |
| `-m / --model` | 模型名 |
| `--max-tokens` | 最大输出 token（默认 4096） |
| `--system` | 系统提示词 |
| `--tools` | 工具定义 JSON 文件（Claude 或 OpenAI 格式均可） |
| `--messages` | 消息数组 JSON 文件（也可 stdin） |
| `--raw` | 纯文本输出模式（不显示协议前缀） |
| `--no-stream` | 禁用流式 |
| `--api-key` | 手动指定 key |
| `--base-url` | 覆盖 API base URL（含版本路径） |
| `-v / --verbose` | 调试模式：显示 API URL、请求体、SSE 解析详情 |

### 环境变量

| 变量 | 说明 |
|------|------|
| `ANTHROPIC_API_KEY` | Claude API key |
| `OPENAI_API_KEY` | OpenAI API key |
| `ANTHROPIC_BASE_URL` | Claude API base URL（含版本路径） |
| `OPENAI_BASE_URL` | OpenAI API base URL（含版本路径） |
| `LLM_BASE_URL` | 通用 base URL，所有 provider 共用 |

**Base URL 优先级：** `--base-url` 参数 > `LLM_BASE_URL` > `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` > 默认值

### 消息格式自动转换

Agent 使用 Claude 格式（canonical）传递消息，llm.sh 内部根据 provider 自动转换：

```
agent.sh (固定 Claude 格式)  →  llm.sh
                                  ├─ claude:    直接使用
                                  ├─ openai:    convert_messages_to_openai()
                                  └─ responses: convert_messages_to_openai()
```

转换内容包括：

| Claude 格式 | OpenAI 格式 |
|-------------|-------------|
| `{"type":"tool_use","id":"...","name":"...","input":{...}}` | `{"tool_calls":[{"id":"...","type":"function","function":{"name":"...","arguments":"..."}}]}` |
| `{"type":"tool_result","tool_use_id":"...","content":"..."}` | `{"role":"tool","tool_call_id":"...","content":"..."}` |
| `{"name":"x","input_schema":{...}}` (tools) | `{"type":"function","function":{"name":"x","parameters":{...}}}` |

### JSON 空格兼容

`find_key()` 函数兼容 JSON 中冒号后有无空格的两种格式：

```
"type":"text"     ← 无空格
"type": "text"    ← 有空格（BigModel 等供应商）
```

### 代码结构（llm.sh ~1400 行）

| Section | 功能 |
|---------|------|
| 1. 配置 | shebang, 默认值, 环境变量 |
| 2. 工具函数 | json_escape, log, cleanup, parse_args |
| 3. 消息读取 | stdin/文件/CLI prompt → JSON messages |
| 4. 格式转换 | `convert_messages_to_openai()`, `convert_tools_to_openai()` |
| 5. 请求构建 | Claude/OpenAI/OpenAI-Responses request body |
| 6. SSE 解析器 | **核心** — 三个 awk 脚本，输出统一协议 |
| 7. curl 调用 | `_stream_curl()` 流式请求 + HTTP 状态捕获 |
| 8. 输出格式化 | raw 模式过滤器 |
| 9. main | 参数校验 + provider 路由 |

---

## bash-agent

AI Agent，调用 bash-llm，实现 agent loop + 4 个内置 tools。

### 架构

```
agent.sh
├── Agent Loop（循环调用 LLM 直到任务完成）
│   ├── 调用 llm.sh（读取统一协议输出）
│   ├── 解析 TEXT / TOOL_START / TOOL_INPUT / STOP
│   ├── STOP:end_turn/stop/done → 输出文本，结束
│   └── STOP:tool_use/tool_calls → 执行 tools，继续循环
├── Tools（4 个内置工具）
│   ├── read_file — 读文件（≤100KB）
│   ├── write_file — 写文件（自动创建目录）
│   ├── edit_file — 字符串替换编辑（awk + ENVIRON）
│   └── bash — 执行命令（30s 超时，≤50KB 输出）
├── 对话管理（temp file 方案）
│   └── 每行一个 JSON message，最后 join 成数组
└── CLI
    ├── 单次模式：./agent.sh "你的问题"
    └── 交互模式：./agent.sh -i
```

### CLI 用法

```bash
# 基本用法（使用环境变量中的 API key 和 base URL）
./agent.sh "Read /etc/hostname and tell me what it says"

# 指定 provider 和 model
./agent.sh -p openai -m gpt-4o "List files in /tmp"

# 使用 BigModel (Anthropic 兼容)
./agent.sh -p claude -m glm-4.5-air "Read /etc/hostname"

# 使用 BigModel (OpenAI 兼容)
./agent.sh -p openai -m glm-5 "Read /etc/hostname"

# Verbose 调试
./agent.sh -p openai -m glm-5 -v "Read /etc/hostname"

# 接入 Ollama
OPENAI_BASE_URL=http://localhost:11434/v1 ./agent.sh -p openai -m llama3 "Hello"

# 交互模式
./agent.sh -i

# 自定义 system prompt
./agent.sh --system "You are a helpful coding assistant" "Explain bash arrays"
```

### CLI 参数

| 参数 | 说明 |
|------|------|
| `-p / --provider` | LLM provider（默认 `claude`） |
| `-m / --model` | 模型名（默认 `claude-sonnet-4-20250514`） |
| `--llm` | llm.sh 路径（自动检测） |
| `--system` | Agent 系统提示词 |
| `--max-turns` | 最大 agent 循环次数（默认 20） |
| `--api-key` | API key |
| `--base-url` | 传递给 llm.sh 的 base URL |
| `-v / --verbose` | 调试模式：显示每行协议输出 |
| `-i / --interactive` | 交互模式 |

---

## 快速开始

```bash
# 1. 设置 API key（任选一个）
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."

# 2. 测试 llm.sh
./llm.sh -p claude "Say hello in 5 words"
./llm.sh -p openai "Say hello in 5 words"

# 3. 测试 agent.sh
./agent.sh "What's in the current directory? List the files."

# 4. 交互模式
./agent.sh -i

# 5. 用 Ollama（本地，无需 API key）
export OPENAI_BASE_URL=http://localhost:11434/v1
./agent.sh -p openai -m llama3 "Hello"
```

## 测试

```bash
# Mock 测试（不需要 API key，8 个测试）
cd tests
./mock-server.sh 8888 &
./test.sh 8888
kill %1

# 真实 API tool_use 测试（需要 ANTHROPIC_API_KEY）
ANTHROPIC_API_KEY=xxx ./tests/test-tool-stop.sh
```

---

## 已完成

- [x] llm.sh：三种 provider SSE 解析（Claude / OpenAI / OpenAI Responses）
- [x] llm.sh：统一输出协议（TEXT/TOOL_START/TOOL_INPUT/USAGE/STOP/ERROR）
- [x] llm.sh：`--base-url` + 环境变量支持（Ollama/DeepSeek/BigModel 等）
- [x] llm.sh：JSON 空格兼容（`"key": "value"` 和 `"key":"value"`）
- [x] llm.sh：`_stream_curl()` 流式输出 + HTTP 状态捕获
- [x] llm.sh：TOOL_INPUT JSON 解码（`\"` → `"`）
- [x] llm.sh：`\r` (carriage return) 剥离（兼容 BigModel 等 SSE 响应）
- [x] llm.sh：消息格式自动转换（Claude ↔ OpenAI）
- [x] llm.sh：工具格式自动转换（`input_schema` → `parameters`，`name` → `function.name`）
- [x] agent.sh：Agent loop（最多 20 轮）
- [x] agent.sh：4 个内置 tools（read_file / write_file / edit_file / bash）
- [x] agent.sh：对话管理（temp file 方案）
- [x] agent.sh：`-v` verbose 调试模式
- [x] 测试：8 个 mock 测试 + 真实 API tool_use 测试

## 待处理

- [ ] **`--print` stream-json 模式**：参考 Claude Code 的 `--print`，输入输出均为 JSON stream（每行一个 JSON 事件），便于程序化集成和管道编排
- [ ] OpenAI Responses API 的完整测试（目前只有 Claude 和 OpenAI Chat 经过验证）
- [ ] agent.sh 交互模式的完善（历史记录、多行输入）
- [ ] 更多 provider 的兼容性测试（DeepSeek、Groq 等的真实 API）
- [ ] 错误重试机制（网络超时、rate limit）
- [ ] 更复杂的 tool 场景测试（多 tool 并行调用、嵌套编辑等）
- [ ] `--no-stream` 模式下 tool_use 的支持
