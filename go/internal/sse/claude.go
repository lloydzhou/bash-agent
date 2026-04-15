package sse

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/lloydzhou/bash-agent/internal/protocol"
)

type SSEEvent struct {
	Event string
	Data  string
}

func ReadSSE(r io.Reader, fn func(SSEEvent) error) error {
	scanner := bufio.NewScanner(r)
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)
	var current SSEEvent
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if current.Data != "" || current.Event != "" {
				if err := fn(current); err != nil {
					return err
				}
			}
			current = SSEEvent{}
			continue
		}
		switch {
		case strings.HasPrefix(line, "event: "):
			current.Event = strings.TrimPrefix(line, "event: ")
		case strings.HasPrefix(line, "data: "):
			current.Data += strings.TrimPrefix(line, "data: ")
		}
	}
	if current.Data != "" || current.Event != "" {
		if err := fn(current); err != nil {
			return err
		}
	}
	return scanner.Err()
}

type ClaudeParser struct{}

func (p ClaudeParser) Parse(r io.Reader, emit func(protocol.Event) error) error {
	var (
		blockType        string
		toolName         string
		toolID           string
		partialJSON      string
		stopReason       string
		inputTokens      int
		outputTokens     int
		cacheInputTokens int
	)
	return ReadSSE(r, func(evt SSEEvent) error {
		if evt.Data == "" {
			return nil
		}
		var body map[string]json.RawMessage
		if err := json.Unmarshal([]byte(evt.Data), &body); err != nil {
			return fmt.Errorf("parse claude sse: %w", err)
		}
		switch evt.Event {
		case "content_block_start":
			var payload struct {
				ContentBlock struct {
					Type string `json:"type"`
					Name string `json:"name"`
					ID   string `json:"id"`
				} `json:"content_block"`
			}
			if err := json.Unmarshal([]byte(evt.Data), &payload); err != nil {
				return err
			}
			switch payload.ContentBlock.Type {
			case "text":
				blockType = "text"
			case "tool_use":
				blockType = "tool"
				toolName = payload.ContentBlock.Name
				toolID = payload.ContentBlock.ID
				partialJSON = ""
			}
		case "content_block_delta":
			if blockType == "text" {
				var payload struct {
					Delta struct {
						Text string `json:"text"`
					} `json:"delta"`
				}
				if err := json.Unmarshal([]byte(evt.Data), &payload); err != nil {
					return err
				}
				if payload.Delta.Text != "" {
					if err := emit(protocol.TextEvent{Content: payload.Delta.Text}); err != nil {
						return err
					}
				}
			} else if blockType == "tool" {
				var payload struct {
					Delta struct {
						PartialJSON string `json:"partial_json"`
					} `json:"delta"`
				}
				if err := json.Unmarshal([]byte(evt.Data), &payload); err != nil {
					return err
				}
				partialJSON += payload.Delta.PartialJSON
			}
		case "content_block_stop":
			if blockType == "tool" {
				call, err := BuildToolCallEvent(toolName, toolID, partialJSON)
				if err != nil {
					return err
				}
				if err := emit(call); err != nil {
					return err
				}
			}
			blockType = ""
		case "message_delta":
			var payload struct {
				Delta struct {
					StopReason string `json:"stop_reason"`
				} `json:"delta"`
				Usage struct {
					InputTokens              int `json:"input_tokens"`
					OutputTokens             int `json:"output_tokens"`
					CacheReadInputTokens     int `json:"cache_read_input_tokens"`
					CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
				} `json:"usage"`
			}
			if err := json.Unmarshal([]byte(evt.Data), &payload); err != nil {
				return err
			}
			if payload.Delta.StopReason != "" {
				stopReason = payload.Delta.StopReason
			}
			if payload.Usage.InputTokens != 0 {
				inputTokens = payload.Usage.InputTokens
			}
			if payload.Usage.OutputTokens != 0 {
				outputTokens = payload.Usage.OutputTokens
			}
			if payload.Usage.CacheReadInputTokens != 0 {
				cacheInputTokens = payload.Usage.CacheReadInputTokens
			} else if payload.Usage.CacheCreationInputTokens != 0 {
				cacheInputTokens = payload.Usage.CacheCreationInputTokens
			}
		case "message_start":
			var payload struct {
				Message struct {
					Usage struct {
						InputTokens              int `json:"input_tokens"`
						CacheReadInputTokens     int `json:"cache_read_input_tokens"`
						CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
					} `json:"usage"`
				} `json:"message"`
			}
			if err := json.Unmarshal([]byte(evt.Data), &payload); err != nil {
				return err
			}
			if payload.Message.Usage.InputTokens != 0 {
				inputTokens = payload.Message.Usage.InputTokens
			}
			if payload.Message.Usage.CacheReadInputTokens != 0 {
				cacheInputTokens = payload.Message.Usage.CacheReadInputTokens
			} else if payload.Message.Usage.CacheCreationInputTokens != 0 {
				cacheInputTokens = payload.Message.Usage.CacheCreationInputTokens
			}
		case "message_stop":
			if err := emit(protocol.UsageEvent{
				InputTokens:      inputTokens,
				OutputTokens:     outputTokens,
				CacheInputTokens: cacheInputTokens,
			}); err != nil {
				return err
			}
			return emit(protocol.StopEvent{Reason: stopReason})
		case "error":
			var payload struct {
				Error struct {
					Message string `json:"message"`
				} `json:"error"`
				Message string `json:"message"`
			}
			if err := json.Unmarshal([]byte(evt.Data), &payload); err != nil {
				return err
			}
			msg := payload.Message
			if msg == "" {
				msg = payload.Error.Message
			}
			return emit(protocol.ErrorEvent{Message: msg})
		}
		_ = body
		return nil
	})
}
