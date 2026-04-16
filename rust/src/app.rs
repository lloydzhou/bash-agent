use crate::assets::TOOLS_JSON;
use crate::config::{Config, OutputFormat, api_url, apply_provider_defaults, parse_args};
use crate::conversation::{Store, ToolResult, build_tool_call_summary, edit_diff_summary};
use crate::httpclient::{HTTPError, StreamClient};
use crate::prompt;
use crate::protocol::{ErrorEvent, Event, StopEvent, TextEvent, ThinkingEvent, ToolCallEvent, UsageEvent};
use crate::provider;
use crate::session::{self, Paths};
use crate::sse;
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
    let home = PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| String::from(".")));

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
    tmp_dir: PathBuf,
    tools_json: Vec<Value>,
    http: StreamClient,
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
        let tmp_dir = std::env::temp_dir().join(format!(
            "rustagent.{}",
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
        ));
        fs::create_dir_all(&tmp_dir)?;

        let paths = if cfg.session_mode {
            let mut sid = cfg.session_id.clone();
            if sid.is_empty() && cfg.continue_session {
                sid = session::continue_session(&home, &cwd).unwrap_or_default();
            }
            if sid.is_empty() {
                sid = chrono_like_now();
            }
            cfg.session_id = sid.clone();
            let p = session::paths_for(&home, &cwd, &sid);
            session::ensure_dir(&p.base_dir)?;
            for f in [&p.conversation, &p.events, &p.summary, &p.todo] {
                touch(f)?;
            }
            p
        } else {
            let p = Paths {
                base_dir: tmp_dir.clone(),
                conversation: tmp_dir.join("conv.jsonl"),
                events: tmp_dir.join("events.jsonl"),
                summary: tmp_dir.join("summary.txt"),
                todo: tmp_dir.join("todo.md"),
            };
            for f in [&p.conversation, &p.events, &p.summary, &p.todo] {
                touch(f)?;
            }
            p
        };

        let conv = Store {
            path: paths.conversation.clone(),
        };
        conv.ensure()?;

        let tools_json: Vec<Value> = serde_json::from_str(TOOLS_JSON)?;
        let api_url = api_url(&cfg);
        let interrupted = Arc::new(AtomicBool::new(false));

        Ok(Self {
            cfg,
            cwd,
            home,
            api_url,
            paths,
            conv,
            tmp_dir,
            tools_json,
            http: StreamClient::new()?,
            interrupted,
            esc_stop: None,
            esc_thread: None,
        })
    }

    fn interactive_mode(&mut self) -> Result<()> {
        self.info("bash-agent interactive mode (type 'exit' or Ctrl+D to quit)");
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
            self.append_event(json!({"type":"session_start"}))?;
            self.append_event(json!({"type":"user_message","content":user_input}))?;

            let mut turn = 0;
            let mut ds = DisplayState {
                last_char: String::from("\n"),
                prev_was_thinking: false,
            };

            while turn < self.cfg.max_turns {
                turn += 1;
                let mut text = String::new();
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

                let mut stream = self.llm_stream()?;
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
                            let mut display_content = output.clone();
                            if call.name == "Edit" {
                                let edit_diff = output.clone();
                                let summary = edit_diff_summary(
                                    call.fields.get("path").map(String::as_str).unwrap_or(""),
                                    &output,
                                );
                                output = summary;
                                display_content = edit_diff;
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
                                display_content,
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
                    self.conv.add_assistant(&text, &calls)?;
                    self.append_event(self.build_assistant_event(&text, &calls))?;
                    if !tool_results.is_empty() {
                        self.conv.add_tool_results(&tool_results)?;
                        for r in &tool_results {
                            self.append_event(json!({
                                "type":"tool_result",
                                "tool_use_id":r.tool_use_id,
                                "content":r.content,
                            }))?;
                        }
                    }
                    let _ = self.compact_context_window("auto", false);
                    // tool_use/tool_calls → loop continues; anything else → break
                    if stop.as_str() != "tool_use" && stop.as_str() != "tool_calls" {
                        return Ok(());
                    }
                } else {
                    if !self.is_stream_json_mode() {
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

    fn display_event(&self, ds: &mut DisplayState, evt: DisplayEvent) -> Result<()> {
        match evt {
            DisplayEvent::Thinking(content) => {
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({"type":"thinking","content":content}))?;
                } else {
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
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({"type":"text","content":content}))?;
                } else {
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
                if !self.is_stream_json_mode() {
                    if ds.last_char != "\n" {
                        self.write_human("\n")?;
                    } else {
                        self.write_carriage_return()?;
                    }
                    ds.last_char = "\n".to_string();
                }
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({
                        "type":"tool_call",
                        "name": call.name,
                        "id": call.id,
                        "input": call.input_json,
                    }))?;
                } else {
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
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({
                        "type":"usage",
                        "input_tokens":input_tokens,
                        "output_tokens":output_tokens,
                        "cache_input_tokens":cache_input_tokens
                    }))?;
                }
            }
            DisplayEvent::Stop(reason) => {
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({"type":"stop","reason":reason}))?;
                } else if ds.last_char != "\n" {
                    self.write_human("\n")?;
                    ds.last_char = "\n".to_string();
                }
            }
            DisplayEvent::Error(message) => {
                if self.is_stream_json_mode() {
                    let _ = self.emit_stream(json!({"type":"error","message":message}));
                }
                return Err(anyhow!(message));
            }
            DisplayEvent::ToolResult(result) => {
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({
                        "type":"tool_result",
                        "tool_use_id": result.tool_use_id,
                        "content": result.content,
                    }))?;
                } else if !result.content.is_empty() {
                    let display_output = if result.tool_name == "Edit" {
                        let mut out = result.content.clone();
                        if !result.display_content.is_empty() {
                            out.push('\n');
                            out.push_str(&colorize_diff(&result.display_content));
                        }
                        normalize_display_text(&out, self.cfg.interactive)
                    } else if result.tool_name == "Read" {
                        Store::file_tool_result_summary(
                            "Read",
                            result.tool_args.get("path").map(String::as_str).unwrap_or(""),
                        )
                    } else if result.tool_name == "Write" {
                        Store::file_tool_result_summary(
                            "Write",
                            result.tool_args.get("path").map(String::as_str).unwrap_or(""),
                        )
                    } else {
                        normalize_display_text(&result.content, self.cfg.interactive)
                    };
                    if display_output.ends_with('\n') {
                        self.write_human(&display_output)?;
                        ds.last_char = "\n".to_string();
                    } else {
                        let last = display_output.chars().last();
                        self.write_human(&format!("{display_output}\n"))?;
                        ds.last_char = last
                            .map(|c| c.to_string())
                            .unwrap_or_else(|| "\n".to_string());
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
        }
        .build_system_prompt()?;

        let body = provider::build_request(
            &self.cfg,
            &lines,
            &self.tools_json,
            &system_prompt,
            self.cfg.max_tokens,
            self.cfg.thinking_budget,
        )?;
        if self.cfg.verbose {
            self.debug(&format!("POST {} ({}KB body)", self.api_url, body.len() / 1024));
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
        let provider = self.cfg.provider.clone();
        let _reader_thread = std::thread::spawn(move || {
            let reader = CancelReader { inner: resp, cancel: cancel_thread.clone() };
            let send = |evt: Event| -> Result<()> {
                tx.send(StreamMsg::Event(evt)).map_err(|e| anyhow!(e.to_string()))
            };
            let parse_res = match provider.as_str() {
                "claude" => sse::claude::parse(reader, send),
                "openai" => sse::openai::parse(reader, send),
                _ => Err(anyhow!("unknown provider: {}", provider)),
            };
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
        let body = provider::build_request(
            &self.cfg,
            &messages,
            &[],
            &prompt::build_compact_summary_system_prompt(),
            self.cfg.summary_max_tokens,
            0,
        )?;
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
        match self.cfg.provider.as_str() {
            "claude" => sse::claude::parse(resp, &mut parse_emit)?,
            "openai" => sse::openai::parse(resp, &mut parse_emit)?,
            _ => bail!("unknown provider: {}", self.cfg.provider),
        }
        if out.is_empty() {
            bail!("failed to generate context summary");
        }
        Ok(out)
    }

    fn headers(&self) -> Vec<(String, String)> {
        let mut h = vec![("Content-Type".to_string(), "application/json".to_string())];
        match self.cfg.provider.as_str() {
            "claude" => {
                h.push(("x-api-key".to_string(), self.cfg.api_key.clone()));
                h.push(("anthropic-version".to_string(), "2023-06-01".to_string()));
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

    fn build_assistant_event(&self, text: &str, calls: &[ToolCallEvent]) -> Value {
        let tool_calls: Vec<Value> = calls
            .iter()
            .map(|c| json!({"name":c.name,"id":c.id,"input":c.input_json}))
            .collect();
        json!({"type":"assistant_message","text":text,"tool_calls":tool_calls})
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

    fn write_carriage_return(&self) -> Result<()> {
        if self.cfg.interactive {
            print!("\r");
            io::stdout().flush()?;
        }
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

impl Drop for Runtime {
    fn drop(&mut self) {
        self.stop_esc_interrupt_listener();
        let _ = fs::remove_dir_all(&self.tmp_dir);
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

fn colorize_diff(s: &str) -> String {
    let mut out = Vec::new();
    for line in s.lines() {
        let colored = if line.starts_with("--- ") || line.starts_with("+++ ") || line.starts_with("@@ ") {
            format!("\x1b[36m{line}\x1b[0m")
        } else if line.starts_with('+') && !line.starts_with("+++") {
            format!("\x1b[32m{line}\x1b[0m")
        } else if line.starts_with('-') && !line.starts_with("---") {
            format!("\x1b[31m{line}\x1b[0m")
        } else {
            line.to_string()
        };
        out.push(colored);
    }
    out.join("\n")
}

fn touch(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::File::create(path)?;
    }
    Ok(())
}

fn chrono_like_now() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{}", secs)
}

fn list_sessions(home: &Path, cwd: &Path) -> Result<()> {
    let dir = home
        .join(".bash-agent/projects")
        .join(session::project_key(cwd));
    let entries = fs::read_dir(dir);
    if entries.is_err() {
        println!("No sessions found.");
        return Ok(());
    }
    let mut rows: Vec<(String, SystemTime)> = Vec::new();
    for e in entries? {
        let e = e?;
        let name = e.file_name().to_string_lossy().to_string();
        if !name.ends_with(".jsonl") || name.ends_with(".events.jsonl") {
            continue;
        }
        rows.push((
            name.trim_end_matches(".jsonl").to_string(),
            e.metadata()?.modified().unwrap_or(UNIX_EPOCH),
        ));
    }
    if rows.is_empty() {
        println!("No sessions found.");
        return Ok(());
    }
    rows.sort_by(|a, b| b.1.cmp(&a.1));
    println!("{:<40} MODIFIED", "NAME");
    for (name, ts) in rows {
        let secs = ts
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        println!("{:<40} {}", name, secs);
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
