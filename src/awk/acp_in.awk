# acp_in.awk — ACP (Agent Client Protocol) stdin parser for bash-agent --acp
# 常驻进程：逐行读 client 的 JSON-RPC 2.0 报文（每行一条），解析后输出 RESP 帧
# （protocol.awk 的 emit 格式，二进制安全）给 dispatcher（agent.sh acp_mode）：
#   REQ <id_raw> <method> <sessionId> <cwd> <prompt_text>  — 需要回包的请求
#       initialize: method=initialize, 其余字段空
#       session/new|session/resume: sessionId(resume)/cwd
#       session/prompt: sessionId + 已拼接好的纯文本 prompt
#   NOTIF <method> <sessionId>                             — 通知（session/cancel）
#   BAD <id_raw> <code> <message>                          — 解析/参数错误（dispatcher 转 JSON-RPC error 回包）
# 错误码：-32700 非法 JSON / -32600 非法请求 / -32601 未实现 / -32602 参数非法。
# 依赖：json.awk（解析）、protocol.awk（emit 帧）。必须以 LC_ALL=C 运行（字节语义）。
# id_raw 是请求 id 的原始 JSON 值（数字或带引号字符串），回包时原样嵌入；
# notification（无 id）不产生 REQ/BAD 帧（JSON-RPC 规范禁止对 notification 回错误）。

# trim 首尾空白
function acp_trim(s) {
    gsub(/^[ \t\r\n]+/, "", s)
    gsub(/[ \t\r\n]+$/, "", s)
    return s
}

# file:// URI → 本地路径
function acp_uri_to_path(uri) {
    if (substr(uri, 1, 7) == "file://") return substr(uri, 8)
    return uri
}

# 输出 BAD 错误帧
function acp_bad(id_raw, code, msg) {
    emit1("BAD")
    emit(id_raw)
    emit(code)
    emit(msg)
    emit_flush()
}

# 拼接 session/prompt 的 content blocks。
# 成功置 ACP_PROMPT_TEXT 并返回 0；失败置 ACP_BAD_MSG 并返回 -1。
function acp_build_prompt(params,    prompt_raw, n, blocks, i, t, txt, uri, inner, out) {
    prompt_raw = json_get_raw(params, "prompt")
    if (prompt_raw == "" || substr(prompt_raw, 1, 1) != "[") {
        ACP_BAD_MSG = "invalid params: missing prompt array"
        return -1
    }
    out = ""
    n = split_top_level_objects(prompt_raw, blocks)
    for (i = 1; i <= n; i++) {
        t = extract_str(blocks[i], "type")
        if (t == "text") {
            txt = extract_str(blocks[i], "text")
        } else if (t == "resource_link") {
            txt = "@" acp_uri_to_path(extract_str(blocks[i], "uri"))
        } else if (t == "resource") {
            inner = json_get_raw(blocks[i], "resource")
            uri = extract_str(inner, "uri")
            txt = extract_str(inner, "text")
            if (txt == "") {
                ACP_BAD_MSG = "unsupported embedded resource: only text resources are supported"
                return -1
            }
            txt = "<context uri=\"" uri "\">" txt "</context>"
        } else if (t == "image" || t == "audio") {
            ACP_BAD_MSG = "unsupported content block type: " t
            return -1
        } else {
            ACP_BAD_MSG = "unknown content block type: " ((t == "") ? "?" : t)
            return -1
        }
        if (out != "" && txt != "") out = out "\n"
        out = out txt
    }
    ACP_PROMPT_TEXT = out
    return 0
}

# session/new / session/resume 的公共参数校验。
# 成功置 ACP_SID/ACP_CWD 返回 0；失败置 ACP_BAD_MSG 返回 1。
# mcpServers 非空时忽略并向 stderr 记 warning（能力已声明不支持）。
function acp_parse_session_target(params, want_sid,    sid, cwd, mc) {
    sid = ""
    cwd = extract_str(params, "cwd")
    if (want_sid) sid = extract_str(params, "sessionId")
    if (cwd == "" || substr(cwd, 1, 1) != "/") {
        ACP_BAD_MSG = "invalid params: cwd must be an absolute path"
        return 1
    }
    if (want_sid && sid == "") {
        ACP_BAD_MSG = "invalid params: missing sessionId"
        return 1
    }
    mc = json_get_raw(params, "mcpServers")
    if (mc != "" && mc != "[]" && mc != "null") {
        print "bash-agent(acp): warning: mcpServers is not supported and was ignored" > "/dev/stderr"
    }
    ACP_SID = sid
    ACP_CWD = cwd
    return 0
}

{
    line = acp_trim($0)
    if (line == "") next
    id_raw = json_get_raw(line, "id")
    is_notif = ((id_raw == "" || id_raw == "null") ? 1 : 0)
    if (substr(line, 1, 1) != "{") {
        if (!is_notif) acp_bad(id_raw, "-32700", "Parse error: input line is not valid JSON")
        next
    }
    method = extract_str(line, "method")
    if (method == "") {
        if (!is_notif) acp_bad(id_raw, "-32600", "Invalid Request: missing method")
        next
    }
    params = json_get_raw(line, "params")

    if (method == "initialize") {
        if (is_notif) next
        emit1("REQ"); emit(id_raw); emit(method); emit(""); emit(""); emit(""); emit_flush()
    } else if (method == "session/new" || method == "session/resume") {
        if (acp_parse_session_target(params, (method == "session/resume") ? 1 : 0)) {
            if (!is_notif) acp_bad(id_raw, "-32602", ACP_BAD_MSG)
            next
        }
        if (is_notif) next
        emit1("REQ"); emit(id_raw); emit(method); emit(ACP_SID); emit(ACP_CWD); emit(""); emit_flush()
    } else if (method == "session/prompt") {
        if (extract_str(params, "sessionId") == "") {
            if (!is_notif) acp_bad(id_raw, "-32602", "invalid params: missing sessionId")
            next
        }
        if (acp_build_prompt(params)) {
            if (!is_notif) acp_bad(id_raw, "-32602", ACP_BAD_MSG)
            next
        }
        if (is_notif) next
        emit1("REQ"); emit(id_raw); emit(method); emit(extract_str(params, "sessionId")); emit(""); emit(ACP_PROMPT_TEXT); emit_flush()
    } else if (method == "session/cancel") {
        emit1("NOTIF"); emit(method); emit(extract_str(params, "sessionId")); emit_flush()
    } else {
        if (!is_notif) acp_bad(id_raw, "-32601", "Method not found: " method)
    }
}

END { fflush() }
