package conversation

import (
	"encoding/json"
	"math"
)

// DPCompactConfig holds the parameters for the DP compact decision.
// Matches DP_* env vars in bash-agent.
type DPCompactConfig struct {
	PBase         float64 // $/MTok, uncached input price
	PCache        float64 // $/MTok, cached input price
	V             int     // fixed overhead tokens (system prompt + current input)
	Penalty       float64 // $, compact overhead (summary call + cache miss)
	BaselineE     int     // expected remaining user-input rounds (0 = use EFixed or 1)
	EFixed        int     // fixed E (0 = use BaselineE)
	R             float64 // single-step summary retention rate
	Beta          float64 // info loss penalty coefficient
	MinKeepRatio  float64 // minimum fraction of messages to retain
}

func DefaultDPCompactConfig() DPCompactConfig {
	return DPCompactConfig{
		PBase:        3.0,
		PCache:       0.30,
		V:            5000,
		Penalty:      0.25,
		BaselineE:    8,
		EFixed:       0,
		R:            0.70,
		Beta:         0.5,
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

	// Token estimation per line (bytes/4)
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

	// Total tokens
	totalTokens := 0
	for _, s := range sizes {
		totalTokens += s
	}

	// Cumulative retention after prevCompactions compactions
	rCumulative := 1.0
	for i := 0; i < prevCompactions; i++ {
		rCumulative *= cfg.R
	}
	if rCumulative < 0.37 {
		rCumulative = 0.37
	}

	// Expected remaining cost
	nRemain := float64(cfg.EFixed)
	if nRemain <= 0 {
		e := cfg.BaselineE - currentTurn
		if e <= 0 {
			if cfg.BaselineE > 1 {
				e = cfg.BaselineE / 2
			} else {
				e = 2
			}
		}
		nRemain = float64(e)
	}
	nRemainDollars := nRemain * float64(totalTokens) * cfg.PBase / 1_000_000

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
		retained := 0
		for i := n - k; i < n; i++ {
			retained += sizes[i]
		}
		dropped := totalTokens - retained - cfg.V
		if dropped <= 0 {
			continue
		}

		// Monetary benefit
		benefit := nRemain * (cfg.PBase - cfg.PCache) * float64(dropped) / 1_000_000
		benefit -= cfg.Penalty

		// Info loss penalty
		rT := rCumulative * float64(k) / float64(n)
		infoLoss := (1.0 - rT) * (1.0 - rT)
		benefit -= cfg.Beta * infoLoss * nRemainDollars

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
