package provider

import (
	"encoding/json"
	"fmt"

	"github.com/lloydzhou/bash-agent/internal/config"
)

func BuildRequest(cfg config.Config, messages []json.RawMessage, tools []byte, systemPrompt string, maxTokens int, thinkingBudget int) ([]byte, error) {
	switch cfg.Provider {
	case "claude":
		return buildClaudeRequest(cfg, messages, tools, systemPrompt, maxTokens, thinkingBudget)
	case "openai":
		return buildOpenAIRequest(cfg, messages, tools, systemPrompt, maxTokens, thinkingBudget)
	default:
		return nil, fmt.Errorf("unknown provider: %s", cfg.Provider)
	}
}

func buildClaudeRequest(cfg config.Config, messages []json.RawMessage, tools []byte, systemPrompt string, maxTokens int, thinkingBudget int) ([]byte, error) {
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

func buildOpenAIRequest(cfg config.Config, messages []json.RawMessage, tools []byte, systemPrompt string, maxTokens int, thinkingBudget int) ([]byte, error) {
	converted, err := convertMessagesToOpenAI(messages)
	if err != nil {
		return nil, err
	}
	if systemPrompt != "" {
		sysMsg := map[string]any{
			"role":    "system",
			"content": systemPrompt,
		}
		converted = append([]any{sysMsg}, converted...)
	}
	body := map[string]any{
		"model":      cfg.Model,
		"max_tokens": maxTokens,
		"stream":     true,
		"messages":   converted,
	}
	if thinkingBudget > 0 {
		body["reasoning_effort"] = "high"
	}
	if len(tools) > 0 {
		openAITools, err := convertToolsToOpenAI(tools)
		if err != nil {
			return nil, err
		}
		body["tools"] = openAITools
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

func convertMessagesToOpenAI(lines []json.RawMessage) ([]any, error) {
	var result []any
	for _, line := range lines {
		var msg struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal(line, &msg); err != nil {
			return nil, err
		}
		if len(msg.Content) > 0 && msg.Content[0] == '[' {
			if msg.Role == "assistant" {
				converted, err := convertAssistantMessage(msg.Content)
				if err != nil {
					return nil, err
				}
				result = append(result, converted)
				continue
			}
			if msg.Role == "user" {
				toolMsgs, err := convertToolResultMessages(msg.Content)
				if err != nil {
					return nil, err
				}
				if len(toolMsgs) > 0 {
					result = append(result, toolMsgs...)
					continue
				}
			}
		}
		var passthrough map[string]any
		if err := json.Unmarshal(line, &passthrough); err != nil {
			return nil, err
		}
		result = append(result, passthrough)
	}
	return result, nil
}

func convertAssistantMessage(raw json.RawMessage) (map[string]any, error) {
	var blocks []struct {
		Type     string          `json:"type"`
		Text     string          `json:"text"`
		Thinking string          `json:"thinking"`
		ID       string          `json:"id"`
		Name     string          `json:"name"`
		Input    json.RawMessage `json:"input"`
	}
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return nil, err
	}
	text := ""
	thinking := ""
	toolCalls := make([]map[string]any, 0)
	for _, block := range blocks {
		switch block.Type {
		case "thinking":
			thinking += block.Thinking
		case "text":
			text += block.Text
		case "tool_use":
			toolCalls = append(toolCalls, map[string]any{
				"id":   block.ID,
				"type": "function",
				"function": map[string]any{
					"name":      block.Name,
					"arguments": string(block.Input),
				},
			})
		}
	}
	msg := map[string]any{
		"role":              "assistant",
		"reasoning_content": thinking,
		"content":           text,
	}
	if len(toolCalls) > 0 {
		msg["tool_calls"] = toolCalls
	}
	return msg, nil
}

func convertToolResultMessages(raw json.RawMessage) ([]any, error) {
	var blocks []struct {
		Type      string `json:"type"`
		ToolUseID string `json:"tool_use_id"`
		Content   string `json:"content"`
	}
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return nil, err
	}
	out := make([]any, 0)
	for _, block := range blocks {
		if block.Type != "tool_result" {
			continue
		}
		out = append(out, map[string]any{
			"role":         "tool",
			"tool_call_id": block.ToolUseID,
			"content":      block.Content,
		})
	}
	return out, nil
}

func convertToolsToOpenAI(raw []byte) ([]any, error) {
	var tools []map[string]any
	if err := json.Unmarshal(raw, &tools); err != nil {
		return nil, err
	}
	out := make([]any, 0, len(tools))
	for _, tool := range tools {
		if tool["type"] == "function" {
			out = append(out, tool)
			continue
		}
		out = append(out, map[string]any{
			"type": "function",
			"function": map[string]any{
				"name":        tool["name"],
				"description": tool["description"],
				"parameters":  firstNonNil(tool["input_schema"], tool["parameters"], map[string]any{}),
			},
		})
	}
	return out, nil
}

func firstNonNil(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}
