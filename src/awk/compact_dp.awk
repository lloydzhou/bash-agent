# compact_dp.awk — DP compact decision with cache-aware economics
# Input: reads CONV_FILE (NDJSON), computes optimal k messages to retain
# Parameters (via -v):
#   E              — expected remaining user-input rounds
#   L              — avg LLM calls per user input (R = E * L)
#   avg            — avg input tokens per LLM request (for N_remain)
#   V              — fixed prefix tokens (system prompt + tools + old summary)
#   p_base         — uncached input price ($/MTok)
#   p_cache        — cached input price ($/MTok)
#   p_out          — output price ($/MTok)
#   S              — fixed summary length (tokens)
#   min_keep_ratio — minimum fraction of messages to retain
#   c              — number of previous compactions
#   r              — single-step summary retention rate
#   beta           — info loss penalty coefficient
# Output: number of lines to keep (turn-aligned), or "0" if no compact
{
    sizes[NR] = int((length($0) + 3) / 4) + 1
    role[NR]  = ($0 ~ /^\{"role":"user","content":"/) ? "user" : "other"
}
END {
    if (NR == 0) { print "0"; exit }

    total_tokens = 0
    for (i = 1; i <= NR; i++) total_tokens += sizes[i]

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
    #    Result in dollars: beta * (1-r_t) * N_remain * p_base / 1e6
    info_loss = beta * (1.0 - r_t) * N_remain * p_base / 1000000

    # Minimum lines to keep (hard floor)
    min_keep = int(NR * min_keep_ratio + 0.5)
    if (min_keep < 3) min_keep = 3
    if (min_keep > NR) min_keep = NR

    best_k = 0
    best_benefit = -1e18

    for (k = min_keep; k <= NR; k++) {
        K = 0
        for (i = NR - k + 1; i <= NR; i++) K += sizes[i]

        H = total_tokens - K
        if (H <= 0) continue

        # ① Savings: (R-1) subsequent LLM calls save P_cache × H each
        savings = (R - 1) * p_cache * H / 1000000

        # ② Cache invalidation on first LLM call after compact:
        #    Summary content changes → prefix breaks → S + K at P_base
        cache_miss = (S + K) * (p_base - p_cache) / 1000000

        # ③ Compaction request cost:
        #    Cached prefix (V + H) at P_cache, instruction at P_base, output at P_out
        compact_cost = (p_cache * (V + H) + p_base * l_instr + p_out * S) / 1000000

        benefit = savings - cache_miss - compact_cost - info_loss

        if (benefit > best_benefit) {
            best_benefit = benefit
            best_k = k
        }
    }

    if (best_benefit > 0) {
        # Align to user-message (turn) boundary
        adj = best_k
        cut = NR - adj + 1
        while (cut > 1 && role[cut] != "user") {
            cut--
            adj = NR - cut + 1
        }
        if (adj < 1) adj = 1
        print adj
    } else {
        print "0"
    }
}
