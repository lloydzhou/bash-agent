use crate::config::Config;
    use crate::prompt;
    use anyhow::{Result, anyhow, bail};
    use once_cell::sync::Lazy;
    use regex::Regex;
    use serde::Deserialize;
    use serde_json::Value;
    use nix::unistd::pipe;
    use std::fs;
    use std::os::unix::io::{FromRawFd, IntoRawFd, OwnedFd};
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::atomic::AtomicBool;
    use std::sync::{Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    static RE_BASH_ROOT_DELETE: Lazy<Regex> =
        Lazy::new(|| Regex::new(r"(^|[\s;|&])rm\s+-[^\s]*[rf][^\s]*\s+/(\s|$|[*])").expect("regex"));
    static RE_BASH_SYSTEM_PATH: Lazy<Regex> =
        Lazy::new(|| Regex::new(r#"(^|[\s"'`])(/etc|/usr|/bin|/sbin|/var|/library|/system|/dev)(/|[\s"'`]|$)"#).expect("regex"));
    static RE_BASH_SENSITIVE_PATH: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"(^|[\s"'`])(~|\$home)/(\.ssh|\.gnupg|\.aws|\.docker)(/|[\s"'`]|$)|(^|[\s"'`])([^\s"'`]*\.(env|pem|key)|[^\s"'`]*(token|credential|secret)[^\s"'`]*)"#)
            .expect("regex")
    });
    static RE_BASH_EXTERNAL_PATH: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r#"(^|[\s"'`])(~|\$home)(/|[\s"'`]|$)|(^|[\s"'`])/[A-Za-z0-9._-]"#)
            .expect("regex")
    });
    static RE_BASH_DEVICE_WRITE: Lazy<Regex> = Lazy::new(|| {
        Regex::new(r"(^|[\s])(of=|>|1>|>>|1>>)\s*/dev/(sd[a-z][0-9]*|disk[0-9]+|rdisk[0-9]+|nvme[0-9]+n[0-9]+(p[0-9]+)?|vd[a-z][0-9]*|xvd[a-z][0-9]*|hd[a-z][0-9]*)([\s]|$)")
            .expect("regex")
    });

    pub struct Runner {
        pub config: Config,
        pub cwd: std::path::PathBuf,
        pub home: std::path::PathBuf,
        pub interrupted: Arc<AtomicBool>,
        pub cancel_fd: i32, // cancel pipe 读端 FD，-1 表示不可用
    }

    #[derive(Debug, Clone, Deserialize)]
    pub struct TodoArg {
        pub content: String,
        pub status: String,
    }

    impl Runner {
        pub fn dispatch(&self, name: &str, input: &Value) -> Result<String> {
            match name {
                "Read" => {
                    #[derive(Deserialize)]
                    struct Args {
                        path: String,
                        #[serde(default)]
                        offset: Option<usize>,
                        #[serde(default)]
                        limit: Option<usize>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.read(&args.path, args.offset, args.limit)
                }
                "Write" => {
                    #[derive(Deserialize)]
                    struct Args {
                        path: String,
                        content: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.write(&args.path, &args.content)
                }
                "Edit" => {
                    #[derive(Deserialize)]
                    struct Args {
                        path: String,
                        old_string: String,
                        new_string: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.edit(&args.path, &args.old_string, &args.new_string)
                }
                "Bash" => {
                    #[derive(Deserialize)]
                    struct Args {
                        command: String,
                        #[serde(default)]
                        timeout: Option<u64>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.bash(&args.command, args.timeout)
                }
                "Glob" => {
                    #[derive(Deserialize)]
                    struct Args {
                        pattern: String,
                        #[serde(default)]
                        path: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.glob(
                        &args.pattern,
                        if args.path.is_empty() {
                            "."
                        } else {
                            &args.path
                        },
                    )
                }
                "Grep" => {
                    #[derive(Deserialize)]
                    struct Args {
                        pattern: String,
                        #[serde(default)]
                        path: String,
                        #[serde(default)]
                        glob: String,
                        #[serde(default)]
                        context: Option<usize>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.grep(
                        &args.pattern,
                        if args.path.is_empty() {
                            "."
                        } else {
                            &args.path
                        },
                        &args.glob,
                        args.context,
                    )
                }
                "TodoWrite" => {
                    #[derive(Deserialize)]
                    struct Args {
                        todos: Vec<TodoArg>,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.todo_write(args.todos)
                }
                "Skill" => {
                    #[derive(Deserialize)]
                    struct Args {
                        name: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.tool_skill(&args.name)
                }
                "WebSearch" => {
                    #[derive(Deserialize)]
                    struct Args {
                        query: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.web_search(&args.query)
                }
                "WebFetch" => {
                    #[derive(Deserialize)]
                    struct Args {
                        url: String,
                    }
                    let args: Args = serde_json::from_value(input.clone())?;
                    self.web_fetch(&args.url)
                }
                _ => bail!("unknown tool: {name}"),
            }
        }

        fn read(&self, path: &str, offset: Option<usize>, limit: Option<usize>) -> Result<String> {
            if path.is_empty() {
                bail!("no path provided");
            }
            let data = fs::read(path)
                .map_err(|_| anyhow!("Error: file not found or unreadable: {path}"))?;
            // 编码处理：UTF-8 合法 → 直接用；否则尝试 iconv 转码，失败 fallback sanitize
            let content = match std::str::from_utf8(&data) {
                Ok(s) => self.sanitize_utf8(data.as_slice()),
                Err(_) => {
                    match self.iconv_to_utf8(&data) {
                        Some(converted) => converted,
                        None => self.sanitize_utf8(data.as_slice()),
                    }
                }
            };
            if offset.is_none() && limit.is_none() {
                return Ok(content);
            }

            let mut lines: Vec<&str> = content.split('\n').collect();
            if !lines.is_empty() && lines.last().map(|l| l.is_empty()).unwrap_or(false) {
                lines.pop();
            }
            let total_lines = lines.len();

            let start = match offset {
                Some(o) if o > 1 => {
                    if o > total_lines {
                        bail!(
                            "Error: offset {} exceeds total lines {} in {}",
                            o,
                            total_lines,
                            path
                        );
                    }
                    o - 1
                }
                _ => 0,
            };

            let end = match limit {
                Some(l) if l > 0 => (start + l).min(total_lines),
                _ => total_lines,
            };

            let selected = &lines[start..end];
            Ok(selected.join("\n"))
        }

        fn write(&self, path: &str, content: &str) -> Result<String> {
            if path.is_empty() {
                bail!("no path provided");
            }
            if content.len() > self.config.file_write_max_bytes {
                bail!(
                    "Error: content too large for write_file ({} bytes > {} bytes)",
                    content.len(),
                    self.config.file_write_max_bytes
                );
            }
            if let Some(dir) = Path::new(path).parent() {
                fs::create_dir_all(dir)?;
            }
            fs::write(path, content)?;
            let sz = fs::metadata(path)?.len();
            Ok(format!("OK: wrote {sz} bytes to {path}"))
        }

        fn edit(&self, path: &str, old_s: &str, new_s: &str) -> Result<String> {
            if path.is_empty() {
                bail!("no path provided");
            }
            if old_s.is_empty() {
                bail!("empty old_string");
            }
            let content =
                fs::read_to_string(path).map_err(|_| anyhow!("Error: file not found: {path}"))?;
            if content.len() > self.config.file_write_max_bytes {
                bail!(
                    "Error: file too large for edit_file ({} bytes > {} bytes)",
                    content.len(),
                    self.config.file_write_max_bytes
                );
            }
            if !content.contains(old_s) {
                bail!(
                    "Error: old_string not found in {path}. Hint: use Grep to locate the target lines, then Read the relevant portion (with offset/limit) to copy the exact text before retrying Edit."
                );
            }
            let updated = content.replacen(old_s, new_s, 1);
            if updated.is_empty() {
                bail!("edit produced empty result");
            }
            let diff = unified_diff_color(path, &content, &updated)?;
            fs::write(path, updated)?;
            let (added, removed) = count_diff_lines(&diff);
            let summary = format!("Success: Edit({path}) [+{added} -{removed} lines]");
            Ok(format!("{summary}\n{diff}"))
        }

        fn bash(&self, command: &str, timeout_secs: Option<u64>) -> Result<String> {
            if command.trim().is_empty() {
                bail!("no command provided");
            }
            let allowed_mode = bash_mode_normalize(
                &std::env::var("BASH_AGENT_BASH_MODE").unwrap_or_else(|_| "0467".to_string()),
            );
            let required_mode = classify_bash_required_mode(command);
            if !bash_mode_allows(&allowed_mode, &required_mode) {
                bail!(
                    "Error: command blocked by bash safety policy (required={} allowed={}; mode=system/external/network/workspace bits=4:read,2:write,1:execute)",
                    required_mode,
                    allowed_mode
                );
            }
            let timeout = match timeout_secs {
                Some(t) if t > 0 => Duration::from_secs(t),
                _ => Duration::from_secs(if self.config.tool_timeout_secs > 0 {
                    self.config.tool_timeout_secs as u64
                } else {
                    600
                }),
            };

            // 创建手动 pipe：写端给子进程，读端由 reader 线程读取
            // 通过关闭读端 FD 来传播中断信号（chain 模式）
            let (stdout_r, stdout_w): (OwnedFd, OwnedFd) = pipe()?;
            let (stderr_r, stderr_w): (OwnedFd, OwnedFd) = pipe()?;

            let stdout_fd = stdout_r.into_raw_fd(); // 消费 OwnedFd，由我们手动管理 FD 生命周期
            let stderr_fd = stderr_r.into_raw_fd();

            let mut child = Command::new("bash")
                .arg("-lc")
                .arg(command)
                .stdout(unsafe { Stdio::from_raw_fd(stdout_w.into_raw_fd()) })
                .stderr(unsafe { Stdio::from_raw_fd(stderr_w.into_raw_fd()) })
                .spawn()?;

            let stdout_buf: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));
            let stderr_buf: Arc<Mutex<String>> = Arc::new(Mutex::new(String::new()));

            // Reader 线程：读取 stdout FD，FD 被外部关闭时 read 返回 EBADF 自动退出
            let sbuf = stdout_buf.clone();
            let stdout_fd_reader = stdout_fd;
            thread::spawn(move || {
                let mut tmp = Vec::new();
                let mut buf = [0u8; 8192];
                loop {
                    match unsafe { libc::read(stdout_fd_reader, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) } {
                        0 => break,
                        n if n > 0 => tmp.extend_from_slice(&buf[..n as usize]),
                        _ => break, // EBADF（FD 被关）/ 其他错误
                    }
                }
                *sbuf.lock().unwrap() = sanitize_utf8(&tmp);
            });

            let ebuf = stderr_buf.clone();
            let stderr_fd_reader = stderr_fd;
            thread::spawn(move || {
                let mut tmp = Vec::new();
                let mut buf = [0u8; 8192];
                loop {
                    match unsafe { libc::read(stderr_fd_reader, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) } {
                        0 => break,
                        n if n > 0 => tmp.extend_from_slice(&buf[..n as usize]),
                        _ => break,
                    }
                }
                *ebuf.lock().unwrap() = sanitize_utf8(&tmp);
            });

            // 使用 kqueue 事件驱动等待子进程退出 / cancel 信号 / 超时 — 零轮询
            let mut timed_out = false;
            match wait_child_or_cancel(child.id(), self.cancel_fd, timeout) {
                Ok(WaitResult::Exited) => {
                    let _ = child.try_wait(); // reap
                }
                Ok(WaitResult::Cancel) => {
                    timed_out = true; // 标记为截断
                    // drain cancel pipe 防止后续 tool 调用立即收到 Cancel
                    drain_fd(self.cancel_fd);
                }
                Ok(WaitResult::Timeout) => {
                    timed_out = true;
                    // SIGTERM 子进程
                    let _ = Command::new("kill")
                        .arg("--")
                        .arg(format!("-{}", child.id()))
                        .output();
                    let _ = child.try_wait();
                }
                Err(e) => {
                    // 先关闭 FD 再返回错误
                    unsafe { libc::close(stdout_fd); }
                    unsafe { libc::close(stderr_fd); }
                    bail!("wait failed: {e}");
                }
            }

            // 给 reader 线程 1ms 处理剩余数据。FD 链机制下 reader 在子进程退出 / FD 关闭后
            // 立即得到 EOF / EBADF，1ms 足够处理常规输出。大输出场景靠多轮 8KB read 完成。
            thread::sleep(Duration::from_millis(1));

            let mut out = stdout_buf.lock().unwrap().clone();
            let stderr = stderr_buf.lock().unwrap().clone();
            if !stderr.is_empty() {
                if !out.is_empty() {
                    out.push('\n');
                }
                out.push_str(&stderr);
            }

            if timed_out {
                out.push_str(&format!(
                    "\n[... truncated, command timed out after {} seconds ...]",
                    timeout.as_secs()
                ));
            }
            Ok(out)
        }

        fn glob(&self, pattern: &str, path: &str) -> Result<String> {
            if pattern.is_empty() {
                bail!("no pattern provided");
            }
            let _ = Command::new("rg")
                .arg("--version")
                .output()
                .map_err(|_| anyhow!("Error: rg is required for glob"))?;
            let output = Command::new("rg")
                .args(["--files", path, "-g", pattern])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .output()?;
            Ok(String::from_utf8_lossy(&output.stdout).to_string())
        }

        fn grep(
            &self,
            pattern: &str,
            path: &str,
            glob: &str,
            context: Option<usize>,
        ) -> Result<String> {
            if pattern.is_empty() {
                bail!("no pattern provided");
            }
            let _ = Command::new("rg")
                .arg("--version")
                .output()
                .map_err(|_| anyhow!("Error: rg is required for grep"))?;
            let mut cmd = Command::new("rg");
            cmd.args(["-n", "--color", "never", "--heading"]);
            if let Some(c) = context {
                if c > 0 {
                    cmd.args(["-C", &c.to_string()]);
                }
            }
            if !glob.is_empty() {
                cmd.args(["--glob", glob]);
            }
            if pattern.starts_with('-') {
                cmd.args(["-e", pattern]);
            } else {
                cmd.args(["--", pattern]);
            }
            cmd.arg(path);
            let output = cmd.stdout(Stdio::piped()).stderr(Stdio::null()).output()?;
            let result = String::from_utf8_lossy(&output.stdout).to_string();
            Ok(result.trim_end_matches('\n').to_string())
        }

        fn todo_write(&self, todos: Vec<TodoArg>) -> Result<String> {
            let mut lines = Vec::new();
            for t in todos {
                let content = t.content.as_str();
                let status = t.status.as_str();
                if content.is_empty() {
                    bail!("todo item content is required");
                }
                match status {
                    "pending" => lines.push(format!("- [ ] {content}")),
                    "in_progress" => {
                        lines.push(format!("- [ ] {content}"));
                    }
                    "completed" => lines.push(format!("- [x] {content}")),
                    _ => bail!("invalid todo status: {status}"),
                }
            }
            Ok(lines.join("\n"))
        }

        fn tool_skill(&self, name: &str) -> Result<String> {
            let name = name.trim();
            if name.is_empty() {
                bail!("no skill name provided");
            }
            let Some(skill_file) = prompt::resolve_skill_file(&self.cwd, &self.home, name) else {
                bail!("skill not found: {name}");
            };
            let base_dir = skill_file.parent().unwrap_or(Path::new(""));
            let content = fs::read_to_string(&skill_file)?
                .replace("${BASH_AGENT_SKILL_DIR}", &base_dir.display().to_string());
            Ok(format!(
                "Skill: {name}\nBase directory: {}\n\n{content}",
                base_dir.display()
            ))
        }

        fn web_search(&self, query: &str) -> Result<String> {
            if query.is_empty() {
                bail!("no query provided");
            }
            let rt = crate::agent::tokio_runtime();
            let client = reqwest::Client::new();
            let query = query.to_string();
            let result: Result<String> = rt.block_on(async move {
                let mut req = client
                    .get("https://s.jina.ai/")
                    .query(&[("q", &query)])
                    .header("X-Respond-With", "no-content")
                    .timeout(std::time::Duration::from_secs(30));
                if let Ok(key) = std::env::var("JINA_API_KEY") {
                    if !key.is_empty() {
                        req = req.header("Authorization", format!("Bearer {key}"));
                    }
                }
                let resp = req.send().await.map_err(|e| anyhow!(e.to_string()))?;
                let body = resp.text().await.map_err(|e| anyhow!(e.to_string()))?;
                Ok(body)
            });
            result
        }

        fn web_fetch(&self, url: &str) -> Result<String> {
            if url.is_empty() {
                bail!("no url provided");
            }
            let rt = crate::agent::tokio_runtime();
            let client = reqwest::Client::new();
            let url = url.to_string();
            let result: Result<String> = rt.block_on(async move {
                let mut req = client
                    .get(format!("https://r.jina.ai/{url}"))
                    .timeout(std::time::Duration::from_secs(60));
                if let Ok(key) = std::env::var("JINA_API_KEY") {
                    if !key.is_empty() {
                        req = req.header("Authorization", format!("Bearer {key}"));
                    }
                }
                let resp = req.send().await.map_err(|e| anyhow!(e.to_string()))?;
                let body = resp.text().await.map_err(|e| anyhow!(e.to_string()))?;
                Ok(body)
            });
            result
        }
    }

    /// 等待结果：子进程退出 / cancel 信号 / 超时
    enum WaitResult {
        Exited,
        Cancel,
        Timeout,
    }

    /// 使用 kqueue (macOS) 事件驱动等待，零轮询。
    /// 同时监视子进程退出 (EVFILT_PROC + NOTE_EXIT) 和 cancel pipe (EVFILT_READ)。
    #[cfg(target_os = "macos")]
    fn wait_child_or_cancel(child_pid: u32, cancel_fd: i32, timeout: Duration) -> Result<WaitResult> {
        let kq = unsafe { libc::kqueue() };
        if kq < 0 {
            bail!("kqueue() failed: {}", std::io::Error::last_os_error());
        }

        let mut events = Vec::with_capacity(2);
        events.push(libc::kevent {
            ident: child_pid as usize,
            filter: libc::EVFILT_PROC as i16,
            flags: libc::EV_ADD as u16,
            fflags: libc::NOTE_EXIT as u32,
            data: 0,
            udata: std::ptr::null_mut(),
        });
        if cancel_fd >= 0 {
            events.push(libc::kevent {
                ident: cancel_fd as usize,
                filter: libc::EVFILT_READ as i16,
                flags: libc::EV_ADD as u16,
                fflags: 0,
                data: 0,
                udata: std::ptr::null_mut(),
            });
        }

        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        let timeout_nanos = timeout.as_secs().saturating_mul(1_000_000_000) as i64
            + timeout.subsec_nanos() as i64;
        let ts = libc::timespec {
            tv_sec: (timeout_nanos / 1_000_000_000) as libc::time_t,
            tv_nsec: (timeout_nanos % 1_000_000_000) as _,
        };

        let ret = unsafe {
            libc::kevent(
                kq,
                events.as_ptr(),
                events.len() as i32,
                &mut event,
                1,
                &ts as *const libc::timespec,
            )
        };

        unsafe { libc::close(kq); }

        if ret < 0 {
            bail!("kevent() failed: {}", std::io::Error::last_os_error());
        }
        if ret == 0 {
            return Ok(WaitResult::Timeout);
        }

        // kevent 返回了一个事件
        if event.filter == libc::EVFILT_READ as i16 {
            Ok(WaitResult::Cancel)
        } else {
            // EVFILT_PROC — 子进程退出
            Ok(WaitResult::Exited)
        }
    }

    /// 使用 pidfd_open + poll (Linux 5.3+) 事件驱动等待。
    /// 同时监视子进程退出 (pidfd) 和 cancel pipe (poll)。
    #[cfg(target_os = "linux")]
    fn wait_child_or_cancel(child_pid: u32, cancel_fd: i32, timeout: Duration) -> Result<WaitResult> {
        let pidfd = unsafe { libc::syscall(libc::SYS_pidfd_open, child_pid as libc::c_int, 0) };
        if pidfd < 0 {
            bail!("pidfd_open({}) failed: {}", child_pid, std::io::Error::last_os_error());
        }

        let mut poll_fds = vec![
            libc::pollfd {
                fd: pidfd as libc::c_int,
                events: libc::POLLIN as i16,
                revents: 0,
            },
        ];
        if cancel_fd >= 0 {
            poll_fds.push(libc::pollfd {
                fd: cancel_fd,
                events: libc::POLLIN as i16,
                revents: 0,
            });
        }

        let timeout_ms = if timeout == Duration::MAX {
            -1i32
        } else {
            let ms = timeout.as_millis();
            if ms > i32::MAX as u128 { i32::MAX } else { ms as i32 }
        };

        let ret = unsafe {
            libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as libc::nfds_t, timeout_ms)
        };

        unsafe { libc::close(pidfd as libc::c_int); }

        if ret < 0 {
            bail!("poll() failed: {}", std::io::Error::last_os_error());
        }
        if ret == 0 {
            return Ok(WaitResult::Timeout);
        }

        let exited = (poll_fds[0].revents as i16 & libc::POLLIN as i16) != 0;
        let cancelled = poll_fds.len() > 1
            && (poll_fds[1].revents as i16 & libc::POLLIN as i16) != 0;

        if exited {
            Ok(WaitResult::Exited)
        } else if cancelled {
            Ok(WaitResult::Cancel)
        } else {
            bail!("unexpected poll result: revents={:?}",
                poll_fds.iter().map(|p| p.revents).collect::<Vec<_>>());
        }
    }

    /// 跨平台备选：waitpid(WNOHANG) + 50ms 轮询
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    fn wait_child_or_cancel(child_pid: u32, cancel_fd: i32, timeout: Duration) -> Result<WaitResult> {
        let start = std::time::Instant::now();
        loop {
            // waitpid WNOHANG 非阻塞检查子进程状态
            let mut status = 0;
            let ret = unsafe { libc::waitpid(child_pid as libc::pid_t, &mut status, libc::WNOHANG) };
            if ret == child_pid as libc::pid_t {
                return Ok(WaitResult::Exited);
            }
            if ret < 0 {
                if let Some(libc::ECHILD) = std::io::Error::last_os_error().raw_os_error() {
                    return Ok(WaitResult::Exited);
                }
            }

            // 非阻塞检查 cancel pipe
            if cancel_fd >= 0 {
                let mut pfd = libc::pollfd {
                    fd: cancel_fd,
                    events: libc::POLLIN as i16,
                    revents: 0,
                };
                let pret = unsafe { libc::poll(&mut pfd, 1, 0) };
                if pret > 0 && (pfd.revents as i16 & libc::POLLIN as i16) != 0 {
                    return Ok(WaitResult::Cancel);
                }
            }

            if start.elapsed() >= timeout {
                return Ok(WaitResult::Timeout);
            }

            std::thread::sleep(std::time::Duration::from_millis(50));
        }
    }

    /// 非阻塞地 drain 一个 FD 的所有待读数据。
    /// 用于 cancel pipe：Cancel 后清空管道，避免后续 tool 调用错误地立即收到 Cancel。
    pub fn drain_fd(fd: i32) {
        if fd < 0 {
            return;
        }
        // 临时设为非阻塞
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL, 0) };
        if flags < 0 {
            return;
        }
        let _ = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
        let mut buf = [0u8; 64];
        loop {
            let ret = unsafe {
                libc::read(fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len())
            };
            if ret <= 0 {
                break;
            }
        }
        // 恢复阻塞模式
        let _ = unsafe { libc::fcntl(fd, libc::F_SETFL, flags) };
    }

    fn bash_mode_normalize(mode: &str) -> String {
        if mode.len() == 4 && mode.bytes().all(|b| (b'0'..=b'7').contains(&b)) {
            mode.to_string()
        } else {
            "0000".to_string()
        }
    }

    fn bash_add_mode(mask: &mut u16, scopes: u16, perms: u16) {
        *mask |= ((scopes & 8 != 0) as u16) * (perms << 9)
            | ((scopes & 4 != 0) as u16) * (perms << 6)
            | ((scopes & 2 != 0) as u16) * (perms << 3)
            | ((scopes & 1 != 0) as u16) * perms;
    }

    fn bash_add_path(mask: &mut u16, path: &str, perms: u16, cwd: &str) {
        let mut scope = 1;
        let path = path
            .trim_matches(|c| c == '"' || c == '\'')
            .trim_start_matches("of=")
            .trim_end_matches(';')
            .trim_end_matches(',')
            .trim_end_matches(')');
        if path.is_empty()
            || path == "/tmp"
            || path.starts_with("/tmp/")
            || path == "/dev/null"
            || path.starts_with('&')
        {
            return;
        }
        if path.starts_with("/dev/tcp") {
            scope = 2;
        } else if path == "/" || path == "/*" {
            scope = 8;
        } else if RE_BASH_SENSITIVE_PATH.is_match(path) || RE_BASH_SYSTEM_PATH.is_match(path) {
            scope = 8;
        } else if !cwd.is_empty() && (path == cwd || path.starts_with(&format!("{}/", cwd))) {
            scope = 1;
        } else if RE_BASH_EXTERNAL_PATH.is_match(path) || path.contains("..") {
            scope = 4;
        }
        bash_add_mode(mask, scope, perms);
    }

    fn bash_scan_segment(mask: &mut u16, seg: &str, cwd: &str) {
        let (mut redir, mut path_bits, mut flags) = (0u16, 4u16, 0u8);
        match seg {
            s if s == "sudo" || s.starts_with("sudo ")
                || s == "su" || s.starts_with("su ")
                || s == "doas" || s.starts_with("doas ")
                || s.starts_with("shutdown")
                || s.starts_with("reboot")
                || s.starts_with("halt")
                || s.starts_with("poweroff") => bash_add_mode(mask, 8, 1),
            s if s.starts_with("mkfs")
                || s.starts_with("fdisk")
                || s.starts_with("diskutil")
                || s.starts_with("mount ")
                || s.starts_with("umount ") => bash_add_mode(mask, 8, 2),
            _ => {}
        }
        if seg.contains("curl ")
            || seg.contains("wget ")
            || seg.contains("http ")
            || seg.contains("https://")
            || seg.contains("http://")
            || seg.starts_with("git clone")
            || seg.starts_with("git fetch")
            || seg.starts_with("git pull")
            || seg.starts_with("git ls-remote")
        {
            bash_add_mode(mask, 2, 4);
        }
        if seg.starts_with("git push")
            || seg.contains("scp ")
            || seg.contains("curl -d ")
            || seg.contains("curl --data")
            || seg.contains("curl -f ")
            || seg.contains("curl -t ")
        {
            bash_add_mode(mask, 2, 2);
        } else if (seg.contains("| bash")
            || seg.contains("| sh")
            || seg.contains("eval ")
            || seg.contains("source <(")
            || seg.contains("bash -c $(")
            || seg.contains("sh -c $("))
            && (seg.contains("curl ")
                || seg.contains("wget ")
                || seg.contains("http://")
                || seg.contains("https://"))
        {
            bash_add_mode(mask, 2, 1);
        }
        if RE_BASH_ROOT_DELETE.is_match(seg) || RE_BASH_DEVICE_WRITE.is_match(seg) {
            bash_add_mode(mask, 8, 2);
        }
        if seg.starts_with("./")
            || seg.starts_with("bash ")
            || seg.starts_with("sh ")
            || seg.starts_with("zsh ")
            || seg.starts_with("python")
            || seg.starts_with("node ")
            || seg.starts_with("ruby ")
            || seg.starts_with("perl ")
            || seg.starts_with("npm test")
            || seg.starts_with("npm run")
            || seg.starts_with("make")
            || seg.starts_with("cargo test")
            || seg.starts_with("cargo build")
            || seg.starts_with("go test")
                || seg.starts_with("git commit")
                || seg.starts_with("git add")
                || seg.starts_with("git checkout")
                || seg.starts_with("git merge")
                || seg.starts_with("git rebase")
                || seg.starts_with("git stash")
                || seg.starts_with("git cherry-pick")
            || seg.contains("function ")
            || seg.contains("()")
            || seg.contains('{')
            || seg.contains(" if ")
            || seg.starts_with("if ")
            || seg.contains(" for ")
            || seg.starts_with("for ")
            || seg.contains(" while ")
            || seg.starts_with("while ")
            || seg.contains(" case ")
            || seg.starts_with("case ")
            || seg.contains(":(){:|:&};:")
        {
            bash_add_mode(mask, 1, 1);
        }
        if seg.contains('>')
            || seg.contains("tee ")
            || seg.starts_with("mkdir ")
            || seg.starts_with("touch ")
            || seg.starts_with("cp ")
            || seg.starts_with("mv ")
            || seg.starts_with("rm ")
            || seg.contains(" rm ")
            || seg.contains("sed -i")
            || seg.contains(" -delete")
            || seg.starts_with("git fetch")
            || seg.starts_with("git pull")
            || seg.starts_with("git clone")
                || seg.starts_with("git commit")
                || seg.starts_with("git add")
                || seg.starts_with("git checkout")
                || seg.starts_with("git merge")
                || seg.starts_with("git rebase")
                || seg.starts_with("git stash")
            || seg.starts_with("npm install")
            || seg.starts_with("pnpm install")
            || seg.starts_with("yarn install")
            || seg.starts_with("cargo build")
            || seg.starts_with("go test")
            || seg.starts_with("npm test")
        {
            path_bits = 6;
            flags = 1;
        }
        for tok in seg.split_whitespace() {
            if redir != 0 {
                bash_add_path(mask, tok, redir, cwd);
                flags = 3;
                redir = 0;
                continue;
            }
            if matches!(tok, ">" | ">>" | "1>" | "1>>") {
                redir = 2;
            } else if tok == "<>" {
                redir = 6;
            } else if tok.starts_with("2>") {
            } else if tok.starts_with('>') {
                bash_add_path(mask, tok.trim_start_matches('>'), 2, cwd);
                flags = 3;
            } else if let Some(rest) = tok.strip_prefix("<>") {
                bash_add_path(mask, rest, 6, cwd);
                flags = 3;
            } else if tok.starts_with('/')
                || tok.starts_with("./")
                || tok.starts_with("../")
                || tok.starts_with("~/")
            {
                bash_add_path(mask, tok, path_bits, cwd);
                flags = 3;
            } else if RE_BASH_SENSITIVE_PATH.is_match(tok) {
                bash_add_path(mask, tok, path_bits, cwd);
                flags = 3;
            }
        }
        if flags == 1 && !seg.contains("/tmp/") {
            bash_add_mode(mask, 1, 2);
        }
    }

    fn bash_scan_script(script: &str, cwd: &str) -> u16 {
        let mut mask = 0u16;
        let script = script.replace("\\\n", " ");
        if script.contains("/dev/tcp") {
            bash_add_mode(&mut mask, 2, 6);
        }
        let normalized = script.replace("&&", "\n").replace("||", "\n").replace(';', "\n");
        for segment in normalized.lines().map(str::trim).filter(|s| !s.is_empty()) {
            bash_scan_segment(&mut mask, segment, cwd);
        }
        mask
    }

    fn classify_bash_required_mode(command: &str) -> String {
        if command.is_empty() {
            return "0000".to_string();
        }
        let cwd = std::env::current_dir()
            .map(|p| p.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        let mut mask = bash_scan_script(&command.to_lowercase(), &cwd);
        if mask == 0 {
            bash_add_mode(&mut mask, 1, 4);
        }
        format!("{mask:04o}")
    }

    fn bash_mode_allows(allowed: &str, required: &str) -> bool {
        let allowed = u16::from_str_radix(&bash_mode_normalize(allowed), 8).unwrap_or(0);
        let required = u16::from_str_radix(&bash_mode_normalize(required), 8).unwrap_or(0);
        (required & (4095 ^ allowed)) == 0
    }

    impl crate::traits::ToolDispatcher for Runner {
        fn dispatch(&self, name: &str, input: &Value) -> anyhow::Result<String> {
            Runner::dispatch(self, name, input)
        }
    }

    pub fn tool_dispatch(runner: &Runner, name: &str, input: &Value) -> Result<String> {
        runner.dispatch(name, input)
    }

    pub fn tool_read(runner: &Runner, path: &str, offset: Option<usize>, limit: Option<usize>) -> Result<String> {
        runner.read(path, offset, limit)
    }

    pub fn tool_write(runner: &Runner, path: &str, content: &str) -> Result<String> {
        runner.write(path, content)
    }

    pub fn tool_edit(runner: &Runner, path: &str, old_string: &str, new_string: &str) -> Result<String> {
        runner.edit(path, old_string, new_string)
    }

    pub fn tool_bash(runner: &Runner, command: &str, timeout_secs: Option<u64>) -> Result<String> {
        runner.bash(command, timeout_secs)
    }

    pub fn tool_glob(runner: &Runner, pattern: &str, path: &str) -> Result<String> {
        runner.glob(pattern, path)
    }

    pub fn tool_grep(
        runner: &Runner,
        pattern: &str,
        path: &str,
        glob: &str,
        context: Option<usize>,
    ) -> Result<String> {
        runner.grep(pattern, path, glob, context)
    }

    pub fn tool_skill(runner: &Runner, name: &str) -> Result<String> {
        runner.tool_skill(name)
    }

    pub fn tool_web_search(runner: &Runner, query: &str) -> Result<String> {
        runner.web_search(query)
    }

    pub fn tool_web_fetch(runner: &Runner, url: &str) -> Result<String> {
        runner.web_fetch(url)
    }

    pub fn tool_format_result(s: &str, max: usize) -> String {
        format_tool_result(s, max)
    }

    fn unified_diff_color(path: &str, old_content: &str, new_content: &str) -> Result<String> {
        let old_path = std::env::temp_dir().join(format!("edit-old-{}", std::process::id()));
        let new_path = std::env::temp_dir().join(format!("edit-new-{}", std::process::id()));
        fs::write(&old_path, old_content)?;
        fs::write(&new_path, new_content)?;
        let label = path.trim_start_matches('/');
        let diff = Command::new("diff")
            .args([
                "-u",
                "--color=always",
                "--label",
                &format!("a/{label}"),
                "--label",
                &format!("b/{label}"),
                old_path.to_str().unwrap_or(""),
                new_path.to_str().unwrap_or(""),
            ])
            .output();
        let _ = fs::remove_file(&old_path);
        let _ = fs::remove_file(&new_path);
        match diff {
            Ok(output) => {
                if output.status.success() || output.status.code() == Some(1) {
                    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
                    if stdout.contains("unsupported --color")
                        || stdout.contains("unrecognized option '--color'")
                    {
                        let old_path2 =
                            std::env::temp_dir().join(format!("edit-old2-{}", std::process::id()));
                        let new_path2 =
                            std::env::temp_dir().join(format!("edit-new2-{}", std::process::id()));
                        fs::write(&old_path2, old_content)?;
                        fs::write(&new_path2, new_content)?;
                        let diff2 = Command::new("diff")
                            .args([
                                "-u",
                                "--label",
                                &format!("a/{label}"),
                                "--label",
                                &format!("b/{label}"),
                                old_path2.to_str().unwrap_or(""),
                                new_path2.to_str().unwrap_or(""),
                            ])
                            .output();
                        let _ = fs::remove_file(&old_path2);
                        let _ = fs::remove_file(&new_path2);
                        match diff2 {
                            Ok(o) if o.status.success() || o.status.code() == Some(1) => {
                                Ok(String::from_utf8_lossy(&o.stdout).to_string())
                            }
                            _ => bail!("diff failed"),
                        }
                    } else {
                        Ok(stdout)
                    }
                } else {
                    bail!("diff failed")
                }
            }
            Err(_) => bail!("diff failed"),
        }
    }

    fn count_diff_lines(diff: &str) -> (usize, usize) {
        let mut added = 0usize;
        let mut removed = 0usize;
        for line in diff.lines() {
            let stripped = strip_ansi(line);
            if stripped.starts_with('+') && !stripped.starts_with("+++") {
                added += 1;
            }
            if stripped.starts_with('-') && !stripped.starts_with("---") {
                removed += 1;
            }
        }
        (added, removed)
    }

    fn strip_ansi(s: &str) -> String {
        let bytes = s.as_bytes();
        let mut out = String::with_capacity(s.len());
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == 0x1b && i + 1 < bytes.len() && bytes[i + 1] == b'[' {
                let mut j = i + 2;
                while j < bytes.len()
                    && ((bytes[j] >= 0x30 && bytes[j] <= 0x3f)
                        || (bytes[j] >= 0x20 && bytes[j] <= 0x2f))
                {
                    j += 1;
                }
                if j < bytes.len() && bytes[j] >= 0x40 && bytes[j] <= 0x7e {
                    j += 1;
                }
                i = j;
            } else {
                out.push(bytes[i] as char);
                i += 1;
            }
        }
        out
    }

    /// iconv_to_utf8: 调用系统 iconv 将非 UTF-8 编码（GBK/GB18030 等）转为 UTF-8。
    /// file 命令对中文文件常报 iso-8859-1，实际多为 GBK/GB18030；GB18030 是 GBK 超集。
    /// 返回 Some(sanitized_content) 或 None（失败时调用方应 fallback 到 sanitize_utf8）。
    fn iconv_to_utf8(&self, data: &[u8]) -> Option<String> {
        // 检测编码：file -bi，iso-8859-* 一律按 gb18030 处理（兼容 GBK）
        let mut from_enc = "gb18030";
        // 写临时文件用 file 检测
        let tmp = std::env::temp_dir().join(format!("iconv-{}.tmp", std::process::id()));
        if fs::write(&tmp, data).is_ok() {
            if let Ok(out) = Command::new("file").arg("-bi").arg(&tmp).output() {
                let mime = String::from_utf8_lossy(&out.stdout).to_lowercase();
                if mime.contains("charset=utf-8") || mime.contains("charset=us-ascii") {
                    let _ = fs::remove_file(&tmp);
                    return Some(self.sanitize_utf8(data));
                }
                for enc in &["gbk", "gb2312", "gb18030", "big5", "shift_jis", "euc-jp", "euc-kr"] {
                    if mime.contains(&format!("charset={enc}")) {
                        from_enc = enc;
                        break;
                    }
                }
            }
            let _ = fs::remove_file(&tmp);
        }
        // 调用 iconv 转码
        let child = Command::new("iconv")
            .arg("-f").arg(from_enc)
            .arg("-t").arg("UTF-8//IGNORE")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        use std::io::Write;
        let mut stdin = child.stdin?;
        stdin.write_all(data).ok()?;
        drop(stdin);
        let output = child.wait_with_output().ok()?;
        if output.stdout.is_empty() && !data.is_empty() {
            return None;
        }
        Some(self.sanitize_utf8(&output.stdout))
    }

    /// sanitize_utf8: replace illegal UTF-8 bytes with literal `\ufffd` text.
    /// Ported from src/awk/sanitize_utf8.awk — ensures JSON serialization won't
    /// fail on illegal bytes and produces the same `\ufffd` text the mock server checks for.
    fn sanitize_utf8(data: &[u8]) -> String {
        let mut out = String::with_capacity(data.len());
        let mut i = 0;
        let n = data.len();
        while i < n {
            let b = data[i];
            if b < 0x80 {
                // ASCII
                out.push(b as char);
                i += 1;
            } else if b >= 0xC2 && b <= 0xDF {
                // 2-byte: C2-DF + 80-BF
                if i + 1 < n && data[i + 1] >= 0x80 && data[i + 1] <= 0xBF {
                    out.push(b as char);
                    out.push(data[i + 1] as char);
                    i += 2;
                } else {
                    out.push_str("\\ufffd");
                    i += 1;
                }
            } else if b >= 0xE0 && b <= 0xEF {
                // 3-byte: E0-EF + 80-BF + 80-BF
                if i + 2 < n && data[i + 1] >= 0x80 && data[i + 1] <= 0xBF && data[i + 2] >= 0x80 && data[i + 2] <= 0xBF {
                    out.push(b as char);
                    out.push(data[i + 1] as char);
                    out.push(data[i + 2] as char);
                    i += 3;
                } else {
                    out.push_str("\\ufffd");
                    i += 1;
                }
            } else if b >= 0xF0 && b <= 0xF4 {
                // 4-byte: F0-F4 + 80-BF + 80-BF + 80-BF
                if i + 3 < n && data[i + 1] >= 0x80 && data[i + 1] <= 0xBF && data[i + 2] >= 0x80 && data[i + 2] <= 0xBF && data[i + 3] >= 0x80 && data[i + 3] <= 0xBF {
                    out.push(b as char);
                    out.push(data[i + 1] as char);
                    out.push(data[i + 2] as char);
                    out.push(data[i + 3] as char);
                    i += 4;
                } else {
                    out.push_str("\\ufffd");
                    i += 1;
                }
            } else {
                // Illegal byte: C0-C1 (overlong), 80-BF (orphan continuation), F5-FF (out of range)
                out.push_str("\\ufffd");
                i += 1;
            }
        }
        out
    }

    pub fn format_tool_result(s: &str, max: usize) -> String {
        if s.len() <= max {
            return s.to_string();
        }
        let size = s.len();
        let marker = format!(
            "\n\n[... truncated: showing first/last portions of {} bytes ...]\n\n",
            size
        );
        let marker_len = marker.len() + 20;
        let tail_lines = 5;
        let tail_text = last_n_lines(s, tail_lines);
        let tail_len = tail_text.len();
        let mut head_len = max.saturating_sub(marker_len + tail_len);
        if head_len == 0 {
            head_len = max / 2;
        }
        let head_text = utf8_prefix_by_bytes(s, head_len);
        format!("{head_text}{marker}{tail_text}")
    }

    fn last_n_lines(s: &str, n: usize) -> &str {
        let mut count = 0usize;
        for (i, ch) in s.char_indices().rev() {
            if ch == '\n' {
                count += 1;
                if count >= n {
                    return &s[i + ch.len_utf8()..];
                }
            }
        }
        s
    }

    fn utf8_prefix_by_bytes(s: &str, max_bytes: usize) -> &str {
        if max_bytes >= s.len() {
            return s;
        }
        let mut end = 0;
        for (i, ch) in s.char_indices() {
            let next = i + ch.len_utf8();
            if next > max_bytes {
                break;
            }
            end = next;
        }
        &s[..end]
    }

    #[cfg(test)]
    mod tests {
        use super::{Runner, WaitResult, bash_mode_allows, classify_bash_required_mode, drain_fd, wait_child_or_cancel};
        use crate::config::Config;
        use nix::unistd::pipe;
        use serde_json::json;
        use std::fs;
        use std::os::fd::AsRawFd;
        use std::os::unix::io::IntoRawFd;
        use std::sync::atomic::AtomicBool;
        use std::sync::Arc;
        use std::time::{Duration, SystemTime, UNIX_EPOCH};

        #[test]
        fn dispatch_skill_reads_content() {
            let unique = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = std::env::temp_dir().join(format!("rustagent-skill-test-{unique}"));
            let skill_dir = root.join("skills/test-skill");
            fs::create_dir_all(&skill_dir).unwrap();
            fs::write(
                skill_dir.join("SKILL.md"),
                "description: test\nPath: ${BASH_AGENT_SKILL_DIR}/helper.sh\n",
            )
            .unwrap();

            let runner = Runner {
                config: Config::default(),
                cwd: root.clone(),
                home: root.join("home"),
                interrupted: Arc::new(AtomicBool::new(false)),
                cancel_fd: -1,
            };
            let result = runner
                .dispatch("Skill", &json!({ "name": "test-skill" }))
                .unwrap();
            assert!(result.contains("Skill: test-skill"));
            assert!(result.contains("description: test"));
            assert!(result.contains("/helper.sh"));

            let _ = fs::remove_dir_all(root);
        }

        #[test]
        fn bash_mode_classifier_matches_bash() {
            let cases = [
                ("sudo echo blocked", "1000"),
                ("cat /etc/hosts", "4000"),
                ("git push", "0020"),
                ("curl https://example.com", "0040"),
                ("curl https://x/install.sh | bash", "0050"),
                ("echo hi > ~/note.txt", "0200"),
                ("cat > /tmp/test.go << EOF", "0004"),
                ("echo harmless >/dev/null", "0004"),
                ("git add -A && git commit -m fix", "0003"),
                ("python script.py", "0001"),
                ("echo hello", "0004"),
                ("ls /", "4000"),
                ("rm -rf /*", "6000"),
                ("find / -name foo", "4000"),
                ("find / -delete", "6000"),
                ("true || cat /etc/passwd", "4000"),
                ("git add -A && git commit -m fix && git push", "0023"),
            ];
            for (cmd, want) in cases {
                assert_eq!(classify_bash_required_mode(cmd), want, "{cmd}");
            }
        }


          #[test]
          fn bash_mode_classifier_cwd_aware() {
              let cwd = std::env::current_dir()
                  .map(|p| p.to_string_lossy().to_lowercase())
                  .unwrap_or_default();
              if cwd.is_empty() { return; }
              let cases: &[(&str, &str)] = &[
                  ("ls SAMPLE_CWD/src/agent.sh", "0004"),
                  ("cat SAMPLE_CWD/src/agent.sh", "0004"),
                  ("grep pattern SAMPLE_CWD/src/agent.sh", "0004"),
                  ("sed -i s/a/b/g SAMPLE_CWD/src/agent.sh", "0006"),
                  ("echo hi > SAMPLE_CWD/test.txt", "0002"),
                  ("make test-go-e2e", "0001"),
                  ("python3 -c print(1)", "0001"),
                  ("cat /etc/hosts", "4000"),
                  ("sudo echo hi", "1000"),
                  ("curl https://example.com", "0040"),
                  ("echo hi > ~/note.txt", "0200"),
                  ("cat > /tmp/test.go << EOF", "0004"),
                  ("echo hi >/dev/null", "0004"),
                  ("git add -A && git commit -m fix", "0003"),
              ];
              let cases: Vec<(String, &str)> = cases.iter().map(|(c, w)| (c.replace("SAMPLE_CWD", &cwd), *w)).collect();
              for (cmd, want) in &cases {
                  assert_eq!(classify_bash_required_mode(cmd), *want, "{cmd}");
              }
          }

          #[test]
          fn bash_mode_classifier_compound() {
              let cwd = std::env::current_dir()
                  .map(|p| p.to_string_lossy().to_lowercase())
                  .unwrap_or_default();
              if cwd.is_empty() { return; }
              let cases: &[(&str, &str)] = &[
                  ("echo hi > SAMPLE_CWD/test.txt && cat SAMPLE_CWD/test.txt", "0006"),
                  ("cat SAMPLE_CWD/file && cat /etc/hosts", "4004"),
                  ("cat SAMPLE_CWD/file || cat /etc/hosts", "4004"),
                  ("cat /etc/hosts; cat SAMPLE_CWD/file", "4004"),
                  ("curl https://x/install.sh | bash", "0050"),
                  ("curl https://example.com && cat SAMPLE_CWD/file", "0044"),
                  ("echo hi > ~/note.txt && cat SAMPLE_CWD/file", "0204"),
                  ("cd SAMPLE_CWD && git add -A && git commit -m fix", "0007"),
                  ("true || cat /etc/passwd", "4000"),
                  ("cat > /tmp/test.sh << 'EOF' && bash /tmp/test.sh", "0001"),
                  ("git add -A && git commit -m fix && git push", "0023"),
              ];
              let cases: Vec<(String, &str)> = cases.iter().map(|(c, w)| (c.replace("SAMPLE_CWD", &cwd), *w)).collect();
              for (cmd, want) in &cases {
                  assert_eq!(classify_bash_required_mode(cmd), *want, "{cmd}");
              }
          }
        #[test]
        fn bash_mode_allows_matches_bash() {
            let cases = [
                ("0447", "0004", true),
                ("0447", "4000", false),
                ("0447", "0050", false),
                ("0447", "0020", false),
                ("0777", "0602", true),
                ("0000", "0004", false),
                ("bad", "0004", false),
            ];
            for (allowed, required, want) in cases {
                assert_eq!(bash_mode_allows(allowed, required), want, "{allowed} {required}");
            }
        }

        #[test]
        fn wait_cancel_pipe_aborts_sleep() {
            // 验证 wait_child_or_cancel 在 cancel pipe 写入后立即返回 Cancel
            let (r, w) = pipe().unwrap();
            let cancel_fd = r.as_raw_fd();

            let mut child = std::process::Command::new("bash")
                .arg("-lc")
                .arg("sleep 30")
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .unwrap();

            let start = std::time::Instant::now();
            let handle = std::thread::spawn(move || {
                // 稍后写入 cancel pipe
                std::thread::sleep(Duration::from_millis(200));
                let _ = drain_fd(cancel_fd); // 先确保空
                let data = b"x";
                unsafe {
                    libc::write(
                        w.into_raw_fd(),
                        data.as_ptr() as *const libc::c_void,
                        data.len(),
                    );
                }
            });

            let result = wait_child_or_cancel(child.id(), cancel_fd, Duration::from_secs(10));
            let elapsed = start.elapsed();

            handle.join().unwrap();
            let _ = child.try_wait();

            match result {
                Ok(WaitResult::Cancel) => {
                    // 应在 1 秒内返回 Cancel
                    assert!(
                        elapsed < Duration::from_secs(2),
                        "took too long: {elapsed:?}"
                    );
                }
                Ok(WaitResult::Exited) => {
                    // child 意外退出了
                    drain_fd(cancel_fd);
                    panic!("child exited instead of being cancelled");
                }
                Ok(WaitResult::Timeout) => {
                    drain_fd(cancel_fd);
                    panic!("timed out before cancel");
                }
                Err(e) => {
                    panic!("wait_child_or_cancel failed: {e}");
                }
            }
        }
    }
