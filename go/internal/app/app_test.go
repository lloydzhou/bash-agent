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

	"github.com/lloydzhou/bash-agent/internal/httpclient"
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
	if !strings.Contains(got, "Write(") || !strings.HasSuffix(got, "done") {
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
	matches, err := filepath.Glob(filepath.Join(home, ".bash-agent", "projects", "*", "demo", "conversation.jsonl"))
	if err != nil || len(matches) != 1 {
		t.Fatalf("expected one session file, got %v %v", len(matches), matches)
	}
	conv := matches[0]
	events := filepath.Join(filepath.Dir(conv), "events.jsonl")
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
	if !strings.Contains(string(eventsData), `"type":"session_start"`) {
		t.Fatalf("unexpected events file: %s", string(eventsData))
	}
}

func TestRunClaudeApiErrorReturnsError(t *testing.T) {
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
			"event: error",
			`data: {"error":{"message":"rate limited"}}`,
			"",
		}, "\n")), nil
	})}

	var out, errOut strings.Builder
	withTestHTTPClient(client, func() {
		err := Run([]string{"--base-url", "http://example.invalid", "hello"}, strings.NewReader(""), &out, &errOut)
		if err == nil || !strings.Contains(err.Error(), "rate limited") {
			t.Fatalf("expected rate limited error, got %v", err)
		}
	})
}

// stalledReader delivers some data then returns a timeout error.
type stalledReader struct {
	data   []byte
	offset int
}

func (r *stalledReader) Read(b []byte) (int, error) {
	if r.offset < len(r.data) {
		n := copy(b, r.data[r.offset:])
		r.offset += n
		return n, nil
	}
	return 0, httpclient.ErrStreamRetryable
}

func (r *stalledReader) Close() error { return nil }

func TestRetryOnStreamTimeout(t *testing.T) {
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

	firstSSE := strings.Join([]string{
		"event: content_block_start",
		`data: {"content_block":{"type":"text"}}`,
		"",
		"event: content_block_delta",
		`data: {"delta":{"text":"Partial"}}`,
		"",
	}, "\n")

	secondSSE := strings.Join([]string{
		"event: content_block_start",
		`data: {"content_block":{"type":"text"}}`,
		"",
		"event: content_block_delta",
		`data: {"delta":{"text":"After retry"}}`,
		"",
		"event: message_delta",
		`data: {"delta":{"stop_reason":"end_turn"},"usage":{"input_tokens":10,"output_tokens":5}}`,
		"",
		"event: message_stop",
		`data: {}`,
		"",
	}, "\n")

	var calls atomic.Int32
	client := &http.Client{Transport: roundTripFunc(func(req *http.Request) (*http.Response, error) {
		switch calls.Add(1) {
		case 1:
			return &http.Response{
				StatusCode: 200,
				Header:     http.Header{"Content-Type": []string{"text/event-stream"}},
				Body:       &stalledReader{data: []byte(firstSSE)},
			}, nil
		default:
			return sseResponse(secondSSE), nil
		}
	})}

	var out strings.Builder
	var errOut strings.Builder
	withTestHTTPClient(client, func() {
		err := Run([]string{"--base-url", "http://example.invalid", "test retry"}, strings.NewReader(""), &out, &errOut)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	})

	got := out.String()
	if !strings.Contains(got, "Partial") {
		t.Errorf("missing text from first response: %q", got)
	}
	if !strings.Contains(got, "After retry") {
		t.Errorf("missing text from retry response: %q", got)
	}
}

func TestTruncateRunes(t *testing.T) {
	got := truncateRunes("你好世界abc", 2)
	if got != "你好..." {
		t.Fatalf("unexpected truncation: %q", got)
	}
	if strings.ContainsRune(got, '\uFFFD') {
		t.Fatalf("truncation broke UTF-8: %q", got)
	}
}
