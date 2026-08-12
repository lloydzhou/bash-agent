use crate::TOOLS_JSON;
use crate::config::{Config, OutputFormat, api_url};
use crate::conversation::{Store, ToolResult, build_tool_call_summary, first_line};
use crate::ffi;
use crate::prompt;
use crate::protocol::{
    ErrorEvent, Event, RetryEvent, StopEvent, TextEvent, ThinkingEvent, ToolCallEvent, UsageEvent,
};
use crate::session::{self, Paths};
use crate::store;
use crate::tools;
use crate::util::{
    build_claude_request, chrono_like_now, chrono_now_rfc3339, parse_input_fields, stats_get_f64,
    touch, truncate_for_replay, truncate_str,
};
use anyhow::{Result, anyhow, bail};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::fs;
use std::io::{self, BufRead, BufReader, IsTerminal, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::io::IntoRawFd;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

type TransportRef = Arc<dyn crate::transport::Transport>;

mod httpclient {
    use anyhow::{Result, anyhow};
    use reqwest::Client;
    use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
    use std::fmt;
    use std::time::{Duration, Instant};

    #[derive(Debug)]
    pub struct HTTPError {
        pub status_code: u16,
        pub body: String,
    }

    impl fmt::Display for HTTPError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            if self.status_code > 0 {
                write!(f, "HTTP {}: {}", self.status_code, self.body)
            } else {
                write!(f, "{}", self.body)
            }
        }
    }

    impl std::error::Error for HTTPError {}

    impl HTTPError {
        pub fn format_detailed(&self) -> String {
            if self.status_code > 0 {
                format!(
                    "ERROR:{}\tHTTP {}: {}",
                    self.status_code, self.status_code, self.body
                )
            } else {
                format!("ERROR:0\t{}", self.body)
            }
        }
    }

    pub struct StreamClient {
        pub client: Client,
    }

    const DEFAULT_RETRY_COUNT: u32 = 2;
    const DEFAULT_RETRY_DELAY: Duration = Duration::from_secs(1);
    const DEFAULT_RETRY_MAX_TIME: Duration = Duration::from_secs(20);
    const DEFAULT_CONNECT_TIMEOUT: Duration = Duration::from_secs(5);

    impl StreamClient {
        pub fn new() -> Result<Self> {
            Ok(Self {
                client: Client::builder()
                    .timeout(Duration::from_secs(300))
                    .connect_timeout(DEFAULT_CONNECT_TIMEOUT)
                    .build()?,
            })
        }

        /// 同步封装：内部使用 tokio runtime 执行 async HTTP 请求。
        pub fn post(
            &self,
            url: &str,
            headers: &[(String, String)],
            body: &[u8],
        ) -> Result<reqwest::Response> {
            let client = self.client.clone();
            let url = url.to_string();
            let hdrs: Vec<(String, String)> = headers
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            let body = body.to_vec();
            super::tokio_runtime().block_on(Self::async_post(client, &url, &hdrs, &body))
        }

        async fn async_post(
            client: Client,
            url: &str,
            headers: &[(String, String)],
            body: &[u8],
        ) -> Result<reqwest::Response> {
            let mut h = HeaderMap::new();
            for (k, v) in headers {
                h.insert(
                    HeaderName::from_bytes(k.as_bytes())?,
                    HeaderValue::from_str(v).map_err(|e| anyhow!(e.to_string()))?,
                );
            }
            let start = Instant::now();
            let mut attempt = 0u32;
            loop {
                attempt += 1;
                let resp = client
                    .post(url)
                    .headers(h.clone())
                    .body(body.to_vec())
                    .send()
                    .await;
                match resp {
                    Ok(resp) => {
                        let code = resp.status().as_u16();
                        if code >= 400 {
                            let text = resp.text().await.unwrap_or_default();
                            if code >= 500
                                && attempt < DEFAULT_RETRY_COUNT
                                && start.elapsed() < DEFAULT_RETRY_MAX_TIME
                            {
                                tokio::time::sleep(DEFAULT_RETRY_DELAY).await;
                                continue;
                            }
                            return Err(HTTPError {
                                status_code: code,
                                body: text.trim().to_string(),
                            }
                            .into());
                        }
                        return Ok(resp);
                    }
                    Err(e) => {
                        if attempt < DEFAULT_RETRY_COUNT && start.elapsed() < DEFAULT_RETRY_MAX_TIME
                        {
                            tokio::time::sleep(DEFAULT_RETRY_DELAY).await;
                            continue;
                        }
                        return Err(HTTPError {
                            status_code: 0,
                            body: e.to_string(),
                        }
                        .into());
                    }
                }
            }
        }
    }
}

use httpclient::{HTTPError, StreamClient};

/// 全局 SIGINT 标志，防止多个 agent 相互覆盖 ctrlc handler。
/// 只在 agent_run / interactive_mode 中设一次。
static CTRLC_FLAG: AtomicBool = AtomicBool::new(false);
/// 全局 cancel pipe 写端 FD，ctrlc handler 通过写入此 pipe 传播中断信号。
static CANCEL_WRITE_FD: AtomicI32 = AtomicI32::new(-1);

/// 全局 tokio 运行时，嵌入在 sync 应用中使用 async HTTP。
pub fn tokio_runtime() -> &'static tokio::runtime::Runtime {
    use std::sync::OnceLock;
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Runtime::new().expect("tokio runtime"))
}

/// 基于 std::sync::mpsc channel 的 Read 实现。
/// async 数据流发送端写入 channel，parse_sse 通过这里读取。
struct ChannelReader {
    rx: std::sync::mpsc::Receiver<Vec<u8>>,
    buf: Vec<u8>,
    pos: usize,
}

impl Read for ChannelReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.buf.len() {
            match self.rx.recv() {
                Ok(data) => {
                    self.buf = data;
                    self.pos = 0;
                }
                Err(_) => return Ok(0), // channel closed = EOF
            }
        }
        let n = std::cmp::min(buf.len(), self.buf.len() - self.pos);
        buf[..n].copy_from_slice(&self.buf[self.pos..self.pos + n]);
        self.pos += n;
        Ok(n)
    }
}

pub fn agent_run(cfg: Config, cwd: PathBuf, home: PathBuf) -> Result<()> {
    // 创建全局 cancel pipe：ctrlc handler 写入，tool 执行通过 kqueue 等待读取
    let (cancel_r, cancel_w) = nix::unistd::pipe()?;
    CANCEL_WRITE_FD.store(cancel_w.as_raw_fd(), Ordering::SeqCst);
    let cancel_read_fd = cancel_r.into_raw_fd();

    // 全局 ctrlc handler：写入 cancel pipe（kqueue）+ 设置 CTRLC_FLAG（interrupted 轮询）
    ctrlc::set_handler(move || {
        CTRLC_FLAG.store(true, Ordering::SeqCst);
        let fd = CANCEL_WRITE_FD.load(Ordering::SeqCst);
        if fd >= 0 {
            let _ = unsafe { libc::write(fd, b"x" as *const u8 as *const libc::c_void, 1) };
        }
    })
    .ok();

    // serve 模式：先强制 stream-json（Agent::new 据此跳过 display worker），
    // 事件经 stdout -> WsWriter 广播到浏览器
    let cfg = if cfg.serve {
        let mut c = cfg;
        c.interactive = true;
        c.output_format = OutputFormat::StreamJson;
        c
    } else {
        cfg
    };
    let mut rt = Agent::new(cfg, cwd, home)?;    rt.cancel_read_fd = cancel_read_fd;

    if rt.cfg.serve {
        return rt.serve_mode();
    }

    if rt.cfg.interactive || (rt.cfg.prompt.is_empty() && io::stdin().is_terminal()) {
        rt.cfg.interactive = true;
        return rt.interactive_mode();
    }

    // 非交互模式也走 mainLoop，确保等待子 agent 完成
    if !rt.cfg.prompt.is_empty() {
        rt.agent_loop(rt.cfg.prompt.clone())?;
    } else {
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        rt.agent_loop(input)?;
    }
    // 等待所有后台任务完成（bash 版没有超时，Ctrl+C 可杀）
    rt.wait_for_background_results()
}

// MainLoopMessage 主循环消息类型
enum MainLoopMessage {
    UserInput {
        input: String,
        // 不再有 done channel — readline 线程不再等待 agent 完成
    },
    AgentResult {
        session_id: String,
        status: String,
        thinking: String,
        text: String,
        in_tokens: usize,
        out_tokens: usize,
        cache_read_tokens: usize,
        cache_creation_tokens: usize,
        request_count: usize,
    },
    AsyncResult {
        task_id: String,
        exit_code: i32,
        output: String,
    },
    UserNotify {
        text: String,
    },
    NotifyPending,
    Exit,
}

struct Agent {
    cfg: Config,
    cwd: PathBuf,
    home: PathBuf,
    api_url: String,
    paths: Paths,
    conv: Store,
    tools_json: Vec<Value>,
    http: StreamClient,
    transport: TransportRef,
    interrupted: Arc<AtomicBool>,
    running: Arc<AtomicBool>, // 1 = agent_loop 执行中，readline 据此判断 Ctrl+C 是否应中断
    last_context_tokens: usize,
    last_input_tokens: usize,
    last_output_tokens: usize,
    last_cache_read_tokens: usize,
    last_cache_creation_tokens: usize,
    msg_tx: Arc<Mutex<Option<mpsc::Sender<MainLoopMessage>>>>, // 主循环消息队列发送端（Arc<Mutex<Option>> 以便 readline 线程退出时主动 drop）
    msg_rx: mpsc::Receiver<MainLoopMessage>,                   // 主循环消息队列接收端
    sub_result_rx: mpsc::Receiver<MainLoopMessage>, // SubAgent 结果专用通道（对齐 NOTIFY_FIFO）
    sub_result_tx: Arc<mpsc::Sender<MainLoopMessage>>, // SubAgent 结果发送端
    active_task_count: usize,                       // 活跃子 agent 计数
    sub_agent_depth: usize,                         // 主代理为 0，第一层子代理为 1
    sub_agent_request_count: usize,                 // SubAgent 请求计数
    stdout: RefCell<Box<dyn Write + Send>>,         // 可替换的输出目标（子 agent 时为 sink）
    stderr: RefCell<Box<dyn Write + Send>>,         // 可替换的错误输出目标（子 agent 时为 sink）
    display_tx: Option<mpsc::Sender<DisplayCommand>>,
    display_handle: Option<thread::JoinHandle<()>>,
    cancel_read_fd: i32, // cancel pipe 读端 FD，传给 Runner 做 kqueue wait
}

struct DisplayState {
    last_char: String,
    prev_was_thinking: bool,
}

enum StreamMsg {
    Event(Event),
    Done(Result<()>),
}

struct LlmStream {
    rx: mpsc::Receiver<StreamMsg>,
    finished: bool,
    cancel: Arc<AtomicBool>,
    interrupted: Arc<AtomicBool>,
}

impl LlmStream {
    fn next_event(&mut self) -> Result<Option<Event>> {
        if self.finished {
            return Ok(None);
        }
        if self.interrupted.load(Ordering::SeqCst) {
            self.finished = true;
            return Err(anyhow!("interrupted"));
        }
        match self.rx.recv() {
            Ok(StreamMsg::Event(evt)) => Ok(Some(evt)),
            Ok(StreamMsg::Done(res)) => {
                self.finished = true;
                res?;
                Ok(None)
            }
            Err(e) => {
                self.finished = true;
                Err(anyhow!(e.to_string()))
            }
        }
    }
}

impl Drop for LlmStream {
    fn drop(&mut self) {
        self.cancel.store(true, Ordering::SeqCst);
    }
}

enum DisplayEvent {
    Thinking(String),
    Text(String),
    ToolCall(ToolCallEvent),
    Usage(UsageEvent),
    Stop(String),
    Error(String),
    ToolResult(ToolResult),
    UserMessage(String),
    ContextUpdate(String),
    SubAgentResult {
        session_id: String,
        status: String,
        thinking: String,
        text: String,
        in_tokens: usize,
        out_tokens: usize,
    },
    AsyncTaskResult {
        task_id: String,
        exit_code: i32,
        output: String,
    },
    UserNotify {
        text: String,
    },
    Title(String), // 终端标题（OSC 序列），通过 display worker 序列化避免与 text 交织
}

enum DisplayCommand {
    Event(DisplayEvent),
    Flush(mpsc::Sender<()>),
}

#[allow(dead_code)]
fn display_write_human(_out: &mut dyn Write, _interactive: bool, _s: &str) -> Result<()> {
    ffi::linenoise_write(_s);
    Ok(())
}

fn render_display_event(ds: &mut DisplayState, interactive: bool, evt: DisplayEvent) -> Result<()> {
    let lw = |s: &str| {
        ffi::linenoise_write(s);
    };

    match evt {
        DisplayEvent::Thinking(content) => {
            if interactive && ds.last_char == "\n" {
                lw("\r\x1b[K");
                ds.last_char.clear();
            }
            if !content.is_empty() {
                /* 颜色码 + 内容 + 重置必须在一个 linenoiseWrite 调用内，
                 * 否则中间的 Show 重绘 prompt 时 \x1b[0m 会重置终端颜色 */
                lw(&format!("\x1b[90m{}\x1b[0m", content));
                update_last_char(ds, &content);
            }
            ds.prev_was_thinking = true;
        }
        DisplayEvent::Text(content) => {
            if interactive && ds.last_char == "\n" {
                lw("\r\x1b[K");
                ds.last_char.clear();
            }
            if ds.prev_was_thinking && ds.last_char != "\n" {
                lw("\n");
                ds.last_char = "\n".to_string();
            }
            if !content.is_empty() {
                lw(&content);
                update_last_char(ds, &content);
            }
            ds.prev_was_thinking = false;
        }
        DisplayEvent::ToolCall(call) => {
            ensure_newline(ds, &lw);
            lw(&format!(
                "\x1b[33m[tool] {}\x1b[0m\n",
                build_tool_call_summary(&call.name, &call.fields)
            ));
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
        DisplayEvent::Usage(_) => {}
        DisplayEvent::Stop(reason) => {
            ensure_newline(ds, &lw);
            if reason == "interrupted" {
                lw("\x1b[36mInterrupted.\x1b[0m\n");
                ds.last_char = "\n".to_string();
            }
            ds.prev_was_thinking = false;
        }
        DisplayEvent::Error(message) => {
            ensure_newline(ds, &lw);
            lw(&format!("\x1b[31mError: {}\x1b[0m\n", message));
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
        DisplayEvent::UserMessage(content) => {
            ensure_newline(ds, &lw);
            lw(&format!(
                "\x1b[32m> {}\x1b[0m\n",
                truncate_for_replay(&content, 77)
            ));
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
        DisplayEvent::ContextUpdate(trigger) => {
            ensure_newline(ds, &lw);
            lw(&format!(
                "\x1b[36mContext compacted ({}).\x1b[0m\n",
                trigger
            ));
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
        DisplayEvent::ToolResult(result) => {
            if result.content.is_empty() {
                return Ok(());
            }
            let tr_text = if result.tool_name == "Edit" {
                let mut s = result.content.replace("\r\n", "\n").replace('\r', "\n");
                if !s.ends_with('\n') {
                    s.push('\n');
                }
                s
            } else if result.tool_name == "Read" || result.tool_name == "Write" {
                first_line(&result.content).to_string() + "\n"
            } else {
                result.content.clone() + "\n"
            };
            if ds.prev_was_thinking && ds.last_char != "\n" {
                lw("\n");
            }
            ds.prev_was_thinking = false;
            lw(&tr_text);
            update_last_char(ds, &tr_text);
        }
        DisplayEvent::SubAgentResult {
            session_id,
            status,
            thinking,
            text,
            in_tokens,
            out_tokens,
        } => {
            if interactive && ds.last_char == "\n" {
                lw("\r\x1b[K");
            }
            ensure_newline(ds, &lw);
            if status == "ok" {
                lw(&format!(
                    "\x1b[35m[sub-agent {}] completed (in={}, out={})\x1b[0m\n",
                    session_id, in_tokens, out_tokens
                ));
            } else {
                lw(&format!(
                    "\x1b[31m[sub-agent {}] failed\x1b[0m\n",
                    session_id
                ));
            }
            if !thinking.is_empty() {
                lw(&format!(
                    "\x1b[90m{}\x1b[0m\n",
                    truncate_str(&thinking, 120)
                ));
            }
            if !text.is_empty() {
                lw(&format!("{}\n", truncate_str(&text, 120)));
            }
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
        DisplayEvent::UserNotify { text } => {
            ensure_newline(ds, &lw);
            lw(&format!("\x1b[33m[user inject] {}\x1b[0m\n", text));
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
        DisplayEvent::Title(title) => {
            // OSC 序列直接写 stderr，通过 display worker 序列化避免与 text delta 交织
            let _ = write!(io::stderr(), "{}", title);
            let _ = io::stderr().flush();
        }
        DisplayEvent::AsyncTaskResult {
            task_id,
            exit_code,
            output,
        } => {
            if interactive && ds.last_char == "\n" {
                lw("\r\x1b[K");
            }
            ensure_newline(ds, &lw);
            let color = if exit_code == 0 { "36" } else { "31" };
            lw(&format!(
                "\x1b[{}m[bg-bash {}] exit_code={}\x1b[0m\n",
                color, task_id, exit_code
            ));
            if !output.is_empty() {
                lw(&format!("{}\n", truncate_str(&output, 120)));
            }
            ds.last_char = "\n".to_string();
            ds.prev_was_thinking = false;
        }
    }
    Ok(())
}

fn ensure_newline(ds: &mut DisplayState, lw: &dyn Fn(&str)) {
    if ds.last_char != "\n" {
        lw("\n");
        ds.last_char = "\n".to_string();
    }
}

fn update_last_char(ds: &mut DisplayState, s: &str) {
    if s.is_empty() {
        return;
    }
    let mut esc = false;
    let mut last_visible: Option<char> = None;
    for c in s.chars() {
        if esc {
            if ('\u{40}'..='\u{7e}').contains(&c) {
                esc = false;
            }
            continue;
        }
        if c == '\u{1b}' {
            esc = true;
            continue;
        }
        last_visible = Some(c);
    }
    if let Some(c) = last_visible {
        ds.last_char = c.to_string();
    }
}

impl Agent {
    fn start_display_worker(
        interactive: bool,
    ) -> (mpsc::Sender<DisplayCommand>, thread::JoinHandle<()>) {
        let (tx, rx) = mpsc::channel::<DisplayCommand>();
        let handle = thread::spawn(move || {
            let mut ds = DisplayState {
                last_char: String::from("\n"),
                prev_was_thinking: false,
            };
            while let Ok(cmd) = rx.recv() {
                match cmd {
                    DisplayCommand::Event(evt) => {
                        let _ = render_display_event(&mut ds, interactive, evt);
                    }
                    DisplayCommand::Flush(done) => {
                        let _ = done.send(());
                    }
                }
            }
        });
        (tx, handle)
    }

    fn flush_display(&self) {
        if let Some(tx) = &self.display_tx {
            let (done_tx, done_rx) = mpsc::channel();
            if tx.send(DisplayCommand::Flush(done_tx)).is_ok() {
                let _ = done_rx.recv();
            }
        }
    }

    fn queue_display_only(&self, evt: DisplayEvent) {
        if let Some(tx) = &self.display_tx {
            let _ = tx.send(DisplayCommand::Event(evt));
        }
    }
}

impl Drop for Agent {
    fn drop(&mut self) {
        self.display_tx.take();
        if let Some(handle) = self.display_handle.take() {
            let _ = handle.join();
        }
    }
}

impl Agent {
    pub(crate) fn new(mut cfg: Config, cwd: PathBuf, home: PathBuf) -> Result<Self> {
        let mut sid = cfg.session_id.clone();
        if sid.is_empty() && (cfg.continue_session || cfg.fork) {
            sid = session::continue_session(&home, &cwd).unwrap_or_default();
        }
        if sid.is_empty() {
            sid = chrono_like_now();
        }
        // --fork：sid 此时已是源 session，保存后替换为新 ID（对齐 bash 版）
        let fork_source_id: Option<String> = if cfg.fork {
            let src_id = sid.clone();
            sid = chrono_like_now();
            Some(src_id)
        } else {
            None
        };
        cfg.session_id = sid.clone();
        let paths = session::paths_for(&home, &cwd, &sid);
        session::ensure_dir(&paths.base_dir)?;
        session::ensure_dir(&paths.session_dir)?;
        // fork 复制 conversation/summary/plan 到新 session 目录（在 touch/init 之前）
        if let Some(src_id) = &fork_source_id {
            let src_paths = session::paths_for(&home, &cwd, src_id);
            let _ = store::store_session_fork(&src_paths, &paths);
        }
        let new_session = paths
            .events
            .metadata()
            .map(|m| m.len() == 0)
            .unwrap_or(true);
        for f in [
            &paths.conversation,
            &paths.events,
            &paths.summary,
            &paths.plan,
            &paths.plan_draft,
        ] {
            touch(f)?;
        }
        if new_session {
            use std::io::Write;
            let mut f = std::fs::File::create(&paths.stats)?;
            write!(
                f,
                r#"{{"current_turn_count":0,"agent_request_count":0,"compact_request_count":0,"sub_agent_request_count":0,"total_input_tokens":0,"total_output_tokens":0,"total_cache_read_tokens":0,"total_cache_creation_tokens":0,"current_context_tokens":0,"last_updated":""}}{}"#,
                '\n'
            )?;
        }

        let conv = Store {
            path: paths.conversation.clone(),
        };
        conv.ensure()?;

        let tools_json: Vec<Value> = serde_json::from_str(TOOLS_JSON)?;
        let api_url = api_url(&cfg);
        let interrupted = Arc::new(AtomicBool::new(false));
        let running = Arc::new(AtomicBool::new(false));
        let transport = Arc::from(crate::transport::new_transport(&cfg));
        let (msg_tx, msg_rx) = mpsc::channel(); // 初始化消息队列
        let msg_tx = Arc::new(Mutex::new(Some(msg_tx))); // 包装在 Arc<Mutex<Option>> 中
        let (_sub_result_tx, sub_result_rx) = mpsc::channel(); // SubAgent 结果专用通道
        let sub_result_tx = Arc::new(_sub_result_tx);

        let (display_tx, display_handle) = if cfg.output_format == OutputFormat::StreamJson {
            (None, None)
        } else {
            let (tx, handle) = Self::start_display_worker(cfg.interactive);
            (Some(tx), Some(handle))
        };

        let rt = Self {
            cfg,
            cwd,
            home,
            api_url,
            paths,
            conv,
            tools_json,
            http: StreamClient::new()?,
            transport,
            interrupted,
            running,
            last_context_tokens: 0,
            last_input_tokens: 0,
            last_output_tokens: 0,
            last_cache_read_tokens: 0,
            last_cache_creation_tokens: 0,
            msg_tx,
            msg_rx,
            sub_result_rx,
            sub_result_tx,
            active_task_count: 0,
            sub_agent_depth: 0,
            sub_agent_request_count: 0,
            stdout: RefCell::new(Box::new(io::stdout())),
            stderr: RefCell::new(Box::new(io::stderr())),
            display_tx,
            display_handle,
            cancel_read_fd: 0, // 占位，稍后由 agent_run 设置
        };

        if new_session {
            let _ = rt.append_event(json!({"type":"session_start","session_id":sid.clone()}));
        }

        Ok(rt)
    }

    // handle_sub_agent 处理 SubAgent 工具调用
    fn handle_sub_agent(&mut self, fields: &std::collections::BTreeMap<String, String>) -> String {
        if self.sub_agent_depth >= 1 {
            return "Error: sub-agent recursion limit reached; child agents cannot launch SubAgent"
                .to_string();
        }
        let prompt = match fields.get("prompt") {
            Some(p) if !p.is_empty() => p.clone(),
            _ => return "Error: no prompt provided for sub-agent".to_string(),
        };
        let description = fields.get("description").cloned().unwrap_or_default();

        // 生成子 session ID
        let sub_session_id = format!("sub_{}", chrono_like_now());

        // 记录 sub_agent_start 事件
        let fork = fields
            .get("fork")
            .map(|s| s == "true" || s == "1")
            .unwrap_or(false);
        let _ = self.append_event(json!({
            "type": "sub_agent_start",
            "session_id": sub_session_id,
            "timestamp": chrono_like_now(),
            "prompt": prompt,
            "description": description,
            "fork": fork,
        }));

        // 增加活跃子 agent 计数
        self.active_task_count += 1;

        // 启动后台线程执行子 agent
        let cwd = self.cwd.clone();
        let home = self.home.clone();
        let cfg = self.cfg.clone();
        let child_depth = self.sub_agent_depth + 1;
        let msg_tx_arc = self.sub_result_tx.clone(); // 子 agent 结果发送到专用通道
        let wake_tx = if self.cfg.interactive {
            Some(self.msg_tx.clone())
        } else {
            None
        };
        let sub_session_id_clone = sub_session_id.clone();
        let parent_paths = self.paths.clone();
        let fork = fields
            .get("fork")
            .map(|s| s == "true" || s == "1")
            .unwrap_or(false);

        // 在主线程中完成 fork 复制（与 Bash 版本一致：在子进程启动前复制，避免竞态）
        let sub_paths = session::paths_for(&home, &cwd, &sub_session_id_clone);
        if fork {
            let _ = store::store_session_fork(&parent_paths, &sub_paths);
        }
        if let Err(e) = store::store_session_init(&sub_paths, false) {
            self.active_task_count -= 1;
            return format!("Failed to create sub-agent session dir: {}", e);
        }

        std::thread::spawn(move || {
            let send_result = |result| {
                if msg_tx_arc.send(result).is_ok() {
                    if let Some(tx) = &wake_tx {
                        if let Ok(guard) = tx.lock() {
                            if let Some(tx) = guard.as_ref() {
                                let _ = tx.send(MainLoopMessage::NotifyPending);
                            }
                        }
                    }
                }
            };

            // 1. 创建子 agent 的 conversation store
            let sub_conv = Store {
                path: sub_paths.conversation.clone(),
            };
            if let Err(e) = sub_conv.ensure() {
                // 早期失败时发送失败结果，让主进程减少 active_task_count
                send_result(MainLoopMessage::AgentResult {
                    session_id: sub_session_id_clone.clone(),
                    status: "failed".to_string(),
                    thinking: String::new(),
                    text: format!("Failed to create sub-agent conversation: {}", e),
                    in_tokens: 0,
                    out_tokens: 0,
                    cache_read_tokens: 0,
                    cache_creation_tokens: 0,
                    request_count: 0,
                });
                return;
            }

            // 2. fork 复制已在主线程完成（避免竞态）

            // 3. 创建子 agent 的 runtime
            let mut sub_cfg = cfg.clone();
            sub_cfg.session_id = sub_session_id_clone.clone();
            sub_cfg.prompt = prompt.clone();
            sub_cfg.interactive = false;

            let (sub_msg_tx, _sub_msg_rx) = mpsc::channel();
            let (sub_rtx, sub_rrx) = mpsc::channel();
            let mut sub_rt = Agent {
                cfg: sub_cfg,
                cwd: cwd.clone(),
                home: home.clone(),
                api_url: api_url(&cfg),
                paths: sub_paths.clone(),
                conv: sub_conv,
                tools_json: serde_json::from_str(TOOLS_JSON).unwrap_or_default(),
                http: StreamClient::new().expect("Failed to create HTTP client"),
                transport: Arc::from(crate::transport::new_transport(&cfg)),
                interrupted: Arc::new(AtomicBool::new(false)),
                running: Arc::new(AtomicBool::new(false)),
                last_context_tokens: 0,
                last_input_tokens: 0,
                last_output_tokens: 0,
                last_cache_read_tokens: 0,
                last_cache_creation_tokens: 0,
                msg_tx: Arc::new(Mutex::new(Some(sub_msg_tx))),
                msg_rx: _sub_msg_rx,
                sub_result_rx: sub_rrx,
                sub_result_tx: Arc::new(sub_rtx),
                active_task_count: 0,
                sub_agent_depth: child_depth,
                sub_agent_request_count: 0,
                stdout: RefCell::new(Box::new(io::sink())), // 子 agent 输出全部丢弃（与 Go 的 io.Discard、Bash 的 >/dev/null 对应）
                stderr: RefCell::new(Box::new(io::sink())), // 子 agent 错误输出全部丢弃
                display_tx: None,
                display_handle: None,
                cancel_read_fd: -1,
            };

            // 4. 执行 agent_loop
            let mut status = "ok";
            if let Err(_e) = sub_rt.agent_loop(prompt.clone()) {
                // 子 agent 执行失败，状态标记为 failed，结果通过 AGENT_RESULT 消息传递
                status = "failed";
            }

            // 5. 提取结果
            let lines = match sub_rt.conv.lines() {
                Ok(l) => l,
                Err(e) => {
                    // 通过消息队列发送失败结果，让主进程减少计数
                    send_result(MainLoopMessage::AgentResult {
                        session_id: sub_session_id_clone,
                        status: "failed".to_string(),
                        thinking: String::new(),
                        text: format!("Sub-agent failed: {}", e),
                        in_tokens: 0,
                        out_tokens: 0,
                        cache_read_tokens: 0,
                        cache_creation_tokens: 0,
                        request_count: 0,
                    });
                    return;
                }
            };

            // 只取最后一条 assistant 消息的 thinking + text（前面的都是中间过程）
            let mut result_thinking = String::new();
            let mut result_text = String::new();
            for line in lines.iter().rev() {
                if let Some(role) = line.get("role").and_then(|v| v.as_str()) {
                    if role == "assistant" {
                        if let Some(content) = line.get("content").and_then(|v| v.as_array()) {
                            let mut found_thinking = false;
                            let mut found_text = false;
                            for b in content.iter() {
                                let block_type =
                                    b.get("type").and_then(|t| t.as_str()).unwrap_or("");
                                match block_type {
                                    "thinking" => {
                                        if let Some(t) = b
                                            .get("thinking")
                                            .and_then(|v| v.as_str())
                                            .filter(|t| !t.is_empty())
                                        {
                                            result_thinking = t.to_string();
                                            found_thinking = true;
                                        }
                                    }
                                    "text" => {
                                        if let Some(t) = b
                                            .get("text")
                                            .and_then(|v| v.as_str())
                                            .filter(|t| !t.is_empty())
                                        {
                                            result_text = t.to_string();
                                            found_text = true;
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            if found_thinking || found_text {
                                break;
                            }
                        }
                    }
                }
            }

            // 5. 收集 usage 统计
            let stats = store::store_stats_read(&sub_rt.paths.stats).unwrap_or_default();
            let in_tokens = stats_get_f64(&stats, "total_input_tokens") as usize;
            let out_tokens = stats_get_f64(&stats, "total_output_tokens") as usize;
            let cache_read_tokens = stats_get_f64(&stats, "total_cache_read_tokens") as usize;
            let cache_creation_tokens =
                stats_get_f64(&stats, "total_cache_creation_tokens") as usize;
            let request_count = stats_get_f64(&stats, "agent_request_count") as usize;

            // 6. 通过结果队列发送，并在交互模式下唤醒主循环消费
            send_result(MainLoopMessage::AgentResult {
                session_id: sub_session_id_clone,
                status: status.to_string(),
                thinking: result_thinking,
                text: result_text,
                in_tokens,
                out_tokens,
                cache_read_tokens,
                cache_creation_tokens,
                request_count,
            });
        });

        format!("Sub-agent started: session_id={}", sub_session_id)
    }

    fn interactive_mode(&mut self) -> Result<()> {
        self.info("bash-agent interactive mode (type 'exit' or Ctrl+D to quit)");
        self.replay_last_turns();
        // Show terminal title AFTER replay so it isn't overwritten by replayed output
        self.update_term_title_with_status("idle");
        let history_path = self.home.join(".bash-agent/history");
        if let Some(parent) = history_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let history_path_str = history_path.to_string_lossy().to_string();
        ffi::history_load(&history_path_str);

        // 注册图片粘贴回调，使 linenoise Ctrl+V 支持图片粘贴
        ffi::set_image_dir(self.paths.session_dir.join("images"));
        ffi::register_paste_callback();

        // 注册 inject callback（Ctrl+O），将文本发送到 channel
        let (inject_tx, inject_rx) = mpsc::channel::<String>();
        ffi::register_inject_callback(inject_tx);

        // 使用 Agent 结构体中的共享 interrupted / running，供 Ctrl+C 中断 agent
        let interrupted_flag = self.interrupted.clone();
        let running_flag = self.running.clone();

        // 启动 readline 线程，将用户输入发送到消息队列
        let msg_tx_arc = self.msg_tx.clone();
        let sub_result_tx = self.sub_result_tx.clone();
        let history_path_clone = history_path.to_string_lossy().to_string();
        let readline_handle = std::thread::spawn(move || {
            ffi::set_multiline(true);
            ffi::history_load(&history_path_clone);
            ffi::history_set_max_len(1000);

            let mut linebuf = vec![0u8; 65536];
            let prompt = "\x1b[32m> \x1b[0m";
            let c_prompt = std::ffi::CString::new(prompt).expect("prompt");

            // 借鉴 bash 版本：线程退出时主动 drop 发送端，让 main_loop 收到 Disconnected
            let result = (|| {
                loop {
                    // 重置 errno
                    #[cfg(target_os = "macos")]
                    unsafe {
                        *libc::__error() = 0
                    };
                    #[cfg(target_os = "linux")]
                    unsafe {
                        *libc::__errno_location() = 0
                    };

                    // EditStart: 初始化非阻塞编辑会话
                    let mut ls: std::mem::MaybeUninit<ffi::LinenoiseState> =
                        std::mem::MaybeUninit::uninit();
                    let rc = unsafe {
                        ffi::edit_start_raw(
                            ls.as_mut_ptr(),
                            0, // stdin fd
                            2, // stderr fd
                            linebuf.as_mut_ptr() as *mut libc::c_char,
                            linebuf.len(),
                            c_prompt.as_ptr(),
                        )
                    };
                    if rc == -1 {
                        return; // 无法启动编辑
                    }
                    let ls_ptr = ls.as_mut_ptr();

                    // 注册到 linenoise 全局状态（linenoiseWrite 用它做 Hide/Show）
                    unsafe {
                        ffi::register_state(ls_ptr);
                    }
                    ffi::set_active(true);

                    // Feed 循环
                    let line = loop {
                        let result = unsafe { ffi::edit_feed_raw(ls_ptr) };
                        let more_ptr = ffi::edit_more_ptr();
                        if result == more_ptr {
                            // Check inject channel (Ctrl+O while editing)
                            if let Ok(text) = inject_rx.try_recv() {
                                if !text.is_empty() {
                                    let _ =
                                        sub_result_tx.send(MainLoopMessage::UserNotify { text });
                                    let tx_guard = msg_tx_arc.lock().unwrap();
                                    if let Some(tx) = tx_guard.as_ref() {
                                        let _ = tx.send(MainLoopMessage::NotifyPending);
                                    }
                                }
                            }
                            continue; // 还在编辑
                        }
                        if result.is_null() {
                            #[cfg(target_os = "macos")]
                            let err = unsafe { *libc::__error() };
                            #[cfg(target_os = "linux")]
                            let err = unsafe { *libc::__errno_location() };
                            #[cfg(target_os = "android")]
                            let err = unsafe { *libc::__errno() };
                            if err == libc::EAGAIN {
                                break Err(ffi::LineError::Interrupted);
                            }
                            break Err(ffi::LineError::Eof);
                        }
                        // Got a line
                        let s = unsafe {
                            let rust_str = std::ffi::CStr::from_ptr(result)
                                .to_string_lossy()
                                .into_owned();
                            ffi::free_line(result);
                            rust_str
                        };
                        break Ok(s);
                    };

                    // 清除共享状态
                    ffi::set_active(false);
                    unsafe {
                        ffi::register_state(std::ptr::null_mut());
                    }

                    // EditStop
                    unsafe {
                        ffi::edit_stop_ptr(ls_ptr);
                    }

                    match line {
                        Ok(s) => {
                            let trimmed = s.trim_end().to_string();
                            if trimmed.is_empty() {
                                continue;
                            }
                            if trimmed == "exit" || trimmed == "quit" {
                                return;
                            }
                            ffi::history_add(&trimmed);
                            ffi::history_save(&history_path_clone);
                            // 发送到消息队列 — 不再等 done
                            let tx_guard = msg_tx_arc.lock().unwrap();
                            if let Some(tx) = tx_guard.as_ref() {
                                if tx
                                    .send(MainLoopMessage::UserInput { input: trimmed })
                                    .is_err()
                                {
                                    return;
                                }
                            } else {
                                return;
                            }
                        }
                        Err(ffi::LineError::Interrupted) => {
                            // Ctrl+C — 如果 agent 正在运行，设置 interrupted 标志中断 HTTP 请求
                            if running_flag.load(Ordering::SeqCst) {
                                interrupted_flag.store(true, Ordering::SeqCst);
                            }
                            continue;
                        }
                        Err(_) => {
                            return; // Ctrl+D / EOF
                        }
                    }
                }
            })();
            // readline 线程退出时，主动 drop 发送端（借鉴 bash 版本 exec 4>&-）
            let mut tx_guard = msg_tx_arc.lock().unwrap();
            *tx_guard = None;
            result
        });

        // 在主线程中运行 main_loop
        self.main_loop()?;

        // 用户可能在后台任务运行时退出；销毁运行时前必须消费剩余结果。
        self.wait_for_background_results()?;

        // 等待读取线程结束
        let _ = readline_handle.join();

        self.info("Goodbye!");
        if !self.cfg.session_id.is_empty() {
            let _ = writeln!(
                self.stderr.borrow_mut(),
                "\x1b[90mResume with: --session {}  or  --continue\x1b[0m",
                self.cfg.session_id
            );
        }
        Ok(())
    }

    /// serve_mode：嵌入 Web UI 服务器模式。
    /// 复用 main_loop 消息通道——WS 客户端文本经 input_rx 转为 UserInput 注入，
    /// stream-json 事件经 stdout（被替换为 WsWriter）广播到浏览器。
    fn serve_mode(&mut self) -> Result<()> {
        let addr = format!("{}:{}", self.cfg.serve_bind, self.cfg.serve_port);
        let events_path = self.events_path_for_serve();
        let (handle, _server_thread) = crate::serve::start_server(&addr, crate::serve::INDEX_HTML, events_path)?;

        // 替换 stdout 为 WS 广播 writer（stream-json 事件自动 tee 到浏览器）
        let ws_writer = crate::serve::WsWriter::new(handle.hub.clone());
        *self.stdout.borrow_mut() = Box::new(ws_writer);

        // 转发 WS 用户输入 -> main_loop 消息队列（等价 readline 线程）
        let input_rx = handle.input_rx;
        let msg_tx_arc = self.msg_tx.clone();
        std::thread::spawn(move || {
            while let Ok(line) = input_rx.recv() {
                let tx_guard = msg_tx_arc.lock().unwrap();
                match tx_guard.as_ref() {
                    Some(tx) => {
                        if tx
                            .send(MainLoopMessage::UserInput { input: line })
                            .is_err()
                        {
                            break;
                        }
                    }
                    None => break,
                }
            }
        });
        self.info(&format!("bash-agent serving on http://{addr}"));
        self.main_loop()?;
        // Ctrl+C 或通道断开时退出。不要 join input_thread——它阻塞在 input_rx.recv()，
        // 而 input_tx 被 server 线程永远持有，join 会死锁。进程退出时线程自动终止。
        self.info("Goodbye!");
        if !self.cfg.session_id.is_empty() {
            let _ = writeln!(
                self.stderr.borrow_mut(),
                "\x1b[90mResume with: --session {}  or  --continue\x1b[0m",
                self.cfg.session_id
            );
        }
        std::process::exit(0);
    }

    /// events.jsonl 路径，供 serve 客户端每次连接时读取并回放历史。
    fn events_path_for_serve(&self) -> Option<std::path::PathBuf> {
        let path = &self.paths.events;
        if path.as_os_str().is_empty() {
            return None;
        }
        Some(path.clone())
    }

    // main_loop 主事件循环，从消息队列读取并分发处理
    // 借鉴 bash 版本设计：readline 线程退出时主动 drop 发送端（类似 bash 的 exec 4>&-），
    // 这样 recv() 收到 Disconnected 后自然退出，无需轮询 should_exit
    pub(crate) fn main_loop(&mut self) -> Result<()> {
        loop {
            let msg = if self.cfg.serve {
                // serve 模式：轮询 CTRLC_FLAG 以便空闲时 Ctrl+C 退出。
                // 正在执行 turn 时 Ctrl+C 由 agent_loop_stream 消费（中断），
                // 这里只在空闲（阻塞 recv）时捕获退出。
                loop {
                    match self.msg_rx.recv_timeout(Duration::from_millis(200)) {
                        Ok(msg) => break msg,
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                            if CTRLC_FLAG.swap(false, Ordering::SeqCst) {
                                break MainLoopMessage::Exit;
                            }
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                            break MainLoopMessage::Exit;
                        }
                    }
                }
            } else {
                match self.msg_rx.recv() {
                    Ok(msg) => msg,
                    Err(std::sync::mpsc::RecvError) => {
                        // 所有发送端已关闭（readline 线程退出时主动 drop），退出
                        break;
                    }
                }
            };
            match msg {
                MainLoopMessage::NotifyPending => {
                    self.running.store(true, Ordering::SeqCst);
                    let _ = self.agent_loop_with_kind(String::new(), "notify");
                    self.running.store(false, Ordering::SeqCst);
                    self.flush_display();
                }
                MainLoopMessage::UserInput { input } => {
                    if self.cfg.interactive {
                        // 清除当前行（包括提示符）
                        let _ = write!(self.stderr.borrow_mut(), "\r\x1b[2K");
                    }
                    self.running.store(true, Ordering::SeqCst);
                    self.interrupted.store(false, Ordering::SeqCst);
                    if let Err(e) = self.agent_loop(input) {
                        let msg = e.to_string();
                        // 不打印中断相关的错误（包括 SSE 流被 Ctrl+C 断开的情况）
                        let is_interrupt = msg == "interrupted"
                            || msg == "sse_parse: cancelled"
                            || msg.contains("ConnectionAborted");
                        if !is_interrupt {
                            self.error(&msg);
                        }
                    }
                    self.running.store(false, Ordering::SeqCst);
                    self.flush_display();

                    // 交互模式不等待后台任务完成。readline 已在下一轮 EditStart，
                    // 普通输入由主消息队列立即调度；后台结果完成时会发送
                    // NotifyPending 唤醒主循环并通过 notify turn 注入。

                    // 不再通知 readline 线程 — 它已经在下一轮 EditStart
                }
                MainLoopMessage::Exit => break,
                _ => {}
            }

            // 非交互模式且无活跃子 agent 时退出
            if !self.cfg.interactive && self.active_task_count == 0 {
                break;
            }
        }
        Ok(())
    }

    // 等待并处理所有后台结果；仅用于非交互退出和交互资源销毁前。
    fn wait_for_background_results(&mut self) -> Result<()> {
        while self.active_task_count > 0 {
            match self.sub_result_rx.recv() {
                Ok(MainLoopMessage::AgentResult {
                    session_id,
                    status,
                    thinking,
                    text,
                    in_tokens,
                    out_tokens,
                    cache_read_tokens,
                    cache_creation_tokens,
                    request_count,
                }) => {
                    self.handle_sub_agent_result(
                        &session_id,
                        &status,
                        &thinking,
                        &text,
                        in_tokens,
                        out_tokens,
                        cache_read_tokens,
                        cache_creation_tokens,
                        request_count,
                    )?;
                    self.flush_display();
                }
                Ok(MainLoopMessage::AsyncResult {
                    task_id,
                    exit_code,
                    output,
                }) => {
                    let _ = self.emit_and_append_event(json!({"type":"async_task_result","task_id":&task_id,"exit_code":exit_code,"output":&output}));
                    if self.active_task_count > 0 {
                        self.active_task_count -= 1;
                    }
                    let ctx = format!(
                        "[bg-bash {}] exit_code={}\nOutput: {}",
                        task_id, exit_code, output
                    );
                    let _ = self.queue_display_event(DisplayEvent::AsyncTaskResult {
                        task_id,
                        exit_code,
                        output,
                    });
                    self.agent_loop_with_kind(ctx, "async_task_result")?;
                    self.flush_display();
                }
                Ok(MainLoopMessage::UserNotify { text }) => {
                    let _ =
                        self.queue_display_event(DisplayEvent::UserNotify { text: text.clone() });
                    self.agent_loop_with_kind(text, "user_notify")?;
                    self.flush_display();
                }
                Ok(MainLoopMessage::NotifyPending) | Ok(MainLoopMessage::UserInput { .. }) => {}
                Ok(_) => {}
                Err(_) => return Err(anyhow!("后台结果通道已断开")),
            }
        }
        Ok(())
    }

    // handle_sub_agent_result 处理子 agent 完成后的结果注入
    pub(crate) fn handle_sub_agent_result(
        &mut self,
        session_id: &str,
        status: &str,
        thinking: &str,
        text: &str,
        in_tokens: usize,
        out_tokens: usize,
        cache_read_tokens: usize,
        cache_creation_tokens: usize,
        request_count: usize,
    ) -> Result<()> {
        // 1. 记录 usage 事件
        let _ = self.append_event(json!({
            "type": "usage",
            "input_tokens": in_tokens,
            "output_tokens": out_tokens,
            "cache_read_input_tokens": cache_read_tokens,
            "cache_creation_input_tokens": cache_creation_tokens,
            "kind": "sub_agent",
            "sub_session_id": session_id,
        }));

        // 2. 记录 sub_agent_result 事件，供 replay / stream-json 复现子 agent 回显
        let _ = self.emit_and_append_event(json!({
            "type": "sub_agent_result",
            "session_id": session_id,
            "status": status,
            "input_tokens": in_tokens,
            "output_tokens": out_tokens,
            "cache_read_input_tokens": cache_read_tokens,
            "cache_creation_input_tokens": cache_creation_tokens,
            "request_count": request_count,
            "thinking": thinking,
            "text": text,
        }));

        // 3. 记录 sub_agent_end 事件
        let _ = self.append_event(json!({
            "type": "sub_agent_end",
            "session_id": session_id,
            "timestamp": chrono_like_now(),
            "status": status,
        }));

        // 4. 更新 stats（对齐 bash 顺序：events → stats → counter → display → conversation）
        store::store_stats_update(&self.paths.stats, |stats| {
            Self::add_stat_usize(stats, "sub_agent_request_count", 1);
            Self::add_stat_usize(stats, "agent_request_count", request_count);
            Self::add_stat_usize(stats, "total_input_tokens", in_tokens);
            Self::add_stat_usize(stats, "total_output_tokens", out_tokens);
            Self::add_stat_usize(stats, "total_cache_read_tokens", cache_read_tokens);
            Self::add_stat_usize(stats, "total_cache_creation_tokens", cache_creation_tokens);
        })?;
        self.update_term_title();

        // 5. 更新活跃子 agent 计数
        self.active_task_count -= 1;
        self.sub_agent_request_count += 1;

        // 6. 显示结果：通过长期 display queue 渲染，避免和 linenoise prompt 竞争。
        let _ = self.queue_display_event(DisplayEvent::SubAgentResult {
            session_id: session_id.to_string(),
            status: status.to_string(),
            thinking: thinking.to_string(),
            text: text.to_string(),
            in_tokens,
            out_tokens,
        });

        // 7. 注入结果到 conversation 并触发 agent loop（忽略错误，与 bash/Go 对齐）
        let context = format!(
            "[sub-agent {}] {} (in={}, out={})\nThinking: {}\nText: {}",
            session_id, status, in_tokens, out_tokens, thinking, text
        );
        let _ = self.agent_loop_with_kind(context, "sub_agent_result");

        Ok(())
    }

    /// drain SubAgent 结果：events + stats + display + conversation 注入（对齐 bash agent_drain_notify_buf）
    /// 返回 true 如果消费了至少一条结果
    fn drain_sub_results(&mut self) -> bool {
        let mut drained = false;
        while let Ok(msg) = self.sub_result_rx.try_recv() {
            match msg {
                MainLoopMessage::AgentResult {
                    session_id,
                    status,
                    thinking,
                    text,
                    in_tokens,
                    out_tokens,
                    cache_read_tokens,
                    cache_creation_tokens,
                    request_count,
                } => {
                    let _ = self.append_event(json!({"type":"usage","input_tokens":in_tokens,"output_tokens":out_tokens,"cache_read_input_tokens":cache_read_tokens,"cache_creation_input_tokens":cache_creation_tokens,"kind":"sub_agent","sub_session_id":&session_id}));
                    let _ = self.emit_and_append_event(json!({"type":"sub_agent_result","session_id":&session_id,"status":&status,"input_tokens":in_tokens,"output_tokens":out_tokens,"thinking":&thinking,"text":&text}));
                    let _ = self.append_event(json!({"type":"sub_agent_end","session_id":&session_id,"timestamp":chrono_like_now(),"status":&status}));
                    let _ = store::store_stats_update(&self.paths.stats, |stats| {
                        Self::add_stat_usize(stats, "sub_agent_request_count", 1);
                        Self::add_stat_usize(stats, "agent_request_count", request_count);
                        Self::add_stat_usize(stats, "total_input_tokens", in_tokens);
                        Self::add_stat_usize(stats, "total_output_tokens", out_tokens);
                        Self::add_stat_usize(stats, "total_cache_read_tokens", cache_read_tokens);
                        Self::add_stat_usize(
                            stats,
                            "total_cache_creation_tokens",
                            cache_creation_tokens,
                        );
                    });
                    if self.active_task_count > 0 {
                        self.active_task_count -= 1;
                    }
                    let ctx = format!(
                        "[sub-agent {}] {} (in={}, out={})\nThinking: {}\nText: {}",
                        session_id, status, in_tokens, out_tokens, thinking, text
                    );
                    let _ = self.queue_display_event(DisplayEvent::SubAgentResult {
                        session_id,
                        status,
                        thinking,
                        text,
                        in_tokens,
                        out_tokens,
                    });
                    let _ = self.conv.add_user(&ctx);
                    drained = true;
                }
                MainLoopMessage::AsyncResult {
                    task_id,
                    exit_code,
                    output,
                } => {
                    let _ = self.emit_and_append_event(json!({"type":"async_task_result","task_id":&task_id,"exit_code":exit_code,"output":&output}));
                    if self.active_task_count > 0 {
                        self.active_task_count -= 1;
                    }
                    let ctx = format!(
                        "[bg-bash {}] exit_code={}\nOutput: {}",
                        task_id, exit_code, output
                    );
                    let _ = self.queue_display_event(DisplayEvent::AsyncTaskResult {
                        task_id,
                        exit_code,
                        output,
                    });
                    let _ = self.conv.add_user(&ctx);
                    drained = true;
                }
                MainLoopMessage::UserNotify { text } => {
                    let _ =
                        self.queue_display_event(DisplayEvent::UserNotify { text: text.clone() });
                    let _ = self.conv.add_user(&text);
                    drained = true;
                }
                _ => {}
            }
        }
        drained
    }

    /// 检查是否被中断（per-agent 标志 + 全局 SIGINT 标志）
    fn is_interrupted(&self) -> bool {
        self.interrupted.load(Ordering::SeqCst) || CTRLC_FLAG.load(Ordering::SeqCst)
    }

    pub(crate) fn agent_loop(&mut self, user_input: String) -> Result<()> {
        self.agent_loop_with_kind(user_input, "user_input")
    }

    pub(crate) fn agent_loop_with_kind(
        &mut self,
        user_input: String,
        turn_kind: &str,
    ) -> Result<()> {
        let result = self.agent_loop_stream(user_input, turn_kind);
        self.update_term_title_with_status("idle");
        result
    }

    pub(crate) fn agent_loop_stream(&mut self, user_input: String, turn_kind: &str) -> Result<()> {
        // 重置 per-agent 中断标志；如果全局 SIGINT 已触发，转存到 per-agent 标志
        self.interrupted.store(false, Ordering::SeqCst);
        if CTRLC_FLAG.swap(false, Ordering::SeqCst) {
            self.interrupted.store(true, Ordering::SeqCst);
        }
        // drain cancel pipe：清理上次可能残留的 Ctrl+C 数据，防止 PollReader 误判
        crate::tools::drain_fd(self.cancel_read_fd);

        let result = (|| -> Result<()> {
            // notify turn 只消费 pending sub_result；stale wakeup 直接返回
            if turn_kind == "notify" {
                if !self.drain_sub_results() {
                    return Ok(());
                }
            } else if turn_kind == "user_input" {
                // 记录 user_input 事件（使用原始文本，包含 [Image #N] 占位符）
                self.append_event(json!({"type":"user_input","content":user_input}))?;
            }

            // events 保留原始占位符；conversation/LLM 追加本地图片路径映射。
            let user_input = if turn_kind == "user_input" && user_input.contains("[Image #") {
                expand_image_placeholders(&user_input, &self.paths)
            } else {
                user_input
            };

            if turn_kind != "notify" {
                self.conv.add_user(&user_input)?;
            }
            // Increment turn count
            self.increment_turn_count();

            let mut turn = 0;
            while turn < self.cfg.max_turns {
                turn += 1;

                // Drain SubAgent 结果（对齐 bash agent_drain_notify_buf）
                self.drain_sub_results();

                // Compact before each LLM call: uses ctx_tokens from previous call's USAGE
                let _ = self.compact_context_window("auto");

                let mut text = String::new();
                let mut thinking = String::new();
                let mut calls: Vec<ToolCallEvent> = Vec::new();
                let mut tool_results: Vec<ToolResult> = Vec::new();
                let mut stop = String::new();
                let mut loop_error = String::new();

                let runner = tools::Runner {
                    config: self.cfg.clone(),
                    cwd: self.cwd.clone(),
                    home: self.home.clone(),
                    interrupted: self.interrupted.clone(),
                    cancel_fd: self.cancel_read_fd,
                };

                let mut stream = match self.llm_stream() {
                    Ok(s) => s,
                    Err(e) => {
                        // Pre-stream HTTP/network error — record to events.jsonl before returning
                        let err_msg = e.to_string();
                        let _ =
                            self.emit_and_append_event(json!({"type":"error","message":&err_msg}));
                        let _ = self.emit_and_append_event(json!({"type":"stop","reason":"error"}));
                        if !self.is_stream_json_mode() {
                            self.error(&err_msg);
                        }
                        return Err(e);
                    }
                };
                loop {
                    let evt = match stream.next_event() {
                        Ok(Some(e)) => e,
                        Ok(None) => break,
                        Err(e) => {
                            // SSE 解析错误：如果是中断导致的，走正常 interrupted 分支
                            let msg = e.to_string();
                            if self.is_interrupted()
                                || msg.contains("cancelled")
                                || msg.contains("ConnectionAborted")
                            {
                                stop = "interrupted".to_string();
                            } else {
                                // 非中断的解析错误，直接返回
                                return Err(e);
                            }
                            break;
                        }
                    };
                    if self.is_interrupted() {
                        stop = "interrupted".to_string();
                        break;
                    }
                    if self.cfg.verbose {
                        self.debug(&format!("<{}>", evt.render()));
                    }
                    match evt {
                        Event::Thinking(ThinkingEvent { content }) => {
                            self.queue_display_event(DisplayEvent::Thinking(content.clone()))?;
                            thinking.push_str(&content);
                        }
                        Event::Text(TextEvent { content }) => {
                            self.queue_display_event(DisplayEvent::Text(content.clone()))?;
                            text.push_str(&content);
                        }
                        Event::ToolCall(call) => {
                            self.queue_display_event(DisplayEvent::ToolCall(call.clone()))?;
                            calls.push(call.clone());

                            if self.is_interrupted() {
                                stop = "interrupted".to_string();
                                break;
                            }
                            // Async bash 拦截：在 dispatch 之前检查
                            let mut output = if call.name == "Bash"
                                && call
                                    .fields
                                    .get("background")
                                    .map(|s| s == "true" || s == "1")
                                    .unwrap_or(false)
                            {
                                let command =
                                    call.fields.get("command").cloned().unwrap_or_default();
                                let task_id = format!("task_{}", chrono_like_now());
                                self.active_task_count += 1;
                                let tx = self.sub_result_tx.clone();
                                let wake_tx = if self.cfg.interactive {
                                    Some(self.msg_tx.clone())
                                } else {
                                    None
                                };
                                let tid = task_id.clone();
                                thread::spawn(move || {
                                    let output = Command::new("bash")
                                        .arg("-lc")
                                        .arg(&command)
                                        .stdin(Stdio::null())
                                        .stdout(Stdio::piped())
                                        .stderr(Stdio::piped())
                                        .process_group(0)
                                        .output();
                                    let (exit_code, stdout) = match output {
                                        Ok(o) => (
                                            o.status.code().unwrap_or(-1),
                                            String::from_utf8_lossy(&o.stdout).to_string()
                                                + &String::from_utf8_lossy(&o.stderr),
                                        ),
                                        Err(e) => (127, e.to_string()),
                                    };
                                    if tx
                                        .send(MainLoopMessage::AsyncResult {
                                            task_id: tid,
                                            exit_code,
                                            output: stdout,
                                        })
                                        .is_ok()
                                    {
                                        if let Some(wake_tx) = wake_tx {
                                            if let Ok(guard) = wake_tx.lock() {
                                                if let Some(tx) = guard.as_ref() {
                                                    let _ = tx.send(MainLoopMessage::NotifyPending);
                                                }
                                            }
                                        }
                                    }
                                });
                                format!("Async task started: task_id={}", task_id)
                            } else {
                                let dispatch_result = runner.dispatch(&call.name, &call.input_json);
                                if self.is_interrupted() {
                                    stop = "interrupted".to_string();
                                    break;
                                }
                                match dispatch_result {
                                    Ok(v) => v,
                                    Err(e) => format!("Error: {e}"),
                                }
                            };
                            output =
                                tools::format_tool_result(&output, self.cfg.tool_result_max_bytes);

                            let mut conv_content = String::new();
                            if call.name == "PlanClear" {
                                let _ = self.compact_context_window("plan_clear");
                                let _ = store::store_plan_clear(&self.paths);
                                output = "Plan cleared.".to_string();
                            }

                            if call.name == "PlanConfirm" {
                                // 先 compact 再写 plan：compact 复用旧缓存前缀，写 plan 后才触发缓存失效——总共一次冷启动
                                match store::store_plan_draft_get(&self.paths) {
                                    Ok(data) if !data.is_empty() => {
                                        let _ = self.compact_context_window("plan_confirm");
                                        let _ = store::store_plan_set(&self.paths, &data);
                                        let _ = store::store_plan_draft_clear(&self.paths);
                                        output = "Plan confirmed and locked in.".to_string();
                                    }
                                    _ => {
                                        output =
                                            "Error: no plan draft found to confirm.".to_string();
                                    }
                                }
                            }

                            if call.name == "SubAgent" {
                                // SubAgent 工具在 app 层处理，因为它需要访问 runtime 的完整上下文
                                output = self.handle_sub_agent(&call.fields);
                            }

                            if call.name == "Edit" {
                                // Tool output = summary_line + "\n" + colorized_diff + "\n" (matches bash tool_edit)
                                // Conv file gets summary only (matches bash: result_for_conv = first line)
                                conv_content = first_line(&output).to_string();
                            } else if call.name == "Read" || call.name == "Write" {
                                // Prepend file summary to content (matches bash behavior)
                                conv_content = output.clone();
                                let file_summary = Store::file_tool_result_summary(
                                    &call.name,
                                    call.fields.get("path").map(String::as_str).unwrap_or(""),
                                    call.fields.get("offset").map(String::as_str).unwrap_or(""),
                                    call.fields.get("limit").map(String::as_str).unwrap_or(""),
                                );
                                output = format!("{}\n{}", file_summary, output);
                            }

                            let tool_result = ToolResult {
                                tool_use_id: call.id.clone(),
                                tool_name: call.name.clone(),
                                tool_args: call
                                    .fields
                                    .iter()
                                    .map(|(k, v)| (k.clone(), v.clone()))
                                    .collect(),
                                content: output.clone(),
                                conv_content,
                            };
                            self.queue_display_event(DisplayEvent::ToolResult(
                                tool_result.clone(),
                            ))?;
                            tool_results.push(tool_result);
                        }
                        Event::Usage(usage) => {
                            self.queue_display_event(DisplayEvent::Usage(usage))?;
                        }
                        Event::Stop(StopEvent { reason }) => {
                            stop = reason.clone();
                            self.queue_display_event(DisplayEvent::Stop(reason))?;
                            break;
                        }
                        Event::Error(ErrorEvent { message }) => {
                            loop_error = message.clone();
                            stop = "error".to_string();
                            let _ = self.queue_display_event(DisplayEvent::Error(message));
                            break;
                        }
                        Event::Retry(RetryEvent {}) => {
                            text.clear();
                            thinking.clear();
                            calls.clear();
                            tool_results.clear();
                            // Always write to events.jsonl, and to stdout if stream-json mode
                            self.emit_and_append_event(json!({"type":"retry"}))?;
                        }
                    }
                }

                // Fatal stop reasons exit immediately
                match stop.as_str() {
                    "error" | "max_tokens" | "length" => {
                        if stop == "error" {
                            if !loop_error.is_empty() {
                                return Err(anyhow!("{}", loop_error));
                            }
                            return Err(anyhow!("unknown API error"));
                        }
                        if stop != "error" {
                            self.error("Response truncated (max_tokens reached)");
                        }
                        return Ok(());
                    }
                    _ => {}
                }

                // Tools already executed inline; persist unless interrupted
                if !self.is_interrupted() {
                    self.conv.add_assistant(&text, &thinking, &calls)?;
                    if !tool_results.is_empty() {
                        self.conv.add_tool_results(&tool_results)?;
                        // Note: granular tool_result events already written by display_event via emit_and_append_event
                    }
                    // Update context tokens from USAGE (used by next turn's compact check)
                    // 对齐 Bash/Go: agent_request_count 和 token totals 无条件更新,
                    // current_context_tokens 仅在 > 0 时写入
                    self.update_stats_from_usage();
                    // tool_use/tool_calls → loop continues; anything else → break
                    if stop.as_str() != "tool_use" && stop.as_str() != "tool_calls" {
                        // end_turn 后尝试 drain（对齐 bash agent_drain_notify_buf && continue）
                        if self.drain_sub_results() {
                            continue;
                        }
                        CTRLC_FLAG.store(false, Ordering::SeqCst);
                        return Ok(());
                    }
                } else {
                    // Match bash: write stop interrupted event and render through display queue.
                    let _ = self.queue_display_event(DisplayEvent::Stop("interrupted".to_string()));
                    CTRLC_FLAG.store(false, Ordering::SeqCst);
                    return Ok(());
                }
            }
            self.error(&format!("Max turns ({}) reached", self.cfg.max_turns));
            Ok(())
        })();
        result
    }

    pub(crate) fn build_system_prompt(&self) -> Result<String> {
        prompt::Builder {
            cwd: self.cwd.clone(),
            home: self.home.clone(),
            skills: self.cfg.skills.clone(),
            summary_file: self.paths.summary.clone(),
            plan_file: self.paths.plan.clone(),
            plan_draft_file: self.paths.plan_draft.clone(),
        }
        .build_system_prompt()
    }

    /// append_event writes an event to events.jsonl and, in stream-json mode,
    /// tees the same JSON line to stdout.
    fn emit_and_append_event(&self, value: Value) -> Result<()> {
        self.append_event(value)
    }

    fn queue_display_event(&mut self, evt: DisplayEvent) -> Result<()> {
        match &evt {
            DisplayEvent::Thinking(content) => {
                self.emit_and_append_event(json!({"type":"thinking","content":content.clone()}))?;
            }
            DisplayEvent::Text(content) => {
                self.emit_and_append_event(json!({"type":"text","content":content.clone()}))?;
            }
            DisplayEvent::ToolCall(call) => {
                self.emit_and_append_event(json!({
                    "type":"tool_call",
                    "name": call.name,
                    "id": call.id,
                    "input": call.input_json,
                }))?;
            }
            DisplayEvent::Usage(UsageEvent {
                input_tokens,
                output_tokens,
                cache_read_input_tokens,
                cache_creation_input_tokens,
            }) => {
                self.emit_and_append_event(json!({
                    "type":"usage",
                    "input_tokens":input_tokens,
                    "output_tokens":output_tokens,
                    "cache_read_input_tokens":cache_read_input_tokens,
                    "cache_creation_input_tokens":cache_creation_input_tokens,
                    "kind":"agent"
                }))?;
                self.last_context_tokens = (*input_tokens
                    + *output_tokens
                    + *cache_read_input_tokens
                    + *cache_creation_input_tokens)
                    as usize;
                self.last_input_tokens = *input_tokens as usize;
                self.last_output_tokens = *output_tokens as usize;
                self.last_cache_read_tokens = *cache_read_input_tokens as usize;
                self.last_cache_creation_tokens = *cache_creation_input_tokens as usize;
            }
            DisplayEvent::Stop(reason) => {
                self.emit_and_append_event(json!({"type":"stop","reason":&reason}))?;
            }
            DisplayEvent::Error(message) => {
                let _ = self.emit_and_append_event(json!({"type":"error","message":&message}));
                return Err(anyhow!("{}", message));
            }
            DisplayEvent::ToolResult(result) => {
                self.emit_and_append_event(json!({
                    "type": "tool_result",
                    "tool_use_id": result.tool_use_id,
                    "name": result.tool_name,
                    "content": result.content,
                }))?;
            }
            DisplayEvent::UserMessage(_) => {}
            DisplayEvent::ContextUpdate(_) => {}
            DisplayEvent::SubAgentResult { .. } => {}
            DisplayEvent::AsyncTaskResult { .. } => {}
            DisplayEvent::UserNotify { .. } => {}
            DisplayEvent::Title(_) => {}
        }
        if let Some(tx) = &self.display_tx {
            tx.send(DisplayCommand::Event(evt))
                .map_err(|e| anyhow!(e.to_string()))?;
        }
        Ok(())
    }

    fn llm_stream(&self) -> Result<LlmStream> {
        let lines = self.conv.lines()?;
        let system_prompt = self.build_system_prompt()?;

        let claude_body = build_claude_request(
            &self.cfg,
            &lines,
            &self.tools_json,
            &system_prompt,
            self.cfg.max_tokens,
            &self.cfg.thinking,
            &self.cfg.effort,
        )?;
        let body = self.transport.convert_body(&claude_body)?;
        if self.cfg.verbose {
            self.debug(&format!(
                "Request body ({}KB): {:.200}...",
                body.len() / 1024,
                String::from_utf8_lossy(&body)
            ));
        }

        let resp = match self.http.post(&self.api_url, &self.headers(), &body) {
            Ok(r) => r,
            Err(e) => {
                if let Some(http_err) = e.downcast_ref::<HTTPError>() {
                    return Err(anyhow!("http_post: {}", http_err.format_detailed()));
                }
                return Err(anyhow!("http_post: {e}"));
            }
        };

        let (tx, rx) = mpsc::channel();
        let transport = self.transport.clone();

        // 同步线程：http_stream → ChannelReader → BufReader → parse_sse → events
        let (reader, cancel) = self.http_stream(resp);
        let _reader_thread = std::thread::spawn(move || {
            let mut send = |evt: Event| -> Result<()> {
                tx.send(StreamMsg::Event(evt))
                    .map_err(|e| anyhow!(e.to_string()))
            };
            let parse_res = transport.parse_sse(Box::new(reader), &mut send);
            let _ = tx.send(StreamMsg::Done(
                parse_res.map_err(|err| anyhow!("sse_parse: {err}")),
            ));
        });

        Ok(LlmStream {
            rx,
            finished: false,
            cancel,
            interrupted: self.interrupted.clone(),
        })
    }

    pub(crate) fn compact_context_window(&mut self, trigger: &str) -> Result<bool> {
        let stats = store::store_stats_read(&self.paths.stats)?;
        let context_tokens = stats_get_f64(&stats, "current_context_tokens") as usize;
        let current_turn = stats_get_f64(&stats, "current_turn_count") as usize;
        let prev_compactions = stats_get_f64(&stats, "compact_request_count") as usize;
        let total_requests = stats_get_f64(&stats, "agent_request_count") as usize;
        let total_input_tokens = stats_get_f64(&stats, "total_input_tokens") as usize;

        let dp_cfg = crate::compact_dp::DPCompactConfig {
            p_input: self.cfg.dp_p_input,
            p_cache: self.cfg.dp_p_cache,
            p_out: self.cfg.dp_p_out,
            v: self.cfg.dp_v,
            s: self.cfg.dp_s,
            l_fixed: self.cfg.dp_l,
            baseline_e: self.cfg.dp_baseline_e,
            e_fixed: self.cfg.dp_e_fixed,
            r: self.cfg.dp_r,
            beta: self.cfg.dp_beta,
            quality_penalty: self.cfg.dp_quality_penalty,
            max_context: self.cfg.max_context_tokens,
            min_keep_ratio: self.cfg.dp_min_keep_ratio,
        };

        let all = self.conv.lines()?;
        // 始终先算 DP 决策（经济最优）
        let mut keep_lines = crate::compact_dp::compact_dp_decision(
            &all,
            &dp_cfg,
            prev_compactions,
            current_turn,
            total_requests,
            total_input_tokens,
        );

        let total_lines = all.len();
        let needs_fallback = keep_lines.is_none()
            || keep_lines.map_or(false, |k| k >= total_lines && total_lines > 0);
        if needs_fallback {
            // DP 认为不值得或全保留 → trigger 或 safety valve 触发时 fallback
            let should_compact = trigger == "plan_clear"
                || trigger == "plan_confirm"
                || (context_tokens > 0 && context_tokens > self.cfg.max_context_tokens * 90 / 100);
            if should_compact {
                keep_lines = crate::compact_dp::compact_turn_keep(&all, dp_cfg.min_keep_ratio);
            } else {
                return Ok(false);
            }
        }

        let k = match keep_lines {
            Some(0) => return Ok(false),
            Some(v) => v,
            None => return Ok(false),
        };
        // 统一 guard：keep >= total 时只有 plan_clear/plan_confirm 继续
        if k >= total_lines && trigger != "plan_clear" && trigger != "plan_confirm" {
            return Ok(false);
        }
        let drop = total_lines - k;
        let dropped_lines = &all[..drop];

        let summary = self.run_summary_call(dropped_lines)?;
        store::store_summary_set(&self.paths, &summary)?;
        self.conv.trim_keep_last(k)?;

        // 注意：不再重置 current_turn_count — 它应始终保持 session 累计计数
        // 只更新 last_updated 和 terminal title
        if let Ok(_) = self.conv.count_user_inputs() {
            store::store_stats_update(&self.paths.stats, |stats| {
                stats.insert(
                    "last_updated".to_string(),
                    Value::String(chrono_now_rfc3339()),
                );
            })?;
            self.update_term_title();
        }

        self.emit_context_update(trigger)?;
        Ok(true)
    }

    fn run_summary_call(&mut self, dropped_lines: &[Value]) -> Result<String> {
        // Build messages: dropped conversation lines + summary instruction
        // Cache-Aligned Summarization: uses same system prompt + tools +
        // thinking as normal requests for prefix cache hit.
        let summary_instruction = "The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. Do NOT think. Just output the summary directly as plain text. Summarize the key information from the messages above into a concise context summary. Update the existing summary snapshot using the messages above. Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:\nReflections:";
        let mut messages: Vec<Value> = dropped_lines.to_vec();
        messages.push(json!({"role":"user","content":summary_instruction}));

        let system_prompt = self.build_system_prompt()?;

        let claude_body = build_claude_request(
            &self.cfg,
            &messages,
            &self.tools_json,
            &system_prompt,
            self.cfg.max_tokens,
            "disabled",
            &self.cfg.effort,
        )?;
        let body = self.transport.convert_body(&claude_body)?;
        let resp = match self.http.post(&self.api_url, &self.headers(), &body) {
            Ok(r) => r,
            Err(e) => {
                if let Some(http_err) = e.downcast_ref::<HTTPError>() {
                    return Err(anyhow!("{}", http_err.format_detailed()));
                }
                return Err(e);
            }
        };
        let (channel_reader, _cancel) = self.http_stream(resp);
        let mut out = String::new();
        let mut last_error = String::new();
        let mut stop_reason = String::new();
        let mut parse_emit = |evt: Event| -> Result<()> {
            match evt {
                Event::Text(TextEvent { content }) => out.push_str(&content),
                Event::Usage(usage) => {
                    let compact_evt = json!({
                        "type":"usage",
                        "input_tokens":usage.input_tokens,
                        "output_tokens":usage.output_tokens,
                        "cache_read_input_tokens":usage.cache_read_input_tokens,
                        "cache_creation_input_tokens":usage.cache_creation_input_tokens,
                        "kind":"compact"
                    });
                    let _ = self.append_event(compact_evt);
                    store::store_stats_update(&self.paths.stats, |stats| {
                        Self::add_stat_usize(stats, "compact_request_count", 1);
                        Self::add_stat_usize(
                            stats,
                            "total_input_tokens",
                            usage.input_tokens as usize,
                        );
                        Self::add_stat_usize(
                            stats,
                            "total_output_tokens",
                            usage.output_tokens as usize,
                        );
                        Self::add_stat_usize(
                            stats,
                            "total_cache_read_tokens",
                            usage.cache_read_input_tokens as usize,
                        );
                        Self::add_stat_usize(
                            stats,
                            "total_cache_creation_tokens",
                            usage.cache_creation_input_tokens as usize,
                        );
                    })?;
                    self.update_term_title();
                }
                Event::Error(ErrorEvent { message }) => {
                    last_error = message.clone();
                }
                Event::Stop(StopEvent { reason }) => {
                    stop_reason = reason.clone();
                }
                _ => {}
            }
            Ok(())
        };
        self.transport
            .parse_sse(Box::new(channel_reader), &mut parse_emit)?;
        if out.is_empty() {
            bail!(
                "failed to generate context summary: empty text response (stop_reason={}, error={})",
                if stop_reason.is_empty() {
                    "none"
                } else {
                    &stop_reason
                },
                if last_error.is_empty() {
                    "none"
                } else {
                    &last_error
                }
            );
        }
        Ok(out)
    }

    /// 通过 mpsc channel 流式传输 HTTP 响应体，100ms 轮询 interrupted + CTRLC_FLAG 实现可中断。
    /// 返回 (ChannelReader, Arc<AtomicBool>)，后者用于 LlmStream::drop 时取消流。
    /// 同时检查 per-agent 的 interrupted 和全局的 CTRLC_FLAG，确保 Ctrl+C 能立即中断当前流。
    fn http_stream(&self, resp: reqwest::Response) -> (ChannelReader, Arc<AtomicBool>) {
        let (chunk_tx, chunk_rx) = std::sync::mpsc::channel::<Vec<u8>>();
        let interrupted = self.interrupted.clone();
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_clone = cancel.clone();
        tokio_runtime().spawn(async move {
            use tokio_stream::StreamExt;
            let stream = resp.bytes_stream();
            tokio::pin!(stream);
            loop {
                tokio::select! {
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                        if interrupted.load(Ordering::SeqCst) || CTRLC_FLAG.load(Ordering::SeqCst) || cancel_clone.load(Ordering::SeqCst) { break; }
                    }
                    chunk = stream.next() => {
                        match chunk {
                            Some(Ok(bytes)) => { if chunk_tx.send(bytes.to_vec()).is_err() { break; } }
                            _ => break,
                        }
                    }
                }
            }
        });
        (
            ChannelReader {
                rx: chunk_rx,
                buf: Vec::new(),
                pos: 0,
            },
            cancel,
        )
    }

    fn headers(&self) -> Vec<(String, String)> {
        let mut h = vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("User-Agent".to_string(), "bash-agent/4.3.2".to_string()),
        ];
        match self.cfg.provider.as_str() {
            "claude" => {
                h.push(("x-api-key".to_string(), self.cfg.api_key.clone()));
                h.push(("anthropic-version".to_string(), "2023-06-01".to_string()));
                h.push(("x-app".to_string(), "cli".to_string()));
            }
            "openai" | "responses" => {
                h.push((
                    "Authorization".to_string(),
                    format!("Bearer {}", self.cfg.api_key),
                ));
            }
            _ => {}
        }
        h
    }

    fn append_event(&self, value: Value) -> Result<()> {
        if self.paths.events.as_os_str().is_empty() {
            return Ok(());
        }
        store::store_event_append_json(&self.paths, &value)?;
        if self.is_stream_json_mode() {
            self.emit_stream(value)?;
        }
        Ok(())
    }

    /// increment_turn_count increments the current_turn_count in stats.json.
    fn increment_turn_count(&self) {
        let _ = store::store_stats_update(&self.paths.stats, |stats| {
            Self::add_stat_usize(stats, "current_turn_count", 1);
            stats.insert(
                "last_updated".to_string(),
                Value::String(chrono_now_rfc3339()),
            );
        });
        self.update_term_title();
    }

    /// update_stats_from_usage updates stats.json with last turn's usage (matches bash stats_inc+stats_set).
    fn update_stats_from_usage(&self) {
        let _ = store::store_stats_update(&self.paths.stats, |stats| {
            Self::add_stat_usize(stats, "agent_request_count", 1);
            Self::add_stat_usize(stats, "total_input_tokens", self.last_input_tokens);
            Self::add_stat_usize(stats, "total_output_tokens", self.last_output_tokens);
            Self::add_stat_usize(
                stats,
                "total_cache_read_tokens",
                self.last_cache_read_tokens,
            );
            Self::add_stat_usize(
                stats,
                "total_cache_creation_tokens",
                self.last_cache_creation_tokens,
            );
            // context = input + output + cache_read + cache_creation
            // 仅在 > 0 时写入（与 bash/c 版一致，避免零值覆盖）
            let ctx = self.last_input_tokens
                + self.last_output_tokens
                + self.last_cache_read_tokens
                + self.last_cache_creation_tokens;
            if ctx > 0 {
                Self::set_stat_usize(stats, "current_context_tokens", ctx);
            }
            stats.insert(
                "last_updated".to_string(),
                Value::String(chrono_now_rfc3339()),
            );
        });
        self.update_term_title();
    }

    fn stat_usize(stats: &serde_json::Map<String, Value>, key: &str) -> usize {
        stats_get_f64(stats, key) as usize
    }

    fn set_stat_usize(stats: &mut serde_json::Map<String, Value>, key: &str, value: usize) {
        stats.insert(key.to_string(), Value::Number(value.into()));
    }

    fn add_stat_usize(stats: &mut serde_json::Map<String, Value>, key: &str, delta: usize) {
        let next = Self::stat_usize(stats, key) + delta;
        Self::set_stat_usize(stats, key, next);
    }

    /// Format integer with comma separators: 28126139 → "28,126,139"
    fn fmt_num(n: usize) -> String {
        let s = n.to_string();
        let mut buf = String::with_capacity(s.len() + s.len() / 3);
        let off = s.len() % 3;
        let first = if off == 0 { 3 } else { off };
        buf.push_str(&s[..first]);
        for i in (first..s.len()).step_by(3) {
            buf.push(',');
            buf.push_str(&s[i..i + 3]);
        }
        buf
    }

    /// update_term_title updates the terminal title with current stats (matches bash stats_show_osc).
    fn update_term_title(&self) {
        self.update_term_title_with_status("");
    }

    fn update_term_title_with_status(&self, status: &str) {
        let stats = store::store_stats_read(&self.paths.stats).unwrap_or_default();
        let tc = stats_get_f64(&stats, "current_turn_count") as usize;
        let ar = stats_get_f64(&stats, "agent_request_count") as usize;
        let ai = stats_get_f64(&stats, "total_input_tokens") as usize;
        let ao = stats_get_f64(&stats, "total_output_tokens") as usize;
        let ctx = stats_get_f64(&stats, "current_context_tokens") as usize;
        let cr = stats_get_f64(&stats, "total_cache_read_tokens") as usize;
        let cache_pct = {
            let total = ai + cr;
            if total > 0 {
                format!("{:.0}%", (cr as f64) / (total as f64) * 100.0)
            } else {
                "—".to_string()
            }
        };
        let idle = status == "idle" && self.active_task_count == 0;
        let prefix = if idle { "" } else { "⏳ " };
        let progress = if idle { 0 } else { 3 };
        let title = format!(
            "\x1b]0;{}{} T:{} R:{} I:{}({}) O:{} C:{}\x07\x1b]9;4;{}\x07",
            prefix,
            self.cfg.model,
            Self::fmt_num(tc),
            Self::fmt_num(ar),
            Self::fmt_num(ai + cr),
            cache_pct,
            Self::fmt_num(ao),
            Self::fmt_num(ctx),
            progress
        );
        // 通过 display worker 序列化输出，避免与 text delta 交织
        if self.display_tx.is_some() {
            self.queue_display_only(DisplayEvent::Title(title));
        } else {
            // 子 agent 无 display worker，直接写 stderr
            let _ = write!(self.stderr.borrow_mut(), "{}", title);
            let _ = self.stderr.borrow_mut().flush();
        }
    }

    fn is_stream_json_mode(&self) -> bool {
        self.cfg.output_format == OutputFormat::StreamJson
    }

    /// Emit a context_update event: write to events.jsonl + emit to stream-json or print info.
    fn emit_context_update(&self, trigger: &str) -> Result<()> {
        let evt = json!({"type":"context_update","kind":"compact","trigger":trigger});
        self.append_event(evt)?;
        if !self.is_stream_json_mode() {
            self.queue_display_only(DisplayEvent::ContextUpdate(trigger.to_string()));
        }
        Ok(())
    }

    fn emit_stream(&self, value: Value) -> Result<()> {
        writeln!(
            self.stdout.borrow_mut(),
            "{}",
            serde_json::to_string(&value)?
        )?;
        Ok(())
    }

    fn info(&self, msg: &str) {
        if self.cfg.interactive {
            let _ = write!(self.stderr.borrow_mut(), "\x1b[36m{msg}\x1b[0m\r\n");
            let _ = self.stderr.borrow_mut().flush();
        } else {
            let _ = writeln!(self.stderr.borrow_mut(), "\x1b[36m{msg}\x1b[0m");
        }
    }

    /// Replay maps stored events into the same display queue used by live execution.
    /// It must not append events again; events.jsonl is already the source of truth.
    /// 行级事件映射已抽为自由函数 replay_event_build / replay_parse_line，
    /// 供 replay_last_turns 与 --watch 共用。

    fn replay_last_turns(&self) {
        let max_turns = 10usize;
        let mut file = match fs::File::open(&self.paths.events) {
            Ok(file) => file,
            Err(_) => return,
        };

        let mut offsets = vec![0u64; max_turns];
        let mut seen = 0usize;
        let mut reader = BufReader::new(file);
        let mut pos = 0u64;
        let mut line = String::new();
        loop {
            line.clear();
            let n = match reader.read_line(&mut line) {
                Ok(n) => n,
                Err(_) => return,
            };
            if n == 0 {
                break;
            }
            if line.contains("\"type\":\"user_input\"")
                || line.contains("\"type\":\"user_message\"")
            {
                offsets[seen % max_turns] = pos;
                seen += 1;
            }
            pos += n as u64;
        }
        if seen == 0 {
            return;
        }

        let start_offset = if seen >= max_turns {
            offsets[seen % max_turns]
        } else {
            offsets[0]
        };

        file = reader.into_inner();
        if file.seek(SeekFrom::Start(start_offset)).is_err() {
            return;
        }

        let reader = BufReader::new(file);
        for line in reader.lines() {
            let Ok(line) = line else { continue };
            for evt in replay_parse_line(&line) {
                self.queue_display_only(evt);
            }
        }
        self.queue_display_only(DisplayEvent::Text("\n".to_string()));
        self.flush_display();
    }

    fn error(&self, msg: &str) {
        if self.cfg.interactive {
            let _ = write!(self.stderr.borrow_mut(), "\x1b[31mError: {msg}\x1b[0m\r\n");
            let _ = self.stderr.borrow_mut().flush();
        } else {
            let _ = writeln!(self.stderr.borrow_mut(), "\x1b[31mError: {msg}\x1b[0m");
        }
    }

    fn debug(&self, msg: &str) {
        if self.cfg.verbose {
            let _ = writeln!(self.stderr.borrow_mut(), "[debug] {msg}");
        }
    }
}

/// 事件类型 + 字段 → DisplayEvent（replay 与 --watch 共用的映射，对齐 bash event_replay.awk）
fn replay_event_build(
    evt_type: &str,
    fields: &std::collections::HashMap<&str, &str>,
) -> Option<DisplayEvent> {
    let evt = match evt_type {
        "TEXT" => DisplayEvent::Text(fields.get("content").copied().unwrap_or("").to_string()),
        "THINKING" => {
            DisplayEvent::Thinking(fields.get("content").copied().unwrap_or("").to_string())
        }
        "TOOL_CALL" => {
            let name = fields.get("name").copied().unwrap_or("").to_string();
            let mut summary_fields = std::collections::BTreeMap::new();
            for (k, v) in fields {
                if *k != "name" {
                    summary_fields.insert(k.to_string(), v.to_string());
                }
            }
            DisplayEvent::ToolCall(ToolCallEvent {
                name,
                id: String::new(),
                input_json: json!({}),
                fields: summary_fields,
                order: Vec::new(),
            })
        }
        "TOOL_RESULT" => DisplayEvent::ToolResult(ToolResult {
            tool_use_id: String::new(),
            tool_name: fields.get("name").copied().unwrap_or("").to_string(),
            tool_args: std::collections::BTreeMap::new(),
            content: fields.get("content").copied().unwrap_or("").to_string(),
            conv_content: String::new(),
        }),
        "USER_MESSAGE" => {
            DisplayEvent::UserMessage(fields.get("content").copied().unwrap_or("").to_string())
        }
        "SUB_AGENT_RESULT" => DisplayEvent::SubAgentResult {
            session_id: fields.get("session_id").copied().unwrap_or("").to_string(),
            status: fields.get("status").copied().unwrap_or("").to_string(),
            thinking: fields.get("thinking").copied().unwrap_or("").to_string(),
            text: fields.get("text").copied().unwrap_or("").to_string(),
            in_tokens: fields
                .get("input_tokens")
                .and_then(|s| s.parse().ok())
                .unwrap_or(0),
            out_tokens: fields
                .get("output_tokens")
                .and_then(|s| s.parse().ok())
                .unwrap_or(0),
        },
        "STOP" => DisplayEvent::Stop(fields.get("reason").copied().unwrap_or("").to_string()),
        "ERROR" => DisplayEvent::Error(fields.get("message").copied().unwrap_or("").to_string()),
        _ => return None,
    };
    Some(evt)
}

/// 将一行 events.jsonl 映射为 DisplayEvent 列表（replay_last_turns 与 --watch 共用）
fn replay_parse_line(line: &str) -> Vec<DisplayEvent> {
    fn push(out: &mut Vec<DisplayEvent>, t: &str, fields: &std::collections::HashMap<&str, &str>) {
        if let Some(e) = replay_event_build(t, fields) {
            out.push(e);
        }
    }

    let mut out = Vec::new();
    if line.trim().is_empty() {
        return out;
    }
    let Ok(evt) = serde_json::from_str::<Value>(line) else {
        return out;
    };
    let evt_type = evt.get("type").and_then(Value::as_str).unwrap_or("");
    match evt_type {
        "session_start" | "usage" | "stop" | "retry" => {}
        "user_input" | "user_message" => {
            let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
            if !content.is_empty() {
                push(
                    &mut out,
                    "USER_MESSAGE",
                    &std::collections::HashMap::from([("content", content)]),
                );
            }
        }
        "sub_agent_result" => {
            let session_id = evt.get("session_id").and_then(Value::as_str).unwrap_or("");
            let status = evt.get("status").and_then(Value::as_str).unwrap_or("");
            let input_tokens = evt
                .get("input_tokens")
                .map(|v| v.to_string())
                .unwrap_or_default();
            let output_tokens = evt
                .get("output_tokens")
                .map(|v| v.to_string())
                .unwrap_or_default();
            let thinking = evt.get("thinking").and_then(Value::as_str).unwrap_or("");
            let text = evt.get("text").and_then(Value::as_str).unwrap_or("");
            push(
                &mut out,
                "SUB_AGENT_RESULT",
                &std::collections::HashMap::from([
                    ("session_id", session_id),
                    ("status", status),
                    ("input_tokens", input_tokens.as_str()),
                    ("output_tokens", output_tokens.as_str()),
                    ("thinking", thinking),
                    ("text", text),
                ]),
            );
        }
        "thinking" => {
            let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
            if !content.is_empty() {
                push(
                    &mut out,
                    "THINKING",
                    &std::collections::HashMap::from([("content", content)]),
                );
            }
        }
        "text" => {
            let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
            if !content.is_empty() {
                push(
                    &mut out,
                    "TEXT",
                    &std::collections::HashMap::from([("content", content)]),
                );
            }
        }
        "tool_call" => {
            let name = evt.get("name").and_then(Value::as_str).unwrap_or("");
            let default_input = json!({});
            let input = evt.get("input").unwrap_or(&default_input);
            let fields = parse_input_fields(input);
            let mut map = std::collections::HashMap::new();
            map.insert("name", name.to_string());
            for (k, v) in &fields {
                map.insert(k.as_str(), v.as_str().to_string());
            }
            let str_map: std::collections::HashMap<&str, &str> =
                map.iter().map(|(k, v)| (*k, v.as_str())).collect();
            push(&mut out, "TOOL_CALL", &str_map);
        }
        "tool_result" => {
            let name = evt.get("name").and_then(Value::as_str).unwrap_or("");
            let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
            let display = truncate_for_replay(content, 200);
            push(
                &mut out,
                "TOOL_RESULT",
                &std::collections::HashMap::from([("name", name), ("content", display.as_str())]),
            );
        }
        "error" => {
            let msg = evt.get("message").and_then(Value::as_str).unwrap_or("");
            push(
                &mut out,
                "ERROR",
                &std::collections::HashMap::from([("message", msg)]),
            );
        }
        "assistant_message" => {
            // Legacy format: emit TEXT + TOOL_CALL per tool_call (match bash event_replay.awk)
            let text = evt.get("text").and_then(Value::as_str).unwrap_or("");
            if !text.is_empty() {
                push(
                    &mut out,
                    "TEXT",
                    &std::collections::HashMap::from([("content", text)]),
                );
            }
            if let Some(tool_calls) = evt.get("tool_calls").and_then(Value::as_array) {
                for tc in tool_calls {
                    let name = tc.get("name").and_then(Value::as_str).unwrap_or("");
                    let default_input = json!({});
                    let input = tc.get("input").unwrap_or(&default_input);
                    let fields = parse_input_fields(input);
                    let mut map = std::collections::HashMap::new();
                    map.insert("name", name.to_string());
                    for (k, v) in &fields {
                        map.insert(k.as_str(), v.as_str().to_string());
                    }
                    let str_map: std::collections::HashMap<&str, &str> =
                        map.iter().map(|(k, v)| (*k, v.as_str())).collect();
                    push(&mut out, "TOOL_CALL", &str_map);
                }
            }
        }
        _ => {}
    }
    out
}

/// --watch 入口：解析 session → 渲染最后 10 行已有事件 → 500ms 轮询 follow 新增事件。
/// 不需要 API key，不创建 session（对齐 bash agent_watch_session）。
pub fn agent_watch_session(home: &std::path::Path, arg: &str, stream_json: bool) -> Result<()> {
    let file = match watch_resolve(home, arg) {
        Some(f) => f,
        None => {
            eprintln!("Error: session not found: {arg}");
            eprintln!(
                "  Searched: {}",
                home.join(".bash-agent/projects").display()
            );
            std::process::exit(1);
        }
    };
    let sid = file
        .parent()
        .and_then(|p| p.file_name())
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();

    let (tx, _handle) = if stream_json {
        (None, None)
    } else {
        let (tx, handle) = Agent::start_display_worker(false);
        println!("\x1b[1m=== {sid} ===\x1b[0m\n");
        (Some(tx), Some(handle))
    };

    let lines = watch_read_lines(&file);
    let start = lines.len().saturating_sub(10);
    for line in &lines[start..] {
        watch_emit(tx.as_ref(), stream_json, line);
    }
    watch_flush(tx.as_ref());
    let mut offset = lines.len();
    loop {
        std::thread::sleep(std::time::Duration::from_millis(500));
        let lines = watch_read_lines(&file);
        if lines.len() <= offset {
            continue;
        }
        for line in &lines[offset..] {
            watch_emit(tx.as_ref(), stream_json, line);
        }
        offset = lines.len();
        watch_flush(tx.as_ref());
    }
}

fn watch_emit(tx: Option<&mpsc::Sender<DisplayCommand>>, stream_json: bool, line: &str) {
    if stream_json {
        println!("{line}");
    } else if let Some(tx) = tx {
        for evt in replay_parse_line(line) {
            let _ = tx.send(DisplayCommand::Event(evt));
        }
    }
}

fn watch_flush(tx: Option<&mpsc::Sender<DisplayCommand>>) {
    if let Some(tx) = tx {
        let (done_tx, done_rx) = mpsc::channel();
        if tx.send(DisplayCommand::Flush(done_tx)).is_ok() {
            let _ = done_rx.recv();
        }
    }
}

/// 读取完整行（对齐 bash 的 wc -l 语义：丢弃末尾未写完的半行）
fn watch_read_lines(path: &std::path::Path) -> Vec<String> {
    let Ok(data) = fs::read(path) else {
        return Vec::new();
    };
    let text = String::from_utf8_lossy(&data);
    let text = text.as_ref();
    let end = if text.ends_with('\n') {
        text.len()
    } else {
        match text.rfind('\n') {
            Some(i) => i + 1,
            None => return Vec::new(),
        }
    };
    text[..end].lines().map(|s| s.to_string()).collect()
}

/// 解析 --watch 参数：events.jsonl 路径 | session 目录 | session_id
/// （对齐 bash agent_watch_resolve / watch.sh resolve_session）
fn watch_resolve(home: &std::path::Path, arg: &str) -> Option<PathBuf> {
    let p = std::path::Path::new(arg);
    if p.is_file() {
        return Some(p.to_path_buf());
    }
    if p.is_dir() {
        let f = p.join("events.jsonl");
        if f.is_file() {
            return Some(f);
        }
    }
    let root = home.join(".bash-agent").join("projects");
    let mut found = None;
    watch_find_dir(&root, arg, &mut found);
    let dir = found?;
    let f = dir.join("events.jsonl");
    if f.is_file() { Some(f) } else { None }
}

/// 递归查找第一个同名目录（遍历顺序对齐 find：先检查目录自身再递归子目录）
fn watch_find_dir(dir: &std::path::Path, name: &str, found: &mut Option<PathBuf>) {
    if found.is_some() {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if entry.file_name() == name {
            *found = Some(path);
            return;
        }
        watch_find_dir(&path, name, found);
        if found.is_some() {
            return;
        }
    }
}

/// Append local path metadata for [Image #N] placeholders.
fn expand_image_placeholders(input: &str, paths: &store::Paths) -> String {
    let re = regex::Regex::new(r"\[Image #(\d+)\]").unwrap();
    let mut attachments = Vec::new();
    for cap in re.captures_iter(input) {
        let p = paths
            .session_dir
            .join("images")
            .join(format!("{}.png", &cap[1]));
        if p.exists() {
            attachments.push(format!("[Image #{}] => {}", &cap[1], p.display()));
        }
    }
    if attachments.is_empty() {
        return input.to_string();
    }
    format!(
        "{}\n\n<attached-images>\nThese placeholders map to local image files:\n{}\nUse an available visual Skill from <skill-index> when image understanding is needed, and pass the corresponding absolute path to that Skill. The runtime does not inspect these images automatically.\n</attached-images>",
        input,
        attachments.join("\n")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncate_for_replay_preserves_utf8() {
        assert_eq!(truncate_for_replay("你好世界abc", 2), "你好...");
    }

    #[test]
    fn first_line_splits_on_newline() {
        assert_eq!(first_line("one\ntwo"), "one");
    }
}
