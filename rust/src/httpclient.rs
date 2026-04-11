use anyhow::{Result, anyhow};
use reqwest::blocking::{Client, Response};
use reqwest::header::{HeaderMap, HeaderName, HeaderValue};

pub struct StreamClient {
    pub client: Client,
}

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
        let resp = self
            .client
            .post(url)
            .headers(h)
            .body(body.to_vec())
            .send()?;
        if resp.status().as_u16() >= 400 {
            let code = resp.status().as_u16();
            let text = resp.text().unwrap_or_default();
            return Err(anyhow!(format!("http {code}: {}", text.trim())));
        }
        Ok(resp)
    }
}
