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
use std::process::{ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Condvar, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant};

/// 握手类请求（initialize / session/new / session/resume）超时。
/// prompt 一律不限时：靠 agent 退出时清空 pending（Sender 全部 drop）解除阻塞，
/// 取消/强制停止由 session/cancel 通知与 terminate() 走独立路径。
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);
/// SIGTERM 后等 agent 自行排空退出的上限：agent.sh 的排空路径固定 sleep 3s
/// 再收尾 worker，窗口给够它才有机会自己清干净。
const TERM_GRACE: Duration = Duration::from_secs(5);
/// SIGKILL 后等退出收尾的上限。
const KILL_GRACE: Duration = Duration::from_secs(2);
/// 清理后代进程组后等其退出上限。
const ORPHAN_GRACE: Duration = Duration::from_millis(800);
/// 进程树快照的采样节奏。worker 的通知子 shell 等进程组在 session 应答之后
/// 才创建（worker 要先加载工具定义），所以 spawn 后这一小段窗口加密采样，
/// 之后放慢到 1s 一次。
const TREE_FAST_WINDOW: Duration = Duration::from_secs(2);
const TREE_FAST_STEP: Duration = Duration::from_millis(250);
const TREE_STEP: Duration = Duration::from_secs(1);

pub(crate) struct AcpClient {
    /// None = stdin 已关闭（优雅退出后）。不手工 libc::close，
    /// 让 ChildStdin 自然 Drop 关 fd，避免双重关闭同一 fd（P0-1）
    stdin: Arc<Mutex<Option<ChildStdin>>>,
    /// JSON-RPC id → 等待回包的 sender（reader 线程按 id 投递）
    pending: Arc<Mutex<HashMap<i64, SyncSender<Value>>>>,
    next_id: AtomicI64,
    pub(crate) session_id: String,
    /// 上层 client 槽（Weak）：stdin 写失败等不可恢复错误时立即置空，
    /// 让下一轮 prompt 重新 spawn，而不是等 watchdog 收尾（issue #116-6）
    st: Weak<Mutex<Option<Arc<AcpClient>>>>,
    /// agent 进程组 id（process_group(0) 下等于子进程 pid）。
    /// Child 本身交给 watchdog 线程 wait/reap，这里只留 pgid 供发信号。
    pgid: i32,
    /// agent 派生的全部进程组（含主组）的累计快照。agent.sh 的 worker 在后台
    /// 子 shell 里跑工具、收通知，它们各自成进程组，killpg 主组打不到；根进程
    /// 退出后 ppid 链断裂就追溯不到，所以必须在它存活期间持续采样（后台定时
    /// + SIGTERM 前补一次，见 spawn_tree_refresher / merge_snapshot）。
    descendant_pgids: Arc<Mutex<Vec<i32>>>,
    /// 退出收尾是否完成（进程已退出 + 孤儿已清 + pending/state 已处理）；
    /// terminate() 等它，保证返回后可以安全 respawn
    done_sig: Arc<(Mutex<bool>, Condvar)>,
}

/// 取全表 pid/ppid/pgid，求根进程（pid == pgid）的后代闭包，返回涉及的
/// 进程组去重列表。一次 ps 调用，macOS/Linux 语法一致。
fn snapshot_pgids(root_pid: i32) -> Vec<i32> {
    let Ok(out) = Command::new("ps")
        .args(["-axo", "pid=,ppid=,pgid="])
        .output()
    else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut children: HashMap<i32, Vec<i32>> = HashMap::new();
    let mut pg_of: HashMap<i32, i32> = HashMap::new();
    for line in text.lines() {
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() != 3 {
            continue;
        }
        let (Ok(p), Ok(pp), Ok(g)) = (f[0].parse(), f[1].parse(), f[2].parse()) else {
            continue;
        };
        children.entry(pp).or_default().push(p);
        pg_of.insert(p, g);
    }
    // 只按进程组杀：pid 在根退出后到清理之间可能已被回收复用，而进程组 id
    // 在组内还有成员时不会复用，误杀风险与原来的 killpg 主组同量级。
    let mut groups: Vec<i32> = Vec::new();
    let mut stack = vec![root_pid];
    while let Some(p) = stack.pop() {
        let g = *pg_of.get(&p).unwrap_or(&root_pid);
        if !groups.contains(&g) {
            groups.push(g);
        }
        if let Some(k) = children.get(&p) {
            stack.extend(k.iter().copied());
        }
    }
    groups
}

/// 对一组进程组发 SIGKILL 并等待其成员退出（孤儿由 init 回收）。
fn kill_groups(groups: &[i32]) {
    for &g in groups {
        unsafe {
            libc::killpg(g, libc::SIGKILL);
        }
    }
    let deadline = Instant::now() + ORPHAN_GRACE;
    loop {
        let alive = groups.iter().any(|&g| unsafe { libc::killpg(g, 0) } == 0);
        if !alive || Instant::now() >= deadline {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// 求根进程当前的后代进程组，并入快照。
///
/// 合并而非覆盖：worker 先于根进程退出时，它留下的孤儿 ppid 变 1，新快照
/// 追不到其进程组；覆盖会把这个组丢掉。所以保留「仍有存活成员」的旧组再
/// 并入新快照，已空的组顺手剔除（同时缩小 pgid 复用误杀窗口）。
/// 只有根进程存活时才能发现新组（它退出后 ppid 链断裂，追溯不到自成进程组
/// 的后代）；根进程退出后再调用不会发现新组，但已有的组照常保留，无害。
fn merge_snapshot(groups: &Mutex<Vec<i32>>, root_pgid: i32) {
    let fresh = snapshot_pgids(root_pgid);
    let mut groups = groups.lock().unwrap();
    groups.retain(|&g| unsafe { libc::killpg(g, 0) } == 0);
    for g in fresh {
        if !groups.contains(&g) {
            groups.push(g);
        }
    }
}

/// agent 存活期间定期刷新进程树快照的后台线程，直到 stop 置位（根进程退出）。
///
/// 不能只在「等回包」时刷新：快轮次（回包早于一个采样周期）或轮次之间的
/// 空闲期没有任何刷新时机，agent 此时被 kill -9 / 崩溃，就只能带着过期快照
/// 收尾，漏掉这段时间里新建的进程组。
fn spawn_tree_refresher(groups: Arc<Mutex<Vec<i32>>>, root_pgid: i32, stop: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        let started = Instant::now();
        while !stop.load(Ordering::Relaxed) {
            merge_snapshot(&groups, root_pgid);
            let step = if started.elapsed() < TREE_FAST_WINDOW {
                TREE_FAST_STEP
            } else {
                TREE_STEP
            };
            std::thread::sleep(step);
        }
    });
}

/// agent 退出收尾（reader EOF 与 watchdog 二选一先到者生效）：
/// 清 pending 解除本轮等待；仅当自己仍是当前 client 才置空 state 并广播
/// process_exit——否则旧 reader 会把 respawn 后的新 client 抹掉（P1-4）。
#[allow(clippy::too_many_arguments)]
fn acp_finalize(
    finalized: &AtomicBool,
    pending: &Mutex<HashMap<i64, SyncSender<Value>>>,
    hub: &WsHub,
    st: &Weak<Mutex<Option<Arc<AcpClient>>>>,
    generation: &AtomicU64,
    slot: &OnceLock<u64>,
) {
    pending.lock().unwrap().clear();
    if finalized.swap(true, Ordering::SeqCst) {
        return;
    }
    let mine = slot.get().copied();
    let current = generation.load(Ordering::SeqCst);
    if mine != Some(current) {
        if mine.is_some() {
            eprintln!("[webagent] stale acp exit (gen {mine:?} != {current}), keep current client");
        }
        return;
    }
    if let Some(st) = st.upgrade() {
        *st.lock().unwrap() = None;
    }
    let evt = json!({"type":"process_exit","code":null}).to_string();
    hub.broadcast(&evt);
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
        _ => v
            .get("text")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string(),
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
            // in_progress 是流式中间态（标准 ACP agent 会持续推送）。映射成
            // tool_result 会让前端提前收尾工具卡片（openToolId 置空），终态到达
            // 时再新建一张 Result 卡片。中间态不映射，等 completed/failed 一次
            // 性出结果（issue #116-2）
            if status == "in_progress" {
                return None;
            }
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
        // 必须在交给 watchdog wait 之前取：process_group(0) 下 pid 即进程组 id
        let pgid = child.id() as i32;

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
        let descendant_pgids: Arc<Mutex<Vec<i32>>> = Arc::new(Mutex::new(Vec::new()));
        // 根进程退出后置位：通知后台刷新线程停手（见 spawn_tree_refresher）
        let tree_stop: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let finalized: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));
        let done_sig: Arc<(Mutex<bool>, Condvar)> = Arc::new((Mutex::new(false), Condvar::new()));

        // reader 线程：解析 stdout JSON-RPC —— 通知转 WS 事件广播；回包按 id 投递
        let p_reader = pending.clone();
        let h_reader = hub.clone();
        let ep_reader = events_path.clone();
        let st_reader = st_weak.clone();
        let p_stdin = stdin.clone();
        let gen_reader = generation.clone();
        let slot_reader = my_gen_slot.clone();
        let fin_reader = finalized.clone();
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
            // stdout EOF：agent 侧全部写端已关闭。退出收尾与 watchdog 共用
            // acp_finalize，先到者生效。
            acp_finalize(
                &fin_reader,
                &p_reader,
                &h_reader,
                &st_reader,
                &gen_reader,
                &slot_reader,
            );
        });

        // watchdog 线程：等直接子进程退出并 reap。退出语义以这里为准，不能
        // 只靠 stdout EOF——agent.sh 的 worker 在后台子 shell 里跑工具、收通知，
        // 这些子 shell 各自成进程组且持有 stdout 写端（fd 10），根进程死了
        // reader 也收不到 EOF，state 永不置空、worker 线程卡在 recv。根进程
        // 退出后 ppid 链断裂，所以先用它存活时留下的进程组快照清掉残留孤儿
        // （否则新旧 worker 会抢同一会话 FIFO），再做收尾，最后通知 terminate()。
        let p_watch = pending.clone();
        let h_watch = hub.clone();
        let st_watch = st_weak.clone();
        let gen_watch = generation.clone();
        let slot_watch = my_gen_slot.clone();
        let fin_watch = finalized.clone();
        let groups_watch = descendant_pgids.clone();
        let done_watch = done_sig.clone();
        // 根进程一退出就停掉后台刷新：此后 ppid 链已断，刷新发现不了新组
        let stop_watch = tree_stop.clone();
        std::thread::spawn(move || {
            let _ = child.wait();
            stop_watch.store(true, Ordering::Relaxed);
            let groups = groups_watch.lock().unwrap().clone();
            kill_groups(&groups);
            acp_finalize(
                &fin_watch,
                &p_watch,
                &h_watch,
                &st_watch,
                &gen_watch,
                &slot_watch,
            );
            let (lock, cv) = &*done_watch;
            *lock.lock().unwrap() = true;
            cv.notify_all();
        });

        let next_id = AtomicI64::new(1);
        let mut client = Self {
            stdin,
            pending,
            next_id,
            session_id: String::new(),
            st: st_weak.clone(),
            pgid,
            descendant_pgids,
            done_sig,
        };
        // 握手（session/new|resume）期间 worker 及其子 shell 就会创建，后台刷新
        // 要在此之前起跑，才不会漏掉它们所属的进程组
        spawn_tree_refresher(client.descendant_pgids.clone(), client.pgid, tree_stop);
        if let Err(e) = client.handshake(&hub, resume_target, cwd) {
            // 握手失败：停掉 agent（连同其派生进程）再返回，避免泄漏
            client.terminate();
            return Err(e);
        }
        // 握手拿到 sessionId 后直接设置回放路径（不依赖 session_start 行）
        let ep = events_path_for(home, cwd, &client.session_id);
        *events_path.lock().unwrap() = Some(ep);
        eprintln!("[webagent] acp session: {}", client.session_id);
        // 占定 generation 号：此后本 client 的退出才有权置空 state（P1-4）
        let my_gen = 1 + generation.fetch_add(1, Ordering::SeqCst);
        let _ = my_gen_slot.set(my_gen);
        Ok(client)
    }

    /// 统一请求入口：timeout=None 不限（agent 退出时清空 pending 解除阻塞）；
    /// Some(t) 仅用于握手。超时/退出路径都回收 pending 条目（P3-17）。
    fn request_raw(&self, method: &str, params: Value, timeout: Option<Duration>) -> Result<Value> {
        let (id, rx) = match send_request(&self.stdin, &self.pending, &self.next_id, method, params)
        {
            Ok(v) => v,
            Err(e) => {
                // stdin 写失败 = agent 已死/正在退出。立即注销自己，否则 watchdog
                // 收尾前队列里的下一条请求会复用失效 client 再报一次错（#116-6）
                self.invalidate();
                return Err(e);
            }
        };
        let res = match timeout {
            Some(t) => rx.recv_timeout(t).map_err(|e| e.to_string()),
            None => rx.recv().map_err(|e| e.to_string()),
        };
        res.map_err(|e| anyhow!("acp {method}: {e}"))
            .inspect_err(|_| {
                self.pending.lock().unwrap().remove(&id);
            })
    }

    /// 立即注销自己：仅当上层 state 仍指向本 client 时置空，让下一轮重新
    /// spawn（用 last_sid 走 session/resume 恢复会话）。reader/watchdog 的
    /// acp_finalize 有 finalized 去重，重复置空无害。
    fn invalidate(&self) {
        let Some(st) = self.st.upgrade() else { return };
        let mut g = st.lock().unwrap();
        if g.as_ref()
            .is_some_and(|c| Arc::as_ptr(c) == self as *const AcpClient)
        {
            *g = None;
        }
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
        // prompt 完全不限时：挂死由 session/cancel 通知与 terminate() 处理，
        // 不再用超时兜底（超时只是把 agent 侧的轮次变成孤儿，见 issue #116-1）
        let resp = self.request_raw("session/prompt", params, None)?;
        if let Some(e) = resp.get("error") {
            let msg = e
                .pointer("/data/message")
                .and_then(|m| m.as_str())
                .or_else(|| e.get("message").and_then(|m| m.as_str()))
                .unwrap_or("internal error")
                .to_string();
            // agent 侧 session 已失效（worker 崩溃后被回收，issue #116-4）：注销
            // 自己，下一轮 spawn 用 last_sid 走 session/resume 自愈
            if e.get("code").and_then(|c| c.as_i64()) == Some(-32002) {
                self.invalidate();
            }
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

    /// 等退出收尾完成（watchdog：进程退出 → 清孤儿 → 置空 state/广播）。返回是否完成。
    fn wait_done(&self, timeout: Duration) -> bool {
        let (lock, cv) = &*self.done_sig;
        let deadline = Instant::now() + timeout;
        let mut done = lock.lock().unwrap();
        while !*done {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                break;
            }
            done = cv.wait_timeout(done, left).unwrap().0;
        }
        *done
    }

    /// 停止 agent：先 SIGTERM 让它自己排空收尾（agent.sh 约 3s），超时再
    /// SIGKILL。两条路都由 watchdog 在根进程退出后清掉残留在后代进程组里的
    /// 孤儿（worker 的后台子 shell 各自成进程组，单 killpg 主组打不到）并广播
    /// process_exit；这里等到收尾完成才返回，返回后可安全 respawn。
    pub(crate) fn terminate(&self) {
        // SIGTERM 前补一次刷新：此刻进程树还完整，把采样间隙里新建的组也记下
        merge_snapshot(&self.descendant_pgids, self.pgid);
        unsafe {
            libc::killpg(self.pgid, libc::SIGTERM);
        }
        if self.wait_done(TERM_GRACE) {
            return;
        }
        unsafe {
            libc::killpg(self.pgid, libc::SIGKILL);
        }
        if !self.wait_done(KILL_GRACE) {
            // 理论上不可达（SIGKILL 必杀、watchdog 必被唤醒）：兜底直接清
            kill_groups(&self.descendant_pgids.lock().unwrap().clone());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ws_event(v: Value) -> Option<Value> {
        acp_update_to_ws(&v).map(|s| serde_json::from_str(&s).expect("合法 WS 事件 JSON"))
    }

    // issue #116-2：tool_call_update 的 in_progress 是流式中间态，不能映射成
    // tool_result——否则前端会提前收尾工具卡片（openToolId 置空），终态到达时
    // 再新建一张 Result 卡片
    #[test]
    fn tool_call_update_in_progress_is_ignored() {
        let u = json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t1",
            "status": "in_progress",
            "content": [{"type":"content","content":{"type":"text","text":"partial"}}],
        });
        assert!(acp_update_to_ws(&u).is_none());
    }

    #[test]
    fn tool_call_update_terminal_states_map_to_tool_result() {
        for (status, is_error) in [("completed", false), ("failed", true)] {
            let u = json!({
                "sessionUpdate": "tool_call_update",
                "toolCallId": "t1",
                "status": status,
                "content": [{"type":"content","content":{"type":"text","text":"done"}}],
                "_meta": {"bash-agent": {"name": "Bash"}},
            });
            let evt = ws_event(u).expect("终态必须映射");
            assert_eq!(evt["type"], "tool_result");
            assert_eq!(evt["is_error"], is_error);
            assert_eq!(evt["content"], "done");
            assert_eq!(evt["name"], "Bash");
        }
    }

    // 兼容性：缺 status 的 tool_call_update 仍按 completed 处理（老 agent/第三方）
    #[test]
    fn tool_call_update_without_status_still_maps() {
        let u = json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": "t1",
            "content": {"type": "text", "text": "x"},
        });
        let evt = ws_event(u).expect("缺 status 不应丢弃");
        assert_eq!(evt["type"], "tool_result");
        assert_eq!(evt["is_error"], false);
    }

    #[test]
    fn stop_reason_mapping() {
        assert_eq!(stop_reason_to_ws("cancelled"), "interrupted");
        assert_eq!(stop_reason_to_ws("end_turn"), "end_turn");
        assert_eq!(stop_reason_to_ws("max_tokens"), "max_tokens");
        assert_eq!(stop_reason_to_ws("refusal"), "error");
    }
}
