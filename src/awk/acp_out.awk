# acp_out.awk — ACP (Agent Client Protocol) output layer for bash-agent --acp
# 常驻进程，是 bash-agent --acp 的**唯一 stdout 写入方**：任何 JSON-RPC 帧
# （session/update、prompt 回包、错误回包）都只能从这里输出，"回包后静默"
# 由 turn_open 门控从结构上保证，不依赖各 worker 的时序。
#
# 输入行（tab 分隔，来自 ACP_OUT 管道，写入方经令牌锁互斥）：
#   <sid>\tTURN\t<reqid_raw>        开启轮次（dispatcher 转发 prompt 前写）
#   <sid>\tEVT\t<depth>\t<json>     events.jsonl 事件（worker store_event_append）
#   <sid>\tDONE\t<reqid_raw>        prompt 结束（worker 满足 ACTIVE_TASK==0 && buf 空后写）
#   <sid>\tRAW\t<json-rpc 单行>     dispatcher 直接回包（initialize/session/new/错误），原样输出
#
# 事件映射（issue #110 §三）：
#   text/thinking → agent_message_chunk / agent_thought_chunk
#   tool_call     → tool_call(in_progress, kind/title/locations 按工具名推断, rawInput)
#   tool_result   → tool_call_update(completed; content 以 "Error:" 开头则 failed)
#   stop          → 记录 last_stop（不输出；DONE 时映射 stopReason）
#   error         → 记录 err_msg（不输出；DONE 时回 JSON-RPC error -32603）
#   sub_agent_start          → tool_call(toolCallId "sub:<sid>", kind think)
#   sub_agent_result         → tool_call_update(completed/failed, content 为子代理 text)
#   session_start/context_update/retry/usage/async_task_result/sub_agent_end → 忽略（P1）
#   depth>0 的 EVT（子代理内部事件）不映射（P5 再做嵌套 transcript）
#
# DONE 处理：先补发 open_tool_calls 里未完成的 tool_call_update(failed, "cancelled")，
# 再写回包（"update 先于回包"由 FIFO 写入顺序 + 单线程消费保证）；然后 turn_open=0。
# turn_open[sid]==0 时到达的 EVT 一律丢弃（events.jsonl 里照常保留）。
# 依赖：json.awk。必须以 LC_ALL=C 运行（字节语义，length/substr 按字节）。

# 输出一行并立即 flush（唯一 stdout 写入点）
function acp_out(s) {
    print s
    fflush()
}

# 输出 session/update 通知
function acp_update(sid, update_json) {
    acp_out("{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"" escape_json_string(sid) "\",\"update\":" update_json "}}")
}

# {"type":"text","text":...} content block
function acp_text_content(t) {
    return "{\"type\":\"text\",\"text\":\"" escape_json_string(t) "\"}"
}

# tool_call_update 的 content 数组（单条 text content）
function acp_tool_content(t) {
    return "[{\"type\":\"content\",\"content\":" acp_text_content(t) "}]"
}

# stop 事件 reason → ACP stopReason 枚举
# （枚举无 error；LLM 错误走 DONE 的 JSON-RPC error，不经过这里）
function acp_stop_reason(r) {
    if (r == "max_tokens" || r == "length") return "max_tokens"
    if (r == "interrupted") return "cancelled"
    return "end_turn"
}

# 从逗号分隔的未完成 toolCallId 列表中移除一个
function acp_tc_remove(sid, tid,    a, n, i, out) {
    out = ""
    n = split(open_tc[sid], a, ",")
    for (i = 1; i <= n; i++) {
        if (a[i] == "" || a[i] == tid) continue
        out = out ((out == "") ? "" : ",") a[i]
    }
    open_tc[sid] = out
}

# 按工具名推断 kind/title/locations（issue #110 §三 推断表）
# 置 META_KIND / META_TITLE / META_LOC_JSON（含前导逗号或空串）
function acp_meta(name, input,    cmd, fp, off, pat, desc) {
    META_KIND = "other"
    META_TITLE = name
    META_LOC_JSON = ""
    if (name == "Bash") {
        META_KIND = "execute"
        cmd = extract_str(input, "command")
        if (cmd != "") META_TITLE = substr(cmd, 1, 80)
    } else if (name == "Read") {
        META_KIND = "read"
        fp = extract_str(input, "file_path")
        if (fp != "") META_TITLE = "Read " fp
        off = extract_num(input, "offset")
        if (off != "" && off != "0") {
            META_LOC_JSON = ",\"locations\":[{\"path\":\"" escape_json_string(fp) "\",\"line\":" off "}]"
        } else {
            META_LOC_JSON = ",\"locations\":[{\"path\":\"" escape_json_string(fp) "\"}]"
        }
    } else if (name == "Edit" || name == "Write") {
        META_KIND = "edit"
        fp = extract_str(input, "file_path")
        if (fp != "") META_TITLE = name " " fp
        if (fp != "") META_LOC_JSON = ",\"locations\":[{\"path\":\"" escape_json_string(fp) "\"}]"
    } else if (name == "Grep" || name == "Glob") {
        META_KIND = "search"
        pat = extract_str(input, "pattern")
        if (pat != "") META_TITLE = name " " pat
        fp = extract_str(input, "path")
        if (fp != "") META_LOC_JSON = ",\"locations\":[{\"path\":\"" escape_json_string(fp) "\"}]"
    } else if (name == "SubAgent") {
        META_KIND = "think"
        desc = extract_str(input, "description")
        if (desc != "") META_TITLE = desc
    }
    # TodoWrite / Plan* / Skill / 其他 → kind=other, title=工具名
}

{
    n = split($0, F, "\t")
    sid = F[1]
    kind = F[2]

    if (kind == "RAW") {
        acp_out(F[3])
        next
    }
    if (kind == "TURN") {
        # 开启轮次：重置该会话的输出状态机
        turn_open[sid] = 1
        open_tc[sid] = ""
        last_stop[sid] = ""
        err_msg[sid] = ""
        next
    }
    if (kind == "DONE") {
        if (turn_open[sid] != 1) next   # 空闲/竞态（已回包）时的 DONE 忽略
        reqid = F[3]
        # F[4] 可选 reason（如 "interrupted"）：显式指定时覆盖 last_stop（取消与正常结束竞态时以先到者为准）
        if (F[4] != "") {
            last_stop[sid] = F[4]
        }
        if (err_msg[sid] != "") {
            # LLM/内部错误：ACP stopReason 枚举无 error，按规范回 JSON-RPC error
            acp_out("{\"jsonrpc\":\"2.0\",\"id\":" reqid ",\"error\":{\"code\":-32603,\"message\":\"Internal error\",\"data\":{\"message\":\"" escape_json_string(err_msg[sid]) "\"}}}")
        } else {
            # 补发未完成 tool_call 的 failed（update 先于回包）
            m = split(open_tc[sid], tc, ",")
            for (i = 1; i <= m; i++) {
                if (tc[i] == "") continue
                acp_update(sid, "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"" escape_json_string(tc[i]) "\",\"status\":\"failed\",\"content\":" acp_tool_content("cancelled") "}")
            }
            acp_out("{\"jsonrpc\":\"2.0\",\"id\":" reqid ",\"result\":{\"stopReason\":\"" acp_stop_reason(last_stop[sid]) "\"}}")
        }
        turn_open[sid] = 0
        open_tc[sid] = ""
        last_stop[sid] = ""
        err_msg[sid] = ""
        next
    }
    if (kind != "EVT") next
    depth = F[3] + 0
    if (depth > 0) next               # 子代理内部事件：只落盘，不映射（P5）
    if (turn_open[sid] != 1) next     # 回包后静默：丢弃轮次外事件

    ev = F[4]
    et = extract_str(ev, "type")
    if (et == "text") {
        acp_update(sid, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":" acp_text_content(extract_str(ev, "content")) "}")
    } else if (et == "thinking") {
        acp_update(sid, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":" acp_text_content(extract_str(ev, "content")) "}")
    } else if (et == "tool_call") {
        tname = extract_str(ev, "name")
        tid = extract_str(ev, "id")
        tinput = json_get_raw(ev, "input")
        acp_meta(tname, tinput)
        acp_update(sid, "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"" escape_json_string(tid) "\",\"kind\":\"" META_KIND "\",\"title\":\"" escape_json_string(META_TITLE) "\",\"status\":\"in_progress\",\"rawInput\":" ((tinput == "" || tinput == "null") ? "{}" : tinput) META_LOC_JSON "}")
        open_tc[sid] = open_tc[sid] ((open_tc[sid] == "") ? "" : ",") tid
    } else if (et == "tool_result") {
        tid = extract_str(ev, "tool_use_id")
        tcontent = extract_str(ev, "content")
        tstatus = ((tcontent ~ /^Error:/) ? "failed" : "completed")
        acp_update(sid, "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"" escape_json_string(tid) "\",\"status\":\"" tstatus "\",\"content\":" acp_tool_content(tcontent) "}")
        acp_tc_remove(sid, tid)
    } else if (et == "stop") {
        last_stop[sid] = extract_str(ev, "reason")
    } else if (et == "error") {
        err_msg[sid] = extract_str(ev, "message")
    } else if (et == "sub_agent_start") {
        subs = extract_str(ev, "session_id")
        sdesc = extract_str(ev, "description")
        sprompt = extract_str(ev, "prompt")
        stitle = ((sdesc != "") ? sdesc : substr(sprompt, 1, 80))
        tid = "sub:" subs
        acp_update(sid, "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"" escape_json_string(tid) "\",\"kind\":\"think\",\"title\":\"" escape_json_string(stitle) "\",\"status\":\"in_progress\",\"rawInput\":{\"prompt\":\"" escape_json_string(sprompt) "\"}}")
        open_tc[sid] = open_tc[sid] ((open_tc[sid] == "") ? "" : ",") tid
    } else if (et == "sub_agent_result") {
        subs = extract_str(ev, "session_id")
        sstatus = extract_str(ev, "status")
        stext = extract_str(ev, "text")
        tstatus = ((sstatus == "ok") ? "completed" : "failed")
        acp_update(sid, "{\"sessionUpdate\":\"tool_call_update\",\"toolCallId\":\"sub:" escape_json_string(subs) "\",\"status\":\"" tstatus "\",\"content\":" acp_tool_content(stext) "}")
        acp_tc_remove(sid, "sub:" subs)
    }
    # session_start / context_update / retry / usage / async_task_result / sub_agent_end → 忽略（P1）
}

END { fflush() }
