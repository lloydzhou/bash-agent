package sse

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/lloydzhou/bash-agent/internal/protocol"
)

type OpenAIParser struct{}

func (p OpenAIParser) Parse(r io.Reader, emit func(protocol.Event) error) error {
	scanner := bufio.NewScanner(r)
	buf := make([]byte, 0, 64*1024)
	scanner.Buffer(buf, 1024*1024)

	stopReason := ""
	inputTokens := 0
	outputTokens := 0
	cacheInputTokens := 0
	sawText := false
	type pending struct {
		ID        string
		Name      string
		Arguments string
	}
	pendingCalls := map[int]*pending{}
	maxIndex := -1

	emitPending := func() error {
		for i := 0; i <= maxIndex; i++ {
			call := pendingCalls[i]
			if call == nil || call.Arguments == "" {
				continue
			}
			event, err := BuildToolCallEvent(call.Name, call.ID, call.Arguments)
			if err != nil {
				return err
			}
			if err := emit(event); err != nil {
				return err
			}
			call.Arguments = ""
		}
		return nil
	}

	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || !strings.HasPrefix(line, "data: ") {
			continue
		}
		payload := strings.TrimPrefix(line, "data: ")
		if payload == "[DONE]" {
			if err := emitPending(); err != nil {
				return err
			}
			if stopReason == "" {
				stopReason = "done"
			}
			if err := emit(protocol.UsageEvent{
				InputTokens:      inputTokens,
				OutputTokens:     outputTokens,
				CacheInputTokens: cacheInputTokens,
			}); err != nil {
				return err
			}
			if err := emit(protocol.StopEvent{Reason: stopReason}); err != nil {
				return err
			}
			break
		}

		var body struct {
			Choices []struct {
				Delta struct {
					Content   string `json:"content"`
					ToolCalls []struct {
						Index    int    `json:"index"`
						ID       string `json:"id"`
						Function struct {
							Name      string `json:"name"`
							Arguments string `json:"arguments"`
						} `json:"function"`
					} `json:"tool_calls"`
				} `json:"delta"`
				FinishReason string `json:"finish_reason"`
			} `json:"choices"`
			Usage struct {
				PromptTokens     int `json:"prompt_tokens"`
				CompletionTokens int `json:"completion_tokens"`
				CachedTokens     int `json:"cached_tokens"`
			} `json:"usage"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal([]byte(payload), &body); err != nil {
			return fmt.Errorf("parse openai sse: %w", err)
		}
		if body.Error != nil {
			return emit(protocol.ErrorEvent{Message: body.Error.Message})
		}
		if body.Usage.PromptTokens != 0 {
			inputTokens = body.Usage.PromptTokens
		}
		if body.Usage.CompletionTokens != 0 {
			outputTokens = body.Usage.CompletionTokens
		}
		if body.Usage.CachedTokens != 0 {
			cacheInputTokens = body.Usage.CachedTokens
		}
		if len(body.Choices) == 0 {
			continue
		}
		choice := body.Choices[0]
		if choice.FinishReason != "" && choice.FinishReason != "null" {
			stopReason = choice.FinishReason
		}
		if choice.Delta.Content != "" {
			content := choice.Delta.Content
			if !sawText {
				content = strings.TrimLeft(content, "\n\r")
			}
			if content != "" {
				sawText = true
				if err := emit(protocol.TextEvent{Content: content}); err != nil {
					return err
				}
			}
		}
		for _, tc := range choice.Delta.ToolCalls {
			call := pendingCalls[tc.Index]
			if call == nil {
				call = &pending{}
				pendingCalls[tc.Index] = call
			}
			if tc.Index > maxIndex {
				maxIndex = tc.Index
			}
			if tc.ID != "" {
				call.ID = tc.ID
			}
			if tc.Function.Name != "" {
				call.Name = tc.Function.Name
			}
			if tc.Function.Arguments != "" {
				call.Arguments += tc.Function.Arguments
			}
		}
		if choice.FinishReason == "tool_calls" {
			if err := emitPending(); err != nil {
				return err
			}
		}
	}
	return scanner.Err()
}
