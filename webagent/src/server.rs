use anyhow::{Context, Result};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use sha1::{Digest, Sha1};
use std::fs;
use std::io::{BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tungstenite::protocol::Message;

pub(crate) const INDEX_HTML: &str = include_str!("index.html");

/// 当前会话的 events.jsonl 路径（可动态更新）。
/// 客户端连接时从中读取最近 500 条做回放，保证 --continue 旧会话也能看到历史。
pub(crate) type EventsPath = Arc<Mutex<Option<PathBuf>>>;

/// 广播中心：持有所有已连接客户端的写入通道。
/// 运行线程 broadcast(line) -> 每个客户端的 channel 收到 -> 客户端线程写 WS。
/// 客户端断开后 receiver 被 drop，send 返回 Err，广播自动跳过，无需显式注销。
pub(crate) struct WsHub {
    clients: Mutex<Vec<mpsc::Sender<String>>>,
}

impl WsHub {
    pub(crate) fn new() -> Self {
        Self {
            clients: Mutex::new(Vec::new()),
        }
    }

    fn register(&self) -> mpsc::Receiver<String> {
        let (tx, rx) = mpsc::channel();
        self.clients.lock().unwrap().push(tx);
        rx
    }

    pub(crate) fn broadcast(&self, line: &str) {
        let clients = self.clients.lock().unwrap();
        for tx in clients.iter() {
            let _ = tx.send(line.to_string());
        }
    }
}

/// HTTP/1.1 最小服务 + WebSocket 握手。
/// 端点：
///   GET /    -> index.html（内嵌单页 UI）
///   GET /ws  -> WebSocket 升级
fn handle_connection(
    stream: TcpStream,
    hub: Arc<WsHub>,
    input_tx: mpsc::Sender<String>,
    events_path: EventsPath,
) -> Result<()> {
    stream.set_nodelay(true)?;

    // 读请求头（到 \r\n\r\n）
    let mut request_head = Vec::new();
    let mut buf = [0u8; 2048];
    {
        let mut reader = BufReader::new(stream.try_clone()?);
        loop {
            let n = reader
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
    }

    let head = String::from_utf8_lossy(&request_head).into_owned();
    let first_line = head.lines().next().unwrap_or("").to_string();
    let mut parts = first_line.split_whitespace();
    let _method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");

    let mut stream = stream;
    if path == "/" {
        serve_static(
            &mut stream,
            INDEX_HTML.as_bytes(),
            "text/html; charset=utf-8",
        )?;
        return Ok(());
    }

    if path == "/ws" {
        let key = head
            .lines()
            .find(|l| l.to_ascii_lowercase().starts_with("sec-websocket-key:"))
            .and_then(|l| l.split_once(':').map(|(_, v)| v.trim().to_string()))
            .ok_or_else(|| anyhow::anyhow!("missing sec-websocket-key"))?;

        let upgrade_ws = head
            .lines()
            .any(|l| l.eq_ignore_ascii_case("upgrade: websocket"));
        if !upgrade_ws {
            serve_static(&mut stream, b"expected websocket upgrade", "text/plain")?;
            return Ok(());
        }

        let accept = ws_accept_key(&key)?;
        let response = format!(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
            accept
        );
        stream.write_all(response.as_bytes())?;
        stream.flush()?;

        // 握手已手动完成，直接接管原始流（不再让 tungstenite 重读请求头）
        let mut ws = tungstenite::WebSocket::<TcpStream>::from_raw_socket(
            stream,
            tungstenite::protocol::Role::Server,
            None,
        );
        client_loop(&mut ws, &hub, &input_tx, &events_path)?;
        return Ok(());
    }

    serve_static(&mut stream, b"not found", "text/plain")?;
    Ok(())
}

/// 每连接一线程：读超时轮询实现双向。
/// WS 来文本 -> 注入 input_tx；hub 队列事件 -> 写 WS。
/// 新连接先从 events.jsonl 读取最近 500 条回放，再注册为活跃监听者。
fn client_loop(
    ws: &mut tungstenite::WebSocket<TcpStream>,
    hub: &Arc<WsHub>,
    input_tx: &mpsc::Sender<String>,
    events_path: &EventsPath,
) -> Result<()> {
    // 从 events.jsonl 回放最近 500 条（页面刷新/重连也能看到完整历史，包括 --continue 的旧会话）
    if let Some(p) = events_path.lock().unwrap().as_ref() {
        if let Ok(h) = fs::read_to_string(p) {
            let tail: Vec<&str> = h.lines().rev().take(500).collect();
            for line in tail.iter().rev() {
                if ws.send(Message::Text(line.to_string())).is_err() {
                    return Ok(());
                }
            }
        }
    }
    let evt_rx = hub.register();

    ws.get_mut()
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

fn ws_accept_key(key: &str) -> Result<String> {
    const GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(GUID.as_bytes());
    let digest = hasher.finalize();
    Ok(BASE64.encode(digest))
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
