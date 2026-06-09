# compact_dp.awk — DP compact decision with cache-aware economics.
# Part of Cache-Aligned Summarization: computes optimal k to retain, so
# the summary call can reuse the main agent's cached prefix.
# Input: reads CONV_FILE (NDJSON), computes optimal k messages to retain
#
# Parameters (via -v):
#   Stats raw values (passed from caller):
#     t              — current user-input turn count (stats[0])
#     total_requests — total LLM request count (stats[1])
#     total_compact  — number of previous compactions (stats[2])
#     total_input    — total cumulative input tokens (stats[3])
#
#   Configuration (from env / defaults):
#     baseline_e     — baseline for E calculation (DP_BASELINE_E, default 8)
#     e_fixed        — fixed E override (DP_E_FIXED, default 0)
#     L_fixed        — fixed L override (DP_L, default 0 = auto)
#     V              — fixed prefix tokens (system prompt + tools + old summary)
#     p_input        — uncached input price ($/MTok)
#     p_cache        — cached input price ($/MTok)
#     p_out          — output price ($/MTok)
#     S              — fixed summary length (tokens)
#     min_keep_ratio — minimum fraction of messages to retain
#     r              — single-step summary retention rate
#     beta           — info loss penalty coefficient
#     max_context    — model max context window (from MAX_CONTEXT_TOKENS, default 200000)
#     quality_penalty— quality decay penalty factor (DP_QUALITY_PENALTY, default 0)
#
# Output: number of lines to keep (turn-aligned), or "0" if no compact
{
    sizes[NR] = int((length($0) + 3) / 4) + 1
    role[NR]  = ($0 ~ /"role":"user"/ && $0 !~ /"content":\[/) ? "user" : "other"
}
END {
    if (NR == 0) { print "0"; exit }

    total_tokens = 0
    for (i = 1; i <= NR; i++) total_tokens += sizes[i]

    # --- E: expected remaining user-input rounds ---
    if (e_fixed > 0) {
        E = e_fixed
    } else if (baseline_e > 0) {
        remaining = baseline_e - t
        floor = (baseline_e > 1) ? int(baseline_e / 2) : 2
        E = (remaining > floor) ? remaining : floor
    } else {
        E = 2
    }

    # --- L: avg LLM calls per user input ---
    if (L_fixed > 0) {
        L = L_fixed
    } else if (t > 0 && total_requests > 0) {
        L = total_requests / t
    } else {
        L = 5
    }
    if (L < 1) L = 1

    # --- avg: avg input tokens per LLM request ---
    if (total_requests > 0 && total_input > 0) {
        avg = total_input / total_requests
    } else {
        avg = 4000
    }

    # --- c: previous compaction count ---
    c = total_compact + 0

    # R = total expected remaining LLM calls
    R = E * L

    # Fixed summary instruction length (~70 tokens)
    l_instr = 70

    # Cumulative retention: r^(c+1) (independent of k)
    r_t = 1.0
    for (i = 1; i <= c + 1; i++) r_t *= r
    if (r_t < 0.37) r_t = 0.37

    # N_remain: expected remaining input tokens (R * avg_per_request)
    N_remain = R * avg

    # ④ Info loss (constant across all k, computed once)
    info_loss = beta * (1.0 - r_t) * N_remain * p_input / 1000000

    # ⑤ Quality penalty: use absolute context ratio (V+K)/M
    #   quality_penalty is dimensionless (default 0.2 based on research data)
    #   p_input is used because degraded quality → retry → new uncached input
    if (quality_penalty == "") quality_penalty = 0.2
    if (max_context == "" || max_context <= 0) max_context = 200000

    # Minimum lines to keep (hard floor)
    min_keep = int(NR * min_keep_ratio + 0.5)
    if (min_keep < 3) min_keep = 3
    if (min_keep > NR) min_keep = NR

    # Maximum lines to keep (hard ceiling) = 1 - min_keep_ratio
    # Rationale: if k > 75% of NR, less than 25% is dropped — too little to
    # justify the cost of an LLM summary call.  This also prevents pathological
    # cases where turn-alignment would expand a small best_k backward past many
    # tool_result lines, inflating the actual keep ratio far above min_keep
    # (e.g. DP picks 25% but turn-alignment pushes it to 80%+), resulting in a
    # compact that barely trims anything while still consuming a full LLM call.
    max_keep = int(NR * (1 - min_keep_ratio) + 0.5)
    if (max_keep > NR) max_keep = NR
    # When min_keep_ratio > 0.5, the ceiling drops below the floor and the
    # for-loop can never execute.  The user set a high min_keep to be
    # conservative — not to disable compression entirely — so fall back to
    # no ceiling and let DP search up to NR.
    if (max_keep < min_keep) max_keep = NR

    # H_min: minimum tokens to drop — must be several × summary output cost (S)
    # Dropping less than H_min means compact costs more than it saves.
    # 20×S: with S=500, requires dropping ≥10k tokens to justify a compact call.
    # At R≈20 remaining calls, 10k drop saves $0.06 vs $0.04 cost — clear margin.
    H_min = 20 * S

    best_k = 0
    best_benefit = -1e18

    for (k = min_keep; k <= max_keep; k++) {
        K = 0
        for (i = NR - k + 1; i <= NR; i++) K += sizes[i]

        H = total_tokens - K
        if (H <= 0) continue

        # ① Savings: (R-1) subsequent LLM calls save P_cache × H each
        savings = (R - 1) * p_cache * H / 1000000

        # ② Cache invalidation on first LLM call after compact:
        #    Summary content changes → prefix breaks → S + K at P_input
        cache_miss = (S + K) * (p_input - p_cache) / 1000000

        # ③ Compaction request cost:
        #    Cached prefix (V) at P_cache, H + instruction at P_input, output at P_out
        compact_cost = (p_cache * V + p_input * (H + l_instr) + p_out * S) / 1000000

        # ⑤ Quality savings: 压缩减少上下文长度 → 改善回答质量 → 减少重试成本
        #   不压缩的衰减成本: QP * p_input * (V+T)² / (M*1e6)
        #   压缩后的衰减成本: QP * p_input * (V+K)² / (M*1e6)
        #   增量收益 = 差值 (T = total_tokens, K = 保留的 tokens)
        #   只在上下文足够大时计入（> max_context × 30%）
        quality_savings = 0
        if (total_tokens > max_context * 0.30) {
            quality_savings = quality_penalty * p_input * ((V + total_tokens) ^ 2 - (V + K) ^ 2) / (max_context * 1000000)
        }

        benefit = savings - cache_miss - compact_cost - info_loss + quality_savings

        if (benefit > best_benefit) {
            best_benefit = benefit
            best_k = k
        }
    }

    if (best_benefit > 0) {
        # Align to user-message (turn) boundary — must cut at user turn
        adj = best_k
        cut = NR - adj + 1
        while (cut > 1 && role[cut] != "user") {
            cut--
            adj = NR - cut + 1
        }
        if (adj < 1) adj = 1

        # Post-alignment guards — alignment result must satisfy both:
        #   1. adj <= max_keep (alignment must not exceed ceiling)
        #   2. H_actual >= H_min  (tokens dropped must justify summary cost)
        # Cannot fall back to best_k — it is not on a user-message boundary.
        abort = 0
        if (adj > max_keep) abort = 1
        if (!abort) {
            H_actual = total_tokens
            for (i = 1; i <= NR - adj; i++) H_actual -= sizes[i]
            if (H_actual < H_min) abort = 1
        }
        if (abort) print "0"; else print adj
    } else {
        print "0"
    }
}
