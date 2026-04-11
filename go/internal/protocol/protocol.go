package protocol

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

type EventKind string

const (
	EventText     EventKind = "TEXT"
	EventToolCall EventKind = "TOOL_CALL"
	EventUsage    EventKind = "USAGE"
	EventStop     EventKind = "STOP"
	EventError    EventKind = "ERROR"
)

type Event interface {
	Kind() EventKind
	Render() string
}

type TextEvent struct{ Content string }

func (e TextEvent) Kind() EventKind { return EventText }
func (e TextEvent) Render() string  { return "TEXT:" + EscapeText(e.Content) }

type StopEvent struct{ Reason string }

func (e StopEvent) Kind() EventKind { return EventStop }
func (e StopEvent) Render() string  { return "STOP:" + e.Reason }

type ErrorEvent struct{ Message string }

func (e ErrorEvent) Kind() EventKind { return EventError }
func (e ErrorEvent) Render() string  { return "ERROR:" + e.Message }

type UsageEvent struct {
	InputTokens      int
	OutputTokens     int
	CacheInputTokens int
}

func (e UsageEvent) Kind() EventKind { return EventUsage }
func (e UsageEvent) Render() string {
	return fmt.Sprintf("USAGE:%d\t%d\t%d", e.InputTokens, e.OutputTokens, e.CacheInputTokens)
}

type ToolCallEvent struct {
	Name      string
	ID        string
	InputJSON json.RawMessage
	Fields    map[string]string
	Order     []string
}

func (e ToolCallEvent) Kind() EventKind { return EventToolCall }
func (e ToolCallEvent) Render() string {
	var b strings.Builder
	b.WriteString("TOOL_CALL:")
	b.WriteString(e.Name)
	b.WriteString("\t")
	b.WriteString(e.ID)
	b.WriteString("\t")
	b.WriteString(EscapeText(string(e.InputJSON)))
	for _, key := range e.Order {
		b.WriteString("\t")
		b.WriteString(key)
		b.WriteString("\t")
		b.WriteString(EscapeText(e.Fields[key]))
	}
	return b.String()
}

func ParseToolCallPayload(payload string) (ToolCallEvent, error) {
	parts := strings.Split(payload, "\t")
	if len(parts) < 3 {
		return ToolCallEvent{}, fmt.Errorf("invalid tool call payload")
	}
	event := ToolCallEvent{
		Name:      parts[0],
		ID:        parts[1],
		InputJSON: json.RawMessage(UnescapeText(parts[2])),
		Fields:    map[string]string{},
	}
	for i := 3; i+1 < len(parts); i += 2 {
		key := parts[i]
		value := UnescapeText(parts[i+1])
		event.Order = append(event.Order, key)
		event.Fields[key] = value
	}
	return event, nil
}

func EscapeText(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\n", "\\n")
	s = strings.ReplaceAll(s, "\r", "\\r")
	s = strings.ReplaceAll(s, "\t", "\\t")
	return s
}

func UnescapeText(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' || i+1 >= len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		switch s[i] {
		case 'n':
			b.WriteByte('\n')
		case 'r':
			b.WriteByte('\r')
		case 't':
			b.WriteByte('\t')
		case '\\':
			b.WriteByte('\\')
		default:
			b.WriteByte('\\')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func ParseUsagePayload(payload string) (UsageEvent, error) {
	parts := strings.Split(payload, "\t")
	if len(parts) != 3 {
		return UsageEvent{}, fmt.Errorf("invalid usage payload")
	}
	in, err := strconv.Atoi(parts[0])
	if err != nil {
		return UsageEvent{}, err
	}
	out, err := strconv.Atoi(parts[1])
	if err != nil {
		return UsageEvent{}, err
	}
	cache, err := strconv.Atoi(parts[2])
	if err != nil {
		return UsageEvent{}, err
	}
	return UsageEvent{InputTokens: in, OutputTokens: out, CacheInputTokens: cache}, nil
}
