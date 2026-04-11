package provider

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/lloydzhou/bash-agent/internal/config"
)

func TestBuildOpenAIRequestConvertsMessagesAndTools(t *testing.T) {
	cfg := config.Default()
	cfg.Provider = "openai"
	cfg.Model = "gpt-4o"
	messages := []json.RawMessage{
		json.RawMessage(`{"role":"user","content":"hello"}`),
		json.RawMessage(`{"role":"assistant","content":[{"type":"text","text":"working"},{"type":"tool_use","id":"call_1","name":"Read","input":{"path":"/tmp/x"}}]}`),
		json.RawMessage(`{"role":"user","content":[{"type":"tool_result","tool_use_id":"call_1","content":"abc"}]}`),
	}
	tools := []byte(`[{"name":"Read","description":"Read a file.","input_schema":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}]`)
	body, err := BuildRequest(cfg, messages, tools, "sys", 123)
	if err != nil {
		t.Fatal(err)
	}
	s := string(body)
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
