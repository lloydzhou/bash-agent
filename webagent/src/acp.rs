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
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Duration;

/// 握手类请求超时。prompt 等待上限由 --prompt-timeout-ms 决定（0=不限）：
/// 不限时靠 agent 退出时 reader 清空 pending（Sender 全部 drop）解除阻塞；
/// 限时则超时报错并回收 pending 条目，避免 agent 活着但不回包卡死 worker（P1-5）。
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

pub(crate) struct AcpClient {
    /// Mutex 包裹以支持 terminate 轮询 try_wait 与 Drop reap（P1-7/P1-8）
    child: Mutex<Child>,
    /// None = stdin 已关闭（优雅退出后）。不手工 libc::close，
    /// 让 ChildStdin 自然 Drop 关 fd，避免双重关闭同一 fd（P0-1）
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    /// JSON-RPC id → 等待回包的 sender（reader 线程按 id 投递）
    pending: Arc<Mutex<HashMap<i64, SyncSender<Value>>>>,
    next_id: AtomicI64,
    pub(crate) session_id: String,
    /// prompt 回包等待上限；None = 不限（P1-5）
    prompt_timeout: Option<Duration>,
}

impl Drop for AcpClient {
    fn drop(&mut self) {
        // reap 已退出子进程：长跑 webagent 每次崩溃/强停置空 state 都会丢弃
        // client，没有 Drop 会留下已退出未 wait 的僵尸进程（P1-7）
        let _ = self.child.lock().unwrap().try_wait();
    }
}


/// 发送 JSON-RPC 请求（写 stdin + 注册 pending）。
fn send_request(
    stdin: &Mutex<Option<ChildStdin>>,
    pending: &Mutex<HashMap<i64, SyncSender<Value>>>,
    next_id: &AtomicI64,
    method: &str,
    params: Value,
) -> Result<(i64, Receiver<Value>)> {
    let id = next_id.fetch_add(1, Ordering::SeqCst);
    let (tx, rx) = sync_channel(1);
    pending.lock().unwrap().insert(id, tx);
    let frame = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
    let write_res = {
        let mut g = stdin.lock().unwrap();
        match g.as_mut() {
            Some(w) => writeln!(w, "{frame}")
                .with_context(|| format!("acp write {method}"))
                .map(|_| w.flush().ok()),
            None => Err(anyhow!("acp stdin closed (agent shutting down)")),
        }
    };
    if let Err(e) = write_res {
        pending.lock().unwrap().remove(&id);
        return Err(e);
    }
    Ok((id, rx))
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
    // refusal / max_turn_requests 等异常收尾不映射 end_turn：
    // 前端把 end_turn 当正常结束展示，掩盖异常收尾（P3-19）
    match reason {
        "cancelled" => "interrupted",
        "end_turn" => "end_turn",
        MAX => MAX,
        _ => "error",
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
        generation: Arc<AtomicU64>,
        prompt_timeout: Option<Duration>,
        st_weak: Weak<Mutex<Option<Arc<AcpClient>>>>,
    ) -> Result<Self> {
        let mut cmd = Command::new(agent_bin);
        cmd.args(base_args);
        cmd.arg("--acp");
        cmd.process_group(0);
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
        // stdin 的 Arc 提前建好：reader 线程要对未知反向请求回 -32601（P0-2）
        let stdin: Arc<Mutex<Option<ChildStdin>>> =
            Arc::new(Mutex::new(Some(child.stdin.take().expect("stdin piped"))));
        // 本 client 的 generation 号：EOF 置空上层 state 前校验自己仍是
        // 当前 client，防旧 reader 抹掉 respawn 后的新 client（P1-4）
        let my_gen_slot: Arc<OnceLock<u64>> = Arc::new(OnceLock::new());

        // reader 线程：解析 stdout JSON-RPC —— 通知转 WS 事件广播；回包按 id 投递
        let p_reader = pending.clone();
        let h_reader = hub.clone();
        let ep_reader = events_path.clone();
        let st_reader = st_weak;
        let p_stdin = stdin.clone();
        let gen_reader = generation.clone();
        let slot_reader = my_gen_slot.clone();
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
                        _ => {
                            // 未知 method：带 id 的请求回 -32601 (Method not found)。
                            // 标准 ACP agent 的 session/request_permission 等反向
                            // 请求无人应答会永久挂住（P0-2，对齐 agent.sh 的
                            // acp_reply_error 行为），回包后 agent 可降级处理
                            if v.get("id").is_some() {
                                let frame = json!({
                                    "jsonrpc": "2.0",
                                    "id": v["id"],
                                    "error": {
                                        "code": -32601,
                                        "message": format!("Method not found: {method}"),
                                    },
                                });
                                let mut g = p_stdin.lock().unwrap();
                                if let Some(w) = g.as_mut() {
                                    let _ = writeln!(w, "{frame}");
                                    w.flush().ok();
                                }
                            }
                            None
                        }
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
            // stdout EOF：agent 进程退出。仅当自己仍是当前 client（generation
            // 未被新 spawn 推进）才置空上层状态并广播退出——否则旧 reader 会
            // 把 respawn 后的新 client 抹掉，双 agent 抢同一 events.jsonl（P1-4）。
            // pending 无论新旧都清（解除本轮等待者）。
            let mine = slot_reader.get().copied();
            let current = gen_reader.load(Ordering::SeqCst);
            let is_current = mine == Some(current);
            if is_current {
                if let Some(st) = st_reader.upgrade() {
                    *st.lock().unwrap() = None;
                }
            } else {
                eprintln!(
                    "[webagent] stale acp reader exit (gen {mine:?} != {current}), keep current client"
                );
            }
            p_reader.lock().unwrap().clear();
            if is_current {
                let evt = json!({"type":"process_exit","code":null}).to_string();
                h_reader.broadcast(&evt);
            }
        });

        let next_id = AtomicI64::new(1);
        let mut client = Self {
            child: Mutex::new(child),
            stdin,
            pending,
            next_id,
            session_id: String::new(),
            prompt_timeout,
        };
        if let Err(e) = client.handshake(&hub, resume_target, cwd) {
            // 握手失败：杀掉进程组再返回，避免泄漏仍活着的子进程
            client.terminate();
            return Err(e);
        }
        // 握手拿到 sessionId 后直接设置回放路径（不依赖 session_start 行）
        let ep = events_path_for(home, cwd, &client.session_id);
        *events_path.lock().unwrap() = Some(ep);
        eprintln!("[webagent] acp session: {}", client.session_id);
        // 占定 generation 号：此后本 client 的 reader EOF 才有权置空 state（P1-4）
        let my_gen = 1 + generation.fetch_add(1, Ordering::SeqCst);
        let _ = my_gen_slot.set(my_gen);
        Ok(client)
    }

    /// 统一请求入口：timeout=None 不限（agent 退出时 reader 清空 pending 解除
    /// 阻塞）；Some(t) 超时报错。超时/退出路径都回收 pending 条目（P3-17）。
    fn request_raw(
        &self,
        method: &str,
        params: Value,
        timeout: Option<Duration>,
    ) -> Result<Value> {
        let (id, rx) = send_request(&self.stdin, &self.pending, &self.next_id, method, params)?;
        let res = match timeout {
            Some(t) => rx.recv_timeout(t).map_err(|e| e.to_string()),
            None => rx.recv().map_err(|e| e.to_string()),
        };
        res.map_err(|e| anyhow!("acp {method}: {e}"))
            .inspect_err(|_| {
                self.pending.lock().unwrap().remove(&id);
            })
    }

    /// initialize 加 session/new 或 resume。resume 失败（含 -32002 会话不存在）退回 session/new。
    fn handshake(
        &mut self,
        hub: &Arc<WsHub>,
        resume_target: Option<String>,
        cwd: &Path,
    ) -> Result<()> {
        let init = self.request_raw(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
            Some(HANDSHAKE_TIMEOUT),
        )?;
        if init.get("error").is_some() {
            return Err(anyhow!("acp initialize failed: {init}"));
        }

        let cwd_str = cwd.to_string_lossy().to_string();
        let mut sid: Option<String> = None;
        if let Some(target) = resume_target {
            let params = json!({"sessionId": target, "cwd": cwd_str, "mcpServers": []});
            let resp = self.request_raw("session/resume", params, Some(HANDSHAKE_TIMEOUT));
            match resp {
                Ok(r) if r.get("error").is_none() => sid = Some(target),
                _ => {
                    let msg = "原 ACP 会话不可恢复，已新建会话";
                    eprintln!("[webagent] acp resume failed, fallback to session/new: {msg}");
                    // 前端可见提示：stderr 是既有事件格式，前端原样展示（P2-10）
                    let evt =
                        json!({"type":"stderr","content": format!("[webagent] {msg}")}).to_string();
                    hub.broadcast(&evt);
                }
            }
        }
        if sid.is_none() {
            // cwd 传真实工作目录：agent 用它推 project_key 定位会话存储，
            // 与 events_path_for(home, cwd, sid) 的推导保持一致
            let params = json!({"cwd": cwd_str, "mcpServers": []});
            let resp = self.request_raw("session/new", params, Some(HANDSHAKE_TIMEOUT))?;
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
        let resp = self.request_raw("session/prompt", params, self.prompt_timeout)?;
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

    /// 发送 session/cancel 通知（JSON-RPC 无 id）：agent 中断当前 prompt，
    /// 回 stopReason=cancelled 的 prompt 回包。
    pub(crate) fn cancel(&self) -> Result<()> {
        let frame = json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId": self.session_id}});
        let mut g = self.stdin.lock().unwrap();
        match g.as_mut() {
            Some(w) => {
                writeln!(w, "{frame}").context("acp write session/cancel")?;
                w.flush().ok();
                Ok(())
            }
            None => Err(anyhow!("acp stdin closed")),
        }
    }

    /// 关闭子进程 stdin：take 出 ChildStdin 让其自然 Drop 关闭 fd——
    /// 不再手工 libc::close，避免与后续 Drop 双重关闭同一 fd（P0-1）。
    /// agent 读到 EOF 后自行收尾退出（SESSION_END 后 wait）。
    pub(crate) fn shutdown_stdin(&self) {
        let _ = self.stdin.lock().unwrap().take();
    }

    /// 停止 agent 整个进程组：先 SIGTERM（agent trap 收尾清理），
    /// 2s 后仍未退出则 SIGKILL（bash 3.2 阻塞 read 可能吞掉 TERM，KILL 兜底）。
    /// stdout 关闭后 reader 线程广播 process_exit。
    pub(crate) fn terminate(&self) {
        let pgid = self.child.lock().unwrap().id() as i32;
        unsafe { libc::killpg(pgid, libc::SIGTERM) };
        // 轮询 try_wait（100ms x 20）：已退出立即返回，不固定睡 2s——
        // 缩短连接线程阻塞，也降低 pgid 复用时误杀无关进程组的风险（P1-8）
        for _ in 0..20 {
            let mut ch = self.child.lock().unwrap();
            match ch.try_wait() {
                Ok(Some(_)) | Err(_) => return,
                Ok(None) => {}
            }
            drop(ch); // 释放锁再睡，reader 置空 state 不被锁卡住
            std::thread::sleep(Duration::from_millis(100));
        }
        unsafe { libc::killpg(pgid, libc::SIGKILL) };
        // KILL 兜底后 reap，防僵尸
        let _ = self.child.lock().unwrap().wait();
    }
}
