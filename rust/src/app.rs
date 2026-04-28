use crate::assets::TOOLS_JSON;
use crate::config::{Config, OutputFormat, api_url, apply_provider_defaults, parse_args};
use crate::conversation::{Store, ToolResult, build_tool_call_summary, first_line};
use crate::httpclient::{HTTPError, StreamClient};
use crate::prompt;
use crate::protocol::{ErrorEvent, Event, RetryEvent, StopEvent, TextEvent, ThinkingEvent, ToolCallEvent, UsageEvent};
use crate::provider;
use crate::session::{self, Paths};
use crate::tools;
use anyhow::{Result, anyhow, bail};
use rustyline::DefaultEditor;
use rustyline::error::ReadlineError;
use serde_json::{Value, json};
use std::fs;
use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type TransportRef = Arc<dyn crate::transport::Transport>;

pub fn run(args: Vec<String>) -> Result<()> {
    let mut cfg = match parse_args(args) {
        Ok(v) => v,
        Err(e) if e.to_string() == "__HELP__" => {
            print_usage();
            return Ok(());
        }
        Err(e) => return Err(e),
    };

    let cwd = std::env::current_dir()?;
    let home = PathBuf::from(std::env::var("BASH_AGENT_HOME")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| String::from(".")));

    if cfg.list_sessions {
        list_sessions(&home, &cwd)?;
        return Ok(());
    }

    apply_provider_defaults(&mut cfg)?;

    let mut rt = Runtime::new(cfg, cwd, home)?;

    if rt.cfg.interactive || (rt.cfg.prompt.is_empty() && io::stdin().is_terminal()) {
        rt.cfg.interactive = true;
        return rt.interactive_mode();
    }

    if !rt.cfg.prompt.is_empty() {
        return rt.agent_loop(rt.cfg.prompt.clone());
    }

    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    rt.agent_loop(input)
}

struct Runtime {
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
    esc_stop: Option<Arc<AtomicBool>>,
    esc_thread: Option<JoinHandle<()>>,
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
}

struct CancelReader<R> {
    inner: R,
    cancel: Arc<AtomicBool>,
}

impl<R: Read> Read for CancelReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.cancel.load(Ordering::SeqCst) {
            return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "cancelled"));
        }
        let n = self.inner.read(buf)?;
        if self.cancel.load(Ordering::SeqCst) {
            return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, "cancelled"));
        }
        Ok(n)
    }
}

impl LlmStream {
    fn next_event(&mut self) -> Result<Option<Event>> {
        if self.finished {
            return Ok(None);
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
}

impl Runtime {
    fn new(mut cfg: Config, cwd: PathBuf, home: PathBuf) -> Result<Self> {
        let mut sid = cfg.session_id.clone();
        if sid.is_empty() && cfg.continue_session {
            sid = session::continue_session(&home, &cwd).unwrap_or_default();
        }
        if sid.is_empty() {
            sid = chrono_like_now();
        }
        cfg.session_id = sid.clone();
        let paths = session::paths_for(&home, &cwd, &sid);
        session::ensure_dir(&paths.base_dir)?;
        session::ensure_dir(&paths.session_dir)?;
        let new_session = !paths.events.exists();
        for f in [&paths.conversation, &paths.events, &paths.summary, &paths.todo, &paths.plan] {
            touch(f)?;
        }

        let conv = Store {
            path: paths.conversation.clone(),
        };
        conv.ensure()?;

        let tools_json: Vec<Value> = serde_json::from_str(TOOLS_JSON)?;
        let api_url = api_url(&cfg);
        let interrupted = Arc::new(AtomicBool::new(false));
        let transport = Arc::from(crate::transport::new_transport(&cfg));

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
            esc_stop: None,
            esc_thread: None,
        };

        if new_session {
            let _ = rt.append_event(json!({"type":"session_start","session_id":sid}));
        }

        Ok(rt)
    }

    fn interactive_mode(&mut self) -> Result<()> {
        self.info("bash-agent interactive mode (type 'exit' or Ctrl+D to quit)");
        self.replay_last_turns();
        let history_path = self.home.join(".bash-agent/history");
        if let Some(parent) = history_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut rl = DefaultEditor::new()?;
        if let Ok(file) = fs::File::open(&history_path) {
            for line in BufReader::new(file).lines() {
                let line = line?;
                let trimmed = line.trim();
                if trimmed.is_empty() || trimmed.starts_with('#') {
                    continue;
                }
                let _ = rl.add_history_entry(trimmed);
            }
        }
        loop {
            let line = match rl.readline("> ") {
                Ok(s) => s.trim_end().to_string(),
                Err(ReadlineError::Interrupted) => continue,
                Err(ReadlineError::Eof) => break,
                Err(e) => return Err(anyhow!("interactive input error: {e}")),
            };
            if line.is_empty() {
                continue;
            }
            if line == "exit" || line == "quit" {
                break;
            }
            let _ = rl.add_history_entry(line.as_str());
            let mut file = fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&history_path)?;
            writeln!(file, "{line}")?;
            if let Err(e) = self.agent_loop(line) {
                self.error(&e.to_string());
            }
        }
        self.info("Goodbye!");
        if !self.cfg.session_id.is_empty() {
            eprintln!("\x1b[90mResume with: --session {}  or  --continue\x1b[0m", self.cfg.session_id);
        }
        Ok(())
    }

    fn agent_loop(&mut self, user_input: String) -> Result<()> {
        self.agent_loop_stream(user_input)
    }

    fn agent_loop_stream(&mut self, user_input: String) -> Result<()> {
        self.interrupted.store(false, Ordering::SeqCst);
        self.start_esc_interrupt_listener();
        let result = (|| -> Result<()> {
            self.conv.add_user(&user_input)?;
            self.append_event(json!({"type":"user_input","content":user_input}))?;

            let mut turn = 0;
            let mut ds = DisplayState {
                last_char: String::from("\n"),
                prev_was_thinking: false,
            };

            while turn < self.cfg.max_turns {
                turn += 1;
                let mut text = String::new();
                let mut thinking = String::new();
                let mut calls: Vec<ToolCallEvent> = Vec::new();
                let mut tool_results: Vec<ToolResult> = Vec::new();
                let mut stop = String::new();
                let mut loop_error = String::new();

                let runner = tools::Runner {
                    config: self.cfg.clone(),
                    todo_file: self.paths.todo.clone(),
                    cwd: self.cwd.clone(),
                    home: self.home.clone(),
                };

                let mut stream = match self.llm_stream() {
                    Ok(s) => s,
                    Err(e) => {
                        // Pre-stream HTTP/network error — record to events.jsonl before returning
                        let err_msg = e.to_string();
                        let _ = self.emit_and_append_event(json!({"type":"error","message":&err_msg}));
                        let _ = self.emit_and_append_event(json!({"type":"stop","reason":"error"}));
                        if !self.is_stream_json_mode() {
                            self.error(&err_msg);
                        }
                        return Err(e);
                    }
                };
                while let Some(evt) = stream.next_event()? {
                    if self.interrupted.load(Ordering::SeqCst) {
                        stop = "interrupted".to_string();
                        break;
                    }
                    if self.cfg.verbose {
                        self.debug(&format!("<{}>", evt.render()));
                    }
                    match evt {
                        Event::Thinking(ThinkingEvent { content }) => {
                            self.display_event(
                                &mut ds,
                                DisplayEvent::Thinking(content.clone()),
                            )?;
                            thinking.push_str(&content);
                        }
                        Event::Text(TextEvent { content }) => {
                            self.display_event(
                                &mut ds,
                                DisplayEvent::Text(content.clone()),
                            )?;
                            text.push_str(&content);
                        }
                        Event::ToolCall(call) => {
                            self.display_event(
                                &mut ds,
                                DisplayEvent::ToolCall(call.clone()),
                            )?;
                            calls.push(call.clone());

                            if self.interrupted.load(Ordering::SeqCst) {
                                stop = "interrupted".to_string();
                                break;
                            }
                            let dispatch_result = runner.dispatch(&call.name, &call.input_json);
                            if self.interrupted.load(Ordering::SeqCst) {
                                stop = "interrupted".to_string();
                                break;
                            }
                            let mut output = match dispatch_result {
                                Ok(v) => v,
                                Err(e) => format!("Error: tool execution failed: {e}"),
                            };
                            output = tools::format_tool_result(&output, self.cfg.tool_result_max_bytes);
                            let mut conv_content = String::new();
                            if call.name == "Edit" {
                                // Tool output = summary_line + "\n" + colorized_diff + "\n" (matches bash tool_edit)
                                // Conv file gets summary only (matches bash: result_for_conv = first line)
                                conv_content = first_line(&output).to_string();
                            } else if call.name == "Read" || call.name == "Write" {
                                // Prepend file summary to content (matches bash behavior)
                                let file_summary = Store::file_tool_result_summary(
                                    &call.name,
                                    call.fields.get("path").map(String::as_str).unwrap_or(""),
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
                            self.display_event(
                                &mut ds,
                                DisplayEvent::ToolResult(tool_result.clone()),
                            )?;
                            tool_results.push(tool_result);

                            if call.name == "TodoWrite" {
                                if let Ok(data) = fs::read_to_string(&self.paths.todo) {
                                    if !data.trim().is_empty() {
                                        let trimmed = data.trim_end().to_string();
                                        self.append_event(json!({"type":"todo_update","content":trimmed}))?;
                                        if self.is_stream_json_mode() {
                                            self.emit_stream(json!({"type":"todo_update","content":trimmed}))?;
                                        }
                                    }
                                }
                            }
                        }
                        Event::Usage(usage) => {
                            self.display_event(&mut ds, DisplayEvent::Usage(usage))?;
                        }
                        Event::Stop(StopEvent { reason }) => {
                            stop = reason.clone();
                            self.display_event(&mut ds, DisplayEvent::Stop(reason))?;
                            break;
                        }
                        Event::Error(ErrorEvent { message }) => {
                            loop_error = message.clone();
                            stop = "error".to_string();
                            let _ = self.display_event(&mut ds, DisplayEvent::Error(message));
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
                if !self.interrupted.load(Ordering::SeqCst) {
                    self.conv.add_assistant(&text, &thinking, &calls)?;
                    if !tool_results.is_empty() {
                        self.conv.add_tool_results(&tool_results)?;
                        // Note: granular tool_result events already written by display_event via emit_and_append_event
                    }
                    let _ = self.compact_context_window("auto", false);
                    // tool_use/tool_calls → loop continues; anything else → break
                    if stop.as_str() != "tool_use" && stop.as_str() != "tool_calls" {
                        return Ok(());
                    }
                } else {
                    // Match bash: write stop interrupted event to events.jsonl (always)
                    // and to stdout if stream-json mode
                    let _ = self.emit_and_append_event(json!({"type":"stop","reason":"interrupted"}));
                    if self.is_stream_json_mode() {
                        // In stream-json mode the JSON was already printed by emit_and_append_event
                    } else {
                        if ds.last_char != "\n" {
                            self.write_human("\n")?;
                        }
                        self.info("Interrupted.");
                    }
                    return Ok(());
                }
            }
            self.error(&format!("Max turns ({}) reached", self.cfg.max_turns));
            Ok(())
        })();
        self.stop_esc_interrupt_listener();
        result
    }

    /// emit_and_append_event writes an event to events.jsonl (always) and to
    /// stdout (only in stream-json mode). Mirrors Go's emitAndAppendEvent and
    /// bash's session_append_line + (stream-json || human display) pattern.
    fn emit_and_append_event(&self, value: Value) -> Result<()> {
        self.append_event(value.clone())?;
        if self.is_stream_json_mode() {
            self.emit_stream(value)?;
        }
        Ok(())
    }

    fn display_event(&self, ds: &mut DisplayState, evt: DisplayEvent) -> Result<()> {
        match evt {
            DisplayEvent::Thinking(content) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                self.emit_and_append_event(json!({"type":"thinking","content":content.clone()}))?;
                if !self.is_stream_json_mode() {
                    // Gray color for thinking output
                    self.write_human(&format!("\x1b[90m{}\x1b[0m", content))?;
                    let display_content = normalize_display_text(&content, self.cfg.interactive);
                    if display_content.ends_with('\n') {
                        ds.last_char = "\n".to_string();
                    } else if let Some(c) = display_content.chars().last() {
                        ds.last_char = c.to_string();
                    }
                }
                ds.prev_was_thinking = true;
            }
            DisplayEvent::Text(content) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                self.emit_and_append_event(json!({"type":"text","content":content.clone()}))?;
                if !self.is_stream_json_mode() {
                    // Insert newline when transitioning from thinking to text
                    if ds.prev_was_thinking && ds.last_char != "\n" {
                        self.write_human("\n")?;
                        ds.last_char = "\n".to_string();
                    }
                    self.write_human(&content)?;
                    let display_content = normalize_display_text(&content, self.cfg.interactive);
                    if display_content.ends_with('\n') {
                        ds.last_char = "\n".to_string();
                    } else if let Some(c) = display_content.chars().last() {
                        ds.last_char = c.to_string();
                    }
                }
                ds.prev_was_thinking = false;
            }
            DisplayEvent::ToolCall(call) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                self.emit_and_append_event(json!({
                    "type":"tool_call",
                    "name": call.name,
                    "id": call.id,
                    "input": call.input_json,
                }))?;
                if !self.is_stream_json_mode() {
                    // display_ensure_newline (match bash)
                    if ds.last_char != "\n" {
                        self.write_human("\n")?;
                    }
                    ds.last_char = "\n".to_string();
                    self.write_human(&format!(
                        "\x1b[33m[tool] {}\x1b[0m\n",
                        build_tool_call_summary(&call.name, &call.fields)
                    ))?;
                }
            }
            DisplayEvent::Usage(UsageEvent {
                input_tokens,
                output_tokens,
                cache_input_tokens,
            }) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                self.emit_and_append_event(json!({
                    "type":"usage",
                    "input_tokens":input_tokens,
                    "output_tokens":output_tokens,
                    "cache_input_tokens":cache_input_tokens
                }))?;
                // No human display for usage events
            }
            DisplayEvent::Stop(reason) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                self.emit_and_append_event(json!({"type":"stop","reason":&reason}))?;
                if !self.is_stream_json_mode() && ds.last_char != "\n" {
                    self.write_human("\n")?;
                    ds.last_char = "\n".to_string();
                }
            }
            DisplayEvent::Error(message) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                let _ = self.emit_and_append_event(json!({"type":"error","message":&message}));
                return Err(anyhow!(message));
            }
            DisplayEvent::ToolResult(result) => {
                // Always write to events.jsonl, and to stdout if stream-json mode
                self.emit_and_append_event(json!({
                    "type":"tool_result",
                    "tool_use_id": result.tool_use_id,
                    "name": result.tool_name,
                    "content": result.content,
                }))?;
                if !self.is_stream_json_mode() && !result.content.is_empty() {
                    // Match bash display_event TOOL_RESULT exactly:
                    // Content already finalized at stream layer — just use as-is
                    let tr_text = if result.tool_name == "Edit" {
                        // Content = summary_line + "\n" + colorized_diff + "\n" (from tool layer)
                        let mut out = normalize_display_text(&result.content, self.cfg.interactive);
                        if !out.ends_with('\n') {
                            out.push('\n');
                        }
                        out
                    } else if result.tool_name == "Read" || result.tool_name == "Write" {
                        // Summary already prepended; use first line for display
                        first_line(&result.content).to_string() + "\n"
                    } else {
                        normalize_display_text(&result.content, self.cfg.interactive) + "\n"
                    };
                    // Insert newline when transitioning from thinking to text
                    if ds.prev_was_thinking && ds.last_char != "\n" {
                        self.write_human("\n")?;
                        ds.last_char = "\n".to_string();
                    }
                    ds.prev_was_thinking = false;
                    if !tr_text.is_empty() {
                        self.write_human(&tr_text)?;
                        if tr_text.ends_with('\n') {
                            ds.last_char = "\n".to_string();
                        } else {
                            ds.last_char = tr_text.chars().last().map(|c| c.to_string()).unwrap_or_else(|| "\n".to_string());
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn llm_stream(&self) -> Result<LlmStream> {
        let lines = self.conv.lines()?;
        let system_prompt = prompt::Builder {
            cwd: self.cwd.clone(),
            home: self.home.clone(),
            skills: self.cfg.skills.clone(),
            summary_file: self.paths.summary.clone(),
            todo_file: self.paths.todo.clone(),
            plan_file: self.paths.plan.clone(),
        }
        .build_system_prompt()?;

        let claude_body = provider::build_claude_request(
            &self.cfg,
            &lines,
            &self.tools_json,
            &system_prompt,
            self.cfg.max_tokens,
            self.cfg.thinking_budget,
        )?;
        let body = self.transport.convert_body(&claude_body)?;
        if self.cfg.verbose {
            self.debug(&format!("Request body ({}KB): {:.200}...", body.len() / 1024, String::from_utf8_lossy(&body)));
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
        let cancel = Arc::new(AtomicBool::new(false));
        let cancel_thread = cancel.clone();
        let transport = self.transport.clone();
        let _reader_thread = std::thread::spawn(move || {
            let reader = CancelReader { inner: resp, cancel: cancel_thread.clone() };
            let mut send = |evt: Event| -> Result<()> {
                tx.send(StreamMsg::Event(evt)).map_err(|e| anyhow!(e.to_string()))
            };
            let parse_res = transport.parse_sse(Box::new(reader), &mut send);
            let _ = tx.send(StreamMsg::Done(parse_res.map_err(|err| anyhow!("sse_parse: {err}"))));
        });

        Ok(LlmStream { rx, finished: false, cancel })
    }

    fn start_esc_interrupt_listener(&mut self) {
        if !self.cfg.interactive {
            return;
        }
        if !Path::new("/dev/tty").exists() {
            return;
        }
        self.stop_esc_interrupt_listener();
        let stop = Arc::new(AtomicBool::new(false));
        let stop_flag = stop.clone();
        let interrupted = self.interrupted.clone();
        let handle = std::thread::spawn(move || {
            use crossterm::event::{self, Event, KeyCode};
            use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
            if enable_raw_mode().is_err() {
                return;
            }
            while !stop_flag.load(Ordering::SeqCst) {
                match event::poll(Duration::from_millis(100)) {
                    Ok(true) => {
                        if let Ok(Event::Key(key)) = event::read() {
                            if key.code == KeyCode::Esc {
                                interrupted.store(true, Ordering::SeqCst);
                            }
                        }
                    }
                    Ok(false) => {}
                    Err(_) => break,
                }
            }
            let _ = disable_raw_mode();
        });
        self.esc_stop = Some(stop);
        self.esc_thread = Some(handle);
    }

    fn stop_esc_interrupt_listener(&mut self) {
        if let Some(stop) = self.esc_stop.take() {
            stop.store(true, Ordering::SeqCst);
        }
        if let Some(handle) = self.esc_thread.take() {
            let _ = handle.join();
        }
    }

    fn compact_context_window(&mut self, trigger: &str, force: bool) -> Result<bool> {
        let total_bytes = self.conv.total_bytes()?;
        if !force && total_bytes <= self.cfg.max_context_bytes {
            return Ok(false);
        }
        let mut target_keep =
            self.cfg.max_context_bytes * (self.cfg.max_context_keep_pct as usize) / 100;
        if target_keep < 1 {
            target_keep = 1;
        }
        let keep_lines = self.conv.keep_line_count(target_keep)?;
        let total_lines = self.conv.total_lines()?;
        if total_lines <= keep_lines {
            return Ok(false);
        }
        let drop = total_lines - keep_lines;

        let all = self.conv.lines()?;
        let mut dropped = String::new();
        for line in &all[..drop] {
            dropped.push_str(&serde_json::to_string(line)?);
            dropped.push('\n');
        }

        let current_summary = fs::read_to_string(&self.paths.summary).unwrap_or_default();

        if trigger == "manual" && self.api_url.is_empty() {
            apply_provider_defaults(&mut self.cfg)?;
            self.api_url = api_url(&self.cfg);
        }

        let summary = self.run_summary_call(&current_summary, dropped.trim_end())?;
        fs::write(&self.paths.summary, format!("{summary}\n"))?;
        self.conv.trim_keep_last(keep_lines)?;

        if self.is_stream_json_mode() {
            let _ = self
                .emit_stream(json!({"type":"context_update","kind":"compact","trigger":trigger}));
        } else if trigger == "auto" {
            self.info("Context compacted automatically.");
        }
        Ok(true)
    }

    fn run_summary_call(
        &mut self,
        current_summary: &str,
        dropped_messages: &str,
    ) -> Result<String> {
        let user_prompt =
            prompt::build_compact_summary_user_prompt(current_summary, dropped_messages);
        let messages = vec![json!({"role":"user","content":user_prompt})];
        // Disable thinking for summary calls (not needed, saves tokens)
        let claude_body = provider::build_claude_request(
            &self.cfg,
            &messages,
            &[],
            &prompt::build_compact_summary_system_prompt(),
            self.cfg.summary_max_tokens,
            0,
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
        let mut out = String::new();
        let mut parse_emit = |evt: Event| -> Result<()> {
            match evt {
                Event::Text(TextEvent { content }) => out.push_str(&content),
                Event::Error(ErrorEvent { message }) => return Err(anyhow!(message)),
                _ => {}
            }
            Ok(())
        };
        self.transport.parse_sse(Box::new(resp), &mut parse_emit)?;
        if out.is_empty() {
            bail!("failed to generate context summary");
        }
        Ok(out)
    }

    fn headers(&self) -> Vec<(String, String)> {
        let mut h = vec![
            ("Content-Type".to_string(), "application/json".to_string()),
            ("User-Agent".to_string(), "claude-cli/1.0.33 (max, cli)".to_string()),
        ];
        match self.cfg.provider.as_str() {
            "claude" => {
                h.push(("x-api-key".to_string(), self.cfg.api_key.clone()));
                h.push(("anthropic-version".to_string(), "2023-06-01".to_string()));
                h.push(("x-app".to_string(), "cli".to_string()));
            }
            "openai" => {
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
        let line = serde_json::to_string(&value)?;
        use std::io::Write;
        let mut f = fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(&self.paths.events)?;
        writeln!(f, "{line}")?;
        Ok(())
    }

    fn is_stream_json_mode(&self) -> bool {
        self.cfg.output_format == OutputFormat::StreamJson
    }

    fn emit_stream(&self, value: Value) -> Result<()> {
        println!("{}", serde_json::to_string(&value)?);
        Ok(())
    }

    fn write_human(&self, s: &str) -> Result<()> {
        print!("{}", normalize_display_text(s, self.cfg.interactive));
        io::stdout().flush()?;
        Ok(())
    }

    fn info(&self, msg: &str) {
        if self.cfg.interactive {
            eprint!("\x1b[36m{msg}\x1b[0m\r\n");
            let _ = io::stderr().flush();
        } else {
            eprintln!("\x1b[36m{msg}\x1b[0m");
        }
    }

    /// display_replay_event mirrors bash's display_event exactly for replay purposes.
    fn display_replay_event(&self, ds: &mut DisplayState, evt_type: &str, fields: &std::collections::HashMap<&str, &str>) {
        match evt_type {
            "TEXT" => {
                let content = fields.get("content").copied().unwrap_or("");
                // Insert newline when transitioning from thinking to text
                if ds.prev_was_thinking && ds.last_char != "\n" {
                    self.write_human("\n").ok();
                    ds.last_char = "\n".to_string();
                }
                ds.prev_was_thinking = false;
                if !content.is_empty() {
                    self.write_human(content).ok();
                    if content.ends_with('\n') {
                        ds.last_char = "\n".to_string();
                    } else {
                        ds.last_char = content.chars().last().map(|c| c.to_string()).unwrap_or("\n".to_string());
                    }
                }
            }
            "THINKING" => {
                let content = fields.get("content").copied().unwrap_or("");
                if !content.is_empty() {
                    self.write_human(&format!("\x1b[90m{}\x1b[0m", content)).ok();
                    if content.ends_with('\n') {
                        ds.last_char = "\n".to_string();
                    } else {
                        ds.last_char = content.chars().last().map(|c| c.to_string()).unwrap_or("\n".to_string());
                    }
                }
                ds.prev_was_thinking = true;
            }
            "TOOL_CALL" => {
                // display_ensure_newline
                if ds.last_char != "\n" {
                    self.write_human("\n").ok();
                }
                let name = fields.get("name").copied().unwrap_or("");
                let mut summary_fields = std::collections::BTreeMap::new();
                for (k, v) in fields {
                    if *k != "name" {
                        summary_fields.insert(k.to_string(), v.to_string());
                    }
                }
                let summary = build_tool_call_summary(name, &summary_fields);
                self.write_human(&format!("\x1b[33m[tool] {}\x1b[0m\n", summary)).ok();
                ds.last_char = "\n".to_string();
                ds.prev_was_thinking = false;
            }
            "TOOL_RESULT" => {
                let name = fields.get("name").copied().unwrap_or("");
                let content = fields.get("content").copied().unwrap_or("");
                // Content already has colorized diff from tool layer — use as-is
                let tr_text = if name == "Edit" {
                    content.to_string() + "\n"
                } else if name == "Read" || name == "Write" {
                    // Summary already prepended; use first line
                    content.lines().next().unwrap_or("").to_string() + "\n"
                } else {
                    content.to_string() + "\n"
                };
                // Insert newline when transitioning from thinking to text
                if ds.prev_was_thinking && ds.last_char != "\n" {
                    self.write_human("\n").ok();
                    ds.last_char = "\n".to_string();
                }
                ds.prev_was_thinking = false;
                if !tr_text.is_empty() {
                    self.write_human(&tr_text).ok();
                    if tr_text.ends_with('\n') {
                        ds.last_char = "\n".to_string();
                    } else {
                        ds.last_char = tr_text.chars().last().map(|c| c.to_string()).unwrap_or("\n".to_string());
                    }
                }
            }
            "USER_MESSAGE" => {
                // display_ensure_newline
                if ds.last_char != "\n" {
                    self.write_human("\n").ok();
                }
                let mut content = fields.get("content").copied().unwrap_or("");
                if content.chars().count() > 80 {
                    content = &content[..content.char_indices().take(77).last().map(|(i, _)| i).unwrap_or(0)];
                    // Can't easily truncate by chars, use owned
                }
                let display = if content.chars().count() > 80 {
                    let truncated: String = content.chars().take(77).collect();
                    format!("{}...", truncated)
                } else {
                    content.to_string()
                };
                self.write_human(&format!("\x1b[32m> {}\x1b[0m\n", display)).ok();
                ds.last_char = "\n".to_string();
                ds.prev_was_thinking = false;
            }
            "STOP" => {
                if ds.last_char != "\n" {
                    self.write_human("\n").ok();
                    ds.last_char = "\n".to_string();
                }
            }
            "ERROR" => {
                if ds.last_char != "\n" {
                    self.write_human("\n").ok();
                }
                let msg = fields.get("message").copied().unwrap_or("");
                eprintln!("\x1b[31mError: {}\x1b[0m", msg);
            }
            _ => {}
        }
    }

    fn replay_last_turns(&self) {
        let events_path = &self.paths.events;
        if !events_path.exists() {
            return;
        }
        let data = match fs::read_to_string(events_path) {
            Ok(d) => d,
            Err(_) => return,
        };
        let events: Vec<Value> = data
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect();
        if events.is_empty() {
            return;
        }

        // Find boundaries of "turns" — each user_input event starts a turn
        let mut turn_starts: Vec<usize> = Vec::new();
        for (i, evt) in events.iter().enumerate() {
            let t = evt.get("type").and_then(Value::as_str).unwrap_or("");
            if t == "user_input" || t == "user_message" {
                turn_starts.push(i);
            }
        }
        if turn_starts.is_empty() {
            return;
        }

        // Keep last 10 turns (match bash)
        let keep = turn_starts.len().saturating_sub(10);
        let start_idx = if keep < turn_starts.len() { turn_starts[keep] } else { 0 };
        let had_turns = turn_starts.len().saturating_sub(keep) > 0;

        let mut ds = DisplayState {
            last_char: "\n".to_string(),
            prev_was_thinking: false,
        };
        let mut acc_text = String::new();
        let mut acc_thinking = String::new();

        for evt in &events[start_idx..] {
            let evt_type = evt.get("type").and_then(Value::as_str).unwrap_or("");
            match evt_type {
                "session_start" | "usage" | "stop" | "retry" => continue,
                "user_input" | "user_message" => {
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "both");
                    let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
                    if content.is_empty() {
                        continue;
                    }
                    self.display_replay_event(&mut ds, "USER_MESSAGE", &std::collections::HashMap::from([("content", content)]));
                }
                "thinking" => {
                    // Flush text, accumulate thinking (match bash event_replay.awk)
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "text");
                    let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
                    acc_thinking.push_str(content);
                }
                "text" => {
                    // Flush thinking, accumulate text (match bash event_replay.awk)
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "thinking");
                    let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
                    acc_text.push_str(content);
                }
                "tool_call" => {
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "both");
                    let name = evt.get("name").and_then(Value::as_str).unwrap_or("");
                    let default_input = json!({});
                    let input = evt.get("input").unwrap_or(&default_input);
                    let fields = parse_input_fields(input);
                    let mut map = std::collections::HashMap::new();
                    map.insert("name", name.to_string());
                    for (k, v) in &fields {
                        map.insert(k.as_str(), v.as_str().to_string());
                    }
                    let str_map: std::collections::HashMap<&str, &str> = map.iter().map(|(k, v)| (*k, v.as_str())).collect();
                    self.display_replay_event(&mut ds, "TOOL_CALL", &str_map);
                }
                "tool_result" => {
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "both");
                    let name = evt.get("name").and_then(Value::as_str).unwrap_or("");
                    let content = evt.get("content").and_then(Value::as_str).unwrap_or("");
                    let mut display = content.to_string();
                    // Truncate for replay (match bash: 200 chars)
                    if display.len() > 200 {
                        display.truncate(200);
                        display.push_str("...");
                    }
                    self.display_replay_event(&mut ds, "TOOL_RESULT", &std::collections::HashMap::from([
                        ("name", name),
                        ("content", display.as_str()),
                    ]));
                }
                "error" => {
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "both");
                    let msg = evt.get("message").and_then(Value::as_str).unwrap_or("");
                    self.display_replay_event(&mut ds, "ERROR", &std::collections::HashMap::from([("message", msg)]));
                }
                "assistant_message" => {
                    // Legacy format: emit TEXT + TOOL_CALL per tool_call (match bash event_replay.awk)
                    Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "both");
                    let text = evt.get("text").and_then(Value::as_str).unwrap_or("");
                    if !text.is_empty() {
                        self.display_replay_event(&mut ds, "TEXT", &std::collections::HashMap::from([("content", text)]));
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
                            let str_map: std::collections::HashMap<&str, &str> = map.iter().map(|(k, v)| (*k, v.as_str())).collect();
                            self.display_replay_event(&mut ds, "TOOL_CALL", &str_map);
                        }
                    }
                }
                _ => {}
            }
        }
        Self::flush_acc(self, &mut acc_thinking, &mut acc_text, &mut ds, "both");
        if had_turns {
            self.write_human("\n").ok();
        }
    }

    /// Flush accumulated text/thinking through display_replay_event.
    /// `which`: "thinking" = flush thinking only, "text" = flush text only, "both" = flush both.
    fn flush_acc(
        this: &Self,
        acc_thinking: &mut String,
        acc_text: &mut String,
        ds: &mut DisplayState,
        which: &str,
    ) {
        if which == "thinking" || which == "both" {
            if !acc_thinking.is_empty() {
                let content = std::mem::take(acc_thinking);
                this.display_replay_event(ds, "THINKING", &std::collections::HashMap::from([("content", content.as_str())]));
            }
        }
        if which == "text" || which == "both" {
            if !acc_text.is_empty() {
                let content = std::mem::take(acc_text);
                this.display_replay_event(ds, "TEXT", &std::collections::HashMap::from([("content", content.as_str())]));
            }
        }
    }

    fn error(&self, msg: &str) {
        if self.cfg.interactive {
            eprint!("\x1b[31mError: {msg}\x1b[0m\r\n");
            let _ = io::stderr().flush();
        } else {
            eprintln!("\x1b[31mError: {msg}\x1b[0m");
        }
    }

    fn debug(&self, msg: &str) {
        if self.cfg.verbose {
            eprintln!("[debug] {msg}");
        }
    }
}

fn normalize_display_text(s: &str, interactive: bool) -> String {
    let normalized = s.replace("\r\n", "\n").replace('\r', "\n");
    if interactive {
        normalized.replace('\n', "\r\n")
    } else {
        normalized
    }
}



fn touch(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::File::create(path)?;
    }
    Ok(())
}

fn format_system_time(st: &SystemTime) -> String {
    use time::macros::format_description;
    let dt: time::OffsetDateTime = match (*st).try_into() {
        Ok(dt) => dt,
        Err(_) => return format!("{:?}", st),
    };
    static FMT: &[time::format_description::FormatItem<'_>] =
        format_description!("[year]-[month]-[day] [hour]:[minute]");
    dt.format(FMT).unwrap_or_else(|_| format!("{:?}", st))
}

fn chrono_like_now() -> String {
    // Format: YYYYMMDD-HHmmss-XXXX (random 4-hex suffix to avoid collisions in fast tests)
    use time::format_description::FormatItem;
    use time::macros::format_description;
    static FMT: &[FormatItem<'_>] = format_description!("[year][month][day]-[hour][minute][second]");
    let base = time::OffsetDateTime::now_utc()
        .format(FMT)
        .unwrap_or_else(|_| format!("{}", std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)));
    let rand_suffix = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u16)
        .unwrap_or(0);
    format!("{}-{:04x}", base, rand_suffix)
}

fn list_sessions(home: &Path, cwd: &Path) -> Result<()> {
    let dir = home
        .join(".bash-agent/projects")
        .join(session::project_key(cwd));
    let entries = fs::read_dir(&dir);
    if entries.is_err() {
        println!("No sessions found.");
        return Ok(());
    }
    struct Row {
        name: String,
        ts: SystemTime,
        summary: String,
    }
    let mut rows: Vec<Row> = Vec::new();
    for e in entries? {
        let e = e?;
        let path = e.path();
        if !path.is_dir() {
            continue;
        }
        let session_name = e.file_name().to_string_lossy().to_string();
        let summary_path = path.join("summary.txt");
        let mut summary = String::new();
        if let Ok(data) = fs::read_to_string(&summary_path) {
            for line in data.lines() {
                let trimmed = line.trim();
                if !trimmed.is_empty() {
                    summary = trimmed.to_string();
                    break;
                }
            }
        }
        rows.push(Row {
            name: session_name,
            ts: e.metadata()?.modified().unwrap_or(UNIX_EPOCH),
            summary,
        });
    }
    if rows.is_empty() {
        println!("No sessions found.");
        return Ok(());
    }
    rows.sort_by(|a, b| b.ts.cmp(&a.ts));
    println!("{:<40} {:<16} PREVIEW", "NAME", "MODIFIED");
    for row in rows {
        let mut preview = row.summary;
        if preview.len() > 60 {
            preview.truncate(57);
            preview.push_str("...");
        }
        let formatted = format_system_time(&row.ts);
        println!("{:<40} {:<16} {}", row.name, formatted, preview);
    }
    Ok(())
}

fn print_usage() {
    println!("Usage: rustagent [options] [prompt]");
    println!();
    println!("Options:");
    println!("  -p, --provider PROV     LLM provider: claude | openai (default: claude)");
    println!("  -m, --model MODEL       Model name");
    println!("  --max-tokens N          Max output tokens (default: 4096)");
    println!("  --tool-timeout N        Tool execution timeout in seconds (default: 600)");
    println!(
        "  --skill NAME            Load skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)"
    );
    println!("  --max-turns N           Max agent turns (default: 40)");
    println!("  --max-context N         Max stored context bytes before compact (default: 200000)");
    println!("  --api-key KEY           API key (default from env)");
    println!("  --base-url URL          Override API base URL");
    println!("  --output-format FMT     Output format: human | stream-json");
    println!("  --print                 Alias for --output-format stream-json");
    println!("  --session [NAME]        Use named session");
    println!("  --continue              Continue most recent session");
    println!("  --list-sessions         List saved sessions");
    println!("  -v, --verbose           Verbose mode");
    println!("  -i, --interactive       Interactive mode (REPL)");
    println!("  -h, --help              Show this help");
}

fn parse_input_fields(input: &Value) -> std::collections::BTreeMap<String, String> {
    let mut fields = std::collections::BTreeMap::new();
    if let Some(obj) = input.as_object() {
        for (k, v) in obj {
            match v {
                Value::String(s) => { fields.insert(k.clone(), s.clone()); }
                _ => { fields.insert(k.clone(), v.to_string()); }
            }
        }
    }
    fields
}
