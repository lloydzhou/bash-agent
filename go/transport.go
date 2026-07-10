package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

// ═══════════════════════════════════════════
// HTTPTransport — HTTP + SSE 流式传输
// ═══════════════════════════════════════════

type HTTPTransport struct {
	cfg    Config
	client *http.Client
}

// ─── Call: 发起流式 LLM 调用，通过 channel 返回 Event ───

func (t *HTTPTransport) Call(ctx context.Context, messages, systemPrompt, toolDefs string, maxTokens int, thinking string) (<-chan Event, error) {
	var body []byte
	var err error

	switch t.cfg.Provider {
	case "openai":
		body, err = t.buildOpenAIBody(messages, systemPrompt, toolDefs, maxTokens, thinking)
	default:
		body, err = t.buildClaudeBody(messages, systemPrompt, toolDefs, maxTokens, thinking)
	}
	if err != nil {
		return nil, fmt.Errorf("build request body: %w", err)
	}

	if t.cfg.Verbose {
		preview := string(body)
		if len(preview) > 200 {
			preview = preview[:200] + "..."
		}
		fmt.Fprintf(osStderr, "[verbose] Request body (%dKB): %s\n", len(body)/1024, preview)
	}

	// 对齐 Bash curl --retry 2 --retry-delay 1 --retry-max-time 20
	// 和 Rust StreamClient: 最多重试 2 次，延迟 1s，总窗口 20s
	const maxRetries = 2
	const retryDelay = 1 * time.Second
	const retryMaxTime = 20 * time.Second

	start := time.Now()
	var resp *http.Response
	var httpErr error

	for attempt := 0; attempt <= maxRetries; attempt++ {
		req, err := http.NewRequestWithContext(ctx, "POST", t.buildURL(), bytes.NewReader(body))
		if err != nil {
			return nil, fmt.Errorf("create request: %w", err)
		}
		req.Header = t.buildHeaders()

		resp, httpErr = t.client.Do(req)
		if httpErr == nil && resp.StatusCode < 500 {
			break // 成功（2xx）或客户端错误（4xx）
		}

		// 传输错误或 5xx → 可重试
		if resp != nil {
			resp.Body.Close()
		}
		if attempt < maxRetries && time.Since(start) < retryMaxTime {
			time.Sleep(retryDelay)
			continue
		}

		// 重试耗尽
		if httpErr != nil {
			return nil, fmt.Errorf("http request: %w", httpErr)
		}
		// 5xx 重试耗尽 → 返回错误事件
		ch := make(chan Event, 2)
		ch <- Event{Type: EventError, Fields: []string{"ERROR", fmt.Sprintf("HTTP %d (server error, retries exhausted)", resp.StatusCode)}}
		ch <- Event{Type: EventStop, Fields: []string{"STOP", "error"}}
		close(ch)
		return ch, nil
	}

	// 4xx 错误处理（不重试）
	if resp.StatusCode >= 400 {
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		ch := make(chan Event, 2)
		ch <- Event{Type: EventError, Fields: []string{"ERROR", fmt.Sprintf("HTTP %d: %s", resp.StatusCode, string(respBody))}}
		ch <- Event{Type: EventStop, Fields: []string{"STOP", "error"}}
		close(ch)
		return ch, nil
	}

	// 成功 → 启动 SSE 解析 goroutine
	ch := make(chan Event, 64)
	go t.parseSSEStream(resp, ch)
	return ch, nil
}

// ─── SummaryCall: 压缩用的摘要调用（返回纯文本）───

func (t *HTTPTransport) SummaryCall(ctx context.Context, droppedMessages, systemPrompt, toolDefs string) (string, Usage, error) {
	// 将 JSONL 转成 JSON 数组，并追加 summary instruction
	summaryInstruction := "The conversation context above needs to be compacted. IMPORTANT: Do NOT use any tools. Do NOT think. Just output the summary directly as plain text. Summarize the key information from the messages above into a concise context summary. Update the existing summary snapshot using the messages above. Use exactly these fields:\nTask focus:\nLatest request:\nProgress:\nTool evidence:\nReflections:"

	lines := splitNonEmpty(droppedMessages)
	msgs := make([]json.RawMessage, 0, len(lines)+1)
	for _, line := range lines {
		msgs = append(msgs, json.RawMessage(line))
	}
	// 追加 summary instruction 作为用户消息（手动拼接保持 role→content 顺序）
	instrMsg := []byte(`{"role":"user","content":"` + UtilJSONEscape(summaryInstruction) + `"}`)
	msgs = append(msgs, instrMsg)

	messagesJSON, _ := json.Marshal(msgs)

	ch, err := t.Call(ctx, string(messagesJSON), systemPrompt, toolDefs, t.cfg.MaxTokens, "disabled")
	if err != nil {
		return "", Usage{}, err
	}
	var text string
	var lastError string
	var usage Usage
	for ev := range ch {
		switch ev.Type {
		case EventText:
			if len(ev.Fields) > 1 {
				text += ev.Fields[1]
			}
		case EventUsage:
			if u, ok := ev.Payload.(Usage); ok {
				usage = u
			}
		case EventError:
			if len(ev.Fields) > 1 {
				lastError = ev.Fields[1]
			}
		}
	}
	if text == "" {
		return "", usage, fmt.Errorf("empty summary response (error=%s)", lastError)
	}
	return text, usage, nil
}

func NewHTTPTransport(cfg Config) *HTTPTransport {
	return &HTTPTransport{
		cfg:    cfg,
		client: &http.Client{},
	}
}

// ─── SSE 流解析 ───

// parseSSEStream 从 HTTP response body 读取 SSE 流，解析为 Event
func (t *HTTPTransport) parseSSEStream(resp *http.Response, ch chan<- Event) {
	var stopEmitted bool
	defer resp.Body.Close()
	defer close(ch)
	defer func() {
		if !stopEmitted {
			// No message_stop received — stream was interrupted (connection reset,
			// timeout, early EOF). 对标 awk 的 END 块兜底逻辑。
			ch <- Event{Type: EventError, Fields: []string{"ERROR", "Stream interrupted (no message_stop received)"}}
			ch <- Event{Type: EventStop, Fields: []string{"STOP", "error"}}
		}
	}()

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	var eventType, blockType, toolName, toolID, partialJSON string
	var stopReason string
	var inputTokens, outputTokens, cacheRead, cacheCreate int

	// OpenAI 流状态
	var openaiTextStarted bool // 是否已收到过非空前导换行的文本
	openaiPendingCalls := map[int]*openAIPendingCall{}

	for scanner.Scan() {
		line := scanner.Text()
		line = strings.TrimRight(line, "\r")

		if strings.HasPrefix(line, ":") {
			continue
		}
		if strings.HasPrefix(line, "event: ") {
			eventType = line[7:]
			continue
		}
		if strings.HasPrefix(line, "data: ") {
			data := line[6:]

			// ─── OpenAI 格式检测：如果有 choices 字段，按 OpenAI 格式处理 ───
			if strings.Contains(data, `"choices"`) || data == "[DONE]" {
				t.handleOpenAIChunk(data, ch,
					openaiPendingCalls,
					&openaiTextStarted,
					&stopReason,
					&inputTokens, &outputTokens, &cacheRead, &cacheCreate)
				if data == "[DONE]" {
					stopEmitted = true
				}
				continue
			}

			switch eventType {
			case "content_block_start":
				blockType, toolName, toolID = t.handleBlockStart(data)

			case "content_block_delta":
				switch blockType {
				case "text":
					if text := t.extractDeltaText(data, "text"); text != "" {
						ch <- Event{Type: EventText, Fields: []string{"TEXT", text}}
					}
				case "thinking":
					if text := t.extractDeltaText(data, "thinking"); text != "" {
						ch <- Event{Type: EventThinking, Fields: []string{"THINKING", text}}
					}
				case "tool":
					partialJSON += t.extractDeltaPartialJSON(data)
				}

			case "content_block_stop":
				if blockType == "tool" {
					input := partialJSON
					if input == "" {
						input = "{}"
					}
					ch <- Event{Type: EventToolCall, Fields: []string{"TOOL_CALL", toolName, toolID, input}}
					partialJSON = ""
				}
				blockType = ""

			case "message_delta":
				sr := t.extractJSONValue(data, "stop_reason")
				if sr != "" {
					stopReason = sr
				}
				t.extractUsageFromDelta(data, &inputTokens, &outputTokens, &cacheRead, &cacheCreate)

			case "message_start":
				t.extractUsageFromStart(data, &inputTokens, &cacheRead, &cacheCreate)

			case "message_stop":
				stopEmitted = true
				// 发送 USAGE + STOP
				ch <- Event{Type: EventUsage, Payload: Usage{
					InputTokens:  inputTokens,
					OutputTokens: outputTokens,
					CacheRead:    cacheRead,
					CacheWrite:   cacheCreate,
				}}
				ch <- Event{Type: EventStop, Fields: []string{"STOP", stopReason}}

			case "error":
				msg := t.extractJSONValue(data, "message")
				ch <- Event{Type: EventError, Fields: []string{"ERROR", msg}}

			case "retry":
				// 对齐 Rust/C: 重置所有累积状态
				blockType = ""
				toolName = ""
				toolID = ""
				partialJSON = ""
				stopReason = ""
				inputTokens = 0
				outputTokens = 0
				cacheRead = 0
				cacheCreate = 0
				ch <- Event{Type: EventRetry}
			}
		}
	}
}

type openAIPendingCall struct {
	ID        string
	Name      string
	Arguments string
}

func emitOpenAIPendingCalls(ch chan<- Event, pending map[int]*openAIPendingCall) {
	keys := make([]int, 0, len(pending))
	for idx := range pending {
		keys = append(keys, idx)
	}
	sort.Ints(keys)
	for _, idx := range keys {
		call := pending[idx]
		if call == nil || call.Arguments == "" {
			continue
		}
		ch <- Event{Type: EventToolCall, Fields: []string{"TOOL_CALL", call.Name, call.ID, call.Arguments}}
	}
	for k := range pending {
		delete(pending, k)
	}
}

// handleOpenAIChunk 处理 OpenAI chat.completion.chunk 格式的 SSE 数据
func (t *HTTPTransport) handleOpenAIChunk(data string, ch chan<- Event,
	pending map[int]*openAIPendingCall,
	textStarted *bool,
	stopReason *string,
	inputTokens, outputTokens, cacheRead, cacheCreate *int) {

	if data == "[DONE]" {
		emitOpenAIPendingCalls(ch, pending)
		// 映射 stop reason
		sr := *stopReason
		switch sr {
		case "stop":
			sr = "end_turn"
		case "tool_calls":
			sr = "tool_use"
		case "length":
			sr = "max_tokens"
		}
		ch <- Event{Type: EventUsage, Payload: Usage{
			InputTokens:  *inputTokens,
			OutputTokens: *outputTokens,
			CacheRead:    *cacheRead,
			CacheWrite:   *cacheCreate,
		}}
		ch <- Event{Type: EventStop, Fields: []string{"STOP", sr}}
		return
	}

	var chunk struct {
		Choices []struct {
			Index int `json:"index"`
			Delta struct {
				Role      string `json:"role"`
				Content   string `json:"content"`
				ToolCalls []struct {
					Index    int    `json:"index"`
					ID       string `json:"id"`
					Type     string `json:"type"`
					Function struct {
						Name      string `json:"name"`
						Arguments string `json:"arguments"`
					} `json:"function"`
				} `json:"tool_calls"`
			} `json:"delta"`
			FinishReason *string `json:"finish_reason"`
		} `json:"choices"`
		Usage struct {
			PromptTokens        int `json:"prompt_tokens"`
			CompletionTokens    int `json:"completion_tokens"`
			PromptTokensDetails struct {
				CachedTokens int `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	if err := json.Unmarshal([]byte(data), &chunk); err != nil {
		return
	}

	// 提取 usage
	if chunk.Usage.PromptTokens > 0 {
		*inputTokens = chunk.Usage.PromptTokens
	}
	if chunk.Usage.CompletionTokens > 0 {
		*outputTokens = chunk.Usage.CompletionTokens
	}
	if chunk.Usage.PromptTokensDetails.CachedTokens > 0 {
		*cacheRead = chunk.Usage.PromptTokensDetails.CachedTokens
	}

	if len(chunk.Choices) == 0 {
		return
	}

	choice := chunk.Choices[0]

	// finish_reason
	if choice.FinishReason != nil {
		*stopReason = *choice.FinishReason
	}

	// text content
	if choice.Delta.Content != "" {
		text := choice.Delta.Content
		// 修剪前导换行（OpenAI 格式有时在 role 行后带 \n\n）
		if !*textStarted {
			text = strings.TrimLeft(text, "\n")
			if text != "" {
				*textStarted = true
			}
		}
		if text != "" {
			*textStarted = true
			ch <- Event{Type: EventText, Fields: []string{"TEXT", text}}
		}
	}

	// tool_calls
	for _, tc := range choice.Delta.ToolCalls {
		call := pending[tc.Index]
		if call == nil {
			call = &openAIPendingCall{}
			pending[tc.Index] = call
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
	if choice.FinishReason != nil && *choice.FinishReason == "tool_calls" {
		emitOpenAIPendingCalls(ch, pending)
	}
}

// handleBlockStart 从 content_block_start 的 data 中提取 block 类型
func (t *HTTPTransport) handleBlockStart(data string) (blockType, toolName, toolID string) {
	var d struct {
		ContentBlock struct {
			Type string `json:"type"`
			Name string `json:"name"`
			ID   string `json:"id"`
		} `json:"content_block"`
	}
	if err := json.Unmarshal([]byte(data), &d); err == nil {
		switch d.ContentBlock.Type {
		case "text":
			return "text", "", ""
		case "thinking":
			return "thinking", "", ""
		case "tool_use":
			return "tool", d.ContentBlock.Name, d.ContentBlock.ID
		}
	}
	return "", "", ""
}

// extractDeltaText 从 content_block_delta 提取文本
func (t *HTTPTransport) extractDeltaText(data, field string) string {
	// 尝试结构化解析
	var d struct {
		Delta struct {
			Text     string `json:"text"`
			Thinking string `json:"thinking"`
		} `json:"delta"`
	}
	if err := json.Unmarshal([]byte(data), &d); err == nil {
		if field == "text" {
			return d.Delta.Text
		}
		return d.Delta.Thinking
	}
	return ""
}

// extractDeltaPartialJSON 从 content_block_delta 提取 partial_json
func (t *HTTPTransport) extractDeltaPartialJSON(data string) string {
	var d struct {
		Delta struct {
			PartialJSON string `json:"partial_json"`
		} `json:"delta"`
	}
	if err := json.Unmarshal([]byte(data), &d); err == nil {
		return d.Delta.PartialJSON
	}
	return ""
}

// extractJSONValue 简单提取 JSON 中的字符串值
func (t *HTTPTransport) extractJSONValue(data, key string) string {
	search := `"` + key + `":`
	idx := strings.Index(data, search)
	if idx < 0 {
		return ""
	}
	rest := data[idx+len(search):]
	rest = strings.TrimLeft(rest, " ")
	if len(rest) == 0 {
		return ""
	}
	if rest[0] == '"' {
		// 提取字符串值
		end := strings.IndexByte(rest[1:], '"')
		if end < 0 {
			return ""
		}
		return rest[1 : end+1]
	}
	return ""
}

// extractUsageFromDelta 从 message_delta 提取 usage
// output_tokens: 总是取。input_tokens/cache_*: 仅在 message_start 未提供时取
// （OpenAI 路径无 message_start，通过 transport 合成 message_delta）
func (t *HTTPTransport) extractUsageFromDelta(data string, inputTokens, outputTokens, cacheRead, cacheCreate *int) {
	var d struct {
		Usage struct {
			OutputTokens             int `json:"output_tokens"`
			InputTokens              int `json:"input_tokens"`
			CacheReadInputTokens     int `json:"cache_read_input_tokens"`
			CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
		} `json:"usage"`
		Delta struct {
			StopReason string `json:"stop_reason"`
		} `json:"delta"`
	}
	if err := json.Unmarshal([]byte(data), &d); err == nil {
		if d.Usage.OutputTokens > 0 {
			*outputTokens = d.Usage.OutputTokens
		}
		if *inputTokens == 0 && d.Usage.InputTokens > 0 {
			*inputTokens = d.Usage.InputTokens
		}
		if *cacheRead == 0 && d.Usage.CacheReadInputTokens > 0 {
			*cacheRead = d.Usage.CacheReadInputTokens
		}
		if *cacheCreate == 0 && d.Usage.CacheCreationInputTokens > 0 {
			*cacheCreate = d.Usage.CacheCreationInputTokens
		}
	}
}

// extractUsageFromStart 从 message_start 提取 usage
func (t *HTTPTransport) extractUsageFromStart(data string, inputTokens, cacheRead, cacheCreate *int) {
	var d struct {
		Message struct {
			Usage struct {
				InputTokens              int `json:"input_tokens"`
				CacheReadInputTokens     int `json:"cache_read_input_tokens"`
				CacheCreationInputTokens int `json:"cache_creation_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	if err := json.Unmarshal([]byte(data), &d); err == nil {
		if d.Message.Usage.InputTokens > 0 {
			*inputTokens = d.Message.Usage.InputTokens
		}
		if d.Message.Usage.CacheReadInputTokens > 0 {
			*cacheRead = d.Message.Usage.CacheReadInputTokens
		}
		if d.Message.Usage.CacheCreationInputTokens > 0 {
			*cacheCreate = d.Message.Usage.CacheCreationInputTokens
		}
	}
}

// buildHeaders 构建请求头
func (t *HTTPTransport) buildHeaders() http.Header {
	h := http.Header{}
	h.Set("Content-Type", "application/json")
	h.Set("User-Agent", "bash-agent/1.0")
	switch t.cfg.Provider {
	case "claude":
		h.Set("x-api-key", t.cfg.APIKey)
		h.Set("anthropic-version", "2023-06-01")
		h.Set("x-app", "cli")
	case "openai":
		h.Set("Authorization", "Bearer "+t.cfg.APIKey)
	}
	return h
}

// buildClaudeBody 构建 Claude Messages API 请求体
func (t *HTTPTransport) buildClaudeBody(messages, systemPrompt, toolDefs string, maxTokens int, thinking string) ([]byte, error) {
	body := map[string]interface{}{
		"model":      t.cfg.Model,
		"max_tokens": maxTokens,
		"stream":     true,
		"messages":   json.RawMessage(messages),
	}
	if thinking != "disabled" {
		body["thinking"] = map[string]interface{}{
			"type": thinking,
		}
		body["output_config"] = map[string]interface{}{
			"effort": t.cfg.Effort,
		}
	}
	if systemPrompt != "" {
		body["system"] = systemPrompt
	}
	if toolDefs != "" {
		body["tools"] = json.RawMessage(toolDefs)
	}
	return json.Marshal(body)
}

// buildOpenAIBody 将 Claude 格式请求体转为 OpenAI 格式
func (t *HTTPTransport) buildOpenAIBody(messages, systemPrompt, toolDefs string, maxTokens int, thinking string) ([]byte, error) {
	// 解析 messages
	var msgs []json.RawMessage
	json.Unmarshal([]byte(messages), &msgs)

	// 如果有 system prompt，在消息头部插入
	if systemPrompt != "" {
		sysMsg, _ := json.Marshal(map[string]interface{}{
			"role":    "system",
			"content": systemPrompt,
		})
		msgs = append([]json.RawMessage{sysMsg}, msgs...)
	}

	// 转换 assistant 消息和 tool_result 消息
	converted := make([]json.RawMessage, 0, len(msgs))
	for _, raw := range msgs {
		converted = append(converted, t.convertMessage(raw))
	}

	body := map[string]interface{}{
		"model":      t.cfg.Model,
		"max_tokens": maxTokens,
		"stream":     true,
		"messages":   converted,
	}
	if thinking == "adaptive" || thinking == "enabled" {
		body["thinking"] = map[string]interface{}{
			"type": "enabled",
		}
		body["reasoning_effort"] = t.cfg.Effort
	}
	if toolDefs != "" {
		body["tools"] = json.RawMessage(t.convertTools(toolDefs))
	}
	return json.Marshal(body)
}

// convertMessage 将单条 Claude 消息转为 OpenAI 格式
func (t *HTTPTransport) convertMessage(raw json.RawMessage) json.RawMessage {
	var msg map[string]json.RawMessage
	if err := json.Unmarshal(raw, &msg); err != nil {
		return raw
	}

	role, _ := extractJSONString(msg, "role")
	switch role {
	case "assistant":
		return t.convertAssistantMsg(msg)
	case "user":
		// 检查是否包含 tool_result
		if content, ok := msg["content"]; ok {
			var arr []json.RawMessage
			if err := json.Unmarshal(content, &arr); err == nil {
				for _, item := range arr {
					var m map[string]json.RawMessage
					json.Unmarshal(item, &m)
					if tp, _ := extractJSONString(m, "type"); tp == "tool_result" {
						return t.convertToolResultMsg(arr)
					}
				}
			}
		}
	}
	return raw
}

func (t *HTTPTransport) convertAssistantMsg(msg map[string]json.RawMessage) json.RawMessage {
	result := map[string]interface{}{"role": "assistant"}

	var textParts []string
	var toolCalls []map[string]interface{}
	var reasoning string

	if content, ok := msg["content"]; ok {
		// 尝试解析为数组
		var arr []map[string]json.RawMessage
		if err := json.Unmarshal(content, &arr); err == nil {
			for _, block := range arr {
				tp, _ := extractJSONString(block, "type")
				switch tp {
				case "text":
					t, _ := extractJSONString(block, "text")
					textParts = append(textParts, t)
				case "thinking":
					r, _ := extractJSONString(block, "thinking")
					reasoning = r
				case "tool_use":
					id, _ := extractJSONString(block, "id")
					name, _ := extractJSONString(block, "name")
					input, _ := block["input"]
					if input == nil {
						input = json.RawMessage("{}")
					}
					toolCalls = append(toolCalls, map[string]interface{}{
						"id":   id,
						"type": "function",
						"function": map[string]interface{}{
							"name":      name,
							"arguments": string(input),
						},
					})
				}
			}
		} else {
			// 纯文本 content
			s, _ := extractJSONString(msg, "content")
			textParts = append(textParts, s)
		}
	}

	if reasoning != "" {
		result["reasoning_content"] = reasoning
	}
	result["content"] = strings.Join(textParts, "")
	if len(toolCalls) > 0 {
		result["tool_calls"] = toolCalls
	}

	out, _ := json.Marshal(result)
	return out
}

func (t *HTTPTransport) convertToolResultMsg(blocks []json.RawMessage) json.RawMessage {
	// 将 Claude 的 tool_result content blocks 展开
	// 实际上 OpenAI 不支持单个 user 消息含多条 tool result，
	// 所以这里返回第一条，多条场景简化处理
	var msgs []json.RawMessage
	for _, block := range blocks {
		var m map[string]json.RawMessage
		json.Unmarshal(block, &m)
		tp, _ := extractJSONString(m, "type")
		if tp != "tool_result" {
			continue
		}
		tid, _ := extractJSONString(m, "tool_use_id")
		rc, _ := extractJSONString(m, "content")
		msg := map[string]interface{}{
			"role":         "tool",
			"tool_call_id": tid,
			"content":      rc,
		}
		out, _ := json.Marshal(msg)
		msgs = append(msgs, out)
	}
	// 返回第一条（OpenAI 格式需要一对一）
	if len(msgs) > 0 {
		return msgs[0]
	}
	return json.RawMessage(`{"role":"user","content":""}`)
}

// convertTools 将 Claude 工具定义转为 OpenAI function 格式
func (t *HTTPTransport) convertTools(toolDefs string) string {
	var tools []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(toolDefs), &tools); err != nil {
		return toolDefs
	}
	result := make([]map[string]interface{}, 0, len(tools))
	for _, td := range tools {
		name, _ := extractJSONString(td, "name")
		desc, _ := extractJSONString(td, "description")
		params, _ := td["input_schema"]
		if params == nil {
			params = td["parameters"]
		}
		if params == nil {
			params = json.RawMessage("{}")
		}
		result = append(result, map[string]interface{}{
			"type": "function",
			"function": map[string]interface{}{
				"name":        name,
				"description": desc,
				"parameters":  params,
			},
		})
	}
	out, _ := json.Marshal(result)
	return string(out)
}

// buildURL 根据 provider 构建 API URL
func (t *HTTPTransport) buildURL() string {
	switch t.cfg.Provider {
	case "claude":
		base := t.cfg.BaseURL
		if base == "" {
			base = "https://api.anthropic.com/v1"
		}
		return base + "/messages"
	case "openai":
		base := t.cfg.BaseURL
		if base == "" {
			base = "https://api.openai.com/v1"
		}
		return base + "/chat/completions"
	default:
		return t.cfg.BaseURL
	}
}
