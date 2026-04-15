package conversation

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/lloydzhou/bash-agent/internal/protocol"
)

type Store struct {
	Path string
}

func (s Store) Ensure() error {
	f, err := os.OpenFile(s.Path, os.O_CREATE, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}

func (s Store) AddUser(content string) error {
	line, err := json.Marshal(map[string]any{
		"role":    "user",
		"content": content,
	})
	if err != nil {
		return err
	}
	return appendLine(s.Path, line)
}

func (s Store) AddAssistant(text string, calls []protocol.ToolCallEvent) error {
	content := make([]any, 0, len(calls)+1)
	if text != "" {
		content = append(content, map[string]any{
			"type": "text",
			"text": text,
		})
	}
	for _, call := range calls {
		content = append(content, map[string]any{
			"type":  "tool_use",
			"id":    call.ID,
			"name":  call.Name,
			"input": json.RawMessage(call.InputJSON),
		})
	}
	line, err := json.Marshal(map[string]any{
		"role":    "assistant",
		"content": content,
	})
	if err != nil {
		return err
	}
	return appendLine(s.Path, line)
}

func (s Store) AddToolResults(results []ToolResult) error {
	content := make([]any, 0, len(results))
	for _, result := range results {
		content = append(content, map[string]any{
			"type":        "tool_result",
			"tool_use_id": result.ToolUseID,
			"content":     result.Content,
		})
	}
	line, err := json.Marshal(map[string]any{
		"role":    "user",
		"content": content,
	})
	if err != nil {
		return err
	}
	return appendLine(s.Path, line)
}

func (s Store) MessagesJSON() ([]byte, error) {
	data, err := os.ReadFile(s.Path)
	if err != nil {
		return nil, err
	}
	var out bytes.Buffer
	out.WriteByte('[')
	first := true
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if !first {
			out.WriteByte(',')
		}
		first = false
		out.WriteString(line)
	}
	out.WriteByte(']')
	return out.Bytes(), nil
}

func (s Store) Lines() ([]json.RawMessage, error) {
	data, err := os.ReadFile(s.Path)
	if err != nil {
		return nil, err
	}
	lines := make([]json.RawMessage, 0)
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		lines = append(lines, json.RawMessage(line))
	}
	return lines, nil
}

func (s Store) TrimKeepLast(keepLines int) error {
	if keepLines < 0 {
		keepLines = 0
	}
	lines, err := s.Lines()
	if err != nil {
		return err
	}
	if keepLines >= len(lines) {
		return nil
	}
	var out bytes.Buffer
	for _, line := range lines[len(lines)-keepLines:] {
		out.Write(line)
		out.WriteByte('\n')
	}
	return os.WriteFile(s.Path, out.Bytes(), 0o644)
}

func (s Store) TotalBytes() (int, error) {
	data, err := os.ReadFile(s.Path)
	if err != nil {
		return 0, err
	}
	return len(data), nil
}

func (s Store) TotalLines() (int, error) {
	lines, err := s.Lines()
	if err != nil {
		return 0, err
	}
	return len(lines), nil
}

func (s Store) KeepLineCount(targetBytes int) (int, error) {
	lines, err := s.Lines()
	if err != nil {
		return 0, err
	}
	if len(lines) == 0 {
		return 0, nil
	}
	sizes := make([]int, len(lines))
	turnStart := make([]bool, len(lines))
	for i, line := range lines {
		sizes[i] = len(line) + 1
		var msg struct {
			Role    string          `json:"role"`
			Content json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal(line, &msg); err == nil {
			turnStart[i] = msg.Role == "user" && len(msg.Content) > 0 && msg.Content[0] == '"'
		}
	}
	keep := 0
	bytes := 0
	for i := len(lines) - 1; i >= 0; i-- {
		if keep > 0 && bytes+sizes[i] > targetBytes {
			break
		}
		bytes += sizes[i]
		keep++
	}
	if keep == 0 {
		keep = 1
	}
	start := len(lines) - keep
	adjusted := start
	for adjusted < len(lines) && !turnStart[adjusted] {
		adjusted++
	}
	if adjusted < len(lines) {
		start = adjusted
	} else {
		for start > 0 && !turnStart[start] {
			start--
		}
	}
	return len(lines) - start, nil
}

func appendLine(path string, line []byte) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.Write(append(line, '\n')); err != nil {
		return err
	}
	return nil
}

type ToolResult struct {
	ToolUseID string
	ToolName  string
	ToolArgs  map[string]string
	Content   string
}

func BuildToolResultJSON(id, content string) ([]byte, error) {
	return json.Marshal(map[string]any{
		"type":        "tool_result",
		"tool_use_id": id,
		"content":     content,
	})
}

func BuildReadToolResultSummary(path string) string {
	if path == "" {
		return "Read"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Sprintf("Read(%s)", path)
	}
	return fmt.Sprintf("Read(%s) [%d lines, %d bytes]", path, lineCount(string(data)), len(data))
}

func BuildTodoEventJSON(content string) ([]byte, error) {
	return json.Marshal(map[string]any{
		"type":    "todo_update",
		"content": content,
	})
}

func BuildToolCallSummary(name string, fields map[string]string) string {
	var label string
	switch name {
	case "Read", "Write", "Edit":
		label = fields["path"]
	case "Glob", "Grep":
		label = fields["pattern"]
	case "Bash":
		label = strings.ReplaceAll(fields["command"], "\n", " ")
		if len(label) > 80 {
			label = label[:77] + "..."
		}
	case "TodoWrite":
		label = fields["summary"]
	case "Skill":
		label = fields["name"]
	}
	if label == "" {
		return name
	}
	return fmt.Sprintf("%s(%s)", name, label)
}

func lineCount(s string) int {
	if s == "" {
		return 0
	}
	n := 1
	for _, ch := range s {
		if ch == '\n' {
			n++
		}
	}
	return n
}
