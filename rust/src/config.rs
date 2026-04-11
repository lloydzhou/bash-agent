use anyhow::{Result, anyhow, bail};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Chat,
    Compact,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputFormat {
    Human,
    StreamJson,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub provider: String,
    pub model: String,
    pub max_tokens: i32,
    pub summary_max_tokens: i32,
    pub tool_timeout_secs: i32,
    pub tool_result_max_bytes: usize,
    pub file_write_max_bytes: usize,
    pub output_format: OutputFormat,
    pub verbose: bool,
    pub api_key: String,
    pub base_url: String,
    pub prompt: String,
    pub max_turns: i32,
    pub max_context_bytes: usize,
    pub max_context_keep_pct: i32,
    pub skills: Vec<String>,
    pub interactive: bool,
    pub command: Command,
    pub session_mode: bool,
    pub session_id: String,
    pub continue_session: bool,
    pub list_sessions: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            provider: "claude".to_string(),
            model: String::new(),
            max_tokens: 4096,
            summary_max_tokens: 1024,
            tool_timeout_secs: 600,
            tool_result_max_bytes: 50_000,
            file_write_max_bytes: 1_048_576,
            output_format: OutputFormat::Human,
            verbose: false,
            api_key: String::new(),
            base_url: String::new(),
            prompt: String::new(),
            max_turns: 20,
            max_context_bytes: 200_000,
            max_context_keep_pct: 25,
            skills: Vec::new(),
            interactive: false,
            command: Command::Chat,
            session_mode: false,
            session_id: String::new(),
            continue_session: false,
            list_sessions: false,
        }
    }
}

pub fn parse_args(args: Vec<String>) -> Result<Config> {
    let mut cfg = Config::default();
    let mut i = 0usize;
    let mut args = args;
    if args.first().map(|s| s.as_str()) == Some("compact") {
        cfg.command = Command::Compact;
        args.remove(0);
    }

    while i < args.len() {
        let arg = &args[i];
        match arg.as_str() {
            "-p" | "--provider" => {
                cfg.provider = require_value(&args, i)?;
                i += 2;
            }
            "-m" | "--model" => {
                cfg.model = require_value(&args, i)?;
                i += 2;
            }
            "--max-tokens" => {
                cfg.max_tokens = require_value(&args, i)?.parse()?;
                i += 2;
            }
            "--tool-timeout" => {
                cfg.tool_timeout_secs = require_value(&args, i)?.parse()?;
                i += 2;
            }
            "--skill" => {
                cfg.skills.push(require_value(&args, i)?);
                i += 2;
            }
            "--max-turns" => {
                cfg.max_turns = require_value(&args, i)?.parse()?;
                i += 2;
            }
            "--max-context" => {
                cfg.max_context_bytes = parse_size_bytes(&require_value(&args, i)?)?;
                i += 2;
            }
            "--api-key" => {
                cfg.api_key = require_value(&args, i)?;
                i += 2;
            }
            "--base-url" => {
                cfg.base_url = require_value(&args, i)?;
                i += 2;
            }
            "--output-format" => {
                let v = require_value(&args, i)?;
                cfg.output_format = match v.as_str() {
                    "human" => OutputFormat::Human,
                    "stream-json" => OutputFormat::StreamJson,
                    _ => bail!("unknown output format: {v}"),
                };
                i += 2;
            }
            "--print" => {
                cfg.output_format = OutputFormat::StreamJson;
                i += 1;
            }
            "--session" => {
                cfg.session_mode = true;
                if i + 1 < args.len() && !args[i + 1].starts_with('-') {
                    cfg.session_id = args[i + 1].clone();
                    i += 2;
                } else {
                    i += 1;
                }
            }
            "--continue" => {
                cfg.session_mode = true;
                cfg.continue_session = true;
                i += 1;
            }
            "--list-sessions" => {
                cfg.list_sessions = true;
                i += 1;
            }
            "-v" | "--verbose" => {
                cfg.verbose = true;
                i += 1;
            }
            "-i" | "--interactive" => {
                cfg.interactive = true;
                i += 1;
            }
            "-h" | "--help" => {
                return Err(anyhow!("__HELP__"));
            }
            _ => {
                if arg.starts_with('-') {
                    bail!("unknown option: {arg}");
                }
                cfg.prompt = arg.clone();
                i += 1;
            }
        }
    }

    Ok(cfg)
}

fn require_value(args: &[String], i: usize) -> Result<String> {
    if i + 1 >= args.len() {
        bail!("missing value for {}", args[i]);
    }
    Ok(args[i + 1].clone())
}

pub fn apply_provider_defaults(cfg: &mut Config) -> Result<()> {
    match cfg.provider.as_str() {
        "claude" => {
            if cfg.api_key.is_empty() {
                cfg.api_key = std::env::var("ANTHROPIC_API_KEY").unwrap_or_default();
            }
            if cfg.base_url.is_empty() {
                cfg.base_url = std::env::var("ANTHROPIC_BASE_URL").unwrap_or_default();
            }
            if cfg.model.is_empty() {
                cfg.model = "claude-sonnet-4-20250514".to_string();
            }
            if cfg.api_key.is_empty() && cfg.base_url.is_empty() {
                bail!("no API key. Set ANTHROPIC_API_KEY or use --api-key");
            }
        }
        "openai" => {
            if cfg.api_key.is_empty() {
                cfg.api_key = std::env::var("OPENAI_API_KEY").unwrap_or_default();
            }
            if cfg.base_url.is_empty() {
                cfg.base_url = std::env::var("OPENAI_BASE_URL").unwrap_or_default();
            }
            if cfg.model.is_empty() {
                cfg.model = "gpt-4o".to_string();
            }
            if cfg.api_key.is_empty() && cfg.base_url.is_empty() {
                bail!("no API key. Set OPENAI_API_KEY or use --api-key");
            }
        }
        _ => bail!("unknown provider: {} (use claude|openai)", cfg.provider),
    }
    Ok(())
}

pub fn api_url(cfg: &Config) -> String {
    match cfg.provider.as_str() {
        "claude" => {
            let base = if cfg.base_url.is_empty() {
                "https://api.anthropic.com/v1"
            } else {
                cfg.base_url.as_str()
            };
            format!("{}/messages", base.trim_end_matches('/'))
        }
        "openai" => {
            let base = if cfg.base_url.is_empty() {
                "https://api.openai.com/v1"
            } else {
                cfg.base_url.as_str()
            };
            format!("{}/chat/completions", base.trim_end_matches('/'))
        }
        _ => String::new(),
    }
}

pub fn parse_size_bytes(raw: &str) -> Result<usize> {
    if raw.is_empty() {
        bail!("empty size");
    }
    let lower = raw.to_lowercase();
    let (num, m) = if let Some(v) = lower.strip_suffix('k') {
        (v, 1_000usize)
    } else if let Some(v) = lower.strip_suffix('m') {
        (v, 1_000_000usize)
    } else if let Some(v) = lower.strip_suffix('g') {
        (v, 1_000_000_000usize)
    } else {
        (lower.as_str(), 1usize)
    };
    Ok(num.parse::<usize>()? * m)
}
