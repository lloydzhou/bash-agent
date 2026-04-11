package app

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/lloydzhou/bash-agent/internal/session"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) { return f(req) }

func withTestHTTPClient(client *http.Client, fn func()) {
	old := newHTTPClient
	newHTTPClient = func() *http.Client { return client }
	defer func() { newHTTPClient = old }()
	fn()
}

func sseResponse(body string) *http.Response {
	return &http.Response{
		StatusCode: 200,
		Header:     http.Header{"Content-Type": []string{"text/event-stream"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestRunClaudePrompt(t *testing.T) {
	project := t.TempDir()
	home := t.TempDir()
	oldHome := os.Getenv("HOME")
	defer os.Setenv("HOME", oldHome)
	_ = os.Setenv("HOME", home)
	oldWD, _ := os.Getwd()
	defer os.Chdir(oldWD)
	if err := os.Chdir(project); err != nil {
		t.Fatal(err)
	}

	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return sseResponse(strings.Join([]string{
			"event: content_block_start",
			`data: {"content_block":{"type":"text"}}`,
			"",
			"event: content_block_delta",
			`data: {"delta":{"text":"hello"}}`,
			"",
			"event: message_delta",
			`data: {"delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"output_tokens":5}}`,
			"",
			"event: message_stop",
			`data: {}`,
			"",
		}, "\n")), nil
	})}
	var out, errOut strings.Builder
	withTestHTTPClient(client, func() {
		if err := Run([]string{"--base-url", "http://example.invalid", "hello"}, strings.NewReader(""), &out, &errOut); err != nil {
			t.Fatal(err)
		}
	})
	if got := out.String(); got != "hello\n" {
		t.Fatalf("unexpected output: %q", got)
	}
}

func TestRunClaudeToolLoop(t *testing.T) {
	project := t.TempDir()
	home := t.TempDir()
	target := filepath.Join(project, "out.txt")
	oldHome := os.Getenv("HOME")
	defer os.Setenv("HOME", oldHome)
	_ = os.Setenv("HOME", home)
	oldWD, _ := os.Getwd()
	defer os.Chdir(oldWD)
	if err := os.Chdir(project); err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch calls.Add(1) {
		case 1:
			return sseResponse(strings.Join([]string{
				"event: content_block_start",
				`data: {"content_block":{"type":"tool_use","id":"toolu_1","name":"Write"}}`,
				"",
				"event: content_block_delta",
				`data: {"delta":{"partial_json":"{\"path\":\"` + target + `\",\"content\":\"abc\"}"}}`,
				"",
				"event: content_block_stop",
				`data: {}`,
				"",
				"event: message_delta",
				`data: {"delta":{"stop_reason":"tool_use"}}`,
				"",
				"event: message_stop",
				`data: {}`,
				"",
			}, "\n")), nil
		default:
			return sseResponse(strings.Join([]string{
				"event: content_block_start",
				`data: {"content_block":{"type":"text"}}`,
				"",
				"event: content_block_delta",
				`data: {"delta":{"text":"done"}}`,
				"",
				"event: message_delta",
				`data: {"delta":{"stop_reason":"end_turn"}}`,
				"",
				"event: message_stop",
				`data: {}`,
				"",
			}, "\n")), nil
		}
	})}

	var out, errOut strings.Builder
	withTestHTTPClient(client, func() {
		if err := Run([]string{"--base-url", "http://example.invalid", "write file"}, strings.NewReader(""), &out, &errOut); err != nil {
			t.Fatal(err)
		}
	})
	got := strings.TrimSpace(out.String())
	if !strings.Contains(got, "OK: wrote") || !strings.HasSuffix(got, "done") {
		t.Fatalf("unexpected output: %q", got)
	}
	data, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "abc" {
		t.Fatalf("unexpected file content: %q", string(data))
	}
}

func TestCompactNoOpWithoutProviderConfig(t *testing.T) {
	project := t.TempDir()
	home := t.TempDir()
	oldHome := os.Getenv("HOME")
	defer os.Setenv("HOME", oldHome)
	_ = os.Setenv("HOME", home)
	oldWD, _ := os.Getwd()
	defer os.Chdir(oldWD)
	if err := os.Chdir(project); err != nil {
		t.Fatal(err)
	}
	sessionDir := filepath.Join(home, ".bash-agent", "projects", session.ProjectKey(project))
	if err := os.MkdirAll(sessionDir, 0o755); err != nil {
		t.Fatal(err)
	}
	conv := filepath.Join(sessionDir, "test.jsonl")
	if err := os.WriteFile(conv, []byte(`{"role":"user","content":"hello"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	var out, errOut strings.Builder
	if err := Run([]string{"compact", "--session", "test"}, strings.NewReader(""), &out, &errOut); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(errOut.String(), "Context is within budget; no compaction needed.") {
		t.Fatalf("unexpected compact output: %q", errOut.String())
	}
}

func TestRunStreamJSONToolLoop(t *testing.T) {
	project := t.TempDir()
	home := t.TempDir()
	target := filepath.Join(project, "out.txt")
	oldHome := os.Getenv("HOME")
	defer os.Setenv("HOME", oldHome)
	_ = os.Setenv("HOME", home)
	oldWD, _ := os.Getwd()
	defer os.Chdir(oldWD)
	if err := os.Chdir(project); err != nil {
		t.Fatal(err)
	}

	var calls atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch calls.Add(1) {
		case 1:
			return sseResponse(strings.Join([]string{
				"event: content_block_start",
				`data: {"content_block":{"type":"tool_use","id":"toolu_1","name":"Write"}}`,
				"",
				"event: content_block_delta",
				`data: {"delta":{"partial_json":"{\"path\":\"` + target + `\",\"content\":\"abc\"}"}}`,
				"",
				"event: content_block_stop",
				`data: {}`,
				"",
				"event: message_delta",
				`data: {"delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":10,"output_tokens":7}}`,
				"",
				"event: message_stop",
				`data: {}`,
				"",
			}, "\n")), nil
		default:
			return sseResponse(strings.Join([]string{
				"event: content_block_start",
				`data: {"content_block":{"type":"text"}}`,
				"",
				"event: content_block_delta",
				`data: {"delta":{"text":"done"}}`,
				"",
				"event: message_delta",
				`data: {"delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":11,"output_tokens":3}}`,
				"",
				"event: message_stop",
				`data: {}`,
				"",
			}, "\n")), nil
		}
	})}

	var out, errOut strings.Builder
	withTestHTTPClient(client, func() {
		if err := Run([]string{"--base-url", "http://example.invalid", "--print", "write file"}, strings.NewReader(""), &out, &errOut); err != nil {
			t.Fatal(err)
		}
	})
	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) < 6 {
		t.Fatalf("expected multiple stream-json lines, got %q", out.String())
	}
	var seenToolCall, seenToolResult, seenStop bool
	for _, line := range lines {
		var evt map[string]any
		if err := json.Unmarshal([]byte(line), &evt); err != nil {
			t.Fatalf("invalid json line %q: %v", line, err)
		}
		switch evt["type"] {
		case "tool_call":
			seenToolCall = true
		case "tool_result":
			seenToolResult = true
		case "stop":
			seenStop = true
		}
	}
	if !seenToolCall || !seenToolResult || !seenStop {
		t.Fatalf("missing expected events in %q", out.String())
	}
}

func TestRunSessionWritesConversationAndEvents(t *testing.T) {
	project := t.TempDir()
	home := t.TempDir()
	oldHome := os.Getenv("HOME")
	defer os.Setenv("HOME", oldHome)
	_ = os.Setenv("HOME", home)
	oldWD, _ := os.Getwd()
	defer os.Chdir(oldWD)
	if err := os.Chdir(project); err != nil {
		t.Fatal(err)
	}

	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		return sseResponse(strings.Join([]string{
			"event: content_block_start",
			`data: {"content_block":{"type":"text"}}`,
			"",
			"event: content_block_delta",
			`data: {"delta":{"text":"hello"}}`,
			"",
			"event: message_delta",
			`data: {"delta":{"stop_reason":"end_turn"}}`,
			"",
			"event: message_stop",
			`data: {}`,
			"",
		}, "\n")), nil
	})}

	var out, errOut strings.Builder
	withTestHTTPClient(client, func() {
		if err := Run([]string{"--base-url", "http://example.invalid", "--session", "demo", "hello"}, strings.NewReader(""), &out, &errOut); err != nil {
			t.Fatal(err)
		}
	})
	matches, err := filepath.Glob(filepath.Join(home, ".bash-agent", "projects", "*", "demo.jsonl"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one session file, got %v %v", len(matches), matches)
	}
	conv := matches[0]
	events := strings.TrimSuffix(conv, ".jsonl") + ".events.jsonl"
	convData, err := os.ReadFile(conv)
	if err != nil {
		t.Fatal(err)
	}
	eventsData, err := os.ReadFile(events)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(convData), `"role":"user"`) || !strings.Contains(string(convData), `"content":"hello"`) || !strings.Contains(string(convData), `"role":"assistant"`) {
		t.Fatalf("unexpected conversation file: %s", string(convData))
	}
	if !strings.Contains(string(eventsData), `"type":"session_start"`) || !strings.Contains(string(eventsData), `"type":"assistant_message"`) {
		t.Fatalf("unexpected events file: %s", string(eventsData))
	}
}
