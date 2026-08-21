use anyhow::{Context, Result};
use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tungstenite::protocol::Message;

pub(crate) const INDEX_HTML: &str = include_str!("index.html");

/// PWA manifest（内嵌，支持安装到桌面/Home Screen）
pub(crate) const MANIFEST_JSON: &str = r####"{
  "name": "bash-agent webagent",
  "short_name": "webagent",
  "description": "WebSocket 桥接器：浏览器操作 agent 子进程",
  "start_url": "/",
  "display": "standalone",
  "background_color": "#151517",
  "theme_color": "#151517",
  "icons": [
    { "src": "/icon.svg", "sizes": "any", "type": "image/svg+xml", "purpose": "any maskable" }
  ]
}"####;

/// bash-agent logo（来自 docs/assets/logo.svg）
pub(crate) const ICON_SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" role="img" aria-label="bash-agent runtime grid logo">
  <rect width="64" height="64" rx="14" fill="#111318"/>
  <rect x="10" y="10" width="20" height="20" rx="5" fill="#42d39b"/>
  <rect x="34" y="10" width="20" height="20" rx="5" fill="#77a8ff"/>
  <rect x="10" y="34" width="20" height="20" rx="5" fill="#f59e68"/>
  <rect x="34" y="34" width="20" height="20" rx="5" fill="#eef2f7"/>
  <path d="M16 19l5 4-5 4" fill="none" stroke="#111318" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M39 21h10" fill="none" stroke="#111318" stroke-width="3" stroke-linecap="round"/>
  <path d="M17 40h6a3 3 0 0 1 0 6h-6V40Zm0 6h7a3 3 0 0 1 0 6h-7v-6Z" fill="none" stroke="#111318" stroke-width="2" stroke-linejoin="round"/>
  <path d="M39 52l5-12h2l5 12" fill="none" stroke="#111318" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M42 48h6" fill="none" stroke="#111318" stroke-width="3.2" stroke-linecap="round"/>
</svg>"##;

/// 每客户端发送队列容量上限：超过此值的慢客户端会被强制断开，防止内存无限增长。
const CLIENT_QUEUE_BOUND: usize = 256;

/// 当前会话的 events.jsonl 路径（可动态更新）。
/// 客户端连接时从中读取最近 500 条做回放，保证 --continue 旧会话也能看到历史。
pub(crate) type EventsPath = Arc<Mutex<Option<PathBuf>>>;

/// 广播中心：持有所有已连接客户端的有界写入通道。
/// broadcast 时对已满/失效的 channel 执行 remove，自动断开慢客户端。
pub(crate) struct WsHub {
    clients: Mutex<Vec<mpsc::SyncSender<String>>>,
}

impl WsHub {
    pub(crate) fn new() -> Self {
        Self {
            clients: Mutex::new(Vec::new()),
        }
    }

    fn register(&self) -> mpsc::Receiver<String> {
        let (tx, rx) = mpsc::sync_channel(CLIENT_QUEUE_BOUND);
        self.clients.lock().unwrap().push(tx);
        rx
    }

    pub(crate) fn broadcast(&self, line: &str) {
        let mut clients = self.clients.lock().unwrap();
        let mut dead = Vec::new();
        for (i, tx) in clients.iter().enumerate() {
            // try_send：有界队列满时返回 Err，标记为死连接稍后移除
            if tx.send(line.to_string()).is_err() {
                dead.push(i);
            }
        }
        // 从后往前删除，避免索引偏移
        for i in dead.into_iter().rev() {
            clients.remove(i);
        }
    }
}

/// HTTP/1.1 最小服务 + WebSocket 握手。
/// 端点：
///   GET /              -> index.html（内嵌单页 UI）
///   GET /manifest.json -> PWA manifest
///   GET /icon.svg      -> logo
///   POST /upload       -> 图片二进制落盘 <session_dir>/images/{n}.png（对齐 CLI [Image #N]）
///   GET /ws            -> WebSocket 升级（交给 tungstenite 完成握手，避免预读丢帧）
fn handle_connection(
    mut stream: TcpStream,
    hub: Arc<WsHub>,
    input_tx: mpsc::Sender<String>,
    events_path: EventsPath,
    index_html: Arc<String>,
) -> Result<()> {
    stream.set_nodelay(true)?;

    // 先读请求头（到 \r\n\r\n），只用于路由判断；不使用 BufReader 以避免预读丢帧。
    let mut request_head = Vec::new();
    let mut buf = [0u8; 2048];
    loop {
        let n = stream
            .read(&mut buf)
            .map_err(|e| anyhow::anyhow!("read request: {e}"))?;
        if n == 0 {
            break;
        }
        request_head.extend_from_slice(&buf[..n]);
        if request_head.len() > 64 * 1024 {
            return Err(anyhow::anyhow!("request too large"));
        }
        if request_head.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }

    let head = String::from_utf8_lossy(&request_head).into_owned();
    let first_line = head.lines().next().unwrap_or("").to_string();
    let mut parts = first_line.split_whitespace();
    let _method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");

    // 静态路由：直接从已读的请求头响应，用原始 stream 写回
    let mut stream = stream;
    if path == "/" {
        serve_static(
            &mut stream,
            index_html.as_bytes(),
            "text/html; charset=utf-8",
        )?;
        return Ok(());
    }
    if path == "/manifest.json" {
        serve_static(
            &mut stream,
            MANIFEST_JSON.as_bytes(),
            "application/manifest+json; charset=utf-8",
        )?;
        return Ok(());
    }
    if path == "/icon.svg" {
        serve_static(&mut stream, ICON_SVG.as_bytes(), "image/svg+xml")?;
        return Ok(());
    }
    if path == "/upload" {
        handle_upload(&mut stream, &request_head, &events_path)?;
        return Ok(());
    }

    if path != "/ws" {
        serve_static(&mut stream, b"not found", "text/plain")?;
        return Ok(());
    }

    // WebSocket：用 tungstenite::accept 完成握手。
    // 由于请求头已被我们读走，需要把已读的原始字节作为前缀喂回 tungstenite。
    let request_bytes = request_head.clone();
    let prefixed = PrefixedRead::new(request_bytes, stream);
    let mut ws = tungstenite::accept(prefixed)?;

    client_loop(&mut ws, &hub, &input_tx, &events_path)?;
    Ok(())
}

/// 包装器：先把前缀字节读出，再透传底层 stream。
/// 这样 tungstenite 能完整重读 HTTP 请求头并继续解析后续 WS 帧，不丢任何字节。
struct PrefixedRead {
    prefix: Vec<u8>,
    pos: usize,
    inner: TcpStream,
}

impl PrefixedRead {
    fn new(prefix: Vec<u8>, inner: TcpStream) -> Self {
        Self {
            prefix,
            pos: 0,
            inner,
        }
    }
}

impl Read for PrefixedRead {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos < self.prefix.len() {
            let remaining = &self.prefix[self.pos..];
            let n = remaining.len().min(buf.len());
            buf[..n].copy_from_slice(&remaining[..n]);
            self.pos += n;
            return Ok(n);
        }
        self.inner.read(buf)
    }
}

impl Write for PrefixedRead {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.inner.write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        self.inner.flush()
    }
}

/// 每连接一线程：读超时轮询实现双向。
/// WS 来文本 -> 注入 input_tx；hub 队列事件 -> 写 WS。
/// 新连接先回放最近 REPLAY_TURNS 轮事件（见 client_loop 内策略），再注册为活跃监听者。
fn client_loop(
    ws: &mut tungstenite::WebSocket<PrefixedRead>,
    hub: &Arc<WsHub>,
    input_tx: &mpsc::Sender<String>,
    events_path: &EventsPath,
) -> Result<()> {
    // 从 events.jsonl 回放：取最近 2000 原始行，合并 delta 分片后取 500 逻辑事件。
    // （thinking/text 流式 delta 一行一小片，长思考一轮可达数千行；不合并的话
    //   500 行只能覆盖尾部一小段，实际展示的内容量很小。）
    // 回放策略：以 user_input 为锚点取最近 REPLAY_TURNS 轮的完整事件流，
    // 轮内的 thinking/text delta 分片合并为单条（一轮长思考可达数千分片，
    // 按行数截断会把思考从中间截掉，实际展示内容量很小）。
    // 兜底：合并后的逻辑事件再按 REPLAY_MAX_EVENTS 从尾部截断。
    const REPLAY_TURNS: usize = 5;
    const REPLAY_MAX_EVENTS: usize = 2000;
    if let Some(p) = events_path.lock().unwrap().as_ref()
        && let Ok(h) = fs::read_to_string(p)
    {
        let lines: Vec<&str> = h.lines().collect();
        // 从尾往前找第 REPLAY_TURNS 个 user_input / user_message 锚点
        let mut anchor = 0usize;
        let mut seen = 0usize;
        for (i, line) in lines.iter().enumerate().rev() {
            if line.contains("\"type\":\"user_input\"")
                || line.contains("\"type\":\"user_message\"")
            {
                seen += 1;
                if seen >= REPLAY_TURNS {
                    anchor = i;
                    break;
                }
            }
        }
        let merged = merge_replay(lines[anchor..].iter().copied(), usize::MAX);
        for line in merged.iter().rev().take(REPLAY_MAX_EVENTS).rev() {
            if ws.send(Message::Text(line.to_string())).is_err() {
                return Ok(());
            }
        }
    }
    let evt_rx = hub.register();

    // 读超时设置在底层 TcpStream 上，实现非阻塞轮询
    ws.get_mut()
        .inner
        .set_read_timeout(Some(Duration::from_millis(100)))?;
    loop {
        match ws.read() {
            Ok(Message::Text(text)) => {
                if !text.trim().is_empty() {
                    let _ = input_tx.send(text.trim().to_string());
                }
            }
            Ok(Message::Close(_)) | Err(tungstenite::Error::ConnectionClosed) => break,
            Err(tungstenite::Error::Io(ref e)) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => break,
            _ => {}
        }
        while let Ok(line) = evt_rx.try_recv() {
            if ws.send(Message::Text(line)).is_err() {
                return Ok(());
            }
        }
    }
    Ok(())
}

/// 回放合并器：把 events.jsonl 中连续的 thinking / text delta 分片合并为单条完整事件。
/// 输入按时间正序（文件顺序），输出同样按正序；非分片事件原样保留。
fn merge_replay<'a, I: Iterator<Item = &'a str>>(lines: I, max_lines: usize) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur_type: Option<&'static str> = None;
    let mut cur_buf = String::new();
    let mut count = 0usize;
    for line in lines {
        count += 1;
        if count > max_lines {
            break;
        }
        let piece: Option<(&'static str, String)> =
            serde_json::from_str::<serde_json::Value>(line)
                .ok()
                .and_then(|v| {
                    let t = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
                    let c = v.get("content").and_then(|x| x.as_str()).unwrap_or("");
                    match t {
                        "thinking" => Some(("thinking", c.to_string())),
                        "text" => Some(("text", c.to_string())),
                        _ => None,
                    }
                });
        match piece {
            Some((t, c)) => {
                if cur_type == Some(t) {
                    cur_buf.push_str(&c);
                } else {
                    flush_piece(&mut out, &mut cur_type, &mut cur_buf);
                    cur_type = Some(t);
                    cur_buf = c;
                }
            }
            None => {
                flush_piece(&mut out, &mut cur_type, &mut cur_buf);
                out.push(line.to_string());
            }
        }
    }
    flush_piece(&mut out, &mut cur_type, &mut cur_buf);
    out
}

fn flush_piece(
    out: &mut Vec<String>,
    cur_type: &mut Option<&'static str>,
    cur_buf: &mut String,
) {
    if let Some(t) = cur_type.take() {
        out.push(
            serde_json::json!({"type": t, "content": cur_buf.as_str()}).to_string(),
        );
        cur_buf.clear();
    }
}

fn serve_static(stream: &mut TcpStream, body: &[u8], ctype: &str) -> Result<()> {
    let headers = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(headers.as_bytes())?;
    stream.write_all(body)?;
    stream.flush()?;
    Ok(())
}

/// 带状态码的纯文本/JSON 响应。
fn serve_status(stream: &mut TcpStream, code: u16, body: &str, ctype: &str) -> Result<()> {
    let reason = match code {
        200 => "OK",
        400 => "Bad Request",
        405 => "Method Not Allowed",
        409 => "Conflict",
        411 => "Length Required",
        413 => "Payload Too Large",
        _ => "Error",
    };
    let headers = format!(
        "HTTP/1.1 {code} {reason}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(headers.as_bytes())?;
    stream.write_all(body.as_bytes())?;
    stream.flush()?;
    Ok(())
}

/// POST /upload：把请求 body（图片二进制）写入 <session_dir>/images/{n}.png，
/// 返回 {"placeholder":"[Image #n]","path":...}。
/// 与 CLI 侧 agent_image_next_name / expand_image_placeholders 同一约定：
/// 用户输入含 [Image #n] 时 agent 自动展开为绝对路径映射，agent 零改动。
fn handle_upload(
    stream: &mut TcpStream,
    request_head: &[u8],
    events_path: &EventsPath,
) -> Result<()> {
    const MAX_UPLOAD: usize = 8 * 1024 * 1024;
    let head = String::from_utf8_lossy(request_head);
    let method = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().next())
        .unwrap_or("");
    if method != "POST" {
        return serve_status(stream, 405, "method not allowed", "text/plain");
    }
    let content_length = head.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.trim()
            .eq_ignore_ascii_case("content-length")
            .then(|| v.trim().parse::<usize>().ok())
            .flatten()
    });
    let Some(len) = content_length else {
        return serve_status(stream, 411, "length required", "text/plain");
    };
    if len > MAX_UPLOAD {
        return serve_status(stream, 413, "payload too large", "text/plain");
    }
    // 请求头已读到 \r\n\r\n；body 可能已有前缀被一并读进 request_head
    let head_end = request_head
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .map(|i| i + 4)
        .unwrap_or(request_head.len());
    let mut body = request_head[head_end..].to_vec();
    body.truncate(len);
    let mut buf = [0u8; 8192];
    while body.len() < len {
        let n = stream
            .read(&mut buf)
            .map_err(|e| anyhow::anyhow!("read body: {e}"))?;
        if n == 0 {
            break;
        }
        let take = (len - body.len()).min(n);
        body.extend_from_slice(&buf[..take]);
    }
    if body.len() != len || body.is_empty() {
        return serve_status(stream, 400, "bad request", "text/plain");
    }
    // session 目录由 events.jsonl 路径派生（同一 session_dir 下的 images/）
    let dir = events_path
        .lock()
        .unwrap()
        .as_ref()
        .and_then(|p| p.parent())
        .map(|d| d.join("images"));
    let Some(dir) = dir else {
        return serve_status(
            stream,
            409,
            r#"{"error":"session not started"}"#,
            "application/json",
        );
    };
    fs::create_dir_all(&dir).ok();
    // 起始序号对齐 agent_image_next_name（现有 png 数 + 1）；
    // create_new 原子占名，并发上传时冲突自动递增，天然不撞名
    let mut n: usize = fs::read_dir(&dir)
        .map(|it| it.filter_map(|e| e.ok()).count())
        .unwrap_or(0)
        + 1;
    let path;
    loop {
        let cand = dir.join(format!("{n}.png"));
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&cand)
        {
            Ok(mut f) => {
                if let Err(e) = f.write_all(&body) {
                    // IO 失败兜底 500：不让连接静默断掉，前端 errorrow 能显示具体原因
                    return serve_status(
                        stream,
                        500,
                        &serde_json::json!({"error": format!("write image: {e}")}).to_string(),
                        "application/json",
                    );
                }
                path = cand;
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => n += 1,
            Err(e) => {
                return serve_status(
                    stream,
                    500,
                    &serde_json::json!({"error": format!("create image: {e}")}).to_string(),
                    "application/json",
                )
            }
        }
    }
    let resp = serde_json::json!({
        "placeholder": format!("[Image #{n}]"),
        "path": path.display().to_string(),
    });
    serve_status(stream, 200, &resp.to_string(), "application/json")
}

/// serve 服务器句柄：hub 用于广播，input_rx 接收用户输入行。
pub(crate) struct ServeHandle {
    pub(crate) hub: Arc<WsHub>,
    pub(crate) input_rx: mpsc::Receiver<String>,
}

pub(crate) fn start_server(
    addr: &str,
    events_path: EventsPath,
    config_json: &str,
) -> Result<(ServeHandle, std::thread::JoinHandle<()>)> {
    let listener = TcpListener::bind(addr).with_context(|| format!("serve on {addr}"))?;
    let hub = Arc::new(WsHub::new());
    let (input_tx, input_rx) = mpsc::channel();
    // 启动时一次性完成占位符替换（model / max_context 注入页面 CFG）
    let index_html = Arc::new(INDEX_HTML.replace("__WEBAGENT_CONFIG__", config_json));
    let hub_clone = hub.clone();
    let handle = std::thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let hub = hub_clone.clone();
                    let input_tx = input_tx.clone();
                    let events_path = events_path.clone();
                    let index_html = index_html.clone();
                    std::thread::spawn(move || {
                        let _ = handle_connection(stream, hub, input_tx, events_path, index_html);
                    });
                }
                Err(_) => break,
            }
        }
    });
    Ok((ServeHandle { hub, input_rx }, handle))
}
