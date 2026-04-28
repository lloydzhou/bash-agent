use anyhow::{Result, anyhow};
use reqwest::blocking::{Client, Response};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use std::collections::VecDeque;
use std::fmt;
use std::io::{Read, Result as IoResult};
use std::sync::mpsc;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::thread;
use std::thread::sleep;
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
const DEFAULT_STREAM_LOW_SPEED_LIMIT: usize = 1;
const DEFAULT_STREAM_LOW_SPEED_TIME: Duration = Duration::from_secs(60);
const DEFAULT_STREAM_CHECK_INTERVAL: Duration = Duration::from_secs(1);

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
                        let retryable =
                            should_retry_status(code) && should_retry_attempt(attempt, start);
                        if retryable {
                            sleep(DEFAULT_RETRY_DELAY);
                            attempt += 1;
                            continue;
                        }
                        return Err(HTTPError {
                            status_code: code,
                            body: text.trim().to_string(),
                        }
                        .into());
                    }
                    return StreamBody::new(
                        self.client.clone(),
                        url.to_string(),
                        h.clone(),
                        body.to_vec(),
                        resp,
                        DEFAULT_STREAM_LOW_SPEED_LIMIT,
                        DEFAULT_STREAM_LOW_SPEED_TIME,
                        DEFAULT_STREAM_CHECK_INTERVAL,
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
                    }
                    .into());
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
    rx: Receiver<StreamChunk>,
    buf: std::io::Cursor<Vec<u8>>,
    done: bool,
    low_speed_limit: usize,
    low_speed_time: Duration,
    check_interval: Duration,
    samples: VecDeque<StreamSample>,
    window_bytes: usize,
}

#[derive(Clone)]
struct StreamChunk {
    at: Instant,
    data: Vec<u8>,
}

#[derive(Clone)]
struct StreamSample {
    at: Instant,
    bytes: usize,
}

impl StreamBody {
    fn new(
        client: Client,
        url: String,
        headers: HeaderMap,
        request_body: Vec<u8>,
        resp: Response,
        low_speed_limit: usize,
        low_speed_time: Duration,
        check_interval: Duration,
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
            low_speed_limit,
            low_speed_time,
            check_interval,
            samples: VecDeque::new(),
            window_bytes: 0,
        })
    }

    fn try_retry(&mut self) -> std::io::Result<()> {
        sleep(self.retry_delay);
        let resp = self
            .client
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

fn spawn_reader(mut resp: Response) -> Receiver<StreamChunk> {
    let (tx, rx) = mpsc::channel();
    let _ = thread::spawn(move || {
        let mut buf = [0u8; 8192];
        loop {
            match resp.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if tx
                        .send(StreamChunk {
                            at: Instant::now(),
                            data: buf[..n].to_vec(),
                        })
                        .is_err()
                    {
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
            match self.rx.recv_timeout(self.check_interval) {
                Ok(chunk) => {
                    self.record_chunk(chunk.at, chunk.data.len());
                    self.buf = std::io::Cursor::new(chunk.data);
                }
                Err(RecvTimeoutError::Timeout) => {
                    if self.low_speed_exceeded(Instant::now()) {
                        if self.attempt < self.max_retries
                            && should_retry_attempt(self.attempt, self.start)
                        {
                            self.attempt += 1;
                            match self.try_retry() {
                                Ok(()) => {
                                    self.buf = std::io::Cursor::new(b"RETRY:\n".to_vec());
                                    continue;
                                }
                                Err(_) => {
                                    self.done = true;
                                    return Err(std::io::Error::new(
                                        std::io::ErrorKind::TimedOut,
                                        "stream low speed timeout",
                                    ));
                                }
                            }
                        }
                        self.done = true;
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::TimedOut,
                            "stream low speed timeout",
                        ));
                    }
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

impl StreamBody {
    fn record_chunk(&mut self, at: Instant, bytes: usize) {
        self.samples.push_back(StreamSample { at, bytes });
        self.window_bytes = self.window_bytes.saturating_add(bytes);
        self.prune_window(at);
    }

    fn prune_window(&mut self, now: Instant) {
        while let Some(sample) = self.samples.front() {
            if now.saturating_duration_since(sample.at) <= self.low_speed_time {
                break;
            }
            self.window_bytes = self.window_bytes.saturating_sub(sample.bytes);
            self.samples.pop_front();
        }
    }

    fn low_speed_exceeded(&mut self, now: Instant) -> bool {
        self.prune_window(now);
        if now.duration_since(self.start) < self.low_speed_time {
            return false;
        }
        self.window_bytes
            < self
                .low_speed_limit
                .saturating_mul(self.low_speed_time.as_secs() as usize)
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

#[cfg(test)]
mod tests {
    use super::{StreamBody, StreamChunk};
    use reqwest::blocking::Client;
    use reqwest::header::HeaderMap;
    use std::collections::VecDeque;
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    #[test]
    fn low_speed_window_expires_without_bytes() {
        let start = Instant::now();
        let mut body = StreamBody {
            client: Client::new(),
            url: String::new(),
            headers: HeaderMap::new(),
            request_body: Vec::new(),
            max_retries: 0,
            retry_delay: Duration::from_secs(1),
            start,
            attempt: 0,
            rx: mpsc::channel::<StreamChunk>().1,
            buf: std::io::Cursor::new(Vec::new()),
            done: false,
            low_speed_limit: 1,
            low_speed_time: Duration::from_secs(60),
            check_interval: Duration::from_secs(1),
            samples: VecDeque::new(),
            window_bytes: 0,
        };

        assert!(!body.low_speed_exceeded(start + Duration::from_secs(59)));
        assert!(body.low_speed_exceeded(start + Duration::from_secs(60)));
    }

    #[test]
    fn low_speed_window_uses_recent_bytes_only() {
        let start = Instant::now();
        let mut body = StreamBody {
            client: Client::new(),
            url: String::new(),
            headers: HeaderMap::new(),
            request_body: Vec::new(),
            max_retries: 0,
            retry_delay: Duration::from_secs(1),
            start,
            attempt: 0,
            rx: mpsc::channel::<StreamChunk>().1,
            buf: std::io::Cursor::new(Vec::new()),
            done: false,
            low_speed_limit: 1,
            low_speed_time: Duration::from_secs(60),
            check_interval: Duration::from_secs(1),
            samples: VecDeque::new(),
            window_bytes: 0,
        };

        body.record_chunk(start + Duration::from_secs(30), 100);
        assert!(!body.low_speed_exceeded(start + Duration::from_secs(60)));
        assert!(body.low_speed_exceeded(start + Duration::from_secs(91)));
    }
}
