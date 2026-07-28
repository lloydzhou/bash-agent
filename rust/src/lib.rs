pub mod agent;
pub mod ffi;
pub mod sse;
pub mod store;
pub mod tools;
pub mod transport;
pub mod util;

pub const TOOLS_JSON: &str = include_str!("tools.json");

pub mod config {
    use anyhow::{Result, bail};

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
        pub tool_timeout_secs: i32,
        pub tool_result_max_bytes: usize,
        pub file_write_max_bytes: usize,
        pub output_format: OutputFormat,
        pub verbose: bool,
        pub api_key: String,
        pub base_url: String,
        pub prompt: String,
        pub max_turns: i32,
        pub max_context_tokens: usize,
        pub dp_p_input: f64,
        pub dp_p_cache: f64,
        pub dp_p_out: f64,
        pub dp_v: usize,
        pub dp_s: usize,
        pub dp_l: f64,
        pub dp_baseline_e: i32,
        pub dp_e_fixed: i32,
        pub dp_r: f64,
        pub dp_beta: f64,
        pub dp_quality_penalty: f64,
        pub dp_min_keep_ratio: f64,
        pub skills: Vec<String>,
        pub thinking: String,
        pub effort: String,
        pub interactive: bool,
        pub session_mode: bool,
        pub session_id: String,
        pub continue_session: bool,
        pub list_sessions: bool,
        pub fork: bool,
    }

    impl Default for Config {
        fn default() -> Self {
            Self {
                provider: "claude".to_string(),
                model: String::new(),
                max_tokens: 16384,
                tool_timeout_secs: 600,
                tool_result_max_bytes: 100_000,
                file_write_max_bytes: 1_048_576,
                output_format: OutputFormat::Human,
                verbose: false,
                api_key: String::new(),
                base_url: String::new(),
                prompt: String::new(),
                max_turns: 1000,
                max_context_tokens: 200_000,
                dp_p_input: 3.0,
                dp_p_cache: 0.30,
                dp_p_out: 15.0,
                dp_v: 5000,
                dp_s: 500,
                dp_l: 0.0,
                dp_baseline_e: 8,
                dp_e_fixed: 0,
                dp_r: 0.8,
                dp_beta: 0.03,
                dp_quality_penalty: 0.2,
                dp_min_keep_ratio: 0.25,
                skills: Vec::new(),
                thinking: "adaptive".to_string(),
                effort: "high".to_string(),
                interactive: false,
                session_mode: false,
                session_id: String::new(),
                continue_session: false,
                list_sessions: false,
                fork: false,
            }
        }
    }

    pub fn apply_provider_defaults(cfg: &mut Config) -> Result<()> {
        if let Ok(v) = std::env::var("TOOL_RESULT_MAX_BYTES") {
            if let Ok(n) = v.parse::<usize>() {
                cfg.tool_result_max_bytes = n;
            }
        }
        if let Ok(v) = std::env::var("FILE_WRITE_MAX_BYTES") {
            if let Ok(n) = v.parse::<usize>() {
                cfg.file_write_max_bytes = n;
            }
        }
        if let Ok(v) = std::env::var("THINKING") {
            cfg.thinking = v;
        }
        if let Ok(v) = std::env::var("EFFORT") {
            cfg.effort = v;
        }
        if let Ok(v) = std::env::var("DP_P_INPUT") {
            if let Ok(f) = v.parse::<f64>() {
                if f > 0.0 {
                    cfg.dp_p_input = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_P_CACHE") {
            if let Ok(f) = v.parse::<f64>() {
                if f >= 0.0 {
                    cfg.dp_p_cache = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_P_OUT") {
            if let Ok(f) = v.parse::<f64>() {
                if f > 0.0 {
                    cfg.dp_p_out = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_V") {
            if let Ok(n) = v.parse::<usize>() {
                if n > 0 {
                    cfg.dp_v = n;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_S") {
            if let Ok(n) = v.parse::<usize>() {
                if n > 0 {
                    cfg.dp_s = n;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_L") {
            if let Ok(f) = v.parse::<f64>() {
                if f >= 0.0 {
                    cfg.dp_l = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_BASELINE_E") {
            if let Ok(n) = v.parse::<i32>() {
                if n >= 0 {
                    cfg.dp_baseline_e = n;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_E_FIXED") {
            if let Ok(n) = v.parse::<i32>() {
                if n >= 0 {
                    cfg.dp_e_fixed = n;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_R") {
            if let Ok(f) = v.parse::<f64>() {
                if f > 0.0 && f <= 1.0 {
                    cfg.dp_r = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_BETA") {
            if let Ok(f) = v.parse::<f64>() {
                if f >= 0.0 {
                    cfg.dp_beta = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_QUALITY_PENALTY") {
            if let Ok(f) = v.parse::<f64>() {
                if f >= 0.0 {
                    cfg.dp_quality_penalty = f;
                }
            }
        }
        if let Ok(v) = std::env::var("DP_MIN_KEEP_RATIO") {
            if let Ok(f) = v.parse::<f64>() {
                if f > 0.0 && f < 1.0 {
                    cfg.dp_min_keep_ratio = f;
                }
            }
        }

        // 先解析当前 provider 的显式参数和环境变量；DeepSeek 回退后才设置模型与传输配置。
        match cfg.provider.as_str() {
            "claude" => {
                if cfg.api_key.is_empty() {
                    cfg.api_key = std::env::var("ANTHROPIC_API_KEY").unwrap_or_default();
                }
                if cfg.base_url.is_empty() {
                    cfg.base_url = std::env::var("ANTHROPIC_BASE_URL").unwrap_or_default();
                }
            }
            "openai" => {
                if cfg.api_key.is_empty() {
                    cfg.api_key = std::env::var("OPENAI_API_KEY").unwrap_or_default();
                }
                if cfg.base_url.is_empty() {
                    cfg.base_url = std::env::var("OPENAI_BASE_URL").unwrap_or_default();
                }
            }
            _ => bail!("unknown provider: {} (use claude|openai)", cfg.provider),
        }

        // 仅当前 provider 没有显式配置时，自动回退至 DeepSeek。
        if cfg.api_key.is_empty() && cfg.base_url.is_empty() {
            if let Ok(ds_key) = std::env::var("DEEPSEEK_API_KEY") {
                if !ds_key.is_empty() {
                    cfg.provider = "claude".to_string();
                    cfg.api_key = ds_key;
                    cfg.base_url = "https://api.deepseek.com/anthropic".to_string();
                    if cfg.model.is_empty() {
                        cfg.model = "deepseek-v4-flash".to_string();
                    }
                }
            }
        }

        if cfg.api_key.is_empty() && cfg.base_url.is_empty() {
            match cfg.provider.as_str() {
                "claude" => bail!("no API key. Set ANTHROPIC_API_KEY or use --api-key"),
                "openai" => bail!("no API key. Set OPENAI_API_KEY or use --api-key"),
                _ => unreachable!(),
            }
        }

        if cfg.model.is_empty() {
            cfg.model = match cfg.provider.as_str() {
                "claude" => "claude-sonnet-4-20250514",
                "openai" => "gpt-4o",
                _ => unreachable!(),
            }
            .to_string();
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
                format!("{}/messages", base)
            }
            "openai" => {
                let base = if cfg.base_url.is_empty() {
                    "https://api.openai.com/v1"
                } else {
                    cfg.base_url.as_str()
                };
                format!("{}/chat/completions", base)
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
}

pub mod types {
    use anyhow::{Result, bail};
    use serde::{Deserialize, Serialize};
    use serde_json::Value;
    use std::collections::BTreeMap;

    /// 消息角色
    #[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
    #[serde(rename_all = "lowercase")]
    pub enum MessageRole {
        User,
        Assistant,
        System,
    }

    /// 消息内容块
    #[derive(Debug, Clone, Serialize, Deserialize)]
    #[serde(tag = "type")]
    pub enum MessageContent {
        #[serde(rename = "text")]
        Text { text: String },
        #[serde(rename = "thinking")]
        Thinking { thinking: String },
        #[serde(rename = "tool_use")]
        ToolUse {
            id: String,
            name: String,
            input: Value,
        },
        #[serde(rename = "tool_result")]
        ToolResult {
            tool_use_id: String,
            content: String,
        },
    }

    /// 流式事件
    #[derive(Debug, Clone)]
    pub enum StreamEvent {
        TextDelta {
            delta: String,
        },
        ThinkingDelta {
            delta: String,
        },
        ToolUseStart {
            id: String,
            name: String,
            input: Value,
        },
        ToolResult {
            tool_use_id: String,
            content: String,
            is_error: bool,
        },
        Usage {
            input_tokens: i64,
            output_tokens: i64,
        },
        Done,
    }

    /// 用量统计
    #[derive(Debug, Clone)]
    pub struct Usage {
        pub input_tokens: i64,
        pub output_tokens: i64,
    }

    /// 对话消息
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct Message {
        pub role: MessageRole,
        pub content: MessageContent,
    }

    #[derive(Debug, Clone)]
    pub enum Event {
        Text(TextEvent),
        Thinking(ThinkingEvent),
        ToolCall(ToolCallEvent),
        Usage(UsageEvent),
        Stop(StopEvent),
        Error(ErrorEvent),
        Retry(RetryEvent),
    }

    impl Event {
        pub fn render(&self) -> String {
            match self {
                Event::Text(e) => format!("TEXT:{}", escape_text(&e.content)),
                Event::Thinking(e) => format!("THINKING:{}", escape_text(&e.content)),
                Event::ToolCall(e) => {
                    let mut out = format!(
                        "TOOL_CALL:{}\t{}\t{}",
                        e.name,
                        e.id,
                        escape_text(&e.input_json.to_string())
                    );
                    for key in &e.order {
                        out.push('\t');
                        out.push_str(key);
                        out.push('\t');
                        out.push_str(&escape_text(
                            e.fields.get(key).map(String::as_str).unwrap_or(""),
                        ));
                    }
                    out
                }
                Event::Usage(e) => format!(
                    "USAGE:{}\t{}\t{}\t{}",
                    e.input_tokens,
                    e.output_tokens,
                    e.cache_read_input_tokens,
                    e.cache_creation_input_tokens
                ),
                Event::Stop(e) => format!("STOP:{}", e.reason),
                Event::Error(e) => format!("ERROR:{}", e.message),
                Event::Retry(_) => "RETRY:".to_string(),
            }
        }
    }

    #[derive(Debug, Clone)]
    pub struct TextEvent {
        pub content: String,
    }

    #[derive(Debug, Clone)]
    pub struct ThinkingEvent {
        pub content: String,
    }

    #[derive(Debug, Clone)]
    pub struct StopEvent {
        pub reason: String,
    }

    #[derive(Debug, Clone)]
    pub struct ErrorEvent {
        pub message: String,
    }

    #[derive(Debug, Clone)]
    pub struct RetryEvent {}

    #[derive(Debug, Clone)]
    pub struct UsageEvent {
        pub input_tokens: i64,
        pub output_tokens: i64,
        pub cache_read_input_tokens: i64,
        pub cache_creation_input_tokens: i64,
    }

    #[derive(Debug, Clone)]
    pub struct ToolCallEvent {
        pub name: String,
        pub id: String,
        pub input_json: Value,
        pub fields: BTreeMap<String, String>,
        pub order: Vec<String>,
    }

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct ToolResultContent {
        #[serde(rename = "type")]
        pub kind: String,
        pub tool_use_id: String,
        pub content: String,
    }

    pub fn escape_text(s: &str) -> String {
        s.replace('\\', "\\\\")
            .replace('\n', "\\n")
            .replace('\r', "\\r")
            .replace('\t', "\\t")
    }

    pub fn unescape_text(s: &str) -> String {
        let mut out = String::with_capacity(s.len());
        let mut chars = s.chars();
        while let Some(c) = chars.next() {
            if c != '\\' {
                out.push(c);
                continue;
            }
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        }
        out
    }

    pub fn parse_tool_call_payload(payload: &str) -> Result<ToolCallEvent> {
        let parts: Vec<&str> = payload.split('\t').collect();
        if parts.len() < 3 {
            bail!("invalid tool call payload")
        }
        let input: Value = serde_json::from_str(&unescape_text(parts[2]))?;
        let mut fields = BTreeMap::new();
        let mut order = Vec::new();
        let mut i = 3;
        while i + 1 < parts.len() {
            let key = parts[i].to_string();
            let value = unescape_text(parts[i + 1]);
            fields.insert(key.clone(), value);
            order.push(key);
            i += 2;
        }
        Ok(ToolCallEvent {
            name: parts[0].to_string(),
            id: parts[1].to_string(),
            input_json: input,
            fields,
            order,
        })
    }

    pub fn parse_usage_payload(payload: &str) -> Result<UsageEvent> {
        let parts: Vec<&str> = payload.split('\t').collect();
        if parts.len() != 4 {
            bail!("invalid usage payload")
        }
        Ok(UsageEvent {
            input_tokens: parts[0].parse()?,
            output_tokens: parts[1].parse()?,
            cache_read_input_tokens: parts[2].parse()?,
            cache_creation_input_tokens: parts[3].parse()?,
        })
    }

    /// 输出格式
    #[derive(Debug, Clone, Copy, PartialEq, Eq)]
    pub enum OutputFormat {
        Human,
        StreamJson,
    }

    /// 配置
    #[derive(Debug, Clone)]
    pub struct Config {
        pub provider: String,
        pub model: String,
        pub max_tokens: i32,
        pub tool_timeout_secs: i32,
        pub tool_result_max_bytes: usize,
        pub file_write_max_bytes: usize,
        pub output_format: OutputFormat,
        pub verbose: bool,
        pub api_key: String,
        pub base_url: String,
        pub prompt: String,
        pub max_turns: i32,
        pub max_context_tokens: usize,
        pub dp_p_input: f64,
        pub dp_p_cache: f64,
        pub dp_p_out: f64,
        pub dp_v: usize,
        pub dp_s: usize,
        pub dp_l: f64,
        pub dp_baseline_e: i32,
        pub dp_e_fixed: i32,
        pub dp_r: f64,
        pub dp_beta: f64,
        pub dp_quality_penalty: f64,
        pub dp_min_keep_ratio: f64,
        pub skills: Vec<String>,
        pub thinking: String,
        pub effort: String,
        pub interactive: bool,
        pub cwd: String,
        pub home: String,
        pub session_mode: bool,
        pub session_id: String,
        pub continue_session: bool,
        pub list_sessions: bool,
    }
}

pub mod compact_dp {
    use serde_json::Value;

    /// DP compact decision configuration.
    /// Matches DP_* env vars in bash-agent.
    #[derive(Debug, Clone)]
    pub struct DPCompactConfig {
        pub p_input: f64,
        pub p_cache: f64,
        pub p_out: f64,
        pub v: usize,
        pub s: usize,
        pub l_fixed: f64,
        pub baseline_e: i32,
        pub e_fixed: i32,
        pub r: f64,
        pub beta: f64,
        pub quality_penalty: f64,
        pub max_context: usize,
        pub min_keep_ratio: f64,
    }

    impl Default for DPCompactConfig {
        fn default() -> Self {
            Self {
                p_input: 3.0,
                p_cache: 0.30,
                p_out: 15.0,
                v: 5000,
                s: 500,
                l_fixed: 0.0,
                baseline_e: 8,
                e_fixed: 0,
                r: 0.8,
                beta: 0.03,
                quality_penalty: 0.2,
                max_context: 200_000,
                min_keep_ratio: 0.25,
            }
        }
    }

    /// compact_turn_keep: compute turn-aligned lines to keep using MinKeepRatio.
    /// Matches bash compact_turn_keep(): counts user inputs, applies ratio, aligns to user boundary.
    pub fn compact_turn_keep(lines: &[Value], min_keep_ratio: f64) -> Option<usize> {
        if lines.is_empty() {
            return None;
        }

        let mut is_user = Vec::with_capacity(lines.len());
        let mut total_turns = 0usize;
        for line in lines {
            let user = line.get("role").and_then(Value::as_str) == Some("user")
                && line.get("content").is_some_and(|c| c.is_string());
            is_user.push(user);
            if user {
                total_turns += 1;
            }
        }

        let target = {
            let t = (total_turns as f64 * min_keep_ratio + 0.5) as usize;
            t.max(1).min(total_turns)
        };

        let mut keep = 0usize;
        let mut found = 0usize;
        for i in (0..lines.len()).rev() {
            if found >= target {
                break;
            }
            keep += 1;
            if is_user[i] {
                found += 1;
            }
        }
        if keep == 0 {
            return None;
        }
        Some(keep)
    }

    /// Compute the optimal number of lines to keep using DP analysis.
    /// All computation (E, L, avg) happens here — callers pass raw stats only.
    /// prev_compactions: number of previous compactions (from stats).
    /// current_turn: completed user-input rounds (from stats).
    /// total_requests: total agent_request_count (from stats).
    /// total_input_tokens: total cumulative input tokens (from stats).
    /// Returns: Some(keep_lines) turn-aligned, or None if no compact beneficial.
    pub fn compact_dp_decision(
        lines: &[Value],
        cfg: &DPCompactConfig,
        prev_compactions: usize,
        current_turn: usize,
        total_requests: usize,
        total_input_tokens: usize,
    ) -> Option<usize> {
        if lines.is_empty() {
            return None;
        }

        let n = lines.len();

        let mut sizes = Vec::with_capacity(n);
        let mut role_user = Vec::with_capacity(n);
        for line in lines {
            let s = serde_json::to_string(line).unwrap_or_default();
            sizes.push((s.len() + 3) / 4 + 1);
            let is_user = line.get("role").and_then(Value::as_str) == Some("user")
                && line.get("content").is_some_and(|c| c.is_string());
            role_user.push(is_user);
        }

        let total_tokens: usize = sizes.iter().sum();

        let e = if cfg.e_fixed > 0 {
            cfg.e_fixed as f64
        } else if cfg.baseline_e > 0 {
            let remaining = cfg.baseline_e - current_turn as i32;
            let floor = if cfg.baseline_e > 1 {
                cfg.baseline_e / 2
            } else {
                2
            };
            remaining.max(floor) as f64
        } else {
            2.0
        };

        let l = if cfg.l_fixed > 0.0 {
            cfg.l_fixed
        } else if current_turn > 0 && total_requests > 0 {
            total_requests as f64 / current_turn as f64
        } else {
            5.0
        };
        let l = l.max(1.0);

        let avg = if total_requests > 0 && total_input_tokens > 0 {
            total_input_tokens as f64 / total_requests as f64
        } else {
            4000.0
        };

        let r_total = e * l;

        let mut r_t = cfg.r.powi((prev_compactions + 1) as i32);
        if r_t < 0.37 {
            r_t = 0.37;
        }

        let n_remain = r_total * avg;
        let info_loss = cfg.beta * (1.0 - r_t) * n_remain * cfg.p_input / 1_000_000.0;

        let l_instr = 70.0_f64;

        let min_keep = {
            let k = (n as f64 * cfg.min_keep_ratio + 0.5) as usize;
            k.max(3).min(n)
        };

        // Maximum lines to keep (hard ceiling) = 1 - min_keep_ratio.
        // Rationale: if k > 75% of NR, less than 25% is dropped — too little to
        // justify the cost of an LLM summary call.  This also prevents pathological
        // cases where turn-alignment would expand a small best_k backward past many
        // tool_result lines, inflating the actual keep ratio far above min_keep
        // (e.g. DP picks 25% but turn-alignment pushes it to 80%+), resulting in a
        // compact that barely trims anything while still consuming a full LLM call.
        let max_keep = {
            let k = (n as f64 * (1.0 - cfg.min_keep_ratio) + 0.5) as usize;
            let k = k.min(n);
            // When min_keep_ratio > 0.5, the ceiling drops below the floor and the
            // for-loop can never execute.  The user set a high min_keep to be
            // conservative — not to disable compression entirely — so fall back to
            // no ceiling and let DP search up to n.
            if k < min_keep { n } else { k }
        };

        // H_min: minimum tokens to drop — must be several × summary output cost (S)
        // Dropping less than H_min means compact costs more than it saves.
        // 20×S: with S=500, requires dropping ≥10k tokens to justify a compact call.
        // At R≈20 remaining calls, 10k drop saves $0.06 vs $0.04 cost — clear margin.
        let h_min = (20.0 * cfg.s as f64) as usize;

        let mut best_k = 0usize;
        let mut best_benefit = f64::NEG_INFINITY;

        for k in min_keep..=max_keep {
            let k_tokens: usize = sizes[n - k..].iter().sum();
            let h = total_tokens as f64 - k_tokens as f64;
            if h <= 0.0 {
                continue;
            }

            let kf = k_tokens as f64;
            let sf = cfg.s as f64;
            let vf = cfg.v as f64;

            let savings = (r_total - 1.0) * cfg.p_cache * h / 1_000_000.0;
            let cache_miss = (sf + kf) * (cfg.p_input - cfg.p_cache) / 1_000_000.0;
            let compact_cost =
                (cfg.p_cache * vf + cfg.p_input * (h + l_instr) + cfg.p_out * sf) / 1_000_000.0;

            // ⑤ Quality savings: only when context is large enough (> max_ctx × 30%)
            let max_ctx = cfg.max_context as f64;
            let tf = total_tokens as f64;
            let quality_savings = if tf > max_ctx * 0.30 {
                cfg.quality_penalty * cfg.p_input * ((vf + tf) * (vf + tf) - (vf + kf) * (vf + kf))
                    / (max_ctx * 1_000_000.0)
            } else {
                0.0
            };

            let benefit = savings - cache_miss - compact_cost - info_loss + quality_savings;

            if benefit > best_benefit {
                best_benefit = benefit;
                best_k = k;
            }
        }

        if best_benefit <= 0.0 {
            return None;
        }

        // Align to user-message (turn) boundary — must cut at user turn
        let mut adj = best_k;
        let mut cut = n - adj;
        while cut > 0 && !role_user[cut] {
            cut -= 1;
            adj = n - cut;
        }
        if adj < 1 {
            adj = 1;
        }

        // Post-alignment guards — alignment result must satisfy both:
        //   1. adj <= max_keep (alignment must not exceed ceiling)
        //   2. H_actual >= h_min  (tokens dropped must justify summary cost)
        // Cannot fall back to best_k — it is not on a user-message boundary.
        if adj > max_keep {
            return None;
        }
        let k_tokens: usize = sizes[n - adj..].iter().sum();
        let h_actual = total_tokens - k_tokens;
        if h_actual < h_min {
            return None;
        }
        Some(adj)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use serde_json::json;

        fn make_line(role: &str, content: &str) -> Value {
            json!({"role": role, "content": content})
        }

        /// Generate alternating user/assistant lines with string content.
        /// Even indices = user, odd = assistant. Each line has ~chars_per_line chars.
        fn make_conv(msg_count: usize, chars_per_line: usize) -> Vec<Value> {
            let mut lines = Vec::with_capacity(msg_count);
            let pad_len = chars_per_line.saturating_sub(10);
            let pad = if pad_len > 0 {
                "x".repeat(pad_len)
            } else {
                String::new()
            };
            for i in 0..msg_count {
                let role = if i % 2 == 0 { "user" } else { "assistant" };
                let content = if i % 2 == 0 {
                    format!("user_msg_{} {}", i, pad)
                } else {
                    format!("asst_resp_{} {}", i, pad)
                };
                lines.push(make_line(role, &content));
            }
            lines
        }

        #[test]
        fn test_empty() {
            let cfg = DPCompactConfig::default();
            let result = compact_dp_decision(&[], &cfg, 0, 0, 0, 0);
            assert!(result.is_none(), "empty conversation should return None");
        }

        #[test]
        fn test_small() {
            let cfg = DPCompactConfig::default();
            // 2 lines, each ~20K chars → ~5K tokens, total ~10K — too small to compact
            let lines = make_conv(2, 20000);
            let result = compact_dp_decision(&lines, &cfg, 0, 0, 0, 0);
            assert!(result.is_none(), "small conversation should return None");
        }

        #[test]
        fn test_large() {
            // Match bash test 37d: quality_penalty=0, fixed E=8, L=5
            let cfg = DPCompactConfig {
                quality_penalty: 0.0,
                e_fixed: 8,
                l_fixed: 5.0,
                ..DPCompactConfig::default()
            };
            // 60 lines (30 user + 30 assistant), each ~50K chars → ~12.5K tokens
            // Total: ~750K tokens → DP should find positive benefit
            let lines = make_conv(60, 50000);
            let result = compact_dp_decision(&lines, &cfg, 0, 1, 5, 20000);
            assert!(result.is_some(), "large conversation should compact");
            let n = result.unwrap();
            assert!(n > 0, "keep count must be positive");
            assert!(n <= lines.len(), "keep count must not exceed total lines");
            // Verify turn alignment at cut point
            let cut = lines.len() - n;
            if cut > 0 {
                let role_at_cut = lines[cut].get("role").and_then(Value::as_str).unwrap_or("");
                assert_eq!(
                    role_at_cut, "user",
                    "cut point (line {}) must be at user boundary; got role={}",
                    cut, role_at_cut
                );
            }
        }

        #[test]
        fn test_quality_penalty_promotes() {
            // Same data as test_large but with extreme quality penalty
            // QP=500 作为增量正项（quality_savings），大幅促进压缩
            let cfg = DPCompactConfig {
                quality_penalty: 500.0,
                e_fixed: 8,
                l_fixed: 5.0,
                ..DPCompactConfig::default()
            };
            let lines = make_conv(60, 50000);
            let result = compact_dp_decision(&lines, &cfg, 0, 1, 5, 20000);
            assert!(
                result.is_some(),
                "quality_penalty=500 should promote compaction"
            );
        }

        #[test]
        fn test_turn_alignment() {
            // Pattern matching bash test 37f:
            // assistant, user, assistant, assistant, user, assistant, user
            // Each line padded to ~120 chars for enough tokens
            let pad = "x".repeat(100);
            let lines = vec![
                make_line("assistant", &format!("intro {}", pad)),
                make_line("user", &format!("step 1 {}", pad)),
                make_line("assistant", &format!("response 1a {}", pad)),
                make_line("assistant", &format!("response 1b {}", pad)),
                make_line("user", &format!("step 2 {}", pad)),
                make_line("assistant", &format!("response 2 {}", pad)),
                make_line("user", &format!("step 3 {}", pad)),
            ];
            let cfg = DPCompactConfig {
                quality_penalty: 0.0,
                e_fixed: 10,
                l_fixed: 3.0,
                v: 0,
                s: 0,
                beta: 0.001,
                min_keep_ratio: 0.25,
                max_context: 200000,
                ..DPCompactConfig::default()
            };
            let result = compact_dp_decision(&lines, &cfg, 0, 1, 3, 12000);
            assert!(result.is_some(), "turn alignment test should compact");
            let n = result.unwrap();
            // Verify alignment: cut must be at a user message
            let cut = lines.len() - n;
            if cut > 0 {
                let role_at_cut = lines[cut].get("role").and_then(Value::as_str).unwrap_or("");
                assert_eq!(
                    role_at_cut, "user",
                    "cut point (line {}) must be at a user message; got role={}",
                    cut, role_at_cut
                );
            }
            // Expected: best_k=3 aligned to user, result should be 3
            assert_eq!(
                n, 3,
                "expected keep=3 (aligned to user 'step 2'), got keep={}",
                n
            );
        }

        #[test]
        fn test_formatted_tool_result_excluded_from_alignment() {
            let lines = vec![
                make_line("assistant", "intro"),
                json!({"role": "user", "content": "step 1"}),
                make_line("assistant", "response 1"),
                json!({"role": "user", "content": [{"type":"tool_result","tool_use_id":"t1","content":"result 1"}]}),
                make_line("assistant", "response 1b"),
                make_line("user", "step 2"),
                make_line("assistant", "response 2"),
                make_line("user", "step 3"),
            ];
            let cfg = DPCompactConfig {
                quality_penalty: 0.001,
                e_fixed: 10,
                l_fixed: 3.0,
                v: 0,
                s: 0,
                beta: 0.001,
                min_keep_ratio: 0.25,
                max_context: 200000,
                ..DPCompactConfig::default()
            };
            let n = compact_dp_decision(&lines, &cfg, 0, 1, 3, 12000)
                .expect("formatted tool_result scenario should compact");
            let cut = lines.len() - n;
            if cut > 0 {
                let content = &lines[cut]["content"];
                assert!(
                    content.is_string(),
                    "cut must not align to tool_result array: {content:?}"
                );
            }
        }
    }
}

pub mod protocol {
    pub use crate::types::*;
}

pub mod conversation {
    use crate::protocol::ToolCallEvent;
    use crate::store;
    use anyhow::Result;
    use serde_json::{Value, json};
    use std::path::PathBuf;

    #[derive(Debug, Clone)]
    pub struct Store {
        pub path: PathBuf,
    }

    #[derive(Debug, Clone)]
    pub struct ToolResult {
        pub tool_use_id: String,
        pub tool_name: String,
        pub tool_args: std::collections::BTreeMap<String, String>,
        pub content: String,
        pub conv_content: String,
    }

    impl Store {
        pub fn ensure(&self) -> Result<()> {
            store::store_conv_ensure(&self.path)
        }

        pub fn add_user(&self, content: &str) -> Result<()> {
            self.append_line(&json!({"role":"user","content":content}))
        }

        pub fn add_assistant(
            &self,
            text: &str,
            thinking: &str,
            calls: &[ToolCallEvent],
        ) -> Result<()> {
            let mut content = Vec::new();
            content.push(json!({"type":"thinking","thinking":thinking}));
            content.push(json!({"type":"text","text":text}));
            for c in calls {
                content
                    .push(json!({"type":"tool_use","id":c.id,"name":c.name,"input":c.input_json}));
            }
            self.append_line(&json!({"role":"assistant","content":content}))
        }

        pub fn add_tool_results(&self, results: &[ToolResult]) -> Result<()> {
            let content: Vec<Value> = results
                .iter()
                .map(|r| {
                    let conv_content = if r.conv_content.is_empty() {
                        &r.content
                    } else {
                        &r.conv_content
                    };
                    json!({"type":"tool_result","tool_use_id":r.tool_use_id,"content":conv_content})
                })
                .collect();
            self.append_line(&json!({"role":"user","content":content}))
        }

        pub fn file_tool_result_summary(
            kind: &str,
            path: &str,
            offset: &str,
            limit: &str,
        ) -> String {
            if path.is_empty() {
                return kind.to_string();
            }
            match std::fs::read(path) {
                Ok(data) => {
                    let lines = line_count(&data);
                    let mut rng = String::new();
                    if !offset.is_empty() || !limit.is_empty() {
                        let o = if offset.is_empty() { "1" } else { offset };
                        let l = if limit.is_empty() {
                            &lines.to_string()
                        } else {
                            limit
                        };
                        rng = format!(", offset={o}, limit={l}");
                    }
                    format!("{kind}({path}) [{lines} lines, {} bytes{rng}]", data.len())
                }
                Err(_) => format!("{kind}({path})"),
            }
        }

        pub fn lines(&self) -> Result<Vec<Value>> {
            store::store_conv_lines(&self.path)
        }

        pub fn messages_json(&self) -> Result<Value> {
            Ok(Value::Array(self.lines()?))
        }

        pub fn total_bytes(&self) -> Result<usize> {
            store::store_conv_total_bytes(&self.path)
        }

        pub fn total_lines(&self) -> Result<usize> {
            store::store_conv_total_lines(&self.path)
        }

        pub fn count_user_inputs(&self) -> Result<usize> {
            store::store_conv_count_user_inputs(&self.path)
        }

        pub fn trim_keep_last(&self, keep_lines: usize) -> Result<()> {
            store::store_conv_trim_keep_last(&self.path, keep_lines)
        }

        pub fn keep_line_count(&self, target_bytes: usize) -> Result<usize> {
            store::store_conv_keep_line_count(&self.path, target_bytes)
        }

        fn append_line(&self, value: &Value) -> Result<()> {
            store::store_conv_add_json(&self.path, value)
        }
    }

    pub fn first_line(s: &str) -> &str {
        s.lines().next().unwrap_or(s)
    }

    fn line_count(s: &[u8]) -> usize {
        if s.is_empty() {
            0
        } else {
            let nl = s.iter().filter(|&&c| c == b'\n').count();
            // 对齐 awk NR: 换行符个数，最后不以 \n 结尾则补1
            if s.last() == Some(&b'\n') { nl } else { nl + 1 }
        }
    }

    pub fn build_tool_call_summary(
        name: &str,
        fields: &std::collections::BTreeMap<String, String>,
    ) -> String {
        let mut label = String::new();
        match name {
            "Read" | "Write" | "Edit" => label = fields.get("path").cloned().unwrap_or_default(),
            "Glob" | "Grep" => label = fields.get("pattern").cloned().unwrap_or_default(),
            "Bash" => {
                label = fields
                    .get("command")
                    .cloned()
                    .unwrap_or_default()
                    .replace('\n', " ");
                if label.chars().count() > 80 {
                    let truncated: String = label.chars().take(77).collect();
                    label = format!("{truncated}...");
                }
            }
            "TodoWrite" => {
                if let Some(summary) = fields.get("summary").cloned() {
                    if !summary.is_empty() {
                        label = summary;
                    }
                }
                if label.is_empty() {
                    if let Some(todos) = fields.get("todos") {
                        if let Ok(arr) = serde_json::from_str::<Vec<Value>>(todos) {
                            let total = arr.len();
                            let completed = arr
                                .iter()
                                .filter(|item| {
                                    item.get("status").and_then(Value::as_str) == Some("completed")
                                })
                                .count();
                            label = format!("{completed}/{total}");
                        }
                    }
                }
            }
            "Skill" => label = fields.get("name").cloned().unwrap_or_default(),
            "SubAgent" => label = fields.get("description").cloned().unwrap_or_default(),
            _ => {}
        }
        if label.is_empty() {
            format!("{name}()")
        } else {
            format!("{name}({label})")
        }
    }
}

pub mod prompt {
    use anyhow::Result;
    use std::collections::HashSet;
    use std::fs;
    use std::path::{Path, PathBuf};

    pub struct Builder {
        pub cwd: PathBuf,
        pub home: PathBuf,
        pub skills: Vec<String>,
        pub summary_file: PathBuf,
        pub plan_file: PathBuf,
        pub plan_draft_file: PathBuf,
    }

    impl Builder {
        pub fn build_system_prompt(&self) -> Result<String> {
            let mut sections = Vec::new();
            let locale_raw = ["LC_ALL", "LC_MESSAGES", "LANG"]
                .iter()
                .find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
                .unwrap_or_else(|| "en_US".to_string());
            let locale = locale_raw
                .split('.')
                .next()
                .unwrap_or(&locale_raw)
                .to_string();
            let identity = if locale.starts_with("zh") {
                "你是 bash-agent，一个在终端中运行的轻量级编码智能体。".to_string()
            } else {
                format!("You are bash-agent, a lightweight coding agent that works in a terminal.")
            };
            sections.push(wrap_section("agent-identity", &identity, None));
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "unknown".to_string());
            let platform = match std::env::consts::OS {
                "macos" => "Darwin",
                "linux" => "Linux",
                other => other,
            };
            let environment = format!(
                "lang: {}\npwd: {}\nhome: {}\nplatform: {}\nshell: {}",
                locale,
                self.cwd.display(),
                self.home.display(),
                platform,
                shell
            );
            sections.push(wrap_section("environment", &environment, None));
            let rules_str = "- Be concise and concrete. Lead with the answer. Use short sections or bullets when they improve readability. No pleasantries, no explanations unless asked. Raw results only.\n- Prefer safe, exact edits.\n- Report failures clearly.";
            sections.push(wrap_section("rules", &rules_str, None));
            sections.push(wrap_section(
                "using-your-tools",
                "- Use Read for a single file. If you need multiple files, call Read multiple times.\n- Read supports optional offset and limit parameters to read specific line ranges (saves tokens for large files). Output includes line numbers.\n- Use Glob and Grep for one pattern at a time.\n- Grep supports a context parameter to show surrounding lines — use it to get enough text for Edit directly from Grep output, avoiding a separate Read.\n- Use multiple tool calls in one response when they are independent.\n- Prefer dedicated tools over Bash when a dedicated tool fits the task.\n- For Edit: copy old_string exactly (including whitespace/indent/newlines). If you already know the location from prior context, use Read with offset/limit. If you need to locate the text first, use Grep with context — its output is often sufficient for Edit without an extra Read.\n- For skills, first check the skill-index section, then use Skill(name) for the matching skill.\n- Bash supports background=true for long-running commands. Returns task_id immediately; output delivered asynchronously like SubAgent.\n- SubAgent launches a background agent session. Results are injected back into your conversation when complete. Use for parallelizable or independent sub-tasks. See sub-agent-guidance section for context inheritance rules.",
                None,
            ));
            sections.push(wrap_section(
                "sub-agent-guidance",
                "- **When to use**: delegating independent sub-tasks that do NOT need your current conversation context — e.g. investigating a separate file, running a focused search, testing a hypothesis in isolation.\n- **Recursion limit**: only the main agent may launch SubAgent. A child agent must not call SubAgent again; the runtime rejects nested launches.\n- **When NOT to use**: tasks that depend on your working context, conversation history, or intermediate state. The child agent starts with a blank slate.\n- **Fork mode**: pass `fork=true` to inherit parent session context (conversation history, plan, skills). Use when the child needs your working context.\n- **Prompt design**: write a complete, self-contained prompt. Include all file paths, function names, error messages, and constraints the child needs. Assume zero shared context.\n- **Result handling**: when the child completes, its result is injected as a user message: `[sub-agent <id>] <status> (in=<n>, out=<n>)\nThinking: ...\nText: ...`. You then get another LLM turn to interpret and act on it.\n- **Parallelism**: multiple SubAgent calls in one turn run concurrently. Use this to parallelize independent investigations. **IMPORTANT**: results return asynchronously as each sub-agent finishes — they do NOT return together. When you receive a result for one sub-agent, the others are still running. Simply wait for all results to arrive before acting. Do NOT re-launch a sub-agent just because another one finished first — match results by session_id.\n- **Failure**: if the child fails (status=failed), the result text may be partial or empty. Handle gracefully — do not retry automatically.",
                None,
            ));
            sections.push(wrap_section(
                "todo-guidance",
                "- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.\n- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.\n- After receiving a non-trivial task, create an initial checklist before or as you begin work.\n- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.\n- Keep the checklist short, concrete, and actionable.\n- Prefer exactly one in_progress item when work is actively underway.\n- Mark items completed immediately after finishing them, and remove stale items that no longer matter.",
                None,
            ));
            let plan_file_display = if self.plan_file.as_os_str().is_empty() {
                "<not set>".to_string()
            } else {
                self.plan_file.display().to_string()
            };
            let plan_draft_file_display = if self.plan_draft_file.as_os_str().is_empty() {
                "<not set>".to_string()
            } else {
                self.plan_draft_file.display().to_string()
            };
            let plan_lifecycle_guidance = format!(
                concat!(
                    "- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)\n",
                    "- **Files**: PLAN_DRAFT_FILE: {} | PLAN_FILE: {}\n",
                    "- **Why draft first?** Writing to PLAN_FILE immediately invalidates the system prompt cache. Use PLAN_DRAFT_FILE for all drafting iterations to avoid this cost.\n",
                    "- **Drafting phase** (PLAN_DRAFT_FILE non-empty → you are drafting):\n",
                    "  Every user reply MUST be classified as exactly ONE of:\n",
                    "  ① REVISE (any feedback/question/change) → Edit PLAN_DRAFT_FILE → ask confirmation → stay in drafting\n",
                    "  ② CONFIRM (explicit ok/go/confirmed) → call PlanConfirm IMMEDIATELY (before any other action) → TodoWrite checklist → execute\n",
                    "  ③ CANCEL (explicit cancel/forget it) → Bash `: > PLAN_DRAFT_FILE` → exit to idle\n",
                    "  ⚠ On CONFIRM you MUST call PlanConfirm first — no edits, no tool calls before it.\n",
                    "- **Execution phase**: after PlanConfirm → TodoWrite checklist → execute tasks → PlanClear when all done\n",
                    "- **Plan vs Todo**: PLAN_FILE=locked plan (only via PlanConfirm), PLAN_DRAFT_FILE=draft (edit freely), TodoWrite=progress tracker. Do NOT mix."
                ),
                plan_draft_file_display, plan_file_display
            );
            sections.push(wrap_section(
                "plan-lifecycle-guidance",
                &plan_lifecycle_guidance,
                None,
            ));
            if let Some(s) = self.build_instruction_files_section()? {
                sections.push(wrap_section("instruction-files", &s, None));
            }
            if let Some(s) = self.build_skill_index_section()? {
                sections.push(wrap_section("skill-index", &s, None));
            }
            if let Some(s) = self.build_selected_skills_section()? {
                sections.push(wrap_section("selected-skills", &s, None));
            }
            if let Some(s) = read_optional_file(&self.plan_file)? {
                sections.push(wrap_section(
                    "current-plan",
                    &s,
                    Some(&self.plan_file.display().to_string()),
                ));
            }
            if let Some(s) = read_optional_file(&self.summary_file)? {
                sections.push(wrap_section("context-snapshot", &s, None));
            }
            let output_language = if locale.starts_with("zh") {
                "再次强调：必须使用中文进行所有输出，包括你的思考过程（Chain of Thought/推理/thinking）！严禁在思考或回答中出现任何英文内容！".to_string()
            } else {
                format!(
                    "MUST use \"{}\" for all output, including your Chain of Thought/reasoning/thinking! Never mix languages! Code, commands, and file content remain as-is.",
                    locale
                )
            };
            sections.push(wrap_section("output-language", &output_language, None));
            Ok(sections.join("\n"))
        }

        fn build_instruction_files_section(&self) -> Result<Option<String>> {
            let global_file = find_instruction_file_in_dir(&self.home.join(".bash-agent"));
            let project_file = find_instruction_file_in_dir(&self.cwd);
            let mut out = Vec::new();
            if let Some(f) = global_file {
                out.push(wrap_section(
                    "instruction-file",
                    &trim_trailing_newlines(fs::read_to_string(f)?),
                    Some("global"),
                ));
            }
            if let Some(f) = project_file {
                out.push(wrap_section(
                    "instruction-file",
                    &trim_trailing_newlines(fs::read_to_string(f)?),
                    Some("project"),
                ));
            }
            if out.is_empty() {
                Ok(None)
            } else {
                Ok(Some(out.join("\n")))
            }
        }

        fn build_skill_index_section(&self) -> Result<Option<String>> {
            let bases = find_skill_base_dirs(&self.cwd, &self.home);
            if bases.is_empty() {
                return Ok(None);
            }
            let mut seen = HashSet::new();
            let mut lines = Vec::new();
            for base in bases {
                for entry in fs::read_dir(base)? {
                    let entry = entry?;
                    if !entry.file_type()?.is_dir() {
                        continue;
                    }
                    let name = entry.file_name().to_string_lossy().to_string();
                    if seen.contains(&name) {
                        continue;
                    }
                    let skill_file = entry.path().join("SKILL.md");
                    let Ok(data) = fs::read_to_string(skill_file) else {
                        continue;
                    };
                    seen.insert(name.clone());
                    let summary = extract_skill_summary(&data);
                    if summary.is_empty() {
                        lines.push(format!("- {name}"));
                    } else {
                        lines.push(format!("- {name}: {summary}"));
                    }
                }
            }
            if lines.is_empty() {
                Ok(None)
            } else {
                Ok(Some(lines.join("\n")))
            }
        }

        fn build_selected_skills_section(&self) -> Result<Option<String>> {
            if self.skills.is_empty() {
                return Ok(None);
            }
            let bases = find_skill_base_dirs(&self.cwd, &self.home);
            if bases.is_empty() {
                return Ok(None);
            }
            let mut sections = Vec::new();
            for skill in &self.skills {
                let Some(skill_file) = find_skill_file(&bases, skill) else {
                    return Err(anyhow::anyhow!(
                        "skill not found: {skill} (expected .claude/skills/{skill}/SKILL.md or ~/.claude/skills/{skill}/SKILL.md)"
                    ));
                };
                let content = trim_trailing_newlines(fs::read_to_string(&skill_file)?);
                let full = format!(
                    "Base directory: {}\n\n{}",
                    skill_file.parent().unwrap_or(Path::new("")).display(),
                    content.replace(
                        "${BASH_AGENT_SKILL_DIR}",
                        &skill_file
                            .parent()
                            .unwrap_or(Path::new(""))
                            .display()
                            .to_string()
                    )
                );
                sections.push(wrap_section("skill", &full, Some(skill)));
            }
            Ok(Some(sections.join("\n")))
        }
    }

    fn wrap_section(tag: &str, content: &str, name: Option<&str>) -> String {
        let content = content.trim_end_matches(['\r', '\n']);
        if content.is_empty() {
            return String::new();
        }
        match name {
            Some(n) => format!("<{tag} name=\"{}\">\n{}\n</{tag}>", escape_attr(n), content),
            None => format!("<{tag}>\n{}\n</{tag}>", content),
        }
    }

    fn escape_attr(s: &str) -> String {
        let mut out = String::new();
        for ch in s.chars() {
            match ch {
                '\\' => out.push_str("\\\\"),
                '"' => out.push_str("\\\""),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '\u{08}' => out.push_str("\\b"),
                '\u{0c}' => out.push_str("\\f"),
                _ => out.push(ch),
            }
        }
        out
    }

    fn read_optional_file(path: &Path) -> Result<Option<String>> {
        if !path.exists() {
            return Ok(None);
        }
        let s = trim_trailing_newlines(fs::read_to_string(path)?);
        if s.trim().is_empty() {
            Ok(None)
        } else {
            Ok(Some(s))
        }
    }

    fn trim_trailing_newlines(mut s: String) -> String {
        while s.ends_with('\n') || s.ends_with('\r') {
            s.pop();
        }
        s
    }

    fn find_skill_base_dirs(cwd: &Path, home: &Path) -> Vec<PathBuf> {
        let mut out = Vec::new();
        let project = cwd.join(".claude/skills");
        if project.is_dir() {
            out.push(project);
        }
        let project_dev = cwd.join("skills");
        if project_dev.is_dir() {
            out.push(project_dev);
        }
        let global = home.join(".claude/skills");
        if global.is_dir() {
            out.push(global);
        }
        out
    }

    fn find_skill_file(bases: &[PathBuf], skill: &str) -> Option<PathBuf> {
        for base in bases {
            let path = base.join(skill).join("SKILL.md");
            if path.is_file() {
                return Some(path);
            }
        }
        None
    }

    pub fn resolve_skill_file(cwd: &Path, home: &Path, skill: &str) -> Option<PathBuf> {
        find_skill_file(&find_skill_base_dirs(cwd, home), skill)
    }

    fn find_instruction_file_in_dir(dir: &Path) -> Option<PathBuf> {
        let candidates = [
            dir.join("AGENTS.md"),
            dir.join("AGENT.md"),
            dir.join("CLAUDE.md"),
            dir.join(".claude/CLAUDE.md"),
        ];
        candidates.into_iter().find(|p| p.is_file())
    }

    fn extract_skill_summary(content: &str) -> String {
        let mut fallback = String::new();
        for line in content.lines() {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if trimmed.starts_with("description:") {
                let desc = trimmed.trim_start_matches("description:").trim();
                let desc = if desc.len() >= 2 {
                    let first_char = desc.chars().next().unwrap();
                    if first_char == '"' {
                        desc.trim_start_matches('"').trim_end_matches('"')
                    } else if first_char == '\'' {
                        desc.trim_start_matches('\'').trim_end_matches('\'')
                    } else {
                        desc
                    }
                } else {
                    desc
                };
                return desc.to_string();
            }
            if fallback.is_empty()
                && !trimmed.starts_with('#')
                && trimmed != "---"
                && !trimmed.starts_with("```")
            {
                fallback = trimmed.to_string();
            }
        }
        fallback
    }
}

pub mod session {
    pub use crate::store::{Paths, continue_session, ensure_dir, paths_for, project_key};
}

pub mod traits {
    use anyhow::Result;
    use serde_json::Value;
    use std::io::Read;

    use crate::protocol::Event;
    use crate::types::Message;

    pub trait SessionStore: Send + Sync {
        fn init(&self) -> Result<()>;
        fn add_user(&self, message: &Message) -> Result<()>;
        fn add_assistant(&self, message: &Message) -> Result<()>;
        fn add_tool_results(&self, message: &Message) -> Result<()>;
        fn get_messages(&self) -> Result<Vec<Message>>;
        fn append_event(&self, event: &str) -> Result<()>;
    }
    pub trait Transport: Send + Sync {
        fn convert_body(&self, claude_body: &[u8]) -> Result<Vec<u8>>;
        fn parse_sse(
            &self,
            reader: Box<dyn Read + Send>,
            emit: &mut dyn FnMut(Event) -> Result<()>,
        ) -> Result<()>;
    }

    pub trait ToolDispatcher: Send + Sync {
        fn dispatch(&self, name: &str, input: &Value) -> Result<String>;
    }
}
