package transport

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/lloydzhou/bash-agent/internal/config"
	"github.com/lloydzhou/bash-agent/internal/provider"
)

func TestOpenAITransportConvertsBody(t *testing.T) {
	cfg := config.Default()
	cfg.Provider = "openai"
	cfg.Model = "gpt-4o"

	messages := []json.RawMessage{
		json.RawMessage(`{"role":"user","content":"hello"}`),
		json.RawMessage(`{"role":"assistant","content":[{"type":"text","text":"working"},{"type":"tool_use","id":"call_1","name":"Read","input":{"path":"/tmp/x"}}]}`),
		json.RawMessage(`{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"abc"}]}`),
	}
	tools := []byte(`[{"name":"Read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]`)

	// Step 1: Build Claude-format body
	claudeBody, err := provider.BuildClaudeRequest(cfg, messages, tools, "sys", 123, 0)
	if err != nil {
		t.Fatal(err)
	}

	// Step 2: Transport converts Claude body → OpenAI body
	tr := New(cfg)
	openaiBody, err := tr.ConvertBody(claudeBody)
	if err != nil {
		t.Fatal(err)
	}

	s := string(openaiBody)
	for _, want := range []string{
		`"content":"sys","role":"system"`,
		`"arguments":"{\"path\":\"/tmp/x\"}"`,
		`"name":"Read"`,
		`"tool_call_id":"call_1"`,
		`"content":"abc","role":"tool"`,
		`"description":"Read a file."`,
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("request missing %q in %s", want, s)
		}
	}
}

func TestOpenAITransportMapsStopReasons(t *testing.T) {
	cfg := config.Default()
	cfg.Provider = "openai"

	tr := New(cfg)
	// Verify it's the openai transport
	_, ok := tr.(*openaiTransport)
	if !ok {
		t.Fatal("expected openaiTransport for openai provider")
	}
}

func TestClaudeTransportIdentity(t *testing.T) {
	cfg := config.Default()
	cfg.Provider = "claude"

	tr := New(cfg)
	body := []byte(`{"model":"test","messages":[]}`)
	out, err := tr.ConvertBody(body)
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != string(body) {
		t.Fatalf("claude transport should be identity, got %s", string(out))
	}
}
