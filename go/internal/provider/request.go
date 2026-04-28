package provider

import (
	"encoding/json"

	"github.com/lloydzhou/bash-agent/internal/config"
)

// BuildClaudeRequest builds a Claude Messages API request body.
// Always produces Claude-format JSON; the transport layer handles provider conversion.
func BuildClaudeRequest(cfg config.Config, messages []json.RawMessage, tools []byte, systemPrompt string, maxTokens int, thinkingBudget int) ([]byte, error) {
	body := map[string]any{
		"model":      cfg.Model,
		"max_tokens": maxTokens,
		"stream":     true,
		"messages":   rawArray(messages),
	}
	if thinkingBudget > 0 {
		body["thinking"] = map[string]any{
			"type":          "enabled",
			"budget_tokens": thinkingBudget,
		}
	}
	if systemPrompt != "" {
		body["system"] = systemPrompt
	}
	if len(tools) > 0 {
		body["tools"] = json.RawMessage(tools)
	}
	return json.Marshal(body)
}

func rawArray(lines []json.RawMessage) []json.RawMessage {
	out := make([]json.RawMessage, 0, len(lines))
	for _, line := range lines {
		out = append(out, line)
	}
	return out
}
