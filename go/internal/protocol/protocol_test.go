package protocol

import "testing"

func TestToolCallRenderParseRoundTrip(t *testing.T) {
	evt := ToolCallEvent{
		Name:      "Write",
		ID:        "call_1",
		InputJSON: []byte(`{"path":"/tmp/test.txt","content":"AbC"}`),
		Fields: map[string]string{
			"path":    "/tmp/test.txt",
			"content": "AbC",
		},
		Order: []string{"path", "content"},
	}

	line := evt.Render()
	got, err := ParseToolCallPayload(line[len("TOOL_CALL:"):])
	if err != nil {
		t.Fatalf("ParseToolCallPayload: %v", err)
	}
	if got.Name != evt.Name || got.ID != evt.ID {
		t.Fatalf("unexpected identity: %#v", got)
	}
	if string(got.InputJSON) != string(evt.InputJSON) {
		t.Fatalf("unexpected input json: %s", got.InputJSON)
	}
	if got.Fields["path"] != "/tmp/test.txt" || got.Fields["content"] != "AbC" {
		t.Fatalf("unexpected fields: %#v", got.Fields)
	}
}

func TestThinkingEventRender(t *testing.T) {
	evt := ThinkingEvent{Content: "Let me think\nabout this"}
	got := evt.Render()
	want := "THINKING:Let me think\\nabout this"
	if got != want {
		t.Fatalf("unexpected render: %q", got)
	}
}

func TestEscapeUnescapeText(t *testing.T) {
	raw := "line1\nline2\t中文\\tail"
	escaped := EscapeText(raw)
	if got := UnescapeText(escaped); got != raw {
		t.Fatalf("round-trip mismatch: %q != %q", got, raw)
	}
}
