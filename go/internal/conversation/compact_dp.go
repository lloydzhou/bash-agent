package conversation

import (
	"encoding/json"
	"math"
	"strings"
)

// DPCompactConfig holds the parameters for the DP compact decision.
// Matches DP_* env vars in bash-agent.
type DPCompactConfig struct {
	PInput        float64 // $/MTok, uncached input price
	PCache       float64 // $/MTok, cached input price
	POut         float64 // $/MTok, output price
	V            int     // fixed prefix tokens (system prompt + tools + summary)
	S            int     // fixed summary length (tokens)
	LFixed       float64 // fixed L override (0 = auto from stats)
	BaselineE    int     // baseline for E calculation
	EFixed       int     // fixed E override (0 = use BaselineE)
	R            float64 // single-step summary retention rate
	Beta         float64 // info loss penalty coefficient
	MinKeepRatio float64 // minimum fraction of messages to retain
}

func DefaultDPCompactConfig() DPCompactConfig {
	return DPCompactConfig{
		PInput:        3.0,
		PCache:       0.30,
		POut:         15.0,
		V:            5000,
		S:            500,
		LFixed:       0,
		BaselineE:    8,
		EFixed:       0,
		R:            0.8,
		Beta:         0.03,
		MinKeepRatio: 0.12,
	}
}

// CompactTurnKeep computes turn-aligned lines to keep using MinKeepRatio.
// Matches bash compact_turn_keep(): counts user inputs, applies ratio, aligns to user boundary.
func (s Store) CompactTurnKeep(minKeepRatio float64) (int, error) {
	lines, err := s.Lines()
	if err != nil {
		return 0, err
	}
	if len(lines) == 0 {
		return 0, nil
	}

	// Detect user role: match {"role":"user","content":"... (excludes tool_result lines)
	roleUser := make([]bool, len(lines))
	totalTurns := 0
	for i, line := range lines {
		s := string(line)
		if strings.HasPrefix(s, `{"role":"user","content":"`) {
			roleUser[i] = true
			totalTurns++
		}
	}

	target := int(float64(totalTurns)*minKeepRatio + 0.5)
	if target < 1 {
		target = 1
	}
	if target > totalTurns {
		target = totalTurns
	}

	keep := 0
	found := 0
	for i := len(lines) - 1; i >= 0 && found < target; i-- {
		keep++
		if roleUser[i] {
			found++
		}
	}
	if keep < 3 {
		return len(lines), nil
	}
	return keep, nil
}

// CompactDPDecision computes the optimal number of lines to keep.
// All computation (E, L, avg) happens here — callers pass raw stats only.
// prevCompactions: number of previous compactions (from stats).
// currentTurn: completed user-input rounds (from stats).
// totalRequests: total LLM request count (from stats).
// totalInputTokens: total cumulative input tokens (from stats).
// Returns: keepLines (turn-aligned, or 0 if no compact beneficial).
func (s Store) CompactDPDecision(cfg DPCompactConfig, prevCompactions int, currentTurn int, totalRequests int, totalInputTokens int) (int, error) {
	lines, err := s.Lines()
	if err != nil {
		return 0, err
	}
	if len(lines) == 0 {
		return 0, nil
	}

	n := len(lines)
	sizes := make([]int, n)
	roleUser := make([]bool, n)
	for i, line := range lines {
		sizes[i] = (len(line) + 3) / 4
		if len(line) > 0 {
			var msg struct {
				Role    string          `json:"role"`
				Content json.RawMessage `json:"content"`
			}
			if err := json.Unmarshal(line, &msg); err == nil {
				roleUser[i] = msg.Role == "user" && len(msg.Content) > 0 && msg.Content[0] == '"'
			}
		}
	}

	totalTokens := 0
	for _, s := range sizes {
		totalTokens += s
	}

	// E: expected remaining user-input rounds
	var E float64
	if cfg.EFixed > 0 {
		E = float64(cfg.EFixed)
	} else if cfg.BaselineE > 0 {
		remaining := cfg.BaselineE - currentTurn
		floor := cfg.BaselineE / 2
		if floor < 2 {
			floor = 2
		}
		if remaining < floor {
			remaining = floor
		}
		E = float64(remaining)
	} else {
		E = 2.0
	}

	// L: avg LLM calls per user input (auto from stats if LFixed=0)
	var L float64
	if cfg.LFixed > 0 {
		L = cfg.LFixed
	} else if currentTurn > 0 && totalRequests > 0 {
		L = float64(totalRequests) / float64(currentTurn)
	} else {
		L = 5.0
	}
	if L < 1 {
		L = 1
	}

	// avg: avg input tokens per LLM request (auto from stats)
	var avg float64
	if totalRequests > 0 && totalInputTokens > 0 {
		avg = float64(totalInputTokens) / float64(totalRequests)
	} else {
		avg = 4000
	}

	// R = E * L: total expected remaining LLM calls
	R := E * L

	// Cumulative retention: r^(c+1) (independent of k)
	rT := math.Pow(cfg.R, float64(prevCompactions+1))
	if rT < 0.37 {
		rT = 0.37
	}

	// N_remain: expected remaining input tokens (R * avg_per_request)
	NRemain := R * avg

	// ④ Info loss (constant across all k)
	infoLoss := cfg.Beta * (1.0 - rT) * NRemain * cfg.PInput / 1_000_000

	// Summary instruction length (fixed ~70 tokens)
	lInstr := 70.0

	// Minimum keep (hard floor at 3)
	minKeep := int(float64(n)*cfg.MinKeepRatio + 0.5)
	if minKeep < 3 {
		minKeep = 3
	}
	if minKeep > n {
		minKeep = n
	}

	bestK := 0
	bestBenefit := math.Inf(-1)

	for k := minKeep; k <= n; k++ {
		K := 0
		for i := n - k; i < n; i++ {
			K += sizes[i]
		}

		H := totalTokens - K
		if H <= 0 {
			continue
		}

		Hf := float64(H)
		Kf := float64(K)
		Sf := float64(cfg.S)
		Vf := float64(cfg.V)

		// ① Savings: (R-1) subsequent LLM calls save P_cache × H each
		savings := (R - 1) * cfg.PCache * Hf / 1_000_000

		// ② Cache invalidation: (S + K) at P_base instead of P_cache
		cacheMiss := (Sf + Kf) * (cfg.PInput - cfg.PCache) / 1_000_000

		// ③ Compaction request cost
		compactCost := (cfg.PCache*(Vf+Hf) + cfg.PInput*lInstr + cfg.POut*Sf) / 1_000_000

		benefit := savings - cacheMiss - compactCost - infoLoss

		if benefit > bestBenefit {
			bestBenefit = benefit
			bestK = k
		}
	}

	if bestBenefit <= 0 {
		return 0, nil
	}

	// Align to user-message (turn) boundary
	adj := bestK
	cut := n - adj
	for cut > 0 && !roleUser[cut] {
		cut--
		adj = n - cut
	}
	if adj < 1 {
		adj = 1
	}
	return adj, nil
}
