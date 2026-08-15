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
///   GET /ws            -> WebSocket 升级（交给 tungstenite 完成握手，避免预读丢帧）
fn handle_connection(
    mut stream: TcpStream,
    hub: Arc<WsHub>,
    input_tx: mpsc::Sender<String>,
    events_path: EventsPath,
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
            INDEX_HTML.as_bytes(),
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
/// 新连接先从 events.jsonl 读取最近 500 条回放，再注册为活跃监听者。
fn client_loop(
    ws: &mut tungstenite::WebSocket<PrefixedRead>,
    hub: &Arc<WsHub>,
    input_tx: &mpsc::Sender<String>,
    events_path: &EventsPath,
) -> Result<()> {
    // 从 events.jsonl 回放最近 500 条
    if let Some(p) = events_path.lock().unwrap().as_ref()
        && let Ok(h) = fs::read_to_string(p)
    {
        let tail: Vec<&str> = h.lines().rev().take(500).collect();
        for line in tail.iter().rev() {
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

/// serve 服务器句柄：hub 用于广播，input_rx 接收用户输入行。
pub(crate) struct ServeHandle {
    pub(crate) hub: Arc<WsHub>,
    pub(crate) input_rx: mpsc::Receiver<String>,
}

pub(crate) fn start_server(
    addr: &str,
    events_path: EventsPath,
) -> Result<(ServeHandle, std::thread::JoinHandle<()>)> {
    let listener = TcpListener::bind(addr).with_context(|| format!("serve on {addr}"))?;
    let hub = Arc::new(WsHub::new());
    let (input_tx, input_rx) = mpsc::channel();
    let hub_clone = hub.clone();
    let handle = std::thread::spawn(move || {
        for stream in listener.incoming() {
            match stream {
                Ok(stream) => {
                    let hub = hub_clone.clone();
                    let input_tx = input_tx.clone();
                    let events_path = events_path.clone();
                    std::thread::spawn(move || {
                        let _ = handle_connection(stream, hub, input_tx, events_path);
                    });
                }
                Err(_) => break,
            }
        }
    });
    Ok((ServeHandle { hub, input_rx }, handle))
}
