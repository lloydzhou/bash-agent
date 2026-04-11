package sse

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/lloydzhou/bash-agent/internal/protocol"
)

func BuildToolCallEvent(name, id string, input string) (protocol.ToolCallEvent, error) {
	input = strings.TrimSpace(input)
	if input == "" {
		input = "{}"
	}
	var obj map[string]any
	if err := json.Unmarshal([]byte(input), &obj); err != nil {
		return protocol.ToolCallEvent{}, fmt.Errorf("parse tool input: %w", err)
	}
	event := protocol.ToolCallEvent{
		Name:      name,
		ID:        id,
		InputJSON: json.RawMessage(input),
		Fields:    map[string]string{},
	}
	if name == "TodoWrite" {
		checklist, summary, err := todoFields(obj)
		if err != nil {
			return protocol.ToolCallEvent{}, err
		}
		event.Order = []string{"checklist", "summary"}
		event.Fields["checklist"] = checklist
		event.Fields["summary"] = summary
		return event, nil
	}
	for key, value := range obj {
		event.Order = append(event.Order, key)
		event.Fields[key] = jsonScalarString(value)
	}
	return event, nil
}

func jsonScalarString(v any) string {
	switch t := v.(type) {
	case nil:
		return "null"
	case string:
		return t
	case bool:
		if t {
			return "true"
		}
		return "false"
	default:
		data, _ := json.Marshal(v)
		return string(data)
	}
}

func todoFields(obj map[string]any) (string, string, error) {
	rawTodos, ok := obj["todos"].([]any)
	if !ok {
		return "", "", fmt.Errorf("invalid TodoWrite input: missing todos")
	}
	var lines []string
	completed := 0
	inProgress := 0
	total := 0
	for _, item := range rawTodos {
		todo, ok := item.(map[string]any)
		if !ok {
			return "", "", fmt.Errorf("invalid TodoWrite input: todo item")
		}
		content, _ := todo["content"].(string)
		status, _ := todo["status"].(string)
		if content == "" {
			return "", "", fmt.Errorf("Error: todo item content is required")
		}
		switch status {
		case "pending":
			lines = append(lines, "- [ ] "+content)
		case "in_progress":
			inProgress++
			lines = append(lines, "- [ ] "+content)
		case "completed":
			completed++
			lines = append(lines, "- [x] "+content)
		default:
			return "", "", fmt.Errorf("Error: invalid todo status: %s", status)
		}
		total++
	}
	if inProgress > 1 {
		return "", "", fmt.Errorf("Error: todo_write allows at most one in_progress item")
	}
	return strings.Join(lines, "\n"), fmt.Sprintf("%d/%d", completed, total), nil
}
