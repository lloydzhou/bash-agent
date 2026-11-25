//! webagent 的 ACP (Agent Client Protocol) client（issue #110 §五 P2）。
//!
//! 与 stream-json「每轮 spawn 一次」不同，ACP 模式常驻一个 `agent --acp`
//! 子进程：启动时完成 initialize + session/new|resume 握手，之后每轮把
//! WS 输入包装成 `session/prompt`，把 `session/update` 通知还原成现有
//! WS 事件格式广播——前端事件流格式与 stream-json 模式完全一致。

use crate::events_path_for;
use crate::server::{EventsPath, WsHub};
use crate::wait_for_speed_from_stats;
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// 握手类请求超时；prompt 回包用 recv() 阻塞等待，
/// agent 进程退出时 reader 线程清空 pending（Sender 全部 drop）从而立刻解除阻塞。
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

pub(crate) struct AcpClient {
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    /// JSON-RPC id → 等待回包的 sender（reader 线程按 id 投递）
    pending: Arc<Mutex<HashMap<i64, SyncSender<Value>>>>,
    next_id: AtomicI64,
    pub(crate) session_id: String,
}


/// 发送 JSON-RPC 请求（写 stdin + 注册 pending）。
fn send_request(
    stdin: &Mutex<ChildStdin>,
    pending: &Mutex<HashMap<i64, SyncSender<Value>>>,
    next_id: &AtomicI64,
    method: &str,
    params: Value,
) -> Result<Receiver<Value>> {
    let id = next_id.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = sync_channel(1);
    pending.lock().unwrap().insert(id, tx);
    let frame = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
    {
        let mut w = stdin.lock().unwrap();
        writeln!(w, "{frame}").with_context(|| format!("acp write {method}"))?;
        w.flush().ok();
    }
    Ok(rx)
}

/// ACP content（单对象或数组）→ 纯文本。
/// agent_message_chunk 的 content 是 `{type:text,text}`；
/// tool_call_update 的 content 是 `[{type:content,content:{type:text,text}}]`。
fn content_to_text(v: &Value) -> String {
    match v {
        Value::Array(items) => items
            .iter()
            .map(|it| {
                let inner = it.get("content").unwrap_or(it);
                inner
                    .get("text")
                    .and_then(|t| t.as_str())
                    .unwrap_or("")
                    .to_string()
            })
            .collect::<Vec<_>>()
            .join(""),
        _ => v.get("text").and_then(|t| t.as_str()).unwrap_or("").to_string(),
    }
}

/// 从 update 的 `_meta.bash-agent.name` 取 bash-agent 扩展的工具名（阶段 1 约定）。
fn meta_tool_name(update: &Value) -> Option<&str> {
    update
        .pointer("/_meta/bash-agent/name")
        .and_then(|n| n.as_str())
}

/// `session/update` 的 update → 现有 WS 事件（前端 handleLine 可识别的格式）。
/// 无法识别的 update 类型返回 None（忽略）。
fn acp_update_to_ws(update: &Value) -> Option<String> {
    let kind = update.get("sessionUpdate").and_then(|k| k.as_str())?;
    let evt = match kind {
        "agent_message_chunk" => json!({
            "type": "text",
            "content": content_to_text(update.get("content").unwrap_or(&Value::Null)),
        }),
        "agent_thought_chunk" => json!({
            "type": "thinking",
            "content": content_to_text(update.get("content").unwrap_or(&Value::Null)),
        }),
        "tool_call" => {
            let name = meta_tool_name(update).unwrap_or("tool");
            json!({
                "type": "tool_call",
                "id": update.get("toolCallId").cloned().unwrap_or(Value::Null),
                "name": name,
                "input": update.get("rawInput").cloned().unwrap_or(json!({})),
            })
        }
        "tool_call_update" => {
            let status = update.get("status").and_then(|s| s.as_str()).unwrap_or("");
            json!({
                "type": "tool_result",
                "tool_use_id": update.get("toolCallId").cloned().unwrap_or(Value::Null),
                "name": meta_tool_name(update).unwrap_or("Result"),
                "content": content_to_text(update.get("content").unwrap_or(&Value::Null)),
                "is_error": status == "failed",
            })
        }
        _ => return None,
    };
    Some(evt.to_string())
}

/// `_bash-agent/usage` 通知的 params → usage 事件（params 已是完整 usage 事件体），
/// 与 stream-json 路径一致：从 stats.json 注入本次调用速度。
fn usage_to_ws(
    params: &Value,
    events_file: Option<PathBuf>,
    previous_speed: &mut Option<i64>,
) -> Option<String> {
    let mut obj = params.as_object()?.clone();
    obj.insert("type".into(), json!("usage"));
    if let Some(ep) = events_file {
        if let Some(s) = wait_for_speed_from_stats(&ep, *previous_speed) {
            *previous_speed = Some(s);
            obj.insert("speed_tok_per_sec".into(), json!(s));
        }
    }
    Some(Value::Object(obj).to_string())
}

/// ACP stopReason → stream-json stop 事件 reason。
fn stop_reason_to_ws(reason: &str) -> &'static str {
    const MAX: &str = "max_tokens";
    match reason {
        "cancelled" => "interrupted",
        MAX => MAX,
        _ => "end_turn",
    }
}
impl AcpClient {
    /// 常驻 spawn agent 子进程（基础参数追加 --acp）并完成握手。
    /// resume_target 为 Some 时先试 session/resume（失败退 session/new）；
    /// None 直接 session/new。成功后设置 events_path 供回放/速度读取。
    pub(crate) fn spawn(
        agent_bin: &Path,
        base_args: &[String],
        hub: Arc<WsHub>,
        resume_target: Option<String>,
        events_path: &EventsPath,
        home: &Path,
        cwd: &Path,
    ) -> Result<Self> {
        let mut cmd = Command::new(agent_bin);
        cmd.args(base_args);
        cmd.arg("--acp");
        cmd.stdin(Stdio::piped());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        let mut child = cmd
            .spawn()
            .with_context(|| format!("spawn {}", agent_bin.display()))?;
        let stdout = child.stdout.take().expect("stdout piped");
        let stderr = child.stderr.take().expect("stderr piped");

        // stderr 线程：与 stream-json 路径一致，内容包 stderr 事件外壳
        let h_err = hub.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let evt = json!({"type":"stderr","content":line}).to_string();
                h_err.broadcast(&evt);
            }
        });

        let pending: Arc<Mutex<HashMap<i64, SyncSender<Value>>>> =
            Arc::new(Mutex::new(HashMap::new()));

        // reader 线程：解析 stdout JSON-RPC —— 通知转 WS 事件广播；回包按 id 投递
        let p_reader = pending.clone();
        let h_reader = hub.clone();
        let ep_reader = events_path.clone();
        std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            let mut previous_speed: Option<i64> = None;
            for line in reader.lines() {
                let Ok(line) = line else { break };
                let line = line.trim_end();
                if line.is_empty() {
                    continue;
                }
                let Ok(v) = serde_json::from_str::<Value>(line) else {
                    continue;
                };
                if let Some(method) = v.get("method").and_then(|m| m.as_str()) {
                    let params = v.get("params").cloned().unwrap_or(Value::Null);
                    let evt = match method {
                        "session/update" => params
                            .get("update")
                            .and_then(acp_update_to_ws),
                        "_bash-agent/usage" => {
                            let events_file = ep_reader.lock().unwrap().clone();
                            usage_to_ws(&params, events_file, &mut previous_speed)
                        }
                        _ => None,
                    };
                    if let Some(evt) = evt {
                        h_reader.broadcast(&evt);
                    }
                    continue;
                }
                // 回包（result / error 都投给等待者）
                if let Some(id) = v.get("id").and_then(|i| i.as_i64()) {
                    let waiter = p_reader.lock().unwrap().remove(&id);
                    match waiter {
                        Some(tx) => {
                            let _ = tx.send(v);
                        }
                        None => {
                            // 没人等的回包：error 兜底广播，避免错误静默丢失
                            if v.get("error").is_some() {
                                let msg = v
                                    .pointer("/error/message")
                                    .and_then(|m| m.as_str())
                                    .unwrap_or("acp error reply");
                                let evt = json!({"type":"error","message":msg}).to_string();
                                h_reader.broadcast(&evt);
                            }
                        }
                    }
                }
            }
            // stdout EOF：agent 进程退出 —— 清空 pending 解除所有阻塞等待，并广播退出
            p_reader.lock().unwrap().clear();
            let evt = json!({"type":"process_exit","code":null}).to_string();
            h_reader.broadcast(&evt);
        });

        let next_id = AtomicI64::new(1);
        let stdin = Arc::new(Mutex::new(child.stdin.take().expect("stdin piped")));
        let mut client = Self {
            child,
            stdin,
            pending,
            next_id,
            session_id: String::new(),
        };
        client.handshake(&hub, resume_target, home, cwd)?;
        // 握手拿到 sessionId 后直接设置回放路径（不依赖 session_start 行）
        let ep = events_path_for(home, cwd, &client.session_id);
        *events_path.lock().unwrap() = Some(ep);
        eprintln!("[webagent] acp session: {}", client.session_id);
        Ok(client)
    }

    fn request_timeout(&self, method: &str, params: Value, timeout: Duration) -> Result<Value> {
        let rx = send_request(&self.stdin, &self.pending, &self.next_id, method, params)?;
        rx.recv_timeout(timeout)
            .map_err(|_| anyhow!("acp {method} timeout / agent exited"))
    }

    fn request(&self, method: &str, params: Value) -> Result<Value> {
        let rx = send_request(&self.stdin, &self.pending, &self.next_id, method, params)?;
        // agent 退出时 reader 清空 pending → recv 立即返回 Err，不会永久阻塞
        rx.recv().map_err(|_| anyhow!("acp {method}: agent exited"))
    }

    /// initialize 加 session/new 或 resume。resume 失败（含 -32002 会话不存在）退回 session/new。
    fn handshake(
        &mut self,
        hub: &Arc<WsHub>,
        resume_target: Option<String>,
        home: &Path,
        cwd: &Path,
    ) -> Result<()> {
        let _unused = home; // home 仅由调用方用于 events_path_for；会话 cwd 用真实 cwd
        let init = self.request_timeout(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
            HANDSHAKE_TIMEOUT,
        )?;
        if init.get("error").is_some() {
            return Err(anyhow!("acp initialize failed: {init}"));
        }

        let cwd_str = cwd.to_string_lossy().to_string();
        let mut sid: Option<String> = None;
        if let Some(target) = resume_target {
            let params = json!({"sessionId": target, "cwd": cwd_str, "mcpServers": []});
            let resp = self.request_timeout("session/resume", params, HANDSHAKE_TIMEOUT);
            match resp {
                Ok(r) if r.get("error").is_none() => sid = Some(target),
                _ => eprintln!("[webagent] acp resume failed, fallback to session/new"),
            }
        }
        if sid.is_none() {
            // cwd 传真实工作目录：agent 用它推 project_key 定位会话存储，
            // 与 events_path_for(home, cwd, sid) 的推导保持一致
            let params = json!({"cwd": cwd_str, "mcpServers": []});
            let resp = self.request_timeout("session/new", params, HANDSHAKE_TIMEOUT)?;
            let got = resp
                .pointer("/result/sessionId")
                .and_then(|s| s.as_str())
                .map(String::from);
            let Some(got) = got else {
                return Err(anyhow!("acp session/new 未返回 sessionId: {resp}"));
            };
            sid = Some(got);
        }
        self.session_id = sid.expect("session id resolved");

        // 对齐 stream-json：前端靠 session_start 重置 HUD / 结束 loading 态
        let evt = json!({"type":"session_start","session_id":self.session_id}).to_string();
        hub.broadcast(&evt);
        Ok(())
    }

    /// 单轮：user_input 事件 → session/prompt → stop 或 error 事件。
    /// 返回原始回包供上层判断（后续取消三态需要 stopReason）。
    pub(crate) fn run_turn(&self, prompt: &str, hub: &Arc<WsHub>) -> Result<Value> {
        // 对齐 stream-json 实时流：前端显示用户消息 + working 状态
        // （events.jsonl 的 user_input 由 agent worker 自己写，这里只补 WS 流）
        let evt = json!({"type":"user_input","content":prompt}).to_string();
        hub.broadcast(&evt);

        let params = json!({
            "sessionId": self.session_id,
            "prompt": [{"type":"text","text": prompt}],
        });
        let resp = self.request("session/prompt", params)?;
        if let Some(e) = resp.get("error") {
            let msg = e
                .pointer("/data/message")
                .and_then(|m| m.as_str())
                .or_else(|| e.get("message").and_then(|m| m.as_str()))
                .unwrap_or("internal error")
                .to_string();
            let evt = json!({"type":"error","message":msg}).to_string();
            hub.broadcast(&evt);
            return Ok(resp);
        }
        let stop = resp
            .pointer("/result/stopReason")
            .and_then(|s| s.as_str())
            .unwrap_or("end_turn");
        let evt = json!({"type":"stop","reason":stop_reason_to_ws(stop)}).to_string();
        hub.broadcast(&evt);
        Ok(resp)
    }
}
