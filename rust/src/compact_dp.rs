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
            min_keep_ratio: 0.12,
        }
    }
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
        sizes.push((s.len() + 3) / 4);
        let is_user = line.get("role").and_then(Value::as_str) == Some("user")
            && line.get("content").is_some_and(|c| c.is_string());
        role_user.push(is_user);
    }

    let total_tokens: usize = sizes.iter().sum();

    // E: expected remaining user-input rounds
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

    // L: avg LLM calls per user input (auto from stats if l_fixed=0)
    let l = if cfg.l_fixed > 0.0 {
        cfg.l_fixed
    } else if current_turn > 0 && total_requests > 0 {
        let computed = total_requests as f64 / current_turn as f64;
        if computed >= 1.0 { computed } else { 5.0 }
    } else {
        5.0
    };
    let l = l.max(1.0);

    // avg: avg input tokens per LLM request (auto from stats)
    let avg = if total_requests > 0 && total_input_tokens > 0 {
        total_input_tokens as f64 / total_requests as f64
    } else {
        4000.0
    };

    // R = E * L
    let r_total = e * l;

    // r_t = r^(c+1) (independent of k)
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

    let mut best_k = 0usize;
    let mut best_benefit = f64::NEG_INFINITY;

    for k in min_keep..=n {
        let k_tokens: usize = sizes[n - k..].iter().sum();
        let h = total_tokens as f64 - k_tokens as f64;
        if h <= 0.0 {
            continue;
        }

        let kf = k_tokens as f64;
        let sf = cfg.s as f64;
        let vf = cfg.v as f64;

        // ① Savings: (R-1) * P_cache * H
        let savings = (r_total - 1.0) * cfg.p_cache * h / 1_000_000.0;

        // ② Cache invalidation: (S + K) * (P_base - P_cache)
        let cache_miss = (sf + kf) * (cfg.p_input - cfg.p_cache) / 1_000_000.0;

        // ③ Compaction request cost
        let compact_cost =
            (cfg.p_cache * (vf + h) + cfg.p_input * l_instr + cfg.p_out * sf) / 1_000_000.0;

        let benefit = savings - cache_miss - compact_cost - info_loss;

        if benefit > best_benefit {
            best_benefit = benefit;
            best_k = k;
        }
    }

    if best_benefit <= 0.0 {
        return None;
    }

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
