package sse

import (
	"strings"
	"testing"

	"github.com/lloydzhou/bash-agent/internal/protocol"
)

func TestClaudeParserThinking(t *testing.T) {
	stream := strings.Join([]string{
		"event: content_block_start",
		`data: {"content_block":{"type":"thinking"}}`,
		"",
		"event: content_block_delta",
		`data: {"delta":{"thinking":"Let me think..."}}`,
		"",
		"event: content_block_stop",
		`data: {}`,
		"",
		"event: message_delta",
		`data: {"delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"output_tokens":5}}`,
		"",
		"event: message_stop",
		`data: {}`,
		"",
	}, "\n")
	var events []protocol.Event
	err := (ClaudeParser{}).Parse(strings.NewReader(stream), func(evt protocol.Event) error {
		events = append(events, evt)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// Expect: ThinkingEvent, UsageEvent, StopEvent
	var foundThinking bool
	for _, evt := range events {
		if te, ok := evt.(protocol.ThinkingEvent); ok {
			foundThinking = true
			if te.Content != "Let me think..." {
				t.Fatalf("unexpected thinking content: %q", te.Content)
			}
		}
	}
	if !foundThinking {
		t.Fatalf("expected ThinkingEvent in events: %#v", events)
	}
}

func TestClaudeParserToolUse(t *testing.T) {
	stream := strings.Join([]string{
		"event: content_block_start",
		`data: {"content_block":{"type":"tool_use","id":"toolu_1","name":"Write"}}`,
		"",
		"event: content_block_delta",
		`data: {"delta":{"partial_json":"{\"path\":\"/tmp/test.txt\","}}`,
		"",
		"event: content_block_delta",
		`data: {"delta":{"partial_json":"\"content\":\"AbC\"}"}}`,
		"",
		"event: content_block_stop",
		`data: {}`,
		"",
		"event: message_delta",
		`data: {"delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":10,"output_tokens":7,"cache_creation_input_tokens":4}}`,
		"",
		"event: message_stop",
		`data: {}`,
		"",
	}, "\n")
	var events []protocol.Event
	err := (ClaudeParser{}).Parse(strings.NewReader(stream), func(evt protocol.Event) error {
		events = append(events, evt)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 3 {
		t.Fatalf("expected 3 events, got %d (%#v)", len(events), events)
	}
	call := events[0].(protocol.ToolCallEvent)
	if call.Name != "Write" || call.Fields["path"] != "/tmp/test.txt" || call.Fields["content"] != "AbC" {
		t.Fatalf("unexpected tool call: %+v", call)
	}
}

func TestOpenAIParserReasoning(t *testing.T) {
	stream := strings.Join([]string{
		`data: {"choices":[{"delta":{"reasoning_content":"hmm..."}}]}`,
		`data: {"choices":[{"delta":{"content":"hello"}}]}`,
		`data: [DONE]`,
	}, "\n")
	var events []protocol.Event
	err := (OpenAIParser{}).Parse(strings.NewReader(stream), func(evt protocol.Event) error {
		events = append(events, evt)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var foundThinking, foundText bool
	for _, evt := range events {
		if te, ok := evt.(protocol.ThinkingEvent); ok {
			foundThinking = true
			if te.Content != "hmm..." {
				t.Fatalf("unexpected thinking content: %q", te.Content)
			}
		}
		if _, ok := evt.(protocol.TextEvent); ok {
			foundText = true
		}
	}
	if !foundThinking {
		t.Fatalf("expected ThinkingEvent in events: %#v", events)
	}
	if !foundText {
		t.Fatalf("expected TextEvent in events: %#v", events)
	}
}

func TestOpenAIParserToolCalls(t *testing.T) {
	stream := strings.Join([]string{
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"Write","arguments":"{\"path\":\"/tmp/test.txt\","}}]}}]}`,
		`data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"content\":\"AbC\"}"}}],"finish_reason":"tool_calls"}}]}`,
		`data: [DONE]`,
	}, "\n")
	var events []protocol.Event
	err := (OpenAIParser{}).Parse(strings.NewReader(stream), func(evt protocol.Event) error {
		events = append(events, evt)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(events) < 1 {
		t.Fatalf("expected events")
	}
	call := events[0].(protocol.ToolCallEvent)
	if call.Name != "Write" || call.Fields["path"] != "/tmp/test.txt" || call.Fields["content"] != "AbC" {
		t.Fatalf("unexpected tool call: %+v", call)
	}
}
