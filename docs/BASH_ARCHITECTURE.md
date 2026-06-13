# Bash 版架构文档（基准实现）

> 本文档是 Bash 版 `src/agent.sh` 的完整架构和实现细节记录。
> C / Go / Rust 版本均为 Port，必须逐字段、逐逻辑对齐本文档。
> 任何"简化"或"优化"都是不允许的。

---

## 1. 整体架构概览

### 1.1 进程模型

```
┌─────────────────────────────────────────────────────┐
│ 主进程 (main → agent_main_loop)                      │
│  FD 3 ← INPUT_FIFO (读端)                            │
│  FD 5 → INPUT_FIFO (写端, 防止 EOF)                   │
│  FD 4 → display_stream 子进程 (RESP 消息)              │
│  FD 7 ← agent_loop_stream 管道                        │
│  FD 8 ← llm_call 管道                                │
│                                                      │
│  ┌──────────────────────┐                           │
│  │ agent_loop_stream()   │ (process substitution)    │
│  │  FD 8 ← llm_call 管道 │                          │
│  │  → FD 4 (display)     │                          │
│  └──────────────────────┘                           │
│                                                      │
│  ┌──────────────────────┐                           │
│  │ display_stream()      │ (process substitution)    │
│  │  ← FD 4 (RESP 消息)   │                          │
│  │  → stdout (终端渲染)   │                          │
│  └──────────────────────┘                           │
└─────────────────────────────────────────────────────┘

Sub-Agent (后台子进程):
  ( ... ) &  — 在子 shell 中执行 agent_loop
  完成后通过 store_sub_send_result 写入父进程的 INPUT_FIFO
```

### 1.2 FD 分配（固定）

| FD | 方向 | 用途 | 生命周期 |
|----|------|------|----------|
| 3 | 读 | INPUT_FIFO 读取端 | agent_main_loop |
| 4 | 写 | display_stream 管道 | agent_main_loop |
| 5 | 写 | INPUT_FIFO 写入端（保持打开防 EOF） | agent_main_loop / interactive_mode |
| 7 | 读 | agent_loop_stream → agent_loop 管道 | agent_loop |
| 8 | 读 | llm_call → agent_loop_stream 管道 | agent_loop_stream |
| 9 | 读 | curl SSE 流 | llm_stream_curl |

### 1.3 RESP 消息协议

内部消息使用 RESP-like 二进制安全格式（CRLF）：
```
*N\r\n          — N 个字段
$len0\r\ndata0\r\n   — 字段0: 字节长度 + 数据
$len1\r\ndata1\r\n   — 字段1
...
```

`util_write_msg` 序列化，`util_read_msg` 反序列化到 `REPLY_MESSAGE[]` 数组。

### 1.4 消息类型

| 类型 | 字段 | 来源 |
|------|------|------|
| TEXT | content | LLM SSE |
| THINKING | content | LLM SSE |
| TOOL_CALL | name, id, input, [kv pairs] | LLM SSE |
| TOOL_RESULT | tool_use_id, name, output, [checklist, summary] | tool_dispatch |
| USAGE | in, out, cache_read, cache_creation | LLM SSE |
| STOP | reason | LLM SSE |
| ERROR | message | LLM/内部 |
| RETRY | (无) | LLM SSE (retry 信号) |
| CONTEXT_UPDATE | kind, trigger | compact |
| SUB_AGENT_RESULT | session_id, status, in, out, thinking, text | sub-agent |
| USER_INPUT | seq, content | 用户输入 |
| AGENT_RESULT | session_id, status, thinking, text, in, out, cr, cc, reqs | sub-agent 完成 |
| SESSION_END | code | 退出 |
| IMAGE_DESCRIBE | images, description | 图片描述 |
| USER_MESSAGE | content | 用户消息回显 |

---

## 2. 默认值与环境变量

```bash
# 用户可配置选项（命令行参数可覆盖）
PROVIDER="claude"
MODEL=""                    # 留空，validate_config 中按 provider 填默认
MAX_TOKENS=16384
MAX_TURNS=1000              # 注意：usage() 中写的 500 是旧值
MAX_CONTEXT_TOKENS=200000
TOOL_TIMEOUT_SECS=600
OUTPUT_FORMAT="human"
VERBOSE=false

# 环境变量（带默认值）
TOOL_RESULT_MAX_BYTES=100000
BASH_AGENT_BASH_MODE=0467   # system/external/network/workspace; octal rwx
EFFORT=high                 # thinking effort: low|medium|high|xhigh|max
THINKING=adaptive           # thinking mode: adaptive|enabled|disabled

# 内部运行时状态
INTERACTIVE=false
LOG_EVENTS=true
INTERRUPT_REQUESTED=false
DISPLAY_LAST_CHAR=$'\n'     # 跟踪终端最后输出的字符
PREV_WAS_THINKING=false     # 跟踪是否刚输出 thinking（用于 thinking→text 插入换行）
```

### 2.1 关键细节

- `MAX_TURNS=1000`：实际循环上限。`usage()` 中写的 `--max-turns N (default: 500)` 是文档遗留错误，实际值 1000。
- `MAX_CONTEXT_TOKENS=200000`：compact 阈值。`usage()` 中写 `default: 200000; supports k/m`。
- `TOOL_RESULT_MAX_BYTES=100000`：工具输出截断阈值（字节）。
- `DISPLAY_LAST_CHAR`：全局变量，跟踪终端最后输出的字符。初始为 `\n`。用于判断是否需要补换行。
- `PREV_WAS_THINKING`：全局变量，用于 thinking→text 过渡时插入换行。

---

## 3. System Prompt 构建

### 3.1 agent_build_prompt() — section 顺序（严格固定）

```
1. <agent-identity>           — 身份描述，根据 locale 中英文切换
2. <environment>              — lang/pwd/home/platform/shell
3. <rules>                    — 核心规则（3条）
4. <using-your-tools>         — 工具使用指导
5. <sub-agent-guidance>       — SubAgent 指导
6. <todo-guidance>            — TodoWrite 指导
7. <plan-lifecycle-guidance>  — Plan 生命周期指导（含 PLAN_DRAFT_FILE/PLAN_FILE 实际路径）
8. <instruction-files>        — 指令文件（global + project），可能为空
9. <skill-index>              — 技能索引，可能为空
10. <selected-skills>         — 已选技能内容（--skill 加载的），可能为空
11. <current-plan name="..."> — 当前已确认计划，读取自 PLAN_FILE
12. <context-snapshot>        — 上下文摘要，读取自 summary.txt
13. <output-language>         — 输出语言强调
```

### 3.2 util_append_section() — section 包装规则

```bash
util_append_section output tag content [name]
```

- **空内容跳过**：`[[ -n "$content" ]] || return 0`
- **有 name 属性**：`<tag name="escaped_name">\ncontent\n</tag>\n`
- **无 name 属性**：`<tag>\ncontent\n</tag>\n`
- **name 的 JSON 转义**：使用 `util_json_escape`
- **尾部换行**：每个 section 包装后追加 `\n`（`printf -v '%s%s\n'`）
- **整体尾部去换行**：最终 `printf '%s' "${output%$'\n'}"` 去掉最后一个 `\n`

### 3.3 关键 section 内容

#### agent-identity
```bash
# locale 为 zh* 时：
'你是 bash-agent，一个在终端中运行的轻量级编码智能体。'
# 否则：
'You are bash-agent, a lightweight coding agent that works in a terminal.'
```

#### environment
```
lang: zh_CN          # locale 去掉 .xxx 后缀
pwd: /path/to/cwd    # ${PWD:-$(pwd)}
home: /home/user     # $HOME
platform: Darwin     # uname -s
shell: /bin/zsh      # $SHELL
```

#### plan-lifecycle-guidance
包含 `PLAN_DRAFT_FILE` 和 `PLAN_FILE` 的**实际运行时路径**（动态插入），格式：
```
**Files**: PLAN_DRAFT_FILE: /path/to/plan.draft | PLAN_FILE: /path/to/plan.md
```

#### current-plan
```bash
plan=$(store_plan_read)  # 读取 PLAN_FILE 内容
util_append_section output "current-plan" "$plan" "${PLAN_FILE:-}"
# → <current-plan name="/path/to/plan.md">\n...plan内容...\n</current-plan>
```

#### context-snapshot
```bash
stable_context=$(store_summary_get)  # 读取 summary.txt 内容
util_append_section output "context-snapshot" "$stable_context"
# → <context-snapshot>\n...summary内容...\n</context-snapshot>
```

#### output-language
```bash
# locale 为 zh* 时：
'再次强调：必须使用中文进行所有输出，包括你的思考过程（Chain of Thought/推理/thinking）！严禁在思考或回答中出现任何英文内容！'
# 否则：
'MUST use "locale" for all output, including your Chain of Thought/reasoning/thinking! Never mix languages! Code, commands, and file content remain as-is.'
```

### 3.4 locale 计算
```bash
locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US}}}"
locale="${locale%%.*}"  # 去掉 .UTF-8 等编码后缀
```

---

## 4. LLM 调用

### 4.1 llm_call() — 请求体构建

```bash
llm_call() {
    local messages="$1" max_tokens="${2:-$MAX_TOKENS}" use_thinking="${3:-$THINKING}" body system_prompt
    system_prompt=$(agent_build_prompt)
    body="{\"model\":\"${MODEL}\",\"max_tokens\":${max_tokens},\"stream\":true"
    if [[ "$use_thinking" != "disabled" ]]; then
        body+=",\"thinking\":{\"type\":\"${use_thinking}\"}"
        body+=",\"output_config\":{\"effort\":\"${EFFORT}\"}"
    fi
    [[ -n "$system_prompt" ]] && body+=",\"system\":\"$(util_json_escape "$system_prompt")\""
    [[ -n "$TOOL_DEF_JSON" ]] && body+=",\"tools\":${TOOL_DEF_JSON}"
    body+=",\"messages\":${messages}}"
    printf '%s' "$body" | util_body_convert | llm_stream_curl | sse_convert | sse_parse
}
```

**请求体字段顺序（严格固定）**：
```
model → max_tokens → stream → thinking → output_config → system → tools → messages
```

- `thinking` 和 `output_config` 仅在 `use_thinking != "disabled"` 时出现
- `system` 仅在非空时出现
- `tools` 仅在非空时出现
- `util_body_convert`：Claude provider 时是 `cat`（直通）；OpenAI provider 时做请求体转换
- `sse_convert`：Claude provider 时是 `cat`；OpenAI provider 时做 SSE 格式转换

### 4.2 llm_summary_call() — compact 用

```bash
llm_summary_call() {
    # 构造 messages = dropped_messages + summary_instruction
    messages=$(store_conv_get_messages "${dropped_messages}"$'\n'"{\"role\":\"user\",\"content\":\"...\"}")
    # 直接调用 llm_call，传入 disabled 关闭 thinking
    llm_call "$messages" "" disabled
    # 收集 TEXT，USAGE 记录到 compact_request_count
}
```

**关键细节**：
- `max_tokens` 传空字符串 `""`，在 llm_call 中 `${2:-$MAX_TOKENS}` 会使用默认值
- `use_thinking` 传 `"disabled"`，跳过 thinking 和 output_config 字段
- summary_instruction 是固定文本，包含 5 个字段：Task focus / Latest request / Progress / Tool evidence / Reflections
- 失败时 `util_die` 退出（不返回空文本继续）

### 4.3 llm_stream_curl() — HTTP 流

```bash
llm_stream_curl() {
    exec 9< <(curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 \
        --connect-timeout 5 --speed-limit 1 --speed-time 60 \
        "${HEADER_ARGS[@]}" -d @- "$API_URL" 2>&1)
    curl_pid=$!
    echo "$curl_pid" > "/tmp/agent_curl_pid.$$" 2>/dev/null || true
    util_awk_run -f "$AWK_DIR/http_stream.awk" <&9
    exec 9<&-
    rm -f "/tmp/agent_curl_pid.$$" 2>/dev/null || true
}
```

**curl 参数细节**：
- `-D -`：dump headers to stdout（SSE 解析需要 headers）
- `--retry 2 --retry-delay 1 --retry-max-time 20`：最多重试 2 次
- `--connect-timeout 5`：连接超时 5 秒
- `--speed-limit 1 --speed-time 60`：60 秒内速度 < 1 byte/s 则超时
- `curl_pid` 写入 `/tmp/agent_curl_pid.$$`（`$$` 是进程 PID），供 SIGINT 处理杀 curl

### 4.4 SSE 解析管线

```
curl output → http_stream.awk (解析 HTTP headers/chunked) → sse_convert (provider 格式转换) → sse_parse (统一 Claude SSE 解析)
```

`sse_parse` 使用 4 个 awk 文件：
- `json.awk` — JSON 解析基础
- `protocol.awk` — 协议解析
- `todo_protocol.awk` — TodoWrite 解析
- `claude_sse.awk` — Claude SSE 事件解析

输出为 RESP 消息流（stdout），由 `util_read_msg` 读取。

---

## 5. Agent 主循环

### 5.1 三层循环架构

```
agent_main_loop()       — 最外层：读 INPUT_FIFO，分发 USER_INPUT / AGENT_RESULT
  └─ agent_run_loop()   — 包装层：调用 agent_loop + 更新终端标题 + 交互提示符
      └─ agent_loop()   — 中间层：用户输入处理 + 图片展开 + 事件记录 + SIGINT
          └─ agent_loop_stream() — 最内层：LLM 调用 + 工具执行 + compact
```

### 5.2 agent_main_loop()

```bash
agent_main_loop() {
    until exec 3< "$INPUT_FIFO"; do sleep 0.01; done  # 等待 FIFO 可读
    exec 5> "$INPUT_FIFO"  # 保持写端打开，防止 EOF
    exec 4> >(display_stream)  # 启动 display 子进程
    local display_pid=$! active_sub_count=0
    
    while util_read_msg <&3; do
        case "${REPLY_MESSAGE[0]}" in
            SESSION_END) break ;;
            USER_INPUT)  agent_run_loop "${REPLY_MESSAGE[2]:-${REPLY_MESSAGE[1]:-}}" ;;
            AGENT_RESULT)
                if [[ "$INTERRUPT_REQUESTED" == true ]]; then
                    agent_handle_sub_result true   # silent mode
                else
                    agent_handle_sub_result        # normal mode
                fi
                ;;
        esac
        # 非交互模式且没有活跃 sub-agent → 退出
        [[ "$INTERACTIVE" != true ]] && (( active_sub_count == 0 )) && break
    done
    
    exec 4>&-  # 关闭 display 管道
    wait "$display_pid" 2>/dev/null || true
    cleanup_all_pipes
    rm -f "$INPUT_FIFO"
}
```

**关键细节**：
- `active_sub_count`：跟踪活跃 sub-agent 数量。TOOL_CALL SubAgent 时 +1，AGENT_RESULT 时 -1
- 非交互模式下，如果没有活跃 sub-agent 就退出循环
- INTERRUPT_REQUESTED 时 sub-agent 结果静默处理（不显示回显）

### 5.3 agent_loop()

```bash
agent_loop() {
    local user_input="$1" turn_kind="${2:-user_input}"
    INTERRUPT_REQUESTED=false
    
    # 1. 记录 user_input 事件（仅 turn_kind == user_input）
    [[ "$turn_kind" == user_input ]] && store_event_append '{"type":"user_input",...}'
    
    # 2. 图片占位符展开（仅 user_input 且包含 [Image #N]）
    #    - 提取图片路径，调用 agent_image_describe
    #    - 记录 image_describe 事件
    #    - 将描述追加到 user_input 后面
    
    # 3. 写入 conversation
    store_conv_add_user "$user_input"
    store_stats_update current_turn_count=+1
    
    # 4. SIGINT trap：关闭 FD 7 + 杀 curl
    trap 'INTERRUPT_REQUESTED=true; kill "$(cat "/tmp/agent_curl_pid.$$" ...)" ...; exec 7<&-' INT
    
    # 5. 启动 agent_loop_stream（process substitution → FD 7）
    exec 7< <(agent_loop_stream "$user_input")
    
    # 6. 读取 agent_loop_stream 的 RESP 消息
    while util_read_msg <&7; do
        # 记录 SubAgent 计数
        [[ TOOL_CALL && SubAgent ]] && active_sub_count++
        # 序列化为 stream event，记录到 events.jsonl
        _se=$(util_msg_to_stream) && store_event_append "$_se"
        # 转发给 display（非 stream-json 模式）
        util_is_stream_json || ( util_write_msg ... ) >&4
        # ERROR → break
        # STOP interrupted → break
    done
    
    exec 7<&-
    rm -f "/tmp/agent_curl_pid.$$"
}
```

### 5.4 agent_loop_stream() — 核心循环

```bash
agent_loop_stream() {
    local user_input="$1" turn=0
    trap 'INTERRUPT_REQUESTED=true; cleanup_all_pipes' INT
    
    while (( turn < MAX_TURNS )); do
        (( turn++ ))
        
        # ① Compact before LLM call
        agent_compact_context auto && util_write_msg "CONTEXT_UPDATE" "compact" "auto"
        
        # ② LLM call
        exec 8< <(llm_call "$(store_conv_get_messages)")
        
        # ③ 读取 SSE 消息流
        while util_read_msg <&8; do
            if INTERRUPT_REQUESTED → stop="interrupted"; break
            
            util_write_msg "${REPLY_MESSAGE[@]}"  # 转发给 display（FD 4）
            
            case type:
                RETRY → 重置 text/thinking/tool_calls/tool_conv_results/_ctx_tokens
                TEXT → text += content
                THINKING → thinking += content
                TOOL_CALL → 执行工具，收集结果
                STOP → stop = reason
                ERROR → loop_error, stop="error", break
                USAGE → _ctx_tokens = agent_record_usage(...)
            esac
        done
        exec 8<&-
        
        # ④ Interrupted → emit STOP interrupted, break
        [[ INTERRUPT_REQUESTED ]] && { util_write_msg "STOP" "interrupted"; break; }
        
        # ⑤ Fatal stop → return 1
        case stop:
            error|max_tokens|length → 
                stop != error 时 emit ERROR "Response truncated (max_tokens reached)"
                return 1
        esac
        
        # ⑥ 持久化（非 interrupted）
        store_conv_add_assistant "$text" "$thinking" "$tool_calls"
        if tool_conv_results:
            store_conv_add_tool_results "$tool_conv_results"
        if _ctx_tokens > 0:
            store_stats_update current_context_tokens=${_ctx_tokens}
        
        # ⑦ 继续/退出
        stop == tool_use|tool_calls → continue loop
        else → emit STOP, break
    done
    
    # Max turns reached
    (( turn >= MAX_TURNS )) && util_write_msg "ERROR" "Max turns ($MAX_TURNS) reached"
}
```

**RETRY 处理细节**：
当收到 RETRY 消息时，重置所有累积变量：`text="" thinking="" tool_calls="" tool_conv_results="" _ctx_tokens=""`。这是为了丢弃 retry 前的部分响应。

**工具执行流程（TOOL_CALL 分支）**：
```bash
TOOL_CALL:
    cur_tool_name = REPLY_MESSAGE[1]
    cur_tool_id = REPLY_MESSAGE[2]
    input = REPLY_MESSAGE[3]
    
    # 记录到 tool_calls（用于 conversation 持久化）
    tool_calls += name\tid\tinput\n
    
    # 提取参数
    tool_args_from_msg "$cur_tool_name"  # → _TOOL_ARGS[]
    
    # 执行工具
    output = tool_dispatch "$cur_tool_name" ${_TOOL_ARGS[@]} 2>&1
    # 失败时：output = "Error: $output"
    
    # 截断大输出
    output = tool_format_result "$output"
    
    # conversation 用的结果（可能不同于 display 结果）
    result_for_conv = output
    
    # 特殊处理：
    # Edit → result_for_conv = output 第一行（Success 消息）
    # Read/Write → output 前面加上 file_summary
    
    # JSON escape 后存入 tool_conv_results
    tool_conv_results += cur_tool_id\tjson_escape(result_for_conv)\n
    
    # 发送 TOOL_RESULT 给 display
    tool_emit_result cur_tool_id cur_tool_name output
```

---

## 6. Compact / DP 机制

### 6.1 agent_compact_context()

```bash
agent_compact_context() {
    local trigger=${1:-auto}  # auto | plan_confirm | plan_clear
    
    # ① DP 决策（经济最优）
    keep_lines = store_conv_dp_decision(turn_count, request_count, compact_count, total_input)
    
    # ② DP 返回 0 或 ≥ total_lines → fallback
    if keep_lines == 0 || keep_lines >= total_lines:
        if trigger is plan_clear/plan_confirm || ctx_tokens > 90% of MAX_CONTEXT:
            keep_lines = store_conv_turn_keep(0.25)  # fallback: 按比例
        else:
            return 1  # 不压缩
    
    # ③ Guard
    if keep_lines <= 0 || keep_lines >= total_lines:
        unless trigger is plan_clear/plan_confirm: return 1
    
    # ④ 提取 dropped 消息
    drop = total_lines - keep_lines
    dropped_messages = head(drop lines of conversation)
    
    # ⑤ Summary LLM 调用（先 summary 再 trim）
    summary_response = llm_summary_call(dropped_messages)
    store_summary_set(summary_response)
    
    # ⑥ Trim conversation（最后）
    if keep_lines < total_lines:
        store_conv_trim_tail(keep_lines)
    
    # 注意：不重置 current_turn_count（保持 session 累计）
    return 0
}
```

### 6.2 操作顺序的缓存意义

**为什么先 summary 再 trim？**
- summary 调用 `llm_summary_call` → `llm_call`，请求体 messages 包含完整旧 conversation
- 此时 conversation 文件尚未裁剪，messages 前缀与之前的正常请求一致
- 最大化 KV cache 前缀匹配
- 如果先 trim 再 summary，messages 前缀变了，cache 全部失效

**为什么 compact 在 LLM call 之前？**
- compact 会裁剪 conversation 并更新 summary
- 这些变更反映到下一次 `store_conv_get_messages` 调用
- 如果在 LLM call 之后 compact，当前请求发送旧 conversation（可能超限）

### 6.3 store_conv_dp_decision()

调用 `compact_dp.awk`，传入大量 DP 参数：
```
t, total_requests, total_compact, total_input,
baseline_e(8), e_fixed(0), L_fixed(0), V(5000),
p_input(3.0), p_cache(0.30), p_out(15.0),
S(500), min_keep_ratio(0.25), r(0.8), beta(0.03),
max_context(200000), quality_penalty(0.2)
```

返回值：keep_lines（0 = 不压缩，>0 = 保留最后 N 行）

### 6.4 store_conv_turn_keep()

fallback 策略，按比例保留：
```bash
util_awk_run -v ratio="${1:-0.12}" -f "$AWK_DIR/compact_turn_keep.awk" "$CONV_FILE"
```
保留对话的 `ratio` 比例（基于 turn 边界对齐）。

---

## 7. 工具系统

### 7.1 tool_dispatch() — 工具路由

```bash
tool_dispatch() {
    case "$name" in
        Read)      tool_read "$@" ;;
        Write)     tool_write "$1" "$2" ;;
        Edit)      tool_edit "$@" ;;
        Bash)      tool_bash "$1" "$2" ;;
        Glob)      tool_glob "$1" "$2" ;;
        Grep)      tool_grep "$1" "$2" "$3" "$4" ;;
        TodoWrite) printf '%s' "$1" ;;
        PlanConfirm) tool_plan_confirm ;;
        PlanClear) tool_plan_clear ;;
        Skill)     tool_skill "$1" ;;
        WebSearch) tool_web_search "$1" ;;
        WebFetch)  tool_web_fetch "$1" ;;
        SubAgent)  tool_sub_agent "$1" "$2" "$3" ;;
        *) echo "unknown tool: $name"; return 1 ;;
    esac
}
```

### 7.2 tool_param_keys() — 参数键名映射

| 工具 | 参数键 |
|------|--------|
| Read | path offset limit |
| Write | path content |
| Edit | path old_string new_string |
| Bash | command timeout |
| Glob | pattern path |
| Grep | pattern path glob context |
| TodoWrite | checklist |
| Skill | name |
| WebSearch | query |
| WebFetch | url |
| SubAgent | prompt description fork |

`tool_args_from_msg` 使用此映射从 REPLY_MESSAGE 的 kv pairs 中提取参数到 `_TOOL_ARGS[]`。

### 7.3 各工具实现细节

#### tool_read
```bash
tool_read() {
    local path="$1" offset="${2:-1}" limit="${3:-0}"
    # 空路径/不存在/不可读检查
    if limit > 0:
        sed -n "${offset},$((offset+limit-1))p" "$path"
    else:
        sed -n "${offset},\$p" "$path"
}
```
- 默认 offset=1, limit=0（读到末尾）
- 输出包含行号（由 sed 实现？不，sed -n 不带行号。行号是 awk 在 SSE replay 时加的？不，实际由 display 层不加行号。行号在 tool_read 中不添加——等等，tools.json 的 description 说 "Output includes line numbers"，但 tool_read 实际用 sed -n 不加行号。**实际上行号是 awk 的 edit_file.awk 或其他地方加的？不，是 cat -n 格式。让我看实际代码...**）

实际上 Bash 版 tool_read 不加行号。tools.json 的 description 说有行号是面向 LLM 的描述。实际输出是 `sed -n` 的原始文本。

**但 C/Go/Rust 版本的 Read 工具是否加了行号？这需要对比。**

#### tool_write
```bash
tool_write() {
    # mkdir -p 目录
    printf '%s' "$content" > "$path"
    echo "OK: wrote $(wc -c < "$path") bytes to $path"
}
```

#### tool_edit
```bash
tool_edit() {
    # 用 awk (edit_file.awk) 做替换
    # 用 diff -u --color=always 生成 diff
    # 统计 added/removed 行数
    # 输出: "Success: Edit(path) [+N -M lines]\n" + diff
}
```

#### tool_bash
```bash
tool_bash() {
    # 1. 安全分类：tool_classify_bash_required_mode
    # 2. 权限检查：tool_bash_mode_allows
    # 3. 超时执行：util_run_timeout
    # 4. UTF-8 sanitize：sanitize_utf8.awk
}
```

#### tool_glob
```bash
tool_glob() {
    rg --files "$path" -g "$pattern"
}
```

#### tool_grep
```bash
tool_grep() {
    rg -n --color never --heading [-C context] [--glob glob] -- pattern path
}
```

#### tool_plan_confirm / tool_plan_clear
```bash
tool_plan_confirm() {
    # 先 compact（复用旧缓存前缀），再 mv plan.draft → plan.md
    agent_compact_context plan_confirm
    store_plan_confirm
}

tool_plan_clear() {
    # 先 compact，再清空 plan.md
    agent_compact_context plan_clear
    store_plan_clear
}
```

#### tool_sub_agent
```bash
tool_sub_agent() {
    sub_session_id = "sub_$(util_new_session_id)"
    
    # 记录 sub_agent_start 事件
    store_event_append '{"type":"sub_agent_start",...}'
    
    # 后台子 shell
    (
        if fork == "true":
            store_session_fork(parent_dir, sub_dir)  # 复制 conversation/summary/plan
        export SESSION_ID=sub_session_id
        export INTERACTIVE=false
        store_session_init
        util_load_tool_defs
        trap 'store_sub_send_result ...; rm -f INPUT_FIFO' EXIT
        exec </dev/null >/dev/null 2>&1  # 完全静默
        exec 3<&- 4<&- 5<&- 8<&- ...  # 关闭所有继承的 FD
        agent_loop "$prompt" && _status="ok"
        store_sub_send_result "$sub_session_id" "$_status" "$_parent_input_fifo"
    ) &
    
    printf 'Sub-agent started: session_id=%s, pid=%s' "$sub_session_id" "$!"
}
```

### 7.4 tool_format_result() — 大输出截断

```bash
tool_format_result() {
    if ${#output} <= TOOL_RESULT_MAX_BYTES:
        printf '%s' "$output"  # 直通
    else:
        # 保留头部 + marker + 尾部5行
        marker = '\n\n[... truncated: showing first/last portions of N bytes ...]\n\n'
        head_len = MAX_BYTES - marker_len - tail_len
        printf '%s' "${output:0:head_len}" "$marker" "$tail_text"
}
```

### 7.5 tool_file_summary() — 文件工具摘要

```bash
tool_file_summary() {
    # 输出: Read(path) [N lines, M bytes, offset=X, limit=Y]
    # 用于 Read/Write 工具结果前面加摘要
}
```

### 7.6 tool_call_summary() — 工具调用摘要

```bash
tool_call_summary() {
    # 提取关键参数生成摘要，如:
    # Read(/path/to/file)
    # Bash(git status)
    # Edit(/path/to/file)
    # Bash 命令超 80 字符截断为 77 + ...
}
```

### 7.7 tool_emit_result() — 构建 TOOL_RESULT 消息

```bash
tool_emit_result() {
    # 转发原始 TOOL_CALL 中的 checklist 和 summary kv pairs
    _tr_args = ("TOOL_RESULT", tool_id, tool_name, output)
    # 从 REPLY_MESSAGE 中提取 checklist 和 summary
    util_write_msg "${_tr_args[@]}"
}
```

---

## 8. Bash 安全分类器

### 8.1 权限模型

4 位八进制 rwx，每位对应一个 scope：
```
scope:  system(8) external(4) network(2) workspace(1)
perms:  read(4) write(2) execute(1)
```

默认 `BASH_AGENT_BASH_MODE=0467`：
- system: 0（无权限）
- external: 4（只读）
- network: 6（读写）
- workspace: 7（读写执行）

### 8.2 tool_classify_bash_required_mode()

```bash
tool_classify_bash_required_mode() {
    CWD = lowercased PWD
    TOOL_BASH_REQUIRED_MASK = 0
    
    # 空命令 → 0000
    [[ -z "$cmd" ]] && { TOOL_BASH_REQUIRED_MODE="0000"; return; }
    
    lowered = lowercased cmd
    tool_bash_scan_script "$lowered"
    
    # 如果 mask 仍为 0，默认 workspace read (1*4=4)
    (( TOOL_BASH_REQUIRED_MASK == 0 )) && tool_bash_add_mode 1 4
    
    printf -v TOOL_BASH_REQUIRED_MODE '%04o' "$TOOL_BASH_REQUIRED_MASK"
}
```

### 8.3 tool_bash_scan_script()

```bash
tool_bash_scan_script() {
    # 替换行连接符 \<newline> 为空格
    # /dev/tcp → network rw (2*6=12)
    
    # 按 && / || / ; 分割为 segments
    normalized = script with && || ; → \n
    
    # 逐 segment 调用 tool_bash_scan_segment
}
```

### 8.4 tool_bash_scan_segment() — 核心分类逻辑

```bash
tool_bash_scan_segment() {
    # === 命令模式匹配 ===
    # sudo/su/doas/shutdown/reboot/halt/poweroff → system execute (8*1)
    # mkfs/fdisk/diskutil/mount/umount → system write (8*2)
    # curl/wget/http/https/git clone/fetch/pull → network read (2*4)
    # git push/scp/curl -d/curl --data/curl -f/curl -t → network write (2*2)
    # pipe to bash/sh / eval / source <( / bash -c $( / sh -c $( → network execute (2*1)
    
    # === 路径模式匹配 ===
    # ROOT_DELETE (rm -rf /) → system write (8*2)
    # DEVICE_WRITE (of=/dev/sd*) → system write (8*2)
    
    # === Workspace 命令 ===
    # ./bash/sh/zsh/python/node/ruby/perl/npm/make/cargo/go/git → workspace execute (1*1)
    
    # === 路径写入检测 ===
    # >/>>/tee/mkdir/touch/cp/mv/rm/sed -i/git fetch/pull/npm install → path_bits=6 (rw)
    
    # === 逐 token 路径分析 ===
    # 重定向: > → write(2), <> → rw(6)
    # 绝对路径 → tool_bash_add_path
    # 敏感路径 → system scope
}
```

### 8.5 tool_bash_add_path() — 路径分类

```bash
tool_bash_add_path() {
    # 清理路径引号、of= 前缀等
    # /tmp /dev/null & 开头 → 跳过（不限制）
    
    # /dev/tcp → network scope (2)
    # 敏感路径(.ssh/.gnupg/.aws/.docker/*.env/*.pem/*token*/*credential*/*secret*) → system scope (8)
    # 系统路径(/etc /usr /bin /sbin /var /library /system /dev) → system scope (8)
    # workspace 路径(CWD 或子目录) → workspace scope (1)
    # 外部路径(~//绝对路径/..) → external scope (4)
}
```

### 8.6 tool_bash_mode_allows()

```bash
tool_bash_mode_allows() {
    # required & ~allowed == 0 → 允许
    (( 8#$required & (4095 ^ 8#$allowed) == 0 ))
}
```

---

## 9. 会话存储

### 9.1 目录结构

```
~/.bash-agent/projects/<project-key>/<session-id>/
  conversation.jsonl  — 对话历史（每行一个 JSON 消息）
  events.jsonl        — 事件日志
  stats.json          — 统计数据
  summary.txt         — 上下文摘要
  plan.md             — 已确认计划
  plan.draft          — 计划草稿
  images/             — 粘贴的图片
  input.fifo          — 输入管道（运行时）
```

### 9.2 project_key 计算

```bash
store_session_get_dir() {
    cwd = pwd -P  # 解析符号链接
    project_key = awk '
        sub(/^\/+/, "")          # 去前导 /
        gsub(/\//, "-")          # / → -
        gsub(/[^A-Za-z0-9._-]/, "-")  # 非字母数字._- → -
        gsub(/-+/, "-")          # 合并连续 -
        sub(/^-+/, "")           # 去前导 -
        sub(/-+$/, "")           # 去尾部 -
        print "-" $0             # 前缀 -
    '
    printf '%s/.bash-agent/projects/%s' "$base" "$project_key"
}
```

### 9.3 conversation.jsonl 格式

每行一个 JSON 消息：

**user 消息（纯文本）**：
```json
{"role":"user","content":"text"}
```

**user 消息（工具结果）**：
```json
{"role":"user","content":[{"type":"tool_result","tool_use_id":"xxx","content":"result"}]}
```

**assistant 消息**：
```json
{"role":"assistant","content":[{"type":"thinking","thinking":"..."},{"type":"text","text":"..."},{"type":"tool_use","id":"xxx","name":"Read","input":{...}}]}
```

**关键细节**：
- assistant 消息**总是**包含 thinking block（即使为空字符串）
- thinking → text → tool_use 的顺序固定
- tool_result 消息以 user role 存储

### 9.4 store_conv_add_assistant() 构建

```bash
util_build_assistant_json() {
    content = "["
    content += {"type":"thinking","thinking":"escaped_thinking"}
    content += ,{"type":"text","text":"escaped_text"}
    # 逐个 tool_call:
    while read tc:
        content += ,{"type":"tool_use","id":"...","name":"...","input":...}
    content += "]"
}
```

### 9.5 events.jsonl 事件类型

| 事件 | 记录时机 |
|------|----------|
| session_start | 新会话初始化 |
| user_input | 用户输入（agent_loop 入口） |
| image_describe | 图片描述完成 |
| sub_agent_start | SubAgent 启动 |
| sub_agent_result | SubAgent 完成（含 thinking/text） |
| sub_agent_end | SubAgent 结束 |
| usage | 每次 LLM 调用的 token 使用 |
| text | LLM 文本输出 |
| thinking | LLM 思考输出 |
| tool_call | 工具调用 |
| tool_result | 工具结果 |
| stop | 停止 |
| error | 错误 |
| context_update | compact |

### 9.6 store_session_get_latest_dir() — continue 用的 mtime

```bash
# 优先 events.jsonl mtime，fallback 目录 mtime
ts=$(stat -f "%m" "$dir/events.jsonl" 2>/dev/null || stat -c "%Y" ... || stat -f "%m" "$dir" ... || echo 0)
```

### 9.7 store_session_list_rows() — list-sessions 用的 mtime

```bash
# 直接用目录 mtime
mod=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$session_dir" || stat -c "%y" ... | cut -d. -f1)
```

**注意区别**：
- `store_session_get_latest_dir`（continue）：优先 events.jsonl mtime
- `store_session_list_rows`（list-sessions）：用目录 mtime

### 9.8 summary.txt 操作

```bash
store_summary_set() {
    # 空文本不写入
    [[ -n "$text" ]] || return 0
    printf '%s\n' "$text" > "$CONTEXT_SUMMARY_FILE"
}

store_summary_get() {
    # 文件不存在或为空 → 返回空
    [[ -n "$CONTEXT_SUMMARY_FILE" && -s "$CONTEXT_SUMMARY_FILE" ]] && printf '%s' "$(<"$CONTEXT_SUMMARY_FILE")"
}
```

**注意**：`store_summary_set` 写入时末尾加 `\n`（`printf '%s\n'`），`store_summary_get` 读取时不加处理。

### 9.9 plan 文件操作

```bash
store_plan_confirm() {
    # plan.draft 存在且非空 → mv 到 plan.md，清空 plan.draft
    [[ -n "$PLAN_DRAFT_FILE" && -s "$PLAN_DRAFT_FILE" ]] && {
        mv "$PLAN_DRAFT_FILE" "$PLAN_FILE"
        : > "$PLAN_DRAFT_FILE"  # 清空但不删除
        return 0
    }
    return 1
}

store_plan_clear() {
    # plan.md 存在且非空 → 清空（写入空字符串）
    [[ -n "$PLAN_FILE" && -s "$PLAN_FILE" ]] && printf '' > "$PLAN_FILE"
}

store_plan_read() {
    # plan.md 存在且非空 → 输出内容
    [[ -n "$PLAN_FILE" && -s "$PLAN_FILE" ]] && printf '%s' "$(<"$PLAN_FILE")"
}
```

### 9.10 stats.json 操作

通过 `stats.awk` 实现 update/get：
```bash
store_stats_update() {
    # key=val 覆盖, key=+val 累加
    printf '%s\n' "$@" | awk -v action=update -f stats.awk "$STATS_FILE"
    display_term_title  # 更新终端标题
}

store_stats_get() {
    awk -v action=get -v key="$1" -f stats.awk "$STATS_FILE"
}
```

stats.json 字段：
- `current_turn_count` — 当前 turn 计数（不因 compact 重置）
- `current_context_tokens` — 当前上下文 token 数
- `agent_request_count` — agent LLM 请求计数
- `compact_request_count` — compact LLM 请求计数
- `sub_agent_request_count` — sub-agent 请求计数
- `total_input_tokens` — 累计输入 token
- `total_output_tokens` — 累计输出 token
- `total_cache_read_tokens` — 累计 cache read token
- `total_cache_creation_tokens` — 累计 cache creation token

---

## 10. Display 渲染

### 10.1 display_stream() — 渲染子进程

```bash
display_stream() { while util_read_msg; do display_message; done }
```

从 FD 4 读取 RESP 消息，逐条调用 `display_message` 渲染。

### 10.2 display_message() — 消息渲染逻辑

| 消息类型 | 渲染行为 |
|----------|----------|
| TEXT | 交互模式+行首 → 清行 `\r\033[K`；thinking→text 过渡补换行；`display_human_text` |
| THINKING | 灰色 `\033[90m...\033[0m`；`PREV_WAS_THINKING=true` |
| TOOL_CALL | 黄色 `\033[33m[tool] summary\033[0m`；调用 `tool_call_summary` |
| TOOL_RESULT | Edit→全量输出+换行；Read/Write→第一行+换行；其他→全量+换行 |
| SUB_AGENT_RESULT | 紫色/红色状态行；thinking 截断 120 字符；text 截断 120 字符 |
| IMAGE_DESCRIBE | 青色 `📸 images: description` |
| USER_MESSAGE | 绿色 `> text`（截断 80 字符） |
| STOP | interrupted → 青色 "Interrupted."；其他 → 确保换行 |
| CONTEXT_UPDATE | 青色 "Context compacted (trigger)." |
| ERROR | 红色 "Error: message" 到 stderr |

### 10.3 display_human_text()

```bash
display_human_text() {
    printf '%s' "$s"
    # 更新 DISPLAY_LAST_CHAR
    if s 以 \n 结尾: DISPLAY_LAST_CHAR = \n
    else: DISPLAY_LAST_CHAR = s 最后一个字符
}
```

### 10.4 display_ensure_newline()

```bash
display_ensure_newline() {
    if DISPLAY_LAST_CHAR != \n:
        printf '\n'
        DISPLAY_LAST_CHAR = \n
}
```

### 10.5 interactive 模式行首清行

在 TEXT、THINKING、TOOL_CALL 消息处理中：
```bash
if [[ "$INTERACTIVE" == true && "$DISPLAY_LAST_CHAR" == $'\n' ]]; then
    env printf '\r\033[K'  # 回到行首 + 清行
    DISPLAY_LAST_CHAR=''
fi
```
这是为了在交互模式下清除提示符 `> `，让输出从行首开始。

---

## 11. SubAgent 机制

### 11.1 启动流程

1. 生成 `sub_session_id = "sub_$(util_new_session_id)"`
2. 记录 `sub_agent_start` 事件
3. 后台子 shell：
   - fork=true 时复制 conversation/summary/plan
   - 设置新的 SESSION_ID
   - `store_session_init`（创建新会话目录）
   - trap EXIT：发送结果到父 INPUT_FIFO
   - 关闭所有继承的 FD（3/4/5/8）
   - `exec </dev/null >/dev/null 2>&1`（完全静默）
   - `agent_loop "$prompt"`
   - `store_sub_send_result` 发送结果

### 11.2 结果传递

```bash
store_sub_send_result() {
    # 使用 send_sub_result.awk 从子会话的 stats.json 和 conversation.jsonl 提取:
    # - thinking (最后一条 assistant 的 thinking)
    # - text (最后一条 assistant 的 text)
    # - usage 统计 (in/out/cr/cc)
    # 写入父进程的 INPUT_FIFO
}
```

### 11.3 结果处理

```bash
agent_handle_sub_result() {
    # REPLY_MESSAGE: AGENT_RESULT session_id status thinking text in out cr cc reqs
    
    # 1. 记录 usage 事件 (kind=sub_agent, sub_session_id)
    # 2. 更新 stats: total tokens += sub stats, sub_agent_request_count++, agent_request_count += reqs
    # 3. 记录 sub_agent_result 事件 (供 replay)
    # 4. 记录 sub_agent_end 事件
    # 5. active_sub_count--
    # 6. silent 模式 → return（不显示不触发 LLM）
    # 7. 发送 SUB_AGENT_RESULT 给 display
    # 8. 注入 conversation 触发 agent_run_loop:
    #    "[sub-agent session_id] status (in=N, out=N)\nThinking: ...\nText: ..."
    #    turn_kind = sub_agent_result
}
```

---

## 12. 交互模式 (interactive_mode)

### 12.1 启动流程

```bash
interactive_mode() {
    # 1. 加载 history 文件
    # 2. 回放最近 10 轮事件 (event_replay.awk)
    # 3. 启动 stdin_reader 子进程:
    #    - bind Ctrl+V 到图片粘贴
    #    - readline 循环: read -e -r -p '> '
    #    - USER_INPUT → INPUT_FIFO (FD 5)
    #    - exit/quit → SESSION_END
    # 4. agent_main_loop
    # 5. 清理子进程
}
```

### 12.2 事件回放

```bash
store_event_recent_turn_lines 10 | event_replay.awk | display_stream
```

- 从 events.jsonl 中找到最近 10 个 `user_input` 事件
- 从第一个开始的所有事件
- event_replay.awk 将事件转为 RESP 消息
- display_stream 渲染

---

## 13. 命令行参数解析 (parse_args)

### 13.1 参数列表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| -p/--provider | claude | LLM 提供者 |
| -m/--model | (provider 默认) | 模型名称 |
| --max-tokens | 16384 | 最大输出 token |
| --tool-timeout | 600 | 工具超时（秒） |
| --skill | (无) | 加载技能 |
| --max-turns | 1000 | 最大循环次数 |
| --max-context | 200000 | compact 阈值 |
| --api-key | (env) | API 密钥 |
| --base-url | (env) | API 基础 URL |
| --effort | high | thinking effort |
| --thinking | adaptive | thinking mode |
| --output-format | human | 输出格式 |
| --print | (alias) | = --output-format stream-json |
| --session [NAME] | (auto) | 会话 ID |
| --continue | (无) | 继续最近会话 |
| --list-sessions | (无) | 列出会话 |
| -v/--verbose | false | 详细日志 |
| -i/--interactive | false | 交互模式 |
| -h/--help | (无) | 帮助 |

### 13.2 --max-tokens 和 --max-context 支持 k/m/g 后缀

```bash
--max-tokens)  MAX_TOKENS=$(util_parse_size "$2") ;;
--max-context) MAX_CONTEXT_TOKENS=$(util_parse_size "$2") ;;
```

`util_parse_size` 将 `16k` → 16000, `1m` → 1000000 等。

### 13.3 --session 可选参数

```bash
--session)
    if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
        SESSION_ID="$2"; shift 2  # 有参数
    else
        SESSION_ID="$(util_new_session_id)"; shift  # 无参数，生成新 ID
    fi
    ;;
```

### 13.4 --continue 逻辑

```bash
--continue)
    if [[ -z "${SESSION_ID:-}" ]]; then
        store_session_resolve_continue
    fi
    shift
    ;;
```

仅在未指定 `--session` 时生效。

---

## 14. Provider 配置 (validate_config)

### 14.1 Claude provider

```bash
API_KEY=${API_KEY:-$ANTHROPIC_API_KEY}
BASE_URL=${BASE_URL:-${ANTHROPIC_BASE_URL:-}}
MODEL=${MODEL:-claude-sonnet-4-20250514}
API_URL="${BASE_URL:-https://api.anthropic.com/v1}/messages"
HEADER_ARGS=(
    -H "Content-Type: application/json"
    -H "x-api-key: ${API_KEY}"
    -H "anthropic-version: 2023-06-01"
    -H "User-Agent: claude-cli/1.0.33 (max, cli)"
    -H "x-app: cli"
)
util_body_convert() { cat; }    # 直通
sse_convert() { cat; }          # 直通
```

### 14.2 OpenAI provider

```bash
API_KEY=${API_KEY:-$OPENAI_API_KEY}
BASE_URL=${BASE_URL:-${OPENAI_BASE_URL:-}}
MODEL=${MODEL:-gpt-4o}
API_URL="${BASE_URL:-https://api.openai.com/v1}/chat/completions"
HEADER_ARGS=(
    -H "Content-Type: application/json"
    -H "Authorization: Bearer ${API_KEY}"
    -H "User-Agent: claude-cli/1.0.33 (max, cli)"
)
util_body_convert() { awk transport_openai_body.awk; }  # 请求体转换
sse_convert() { awk transport_openai_sse.awk; }          # SSE 转换
```

### 14.3 DeepSeek 自动检测

```bash
if [[ -z "$API_KEY" && -z "$BASE_URL" && -n "${DEEPSEEK_API_KEY:-}" ]]; then
    PROVIDER="claude"
    API_KEY="$DEEPSEEK_API_KEY"
    BASE_URL="https://api.deepseek.com/anthropic"
    MODEL=${MODEL:-deepseek-v4-flash}
fi
```

### 14.4 API key 缺失检查

```bash
if [[ -z "$API_KEY" && -z "$BASE_URL" ]]; then
    claude) util_die "No API key. Set ANTHROPIC_API_KEY or use --api-key" ;;
    openai) util_die "No API key. Set OPENAI_API_KEY or use --api-key" ;;
fi
```

**注意**：如果 `BASE_URL` 有值但 `API_KEY` 为空，不会报错（允许本地无 key 的 API）。

---

## 15. 工具定义 (tools.json)

`tools.json` 定义了所有工具的 JSON Schema。Bash 版从 `src/tools.json` 加载到 `TOOL_DEF_JSON`。

**四版本一致性要求**：`src/tools.json`、`rust/src/tools.json`、`go/tools.json`、`c/tools.json` 的 SHA256 必须一致。

---

## 16. UTF-8 处理

### 16.1 sanitize_utf8.awk

Bash 工具输出通过 `sanitize_utf8.awk` 清理非法 UTF-8 字节。

### 16.2 util_json_escape

```bash
# 转义: \ " \n \r \t \b \f
_s="${_s//\\/\\\\}" _s="${_s//\"/\\\"}" _s="${_s//$'\n'/\\n}" _s="${_s//$'\r'/\\r}" _s="${_s//$'\t'/\\t}" _s="${_s//$'\b'/\\b}" _s="${_s//$'\f'/\\f}"
```

**注意**：不转义 Unicode 控制字符（如 \u0000-\u001f 中除上述 6 个之外的）。也不转义 `/`。

---

## 17. 图片支持

### 17.1 粘贴（Ctrl+V）

```bash
agent_image_insert_placeholder_readline() {
    # 从剪贴板获取 PNG → 保存到 session/images/N.png
    # 在 readline 光标位置插入 [Image #N]
}
```

### 17.2 描述

```bash
agent_image_describe() {
    # 调用外部 VLM API（默认 glm-4v-flash）
    # 返回图片文字描述
}
```

### 17.3 展开

在 `agent_loop` 中，如果 user_input 包含 `[Image #N]`：
1. 提取所有图片路径
2. 调用 `agent_image_describe`
3. 记录 `image_describe` 事件
4. 将描述以 `<attached-images>` 标签追加到 user_input

---

## 18. 关键实现细节备忘

### 18.1 events.jsonl 的 tee 行为

```bash
store_event_append() {
    if util_is_stream_json:
        printf '%s\n' "$1" | tee -a "$SESSION_EVENT_FILE"  # 同时输出到 stdout 和文件
    else:
        printf '%s\n' "$1" >> "$SESSION_EVENT_FILE"  # 仅写文件
}
```

stream-json 模式下，事件同时输出到 stdout（供管道消费）和写入文件。

### 18.2 agent_record_usage()

```bash
agent_record_usage() {
    # kind: agent | compact | sub_agent
    # counter_key: agent_request_count | compact_request_count
    
    # 从 REPLY_MESSAGE[1..4] 读取 token 数
    _in="${REPLY_MESSAGE[1]:-0}"
    _out="${REPLY_MESSAGE[2]:-0}"
    _cr="${REPLY_MESSAGE[3]:-0}"
    _cc="${REPLY_MESSAGE[4]:-0}"
    
    # 可选写 usage 事件
    if write_event == true:
        store_event_append '{"type":"usage",...,"kind":"$kind"}'
    
    # 更新 stats
    store_stats_update ${counter_key}=+1 total_input_tokens=+${_in} ...
    
    # 返回 context token 总数
    echo $(( _in + _out + _cr + _cc ))
}
```

### 18.3 tool_bash 中 Edit 结果的特殊处理

在 agent_loop_stream 的 TOOL_CALL 分支：
```bash
case "$cur_tool_name" in
    Edit)       result_for_conv="$(printf '%s' "$output" | sed -n '1p')" ;;
    Read|Write) output="$(tool_file_summary ...)"$'\n'"$output" ;;
esac
```

- Edit: conversation 中只存第一行（Success 消息），display 中存完整输出
- Read/Write: display 输出前面加 file_summary，conversation 存原始 output（但 result_for_conv 默认等于 output，这里修改的是 display 用的 output 而非 result_for_conv）

等等，重新审视：
```bash
output=$(tool_format_result "$output")
result_for_conv="$output"   # 默认两者相同
case "$cur_tool_name" in
    Edit)       result_for_conv="$(printf '%s' "$output" | sed -n '1p')" ;;
    Read|Write) output="$(tool_file_summary ...)"$'\n'"$output" ;;
esac
tool_conv_results+="...result_for_conv..."
tool_emit_result "$cur_tool_id" "$cur_tool_name" "$output"
```

- Edit: `result_for_conv` = 第一行（Success 行），`output`（给 display）= 完整输出（含 diff）
- Read/Write: `output`（给 display）= file_summary + 原始输出，`result_for_conv` = 原始格式化输出（不含 file_summary）

### 18.4 --max-context 校验位置

```bash
# 在 API key 检查之前（cagent.c 第 145-149 行对齐）
if max_context_str:
    val = util_parse_size(max_context_str)
    if val <= 0: error "Invalid --max-context"
```

### 18.5 session ID 格式

```bash
util_new_session_id() {
    printf '%s-%04x' "$(date +%Y%m%d-%H%M%S)" "$(( RANDOM << 1 | (RANDOM & 1) ))"
}
# 格式: YYYYMMDD-HHMMSS-XXXX (XXXX 是随机十六进制)
```

### 18.6 INPUT_FIFO 创建

```bash
INPUT_FIFO="${session_dir}/input.fifo"
[[ -p "$INPUT_FIFO" ]] || { rm -f "$INPUT_FIFO"; mkfifo "$INPUT_FIFO"; }
```

### 18.7 store_session_init 中的 new_session 判定

```bash
[[ ! -s "$SESSION_EVENT_FILE" ]] && new_session=true
# touch 所有文件
# 如果 new_session: 记录 session_start 事件
```

只有 events.jsonl 为空时才算新会话（支持 --session 重连已有会话）。
