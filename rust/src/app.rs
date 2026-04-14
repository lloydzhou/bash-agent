use crate::assets::TOOLS_JSON;
use crate::config::{Command, Config, OutputFormat, api_url, apply_provider_defaults, parse_args};
use crate::conversation::{Store, ToolResult, build_tool_call_summary};
use crate::httpclient::StreamClient;
use crate::prompt;
use crate::protocol::{ErrorEvent, Event, StopEvent, TextEvent, ToolCallEvent, UsageEvent};
use crate::provider;
use crate::session::{self, Paths};
use crate::sse;
use crate::tools;
use anyhow::{Result, anyhow, bail};
use rustyline::DefaultEditor;
use rustyline::error::ReadlineError;
use serde_json::{Value, json};
use std::fs;
use std::io::{self, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
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

    if cfg.command != Command::Compact {
        apply_provider_defaults(&mut cfg)?;
    }

    let mut rt = Runtime::new(cfg, cwd, home)?;

    if rt.cfg.command == Command::Compact {
        let compacted = rt.compact_context_window("manual", true)?;
        if rt.cfg.output_format == OutputFormat::Human {
            if compacted {
                rt.info("Context compacted.");
            } else {
                rt.info("Context is within budget; no compaction needed.");
            }
        }
        return Ok(());
    }

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

const INTERRUPTED_ERR: &str = "__INTERRUPTED__";

enum DisplayEvent {
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

        if cfg.command == Command::Compact
            && !cfg.session_mode
            && !cfg.continue_session
            && cfg.session_id.is_empty()
        {
            cfg.session_mode = true;
            cfg.continue_session = true;
        }

        let paths = if cfg.session_mode {
            let mut sid = cfg.session_id.clone();
            if sid.is_empty() && cfg.continue_session {
                sid = session::continue_session(&home, &cwd)
                    .map_err(|_| anyhow!("no existing session found to compact"))?;
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
        let api_url = if cfg.command == Command::Compact {
            String::new()
        } else {
            api_url(&cfg)
        };
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
        let history_path = self.home.join(".bash-agent/rustagent.history");
        if let Some(parent) = history_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut rl = DefaultEditor::new()?;
        let _ = rl.load_history(&history_path);
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
            let _ = rl.save_history(&history_path);
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
            self.append_event(json!({"type":"user_message","content":user_input}))?;

            let mut turn = 0;
            let mut display_last_char = String::from("\n");

            while turn < self.cfg.max_turns {
                turn += 1;
                let mut text = String::new();
                let mut calls: Vec<ToolCallEvent> = Vec::new();
                let mut stop = String::new();

                let call_result = self.llm_call(|evt| {
                    if self.interrupted.load(Ordering::SeqCst) {
                        return Err(anyhow!(INTERRUPTED_ERR));
                    }
                    if self.cfg.verbose {
                        self.debug(&format!("<{}>", evt.render()));
                    }
                    match evt {
                        Event::Text(TextEvent { content }) => {
                            self.display_event(&mut display_last_char, DisplayEvent::Text(content.clone()))?;
                            text.push_str(&content);
                        }
                        Event::ToolCall(call) => {
                            self.display_event(&mut display_last_char, DisplayEvent::ToolCall(call.clone()))?;
                            calls.push(call);
                        }
                        Event::Usage(UsageEvent {
                            input_tokens,
                            output_tokens,
                            cache_input_tokens,
                        }) => {
                            self.display_event(
                                &mut display_last_char,
                                DisplayEvent::Usage(UsageEvent {
                                    input_tokens,
                                    output_tokens,
                                    cache_input_tokens,
                                }),
                            )?;
                        }
                        Event::Stop(StopEvent { reason }) => {
                            stop = reason.clone();
                            self.display_event(&mut display_last_char, DisplayEvent::Stop(reason))?;
                        }
                        Event::Error(ErrorEvent { message }) => {
                            return self.display_event(&mut display_last_char, DisplayEvent::Error(message));
                        }
                    }
                    Ok(())
                });
                if let Err(e) = call_result {
                    if e.to_string().contains(INTERRUPTED_ERR) {
                        if !self.is_stream_json_mode() {
                            self.info("Interrupted.");
                        }
                        return Ok(());
                    }
                    return Err(e);
                }

                self.conv.add_assistant(&text, &calls)?;
                self.append_event(self.build_assistant_event(&text, &calls))?;

                match stop.as_str() {
                    "end_turn" | "stop" | "done" => {
                        let _ = self.compact_context_window("auto", false);
                        return Ok(());
                    }
                    "tool_use" | "tool_calls" => {
                        if self.interrupted.load(Ordering::SeqCst) {
                            if !self.is_stream_json_mode() {
                                self.info("Interrupted.");
                            }
                            return Ok(());
                        }
                        let results = self.execute_tool_calls(&calls)?;
                        if self.interrupted.load(Ordering::SeqCst) {
                            if !self.is_stream_json_mode() {
                                self.info("Interrupted.");
                            }
                            return Ok(());
                        }
                        for result in &results {
                            self.display_event(
                                &mut display_last_char,
                                DisplayEvent::ToolResult(result.clone()),
                            )?;
                        }
                        self.conv.add_tool_results(&results)?;
                        for r in &results {
                            self.append_event(json!({
                                "type":"tool_result",
                                "tool_use_id":r.tool_use_id,
                                "content":r.content,
                            }))?;
                        }
                        let _ = self.compact_context_window("auto", false);
                    }
                    "max_tokens" | "length" => {
                        self.error("Response truncated (max_tokens reached)");
                        return Ok(());
                    }
                    _ => {
                        self.error(&format!("Unknown stop reason: {stop}"));
                        return Ok(());
                    }
                }
            }
            self.error(&format!("Max turns ({}) reached", self.cfg.max_turns));
            Ok(())
        })();
        self.stop_esc_interrupt_listener();
        result
    }

    fn display_event(&self, last_char: &mut String, evt: DisplayEvent) -> Result<()> {
        match evt {
            DisplayEvent::Text(content) => {
                if self.is_stream_json_mode() {
                    self.emit_stream(json!({"type":"text","content":content}))?;
                } else {
                    self.write_human(&content)?;
                    let display_content = normalize_display_text(&content, self.cfg.interactive);
                    if display_content.ends_with('\n') {
                        *last_char = "\n".to_string();
                    } else if let Some(c) = display_content.chars().last() {
                        *last_char = c.to_string();
                    }
                }
            }
            DisplayEvent::ToolCall(call) => {
                if !self.is_stream_json_mode() {
                    if last_char != "\n" {
                        self.write_human("\n")?;
                    } else {
                        self.write_carriage_return()?;
                    }
                    *last_char = "\n".to_string();
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
                } else if last_char != "\n" {
                    self.write_human("\n")?;
                    *last_char = "\n".to_string();
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
                    let display_output = normalize_display_text(&result.content, self.cfg.interactive);
                    let last = display_output.chars().last();
                    if display_output.ends_with('\n') {
                        self.write_human(&display_output)?;
                        *last_char = "\n".to_string();
                    } else {
                        self.write_human(&(display_output + "\n"))?;
                        if let Some(c) = last {
                            *last_char = c.to_string();
                        }
                    }
                }
            }
        }
        Ok(())
    }

    fn llm_call(&self, emit: impl FnMut(Event) -> Result<()>) -> Result<()> {
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
        )?;

        let resp = self.http.post(&self.api_url, &self.headers(), &body)?;

        match self.cfg.provider.as_str() {
            "claude" => sse::claude::parse(resp, emit),
            "openai" => sse::openai::parse(resp, emit),
            _ => Err(anyhow!("unknown provider: {}", self.cfg.provider)),
        }
    }

    fn execute_tool_calls(&mut self, calls: &[ToolCallEvent]) -> Result<Vec<ToolResult>> {
        let runner = tools::Runner {
            config: self.cfg.clone(),
            todo_file: self.paths.todo.clone(),
        };
        let mut results = Vec::new();
        for call in calls {
            if self.interrupted.load(Ordering::SeqCst) {
                break;
            }
            let mut output = match runner.dispatch(&call.name, &call.input_json) {
                Ok(v) => v,
                Err(e) => format!("Error: tool execution failed: {e}"),
            };
            if self.interrupted.load(Ordering::SeqCst) {
                break;
            }
            output = tools::format_tool_result(&output, self.cfg.tool_result_max_bytes);

            results.push(ToolResult {
                tool_use_id: call.id.clone(),
                content: output.clone(),
            });

            if call.name == "TodoWrite" {
                if let Ok(data) = fs::read_to_string(&self.paths.todo) {
                    let trimmed = data.trim_end().to_string();
                    self.append_event(json!({"type":"todo_update","content":trimmed}))?;
                }
            }
        }
        Ok(results)
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
        let body = provider::build_request(
            &self.cfg,
            &messages,
            &[],
            &prompt::build_compact_summary_system_prompt(),
            self.cfg.summary_max_tokens,
        )?;
        let resp = self.http.post(&self.api_url, &self.headers(), &body)?;
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
    println!("       rustagent compact [options]");
    println!();
    println!("Options:");
    println!("  -p, --provider PROV     LLM provider: claude | openai (default: claude)");
    println!("  -m, --model MODEL       Model name");
    println!("  --max-tokens N          Max output tokens (default: 4096)");
    println!("  --tool-timeout N        Tool execution timeout in seconds (default: 600)");
    println!(
        "  --skill NAME            Load skill from .claude/skills/NAME/SKILL.md (fallback: ~/.claude/skills)"
    );
    println!("  --max-turns N           Max agent turns (default: 20)");
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
