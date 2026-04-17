use anyhow::{Result, anyhow};
use reqwest::blocking::{Client, Response};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use std::io::{Read, Result as IoResult};
use std::fmt;
use std::thread::sleep;
use std::sync::mpsc;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

/// HTTPError carries the status code and body of an HTTP or network error.
#[derive(Debug)]
pub struct HTTPError {
    /// HTTP status code (0 when the request never reached the server)
    pub status_code: u16,
    /// Response body or network error message
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
    /// Returns a formatted error string matching Bash's convention:
    ///   "ERROR:{code}\tHTTP {code}: {body}"  (HTTP errors)
    ///   "ERROR:0\t{body}"                     (network errors)
    pub fn format_detailed(&self) -> String {
        if self.status_code > 0 {
            format!("ERROR:{}\tHTTP {}: {}", self.status_code, self.status_code, self.body)
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
const DEFAULT_IDLE_TIMEOUT: Duration = Duration::from_secs(60);

impl StreamClient {
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: Client::builder()
                .timeout(None)
                .connect_timeout(DEFAULT_CONNECT_TIMEOUT)
                .build()?,
        })
    }

    pub fn post(&self, url: &str, headers: &[(String, String)], body: &[u8]) -> Result<StreamBody> {
        let mut h = HeaderMap::new();
        for (k, v) in headers {
            h.insert(
                HeaderName::from_bytes(k.as_bytes())?,
                HeaderValue::from_str(v).map_err(|e| anyhow!(e.to_string()))?,
            );
        }

        let start = Instant::now();
        let mut attempt: u32 = 0;
        loop {
            let resp = self
                .client
                .post(url)
                .headers(h.clone())
                .body(body.to_vec())
                .send();

            match resp {
                Ok(resp) => {
                    let code = resp.status().as_u16();
                    if code >= 400 {
                        let text = resp.text().unwrap_or_default();
                        let retryable = should_retry_status(code) && should_retry_attempt(attempt, start);
                        if retryable {
                            sleep(DEFAULT_RETRY_DELAY);
                            attempt += 1;
                            continue;
                        }
                        return Err(HTTPError {
                            status_code: code,
                            body: text.trim().to_string(),
                        }.into());
                    }
                    return StreamBody::new(
                        self.client.clone(),
                        url.to_string(),
                        h.clone(),
                        body.to_vec(),
                        resp,
                        DEFAULT_IDLE_TIMEOUT,
                        DEFAULT_RETRY_COUNT,
                        DEFAULT_RETRY_DELAY,
                        start,
                    );
                }
                Err(err) => {
                    if should_retry_attempt(attempt, start) {
                        sleep(DEFAULT_RETRY_DELAY);
                        attempt += 1;
                        continue;
                    }
                    return Err(HTTPError {
                        status_code: 0,
                        body: err.to_string(),
                    }.into());
                }
            }
        }
    }
}

pub struct StreamBody {
    // Retry context
    client: Client,
    url: String,
    headers: HeaderMap,
    request_body: Vec<u8>,
    max_retries: u32,
    retry_delay: Duration,
    start: Instant,
    attempt: u32,
    // Current response stream
    rx: Receiver<Vec<u8>>,
    buf: std::io::Cursor<Vec<u8>>,
    done: bool,
    idle_timeout: Duration,
}

impl StreamBody {
    fn new(
        client: Client,
        url: String,
        headers: HeaderMap,
        request_body: Vec<u8>,
        resp: Response,
        idle_timeout: Duration,
        max_retries: u32,
        retry_delay: Duration,
        start: Instant,
    ) -> Result<Self> {
        let rx = spawn_reader(resp);
        Ok(Self {
            client,
            url,
            headers,
            request_body,
            max_retries,
            retry_delay,
            start,
            attempt: 0,
            rx,
            buf: std::io::Cursor::new(Vec::new()),
            done: false,
            idle_timeout,
        })
    }

    fn try_retry(&mut self) -> std::io::Result<()> {
        sleep(self.retry_delay);
        let resp = self.client
            .post(&self.url)
            .headers(self.headers.clone())
            .body(self.request_body.clone())
            .send()
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
        let code = resp.status().as_u16();
        if code >= 400 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::Other,
                format!("HTTP {} on retry", code),
            ));
        }
        self.rx = spawn_reader(resp);
        self.done = false;
        Ok(())
    }
}

fn spawn_reader(mut resp: Response) -> Receiver<Vec<u8>> {
    let (tx, rx) = mpsc::channel();
    let _ = thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match resp.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });
    rx
}

impl Read for StreamBody {
    fn read(&mut self, out: &mut [u8]) -> IoResult<usize> {
        if self.done {
            return Ok(0);
        }
        loop {
            if (self.buf.position() as usize) < self.buf.get_ref().len() {
                return self.buf.read(out);
            }
            match self.rx.recv_timeout(self.idle_timeout) {
                Ok(chunk) => {
                    self.buf = std::io::Cursor::new(chunk);
                }
                Err(RecvTimeoutError::Timeout) => {
                    if self.attempt < self.max_retries
                        && should_retry_attempt(self.attempt, self.start)
                    {
                        self.attempt += 1;
                        match self.try_retry() {
                            Ok(()) => {
                                self.buf =
                                    std::io::Cursor::new(b"RETRY:\n".to_vec());
                                continue;
                            }
                            Err(_) => {
                                self.done = true;
                                return Err(std::io::Error::new(
                                    std::io::ErrorKind::TimedOut,
                                    "idle timeout",
                                ));
                            }
                        }
                    }
                    self.done = true;
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        "idle timeout",
                    ));
                }
                Err(RecvTimeoutError::Disconnected) => {
                    self.done = true;
                    return Ok(0);
                }
            }
        }
    }
}

impl Drop for StreamBody {
    fn drop(&mut self) {
        self.done = true;
        // Intentionally do not join the background reader thread here.
        // The underlying blocking read may still be stuck in the network stack,
        // and joining would turn an idle-timeout into a hang.
    }
}

fn should_retry_attempt(attempt: u32, start: Instant) -> bool {
    if attempt >= DEFAULT_RETRY_COUNT {
        return false;
    }
    start.elapsed() + DEFAULT_RETRY_DELAY <= DEFAULT_RETRY_MAX_TIME
}

fn should_retry_status(code: u16) -> bool {
    matches!(code, 408 | 409 | 425 | 429 | 500 | 502 | 503 | 504)
}
