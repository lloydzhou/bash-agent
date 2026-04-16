use anyhow::{Result, anyhow};
use reqwest::blocking::{Client, Response};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use std::fmt;
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

impl StreamClient {
    pub fn new() -> Result<Self> {
        Ok(Self {
            client: Client::builder().timeout(None).build()?,
        })
    }

    pub fn post(&self, url: &str, headers: &[(String, String)], body: &[u8]) -> Result<Response> {
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
                    return Ok(resp);
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

fn should_retry_attempt(attempt: u32, start: Instant) -> bool {
    if attempt >= DEFAULT_RETRY_COUNT {
        return false;
    }
    start.elapsed() + DEFAULT_RETRY_DELAY <= DEFAULT_RETRY_MAX_TIME
}

fn should_retry_status(code: u16) -> bool {
    matches!(code, 408 | 409 | 425 | 429 | 500 | 502 | 503 | 504)
}
