use anyhow::{Context, Result};
use serde_json::json;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::{Arc, Mutex};

mod server;

const AGENT_NAMES: &[&str] = &["bash-agent", "goagent", "rustagent", "rust2agent", "cagent"];

/// 当前子进程 PID，供 Ctrl+C 时向 agent 发送 SIGINT（kill 回退不需要持有 Child）。
static CURRENT_PID: AtomicI32 = AtomicI32::new(-1);

/// 广播一条事件给所有客户端。
fn emit(hub: &Arc<server::WsHub>, line: &str) {
    hub.broadcast(line);
}

/// 将 cwd 映射为项目目录名（对齐 agent 侧 project_key：/ -> -，折叠连续 -）。
fn project_key(cwd: &Path) -> String {
    let s = cwd.to_string_lossy();
    let stripped = s.strip_prefix(std::path::MAIN_SEPARATOR).unwrap_or(&s);
    let mut clean = String::new();
    let mut prev_dash = false;
    for ch in stripped.chars() {
        let mapped = if ch == std::path::MAIN_SEPARATOR {
            '-'
        } else if ch.is_ascii_alphanumeric() || ch == '.' || ch == '_' || ch == '-' {
            ch
        } else {
            '-'
        };
        if mapped == '-' && prev_dash {
            continue;
        }
        clean.push(mapped);
        prev_dash = mapped == '-';
    }
    format!("-{}", clean.trim_matches('-'))
}

/// 构造 events.jsonl 路径：$BASH_AGENT_HOME/.bash-agent/projects/<project_key>/<session_id>/events.jsonl
fn events_path_for(home: &Path, cwd: &Path, session_id: &str) -> PathBuf {
    home.join(".bash-agent/projects")
        .join(project_key(cwd))
        .join(session_id)
        .join("events.jsonl")
}

/// --continue 模式下扫描项目目录，找最近活跃的 session（对齐 continue_session）。
fn resolve_latest_session(home: &Path, cwd: &Path) -> Option<String> {
    let dir = home.join(".bash-agent/projects").join(project_key(cwd));
    let mut newest: Option<(std::time::SystemTime, String)> = None;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if !entry.path().is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with("sub_") {
                continue;
            }
            let events = entry.path().join("events.jsonl");
            let mt = std::fs::metadata(&events)
                .and_then(|m| m.modified())
                .unwrap_or_else(|_| {
                    std::fs::metadata(entry.path())
                        .and_then(|m| m.modified())
                        .unwrap_or(std::time::SystemTime::UNIX_EPOCH)
                });
            match &newest {
                Some((ts, _)) if *ts >= mt => {}
                _ => newest = Some((mt, name)),
            }
        }
    }
    newest.map(|(_, sid)| sid)
}

/// 启动时尝试解析 events.jsonl 路径：
/// --session <id>  → 直接构造（仅当下一个参数不以 `-` 开头，避免把 --output-format 当 session 名）
/// --continue      → 扫描项目目录找最近 session
/// 都没有           → None（首次 session_start 后动态设置）
fn resolve_events_path(args: &[String], home: &Path, cwd: &Path) -> Option<PathBuf> {
    for i in 0..args.len() {
        if args[i] == "--session"
            && let Some(sid) = args.get(i + 1)
            && !sid.starts_with('-')
        {
            return Some(events_path_for(home, cwd, sid));
        }
    }
    if args.iter().any(|a| a == "--continue") {
        let sid = resolve_latest_session(home, cwd)?;
        return Some(events_path_for(home, cwd, &sid));
    }
    None
}

/// 解析 agent 可执行文件：带路径直接用；否则按名字在可执行文件上级的 dist/、当前目录 dist/ 查找，最后回退 PATH。
fn resolve_agent(bin: &str) -> PathBuf {
    if bin.contains('/') {
        return PathBuf::from(bin);
    }
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        for up in [
            dir.to_path_buf(),
            dir.join(".."),
            dir.join("../.."),
            dir.join("../../.."),
        ] {
            candidates.push(up.join("dist").join(bin));
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("dist").join(bin));
    }
    for cand in candidates {
        if cand.is_file() {
            return cand;
        }
    }
    PathBuf::from(bin)
}

/// 单轮：spawn 一个 agent 子进程，把 stdout 的 stream-json 与 stderr 转发给 WS 广播。
/// 首次 session_start 时动态设置 events_path（供后续客户端连接回放）。
fn run_turn(
    agent_bin: &PathBuf,
    base_args: &[String],
    prompt: &str,
    hub: Arc<server::WsHub>,
    events_path: server::EventsPath,
    home: &Path,
    cwd: &Path,
) -> Result<()> {
    let mut cmd = Command::new(agent_bin);
    cmd.args(base_args);
    // prompt 作为最后一个位置参数（agent 取最后一个非 flag 参数为 prompt）
    cmd.arg(prompt);
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());

    let mut child = cmd
        .spawn()
        .with_context(|| format!("spawn {}", agent_bin.display()))?;
    let pid = child.id() as i32;
    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");
    CURRENT_PID.store(pid, Ordering::SeqCst);

    // stdout 线程：逐行原样转发；看到 session_start 时动态设置 events.jsonl 路径
    let h_out = hub.clone();
    let ep_out = events_path.clone();
    let home_out = home.to_path_buf();
    let cwd_out = cwd.to_path_buf();
    let out_thread = std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            let mut buf = String::new();
            match reader.read_line(&mut buf) {
                Ok(0) => break,
                Ok(_) => {
                    let line = buf.trim_end();
                    // 首次 session_start：如果 events_path 尚未设置，用 session_id 构造路径
                    if let Ok(evt) = serde_json::from_str::<serde_json::Value>(line)
                        && evt.get("type").and_then(|v| v.as_str()) == Some("session_start")
                        && let Some(sid) = evt.get("session_id").and_then(|v| v.as_str())
                    {
                        let mut guard = ep_out.lock().unwrap();
                        if guard.is_none() {
                            *guard = Some(events_path_for(&home_out, &cwd_out, sid));
                        }
                    }
                    emit(&h_out, line);
                }
                Err(_) => break,
            }
        }
    });

    // stderr 线程：内容原样包一层 stderr 事件外壳（仅标注来源，不剥离/不过滤），展示逻辑交给前端
    let h_err = hub.clone();
    let err_thread = std::thread::spawn(move || {
        let mut reader = BufReader::new(stderr);
        loop {
            let mut buf = String::new();
            match reader.read_line(&mut buf) {
                Ok(0) => break,
                Ok(_) => {
                    let evt = json!({"type":"stderr","content":buf.trim_end()}).to_string();
                    emit(&h_err, &evt);
                }
                Err(_) => break,
            }
        }
    });

    let status: Result<ExitStatus> = child.wait().context("wait agent");
    CURRENT_PID.store(-1, Ordering::SeqCst);
    let _ = out_thread.join();
    let _ = err_thread.join();

    let code = status.ok().and_then(|s| s.code());
    emit(&hub, &json!({"type":"process_exit","code":code}).to_string());
    if code != Some(0) {
        emit(
            &hub,
            &json!({"type":"error","message":format!("agent exited with code {code:?}")})
                .to_string(),
        );
    }
    Ok(())
}

fn usage() {
    eprintln!("webagent — WebSocket 桥：每条输入 spawn 一个 agent 子进程，输出转发给浏览器");
    eprintln!();
    eprintln!("Usage:");
    eprintln!("  webagent [options] <agent> [agent args...]");
    eprintln!();
    eprintln!("Options:");
    eprintln!("  --bind ADDR      bind address (default 127.0.0.1)");
    eprintln!("  --port PORT      listen port (default 8686)");
    eprintln!("  --agent PATH     agent binary (default: resolve <agent> from dist/ or PATH)");
    eprintln!("  -h, --help       show this help");
    eprintln!();
    eprintln!("<agent>: {}", AGENT_NAMES.join(" | "));
    eprintln!("Remaining args are passed through to the agent on every spawn, plus");
    eprintln!("a per-input prompt positional and --output-format stream-json.");
}

/// 从透传给 agent 的参数中提取前端展示配置（--model / --provider / --max-context-tokens）。
/// 参数在 `--` 之后也可能出现，扫描全部 pos；值支持 `--k v` 与 `--k=v` 两种形式。
fn build_config_json(args: &[String]) -> String {
    let mut model: Option<&str> = None;
    let mut provider: Option<&str> = None;
    let mut max_context: Option<&str> = None;
    for (i, a) in args.iter().enumerate() {
        let a = a.as_str();
        for (key, slot) in [("--model", &mut model), ("--provider", &mut provider), ("--max-context-tokens", &mut max_context)] {
            if let Some(v) = a.strip_prefix(&format!("{key}=")) {
                *slot = Some(v);
            } else if a == key && let Some(v) = args.get(i + 1) {
                *slot = Some(v.as_str());
            }
        }
    }
    let mut obj = serde_json::Map::new();
    if let Some(m) = model {
        obj.insert("model".into(), json!(m));
    }
    if let Some(p) = provider {
        obj.insert("provider".into(), json!(p));
    }
    if let Some(mc) = max_context {
        if let Ok(n) = mc.replace('_', "").parse::<u64>() {
            obj.insert("max_context".into(), json!(n));
        }
    }
    json!(obj).to_string()
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut bind = "127.0.0.1".to_string();
    let mut port = 8686u16;
    let mut agent_explicit: Option<String> = None;
    let mut pos: Vec<String> = Vec::new();
    let mut after_sep = false;
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        if after_sep {
            pos.push(a.clone());
            i += 1;
            continue;
        }
        match a.as_str() {
            "--" => {
                after_sep = true;
                i += 1;
            }
            "--bind" => {
                bind = args
                    .get(i + 1)
                    .cloned()
                    .ok_or_else(|| anyhow::anyhow!("--bind requires a value"))?;
                i += 2;
            }
            "--port" => {
                let v = args
                    .get(i + 1)
                    .ok_or_else(|| anyhow::anyhow!("--port requires a value"))?;
                port = v
                    .parse()
                    .map_err(|_| anyhow::anyhow!("invalid --ws-port: {v}"))?;
                i += 2;
            }
            "--agent" => {
                agent_explicit = Some(
                    args.get(i + 1)
                        .cloned()
                        .ok_or_else(|| anyhow::anyhow!("--agent requires a value"))?,
                );
                i += 2;
            }
            "-h" | "--help" => {
                usage();
                std::process::exit(0);
            }
            _ => {
                pos.push(a.clone());
                i += 1;
            }
        }
    }

    let (agent_bin, mut base_args) = match agent_explicit {
        Some(ap) => (resolve_agent(&ap), pos),
        None => {
            if pos.is_empty() {
                usage();
                std::process::exit(0);
            }
            let mut it = pos.into_iter();
            let name = it.next().unwrap();
            (resolve_agent(&name), it.collect())
        }
    };

    // 网关不做任何会话魔法：用户参数原样透传，不追加 --session。
    // 会话延续由用户自行控制：--session <id> 或 --continue 保持跨轮上下文；
    // 什么都不传时 agent 每次 spawn 都是新会话。
    base_args.push("--output-format".to_string());
    base_args.push("stream-json".to_string());

    // 解析 home/cwd 用于定位 events.jsonl
    let home = std::env::var("BASH_AGENT_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            std::env::var("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|_| PathBuf::from("."))
        });
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));

    // 启动时尝试解析 events.jsonl 路径（--session 或 --continue），
    // 这样客户端首连即可看到旧会话历史；新会话则在首次 session_start 后动态设置。
    let events_path: server::EventsPath =
        Arc::new(Mutex::new(resolve_events_path(&base_args, &home, &cwd)));
    if let Some(p) = events_path.lock().unwrap().as_ref() {
        eprintln!("[webagent] events: {}", p.display());
    }

    // Ctrl+C：向当前 agent 子进程发 SIGINT，然后退出
    ctrlc::set_handler(|| {
        let pid = CURRENT_PID.load(Ordering::SeqCst);
        if pid > 0 {
            unsafe {
                libc::kill(pid, libc::SIGINT);
            }
        }
        std::process::exit(0);
    })
    .ok();

    let addr = format!("{bind}:{port}");
    let config_json = build_config_json(&base_args);
    eprintln!("[webagent] config: {config_json}");
    let (handle, server_thread) = server::start_server(&addr, events_path.clone(), &config_json)?;

    eprintln!("[webagent] listening on ws://{addr}/  (Ctrl+C to stop)");
    eprintln!("[webagent] agent: {}", agent_bin.display());
    eprintln!("[webagent] agent args: {}", base_args.join(" "));
    eprintln!(
        "[webagent] point your phone browser at http://{}:{}/  (use --bind 0.0.0.0 for LAN)",
        bind, port
    );

    // 工作线程：从队列取一条输入，运行一轮，处理完再取下一条。
    let hub = handle.hub.clone();
    let home_clone = home.clone();
    let cwd_clone = cwd.clone();
    let worker = std::thread::spawn(move || {
        for prompt in handle.input_rx.iter() {
            eprintln!("[webagent] turn: {prompt}");
            if let Err(e) = run_turn(
                &agent_bin,
                &base_args,
                &prompt,
                hub.clone(),
                events_path.clone(),
                &home_clone,
                &cwd_clone,
            ) {
                let msg = format!("[webagent] spawn failed: {e}");
                eprintln!("{msg}");
                emit(&hub, &json!({"type":"error","message":msg}).to_string());
            }
        }
    });

    let _ = worker.join();
    let _ = server_thread.join();
    Ok(())
}
