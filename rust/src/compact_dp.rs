use serde_json::Value;

/// DP compact decision configuration.
/// Matches DP_* env vars in bash-agent.
#[derive(Debug, Clone)]
pub struct DPCompactConfig {
    pub p_base: f64,          // $/MTok, uncached input price
    pub p_cache: f64,         // $/MTok, cached input price
    pub v: usize,             // fixed overhead tokens (system prompt + current input)
    pub penalty: f64,         // $, compact overhead (summary call + cache miss)
    pub baseline_e: i32,      // expected remaining user-input rounds (0 = use e_fixed or 1)
    pub e_fixed: i32,         // fixed E (0 = use baseline_e)
    pub r: f64,               // single-step summary retention rate
    pub beta: f64,            // info loss penalty coefficient
    pub min_keep_ratio: f64,  // minimum fraction of messages to retain
}

impl Default for DPCompactConfig {
    fn default() -> Self {
        Self {
            p_base: 3.0,
            p_cache: 0.30,
            v: 20000,
            penalty: 0.25,
            baseline_e: 8,
            e_fixed: 0,
            r: 0.70,
            beta: 0.5,
            min_keep_ratio: 0.12,
        }
    }
}

/// Compute the optimal number of lines to keep using DP analysis.
/// Returns: Some(keep_lines) turn-aligned, or None if no compact beneficial.
pub fn compact_dp_decision(
    lines: &[Value],
    cfg: &DPCompactConfig,
    prev_compactions: usize,
    current_turn: usize,
) -> Option<usize> {
    if lines.is_empty() {
        return None;
    }

    let n = lines.len();

    // Token estimation per line (bytes/4) and role detection
    let mut sizes = Vec::with_capacity(n);
    let mut role_user = Vec::with_capacity(n);
    for line in lines {
        let s = serde_json::to_string(line).unwrap_or_default();
        sizes.push((s.len() + 3) / 4);
        let is_user = line.get("role").and_then(Value::as_str) == Some("user")
            && line.get("content").is_some_and(|c| c.is_string());
        role_user.push(is_user);
    }

    let total_tokens: usize = sizes.iter().sum();

    // Cumulative retention after prev_compactions compactions
    let mut r_cumulative = 1.0f64;
    for _ in 0..prev_compactions {
        r_cumulative *= cfg.r;
    }
    if r_cumulative < 0.37 {
        r_cumulative = 0.37;
    }

    // Expected remaining user-input rounds
    let n_remain = if cfg.e_fixed > 0 {
        cfg.e_fixed as f64
    } else {
        let e = if cfg.baseline_e > 0 {
            let remaining = cfg.baseline_e - current_turn as i32;
            if remaining <= 0 {
                if cfg.baseline_e > 1 {
                    cfg.baseline_e / 2
                } else {
                    2
                }
            } else {
                remaining
            }
        } else {
            2
        };
        e as f64
    };
    let n_remain_dollars = n_remain * total_tokens as f64 * cfg.p_base / 1_000_000.0;

    // Minimum keep (hard floor at 3)
    let min_keep = {
        let k = (n as f64 * cfg.min_keep_ratio + 0.5) as usize;
        k.max(3).min(n)
    };

    let mut best_k = 0usize;
    let mut best_benefit = f64::NEG_INFINITY;

    for k in min_keep..=n {
        let retained: usize = sizes[n - k..].iter().sum();
        let dropped = total_tokens as f64 - retained as f64 - cfg.v as f64;
        if dropped <= 0.0 {
            continue;
        }

        // Monetary benefit
        let mut benefit = n_remain * (cfg.p_base - cfg.p_cache) * dropped / 1_000_000.0;
        benefit -= cfg.penalty;

        // Info loss penalty
        let r_t = r_cumulative * k as f64 / n as f64;
        let info_loss = (1.0 - r_t) * (1.0 - r_t);
        benefit -= cfg.beta * info_loss * n_remain_dollars;

        if benefit > best_benefit {
            best_benefit = benefit;
            best_k = k;
        }
    }

    if best_benefit <= 0.0 {
        return None;
    }

    // Align to user-message (turn) boundary
    let mut adj = best_k;
    let mut cut = n - adj;
    while cut > 0 && !role_user[cut] {
        cut -= 1;
        adj = n - cut;
    }
    if adj < 1 {
        adj = 1;
    }
    Some(adj)
}
