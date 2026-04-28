# compact_dp.awk — Dynamic Programming compact decision with info loss penalty
# Input: reads CONV_FILE (NDJSON), computes optimal k messages to retain
# Parameters (via -v):
#   E              — expected remaining LLM calls
#   V              — fixed overhead tokens (system + current input)
#   p_base         — uncached input price ($/MTok)
#   p_cache        — cached input price ($/MTok)
#   penalty        — compact overhead ($, summary call + cache miss)
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

    # Cumulative retention after c previous compactions
    # Uses exponential decay with asymptotic floor of 0.37 (Factory AI)
    r_cumulative = 1.0
    for (i = 1; i <= c; i++) r_cumulative *= r
    if (r_cumulative < 0.37) r_cumulative = 0.37

    # Expected remaining total cost ($)
    N_remain = E * total_tokens * p_base / 1000000

    # Minimum lines to keep (hard floor)
    min_keep = int(NR * min_keep_ratio + 0.5)
    if (min_keep < 3) min_keep = 3
    if (min_keep > NR) min_keep = NR

    best_k = 0
    best_benefit = -1e18

    for (k = min_keep; k <= NR; k++) {
        retained = 0
        for (i = NR - k + 1; i <= NR; i++) retained += sizes[i]

        dropped = total_tokens - retained - V
        if (dropped <= 0) continue

        # Monetary savings from reduced future context
        benefit = E * (p_base - p_cache) * dropped / 1000000 - penalty

        # Info loss penalty: loss of context quality degrades agent performance
        # r_t = cumulative retention × this compaction's keep ratio
        # info_loss = (1 - r_t)²  — quadratic penalty for over-compression
        # penalty = beta × info_loss × N_remain
        r_t = r_cumulative * k / NR
        info_loss = (1.0 - r_t) * (1.0 - r_t)
        benefit -= beta * info_loss * N_remain

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
