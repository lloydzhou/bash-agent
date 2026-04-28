package transport

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/lloydzhou/bash-agent/internal/config"
	"github.com/lloydzhou/bash-agent/internal/protocol"
	"github.com/lloydzhou/bash-agent/internal/sse"
)

// Transport abstracts the per-provider body conversion and SSE parsing.
// Mirrors bash's unified pipeline: build_claude_request | body_convert | _stream_curl | sse_convert | sse_parse
// - ConvertBody: Claude-format body → provider body (identity for Claude)
// - ParseSSE:    provider SSE stream → protocol.Event (always emits Claude semantics)
type Transport interface {
	ConvertBody(claudeBody []byte) ([]byte, error)
	ParseSSE(r io.Reader, emit func(protocol.Event) error) error
}

// New returns the appropriate Transport for the configured provider.
func New(cfg config.Config) Transport {
	switch cfg.Provider {
	case "openai":
		return &openaiTransport{}
	default: // claude
		return &claudeTransport{}
	}
}

// --- Claude transport (identity) ---

type claudeTransport struct{}

func (t *claudeTransport) ConvertBody(body []byte) ([]byte, error) {
	return body, nil // identity — no conversion
}

func (t *claudeTransport) ParseSSE(r io.Reader, emit func(protocol.Event) error) error {
	return sse.ClaudeParser{}.Parse(r, emit)
}

// --- OpenAI transport (body conversion + SSE with stop reason mapping) ---

type openaiTransport struct{}

func (t *openaiTransport) ConvertBody(claudeBody []byte) ([]byte, error) {
	var raw struct {
		Model         string          `json:"model"`
		MaxTokens     int             `json:"max_tokens"`
		System        json.RawMessage `json:"system"`
		Thinking      json.RawMessage `json:"thinking"`
		Messages      json.RawMessage `json:"messages"`
		Tools         json.RawMessage `json:"tools"`
	}
	if err := json.Unmarshal(claudeBody, &raw); err != nil {
		return nil, fmt.Errorf("transport_openai_body: %w", err)
	}

	// Convert messages
	var messages []json.RawMessage
	if err := json.Unmarshal(raw.Messages, &messages); err != nil {
		return nil, fmt.Errorf("transport_openai_body: messages: %w", err)
	}
	converted, err := convertMessagesToOpenAI(messages)
	if err != nil {
		return nil, err
	}

	// System prompt → system message (prepend)
	if raw.System != nil && string(raw.System) != "" && string(raw.System) != "null" {
		sysMsg := map[string]any{"role": "system", "content": json.RawMessage(raw.System)}
		converted = append([]any{sysMsg}, converted...)
	}

	body := map[string]any{
		"model":      raw.Model,
		"max_tokens": raw.MaxTokens,
		"stream":     true,
		"messages":   converted,
	}

	// thinking → reasoning_effort
	if raw.Thinking != nil && string(raw.Thinking) != "" && string(raw.Thinking) != "{}" && string(raw.Thinking) != "null" {
		body["reasoning_effort"] = "high"
	}

	// Convert tools
	if raw.Tools != nil && string(raw.Tools) != "" && string(raw.Tools) != "[]" && string(raw.Tools) != "null" {
		var tools []map[string]any
		if err := json.Unmarshal(raw.Tools, &tools); err != nil {
			return nil, fmt.Errorf("transport_openai_body: tools: %w", err)
		}
		openaiTools, err := convertToolsToOpenAI(tools)
		if err != nil {
			return nil, err
		}
		body["tools"] = openaiTools
	}

	return json.Marshal(body)
}

func (t *openaiTransport) ParseSSE(r io.Reader, emit func(protocol.Event) error) error {
	return sse.OpenAIParser{}.Parse(r, func(evt protocol.Event) error {
		// Map OpenAI stop reasons to Claude stop reasons (matches bash transport_openai_sse.awk)
		if e, ok := evt.(protocol.StopEvent); ok {
			switch e.Reason {
			case "stop":
				e.Reason = "end_turn"
			case "tool_calls":
				e.Reason = "tool_use"
			case "length":
				e.Reason = "max_tokens"
			}
			evt = e
		}
		return emit(evt)
	})
}

// --- Message conversion (Claude → OpenAI) ---

func convertMessagesToOpenAI(messages []json.RawMessage) ([]any, error) {
	var result []any
	for _, msg := range messages {
		var m struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal(msg, &m); err != nil {
			return nil, err
		}
		if len(m.Content) > 0 && m.Content[0] == '[' {
			if m.Role == "assistant" {
				converted, err := convertAssistantMessage(m.Content)
				if err != nil {
					return nil, err
				}
				result = append(result, converted)
				continue
			}
			if m.Role == "user" {
				toolMsgs, err := convertToolResultMessages(m.Content)
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
		if err := json.Unmarshal(msg, &passthrough); err != nil {
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

// --- Tool conversion (Claude → OpenAI) ---

func convertToolsToOpenAI(tools []map[string]any) ([]any, error) {
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
	for _, v := range values {
		if v != nil {
			return v
		}
	}
	return nil
}
