use anyhow::Result;
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::time::SystemTime;

pub fn path_to_project_id(path: &str) -> String {
    path.replace('/', "-").trim_start_matches('-').to_string()
}

pub fn normalize_display_text(s: &str, interactive: bool) -> String {
    let normalized = s.replace("\r\n", "\n").replace('\r', "\n");
    if interactive {
        normalized.replace('\n', "\r\n")
    } else {
        normalized
    }
}

pub fn truncate_for_replay(s: &str, limit: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= limit {
        return s.to_string();
    }
    let mut out: String = chars.into_iter().take(limit).collect();
    out.push_str("...");
    out
}

pub fn touch(path: &Path) -> Result<()> {
    if !path.exists() {
        fs::File::create(path)?;
    }
    Ok(())
}

pub fn chrono_like_now() -> String {
    use std::time::UNIX_EPOCH;
    use time::format_description::FormatItem;
    use time::macros::format_description;
    static FMT: &[FormatItem<'_>] =
        format_description!("[year][month][day]-[hour][minute][second]");
    let base = time::OffsetDateTime::now_utc()
        .format(FMT)
        .unwrap_or_else(|_| {
            format!(
                "{}",
                std::time::SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0)
            )
        });
    let rand_suffix = std::time::SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos() as u16)
        .unwrap_or(0);
    format!("{}-{:04x}", base, rand_suffix)
}

pub fn stats_get_f64(m: &serde_json::Map<String, Value>, key: &str) -> f64 {
    m.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0)
}

pub fn chrono_now_rfc3339() -> String {
    let now = time::OffsetDateTime::now_utc();
    let fmt = time::format_description::well_known::Rfc3339;
    now.format(&fmt).unwrap_or_else(|_| String::new())
}

pub fn parse_input_fields(input: &Value) -> std::collections::BTreeMap<String, String> {
    let mut fields = std::collections::BTreeMap::new();
    if let Some(obj) = input.as_object() {
        for (k, v) in obj {
            match v {
                Value::String(s) => {
                    fields.insert(k.clone(), s.clone());
                }
                _ => {
                    fields.insert(k.clone(), v.to_string());
                }
            }
        }
    }
    fields
}

pub fn build_claude_request(
    cfg: &crate::config::Config,
    messages: &[Value],
    tools: &[Value],
    system_prompt: &str,
    max_tokens: i32,
    thinking: &str,
    effort: &str,
) -> Result<Vec<u8>> {
    let mut body = serde_json::json!({
        "model": cfg.model,
        "max_tokens": max_tokens,
        "stream": true,
        "messages": messages,
    });
    if thinking != "disabled" {
        body["thinking"] = serde_json::json!({
            "type": thinking,
        });
        body["output_config"] = serde_json::json!({
            "effort": effort,
        });
    }
    if !system_prompt.is_empty() {
        body["system"] = Value::String(system_prompt.to_string());
    }
    if !tools.is_empty() {
        body["tools"] = Value::Array(tools.to_vec());
    }
    Ok(serde_json::to_vec(&body)?)
}

pub fn truncate_str(s: &str, n: usize) -> String {
    if s.len() <= n {
        return s.to_string();
    }
    let mut end = n;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &s[..end])
}

pub fn format_system_time(st: &SystemTime) -> String {
    use time::macros::format_description;
    let dt: time::OffsetDateTime = match (*st).try_into() {
        Ok(dt) => dt,
        Err(_) => return format!("{:?}", st),
    };
    static FMT: &[time::format_description::FormatItem<'_>] =
        format_description!("[year]-[month]-[day] [hour]:[minute]");
    dt.format(FMT).unwrap_or_else(|_| format!("{:?}", st))
}
