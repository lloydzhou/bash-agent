package conversation

import (
	"encoding/json"
	"math"
)

// DPCompactConfig holds the parameters for the DP compact decision.
// Matches DP_* env vars in bash-agent.
type DPCompactConfig struct {
	PInput        float64 // $/MTok, uncached input price
	PCache       float64 // $/MTok, cached input price
	POut         float64 // $/MTok, output price
	V            int     // fixed prefix tokens (system prompt + tools + summary)
	S            int     // fixed summary length (tokens)
	Avg          int     // avg input tokens per LLM request
	L            float64 // avg LLM calls per user input (R = E * L)
	BaselineE    int     // expected remaining user-input rounds (0 = auto)
	EFixed       int     // fixed E (0 = use BaselineE)
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
		Avg:          4000,
		L:            5.0,
		BaselineE:    8,
		EFixed:       0,
		R:            0.8,
		Beta:         0.03,
		MinKeepRatio: 0.12,
	}
}

// CompactDPDecision computes the optimal number of lines to keep.
// prevCompactions: number of previous compactions (from stats).
// currentTurn: completed user-input rounds (from stats current_turn_count).
// Returns: keepLines (turn-aligned, or 0 if no compact beneficial).
func (s Store) CompactDPDecision(cfg DPCompactConfig, prevCompactions int, currentTurn int) (int, error) {
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
		if remaining <= 0 {
			if cfg.BaselineE > 1 {
				remaining = cfg.BaselineE / 2
			} else {
				remaining = 2
			}
		}
		E = float64(remaining)
	} else {
		E = 2.0
	}

	// R = E * L: total expected remaining LLM calls
	R := E * cfg.L

	// Cumulative retention: r^(c+1) (independent of k)
	rT := math.Pow(cfg.R, float64(prevCompactions+1))
	if rT < 0.37 {
		rT = 0.37
	}

	// N_remain: expected remaining input tokens (R * avg_per_request)
	NRemain := R * float64(cfg.Avg)

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
