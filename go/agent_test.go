package agent

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── Util 测试 ───

func TestUtilJSONEscape(t *testing.T) {
	tests := []struct {
		input    string
		contains string // 检查输出包含特定转义序列
	}{
		{`hello`, `hello`},
		{`say "hi"`, `\"hi\"`},
		{"line1\nline2", `\n`},
		{"tab\there", `\t`},
	}
	for _, tc := range tests {
		got := UtilJSONEscape(tc.input)
		if !strings.Contains(got, tc.contains) {
			t.Errorf("UtilJSONEscape(%q) = %q, should contain %q", tc.input, got, tc.contains)
		}
	}
}

func TestUtilNewSessionID(t *testing.T) {
	id1 := UtilNewSessionID()
	id2 := UtilNewSessionID()
	if id1 == id2 {
		t.Error("session IDs should be unique")
	}
	if len(id1) < 8 {
		t.Errorf("session ID length = %d, too short", len(id1))
	}
}

func TestUtilParseSize(t *testing.T) {
	tests := []struct {
		input    string
		expected int
		hasErr   bool
	}{
		{"100", 100, false},
		{"2k", 2000, false},
		{"1K", 1000, false},
		{"4m", 4000000, false},
		{"1M", 1000000, false},
		{"abc", 0, true},
	}
	for _, tc := range tests {
		got, err := UtilParseSize(tc.input)
		if tc.hasErr {
			if err == nil {
				t.Errorf("UtilParseSize(%q) expected error, got nil", tc.input)
			}
		} else {
			if err != nil {
				t.Errorf("UtilParseSize(%q) unexpected error: %v", tc.input, err)
			}
			if got != tc.expected {
				t.Errorf("UtilParseSize(%q) = %d, want %d", tc.input, got, tc.expected)
			}
		}
	}
}

func TestPathToProjectKeyMatchesBash(t *testing.T) {
	tests := map[string]string{
		"/Users/lloyd/claude-code/bash-agent": "-Users-lloyd-claude-code-bash-agent",
		"/tmp/a b/c:d":                        "-tmp-a-b-c-d",
		"///tmp///a--b///":                    "-tmp-a-b",
	}
	for input, want := range tests {
		if got := pathToProjectKey(input); got != want {
			t.Errorf("pathToProjectKey(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestToolDenyBashReason(t *testing.T) {
	blocked := []string{
		"sudo rm -rf /",
		"mkfs /dev/sda1",
		"dd of=/dev/sda bs=1M",
		":(){:|:&};:",
	}
	for _, cmd := range blocked {
		reason := ToolDenyBashReason(cmd)
		if reason == "" {
			t.Errorf("expected block for: %s", cmd)
		}
	}
	allowed := []string{
		"ls -la",
		"echo hello",
		"cat /etc/hosts",
	}
	for _, cmd := range allowed {
		reason := ToolDenyBashReason(cmd)
		if reason != "" {
			t.Errorf("expected allow for: %s, got block: %s", cmd, reason)
		}
	}
}

func TestFormatToolResult(t *testing.T) {
	// 短输出不截断
	short := "hello"
	if got := FormatToolResult(short); got != short {
		t.Errorf("short output should not be truncated")
	}

	// 长输出应包含截断标记
	long := stringsRepeat("a", defaultToolResultMaxBytes+10000)
	got := FormatToolResult(long)
	if !contains(got, "truncated") {
		t.Errorf("long output should contain 'truncated'")
	}
	if len(got) > defaultToolResultMaxBytes*2 {
		t.Errorf("long output should be much shorter than original, got %d bytes", len(got))
	}
}

func stringsRepeat(s string, n int) string {
	out := make([]byte, 0, len(s)*n)
	for len(out) < n {
		out = append(out, s...)
	}
	return string(out[:n])
}

// ─── Store 测试 ───

func newTestStore(t *testing.T) *FileStore {
	t.Helper()
	dir := t.TempDir()
	store := NewFileStore(dir, dir)
	err := store.Init("test_session")
	if err != nil {
		t.Fatalf("init store: %v", err)
	}
	return store
}

func TestFileStoreInit(t *testing.T) {
	store := newTestStore(t)
	if store.SessionID() != "test_session" {
		t.Errorf("session ID = %q, want test_session", store.SessionID())
	}
	dir := store.GetDir()
	if dir == "" {
		t.Error("GetDir should return non-empty")
	}
	// 检查目录存在
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		t.Error("session dir should exist")
	}
}

func TestFileStoreConversation(t *testing.T) {
	store := newTestStore(t)

	// 添加用户消息
	if err := store.AddUserMessage("hello"); err != nil {
		t.Fatalf("AddUserMessage: %v", err)
	}

	// 检查行数
	count, err := store.ConvLineCount()
	if err != nil {
		t.Fatalf("ConvLineCount: %v", err)
	}
	if count != 1 {
		t.Errorf("ConvLineCount = %d, want 1", count)
	}

	// 添加 assistant 消息
	if err := store.AddAssistantMessage("hi there", "", nil); err != nil {
		t.Fatalf("AddAssistantMessage: %v", err)
	}

	count, _ = store.ConvLineCount()
	if count != 2 {
		t.Errorf("ConvLineCount = %d, want 2", count)
	}

	// 获取 messages
	msgs, err := store.GetMessages()
	if err != nil {
		t.Fatalf("GetMessages: %v", err)
	}
	if !json.Valid([]byte(msgs)) {
		t.Errorf("GetMessages should return valid JSON, got: %s", msgs)
	}
}

func TestFileStoreToolResultConvOutput(t *testing.T) {
	store := newTestStore(t)
	if err := store.AddAssistantMessage("", "", []ToolCallInfo{{Name: "Read", ID: "toolu_1", Input: `{"path":"a.txt"}`}}); err != nil {
		t.Fatalf("AddAssistantMessage: %v", err)
	}
	if err := store.AddToolResults([]ToolResultInfo{{
		ToolID:     "toolu_1",
		ToolName:   "Read",
		Output:     "Read(a.txt) [1 lines, 4 bytes]\nbody",
		ConvOutput: "body",
	}}); err != nil {
		t.Fatalf("AddToolResults: %v", err)
	}
	raw, err := os.ReadFile(store.convFile)
	if err != nil {
		t.Fatalf("read conversation: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 2 {
		t.Fatalf("conversation lines = %d, want 2: %s", len(lines), raw)
	}
	if !strings.Contains(lines[0], `"tool_use"`) {
		t.Fatalf("assistant tool_use should precede tool_result, got: %s", lines[0])
	}
	if strings.Contains(lines[1], "Read(a.txt)") || !strings.Contains(lines[1], `"content":"body"`) {
		t.Fatalf("tool_result conversation content not trimmed to ConvOutput: %s", lines[1])
	}
}

func TestFileStoreSummary(t *testing.T) {
	store := newTestStore(t)

	summary, err := store.GetSummary()
	if err != nil {
		t.Fatalf("GetSummary: %v", err)
	}
	if summary != "" {
		t.Errorf("initial summary should be empty")
	}

	if err := store.SetSummary("test summary"); err != nil {
		t.Fatalf("SetSummary: %v", err)
	}

	summary, _ = store.GetSummary()
	if strings.TrimSpace(summary) != "test summary" {
		t.Errorf("GetSummary = %q, want 'test summary'", summary)
	}
}

func TestFileStorePlan(t *testing.T) {
	store := newTestStore(t)

	empty, _ := store.PlanDraftIsEmpty()
	if !empty {
		t.Error("initial draft should be empty")
	}

	if err := store.SetPlanDraft("draft plan"); err != nil {
		t.Fatalf("SetPlanDraft: %v", err)
	}

	empty, _ = store.PlanDraftIsEmpty()
	if empty {
		t.Error("draft should not be empty after set")
	}

	draft, _ := store.GetPlanDraft()
	if strings.TrimSpace(draft) != "draft plan" {
		t.Errorf("GetPlanDraft = %q, want 'draft plan'", draft)
	}
}

func TestFileStoreFork(t *testing.T) {
	store := newTestStore(t)
	_ = store.AddUserMessage("parent message")
	_ = store.SetSummary("parent summary")

	// parent session 目录
	parentSessionDir := filepath.Join(store.GetDir(), store.SessionID())

	// child 目录在同一 base 下
	childSessionDir := filepath.Join(store.GetDir(), "child_session")

	if err := store.Fork(parentSessionDir, childSessionDir); err != nil {
		t.Fatalf("Fork: %v", err)
	}

	// 子目录应存在
	if _, err := os.Stat(childSessionDir); os.IsNotExist(err) {
		t.Fatal("child session dir should exist")
	}

	// 用同一个 store 的 home/cwd 创建 childStore，这样路径一致
	childStore := NewFileStore(store.home, store.cwd)
	_ = childStore.Init("child_session")

	count, _ := childStore.ConvLineCount()
	if count != 1 {
		t.Errorf("child ConvLineCount = %d, want 1", count)
	}

	summary, _ := childStore.GetSummary()
	if strings.TrimSpace(summary) != "parent summary" {
		t.Errorf("child summary = %q, want 'parent summary'", summary)
	}
}

func TestFileStoreStats(t *testing.T) {
	store := newTestStore(t)

	stats := store.GetStats()
	if stats.InputTokens != 0 {
		t.Errorf("initial InputTokens should be 0")
	}

	usage := Usage{InputTokens: 100, OutputTokens: 50}
	if err := store.UpdateStats(usage, "test-model"); err != nil {
		t.Fatalf("UpdateStats: %v", err)
	}

	stats = store.GetStats()
	if stats.InputTokens != 100 {
		t.Errorf("InputTokens = %d, want 100", stats.InputTokens)
	}
	if stats.OutputTokens != 50 {
		t.Errorf("OutputTokens = %d, want 50", stats.OutputTokens)
	}
}

func TestFileStoreCompactStats(t *testing.T) {
	store := newTestStore(t)
	usage := Usage{InputTokens: 10, OutputTokens: 5, CacheRead: 3, CacheWrite: 2}
	if err := store.UpdateCompactStats(usage); err != nil {
		t.Fatalf("UpdateCompactStats: %v", err)
	}
	stats := store.GetStats()
	if stats.TotalCompact != 1 {
		t.Errorf("TotalCompact = %d, want 1", stats.TotalCompact)
	}
	if stats.TotalRequests != 0 {
		t.Errorf("TotalRequests = %d, want 0", stats.TotalRequests)
	}
	if stats.InputTokens != 10 || stats.OutputTokens != 5 || stats.CacheRead != 3 || stats.CacheWrite != 2 {
		t.Errorf("compact token totals mismatch: %+v", stats)
	}
}

// ─── Tool 测试 ───

func TestToolRead(t *testing.T) {
	td := NewToolDispatcher(DefaultConfig())

	// 创建临时文件
	tmpFile := filepath.Join(t.TempDir(), "test.txt")
	content := "line1\nline2\nline3\n"
	os.WriteFile(tmpFile, []byte(content), 0644)

	output, err := td.toolRead(tmpFile, "1", "2")
	if err != nil {
		t.Fatalf("toolRead: %v", err)
	}
	if !contains(output, "line1") || !contains(output, "line2") {
		t.Errorf("toolRead output missing lines: %s", output)
	}
}

func TestToolWrite(t *testing.T) {
	td := NewToolDispatcher(DefaultConfig())
	dir := t.TempDir()
	p := filepath.Join(dir, "subdir", "test.txt")

	output, err := td.toolWrite(p, "hello world")
	if err != nil {
		t.Fatalf("toolWrite: %v", err)
	}
	if !contains(output, "OK") {
		t.Errorf("toolWrite output: %s", output)
	}

	data, _ := os.ReadFile(p)
	if string(data) != "hello world" {
		t.Errorf("file content = %q, want 'hello world'", string(data))
	}
}

func TestToolEdit(t *testing.T) {
	td := NewToolDispatcher(DefaultConfig())
	tmpFile := filepath.Join(t.TempDir(), "test.txt")
	os.WriteFile(tmpFile, []byte("hello world\nfoo bar\n"), 0644)

	output, err := td.toolEdit(tmpFile, "hello world", "HELLO WORLD")
	if err != nil {
		t.Fatalf("toolEdit: %v", err)
	}
	if !contains(output, "Edit") {
		t.Errorf("toolEdit output: %s", output)
	}

	data, _ := os.ReadFile(tmpFile)
	if !contains(string(data), "HELLO WORLD") {
		t.Errorf("file should contain 'HELLO WORLD': %s", string(data))
	}
}

func TestToolGlob(t *testing.T) {
	td := NewToolDispatcher(DefaultConfig())
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "a.txt"), []byte("a"), 0644)
	os.WriteFile(filepath.Join(dir, "b.go"), []byte("b"), 0644)

	output, err := td.toolGlob("*.txt", dir)
	if err != nil {
		t.Fatalf("toolGlob: %v", err)
	}
	if !contains(output, "a.txt") {
		t.Errorf("toolGlob output should contain a.txt: %s", output)
	}
}

func TestToolDispatch(t *testing.T) {
	td := NewToolDispatcher(DefaultConfig())

	// TodoWrite 直接返回
	output, err := td.Dispatch(nil, "TodoWrite", map[string]string{"checklist": "test"})
	if err != nil {
		t.Fatalf("TodoWrite dispatch: %v", err)
	}
	if output != "test" {
		t.Errorf("TodoWrite output = %q, want 'test'", output)
	}

	// Unknown tool
	_, err = td.Dispatch(nil, "Unknown", nil)
	if err == nil {
		t.Error("unknown tool should return error")
	}
}

func TestCallSummary(t *testing.T) {
	td := NewToolDispatcher(DefaultConfig())
	summary := td.CallSummary("Read", map[string]string{"path": "/tmp/test.txt"})
	if summary != "Read(/tmp/test.txt)" {
		t.Errorf("CallSummary = %q", summary)
	}

	summary = td.CallSummary("Bash", map[string]string{"command": "echo hello"})
	if summary != "Bash(echo hello)" {
		t.Errorf("CallSummary = %q", summary)
	}
}

// ─── Display 测试 ───

func TestTermDisplay(t *testing.T) {
	var buf strings.Builder
	d := NewTermDisplay()
	d.SetWriter(&buf)

	d.HumanText("hello")
	if buf.String() != "hello" {
		t.Errorf("HumanText output = %q, want 'hello'", buf.String())
	}

	buf.Reset()
	d.EnsureNewline() // lastChar is 'o', should add newline
	if buf.String() != "\n" {
		t.Errorf("EnsureNewline should add newline when last char is not newline")
	}

	buf.Reset()
	d.EnsureNewline() // lastChar is '\n', should not add
	if buf.String() != "" {
		t.Errorf("EnsureNewline should not add when already on newline")
	}
}

// ─── Transport 类型转换测试 ───

func TestOpenAIBodyConversion(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Provider = "openai"
	cfg.Model = "gpt-4o"
	tr := NewHTTPTransport(cfg)

	// 测试工具定义转换
	claudeTools := `[{"name":"Read","description":"Read a file","input_schema":{"type":"object","properties":{"path":{"type":"string"}}}}]`
	openaiTools := tr.convertTools(claudeTools)
	if !contains(openaiTools, `"type":"function"`) {
		t.Errorf("convertTools should produce OpenAI format: %s", openaiTools)
	}

	// 测试 assistant 消息转换
	assistantMsg := map[string]json.RawMessage{
		"role":    json.RawMessage(`"assistant"`),
		"content": json.RawMessage(`[{"type":"text","text":"hello"}]`),
	}
	converted := tr.convertAssistantMsg(assistantMsg)
	if !contains(string(converted), `"role":"assistant"`) {
		t.Errorf("convertAssistantMsg: %s", string(converted))
	}
}

func TestSSEParser(t *testing.T) {
	cfg := DefaultConfig()
	tr := NewHTTPTransport(cfg)

	// 测试 handleBlockStart
	bt, tn, tid := tr.handleBlockStart(`{"type":"content_block_start","content_block":{"type":"text","text":""}}`)
	if bt != "text" {
		t.Errorf("handleBlockStart text: got %q", bt)
	}

	bt, tn, tid = tr.handleBlockStart(`{"type":"content_block_start","content_block":{"type":"tool_use","name":"Read","id":"toolu_123"}}`)
	if bt != "tool" || tn != "Read" || tid != "toolu_123" {
		t.Errorf("handleBlockStart tool: bt=%q tn=%q tid=%q", bt, tn, tid)
	}
}

func TestSSEParserInterruptedStreamClosesAfterFallbackEvents(t *testing.T) {
	cfg := DefaultConfig()
	tr := NewHTTPTransport(cfg)
	resp := &http.Response{
		Body: io.NopCloser(strings.NewReader("")),
	}
	ch := make(chan Event, 2)

	tr.parseSSEStream(resp, ch)

	var events []Event
	for ev := range ch {
		events = append(events, ev)
	}
	if len(events) != 2 {
		t.Fatalf("events len = %d, want 2", len(events))
	}
	if events[0].Type != EventError {
		t.Fatalf("first event = %v, want EventError", events[0].Type)
	}
	if events[1].Type != EventStop || len(events[1].Fields) < 2 || events[1].Fields[1] != "error" {
		t.Fatalf("second event = %#v, want STOP error", events[1])
	}
}

// ─── CompactDPDecision 测试 ───

// writeConvRaw 直接写入原始 JSONL 行到 conversation 文件
func writeConvRaw(t *testing.T, store *FileStore, lines []string) {
	t.Helper()
	dir := store.GetDir()
	sessionID := store.SessionID()
	convFile := filepath.Join(dir, sessionID, "conversation.jsonl")
	f, err := os.OpenFile(convFile, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatalf("open conv file: %v", err)
	}
	defer f.Close()
	for _, line := range lines {
		if _, err := fmt.Fprintln(f, line); err != nil {
			t.Fatalf("write conv line: %v", err)
		}
	}
}

// genConv 生成 N 组 user+assistant 对话消息，总 token 数接近 target
func genConv(groups, totalTokenTarget int) []string {
	var lines []string
	bytesPerLine := totalTokenTarget * 4 / groups / 3
	if bytesPerLine < 20 {
		bytesPerLine = 20
	}
	pad := strings.Repeat("x", bytesPerLine)
	assistPad := strings.Repeat("y", bytesPerLine*2)
	for i := 0; i < groups; i++ {
		lines = append(lines, fmt.Sprintf(`{"role":"user","content":"%s"}`, pad))
		lines = append(lines, fmt.Sprintf(`{"role":"assistant","content":"%s"}`, assistPad))
	}
	return lines
}

func TestCompactDPDecision_Empty(t *testing.T) {
	store := newTestStore(t)
	cfg := DefaultConfig()
	n, err := store.CompactDPDecision(cfg)
	if err != nil {
		t.Fatalf("CompactDPDecision: %v", err)
	}
	if n != 0 {
		t.Errorf("empty conv: got %d, want 0", n)
	}
}

func TestCompactDPDecision_Small(t *testing.T) {
	store := newTestStore(t)
	lines := genConv(2, 5000)
	writeConvRaw(t, store, lines)

	cfg := DefaultConfig()
	cfg.DPEFixed = 8
	cfg.DPFixed = 3.0
	n, err := store.CompactDPDecision(cfg)
	if err != nil {
		t.Fatalf("CompactDPDecision: %v", err)
	}
	if n != 0 {
		t.Errorf("small conv: got %d, want 0", n)
	}
}

func TestCompactDPDecision_Large(t *testing.T) {
	store := newTestStore(t)
	lines := genConv(20, 100000)
	writeConvRaw(t, store, lines)

	cfg := DefaultConfig()
	cfg.DPEFixed = 8
	cfg.DPFixed = 5.0
	n, err := store.CompactDPDecision(cfg)
	if err != nil {
		t.Fatalf("CompactDPDecision: %v", err)
	}
	if n == 0 {
		t.Error("large conv: expected > 0, got 0")
	}
}

func TestCompactDPDecision_QualityPenaltyPromotes(t *testing.T) {
	store := newTestStore(t)
	lines := genConv(20, 100000)
	writeConvRaw(t, store, lines)

	cfg := DefaultConfig()
	cfg.DPEFixed = 8
	cfg.DPFixed = 5.0
	cfg.DPQualityPenalty = 500.0
	n, err := store.CompactDPDecision(cfg)
	if err != nil {
		t.Fatalf("CompactDPDecision: %v", err)
	}
	// QP=500 作为增量正项（quality_savings），大幅促进压缩
	if n == 0 {
		t.Errorf("quality_penalty=500: got 0, want >0 (should promote compaction)")
	}
}

func TestCompactDPDecision_TurnAlignment(t *testing.T) {
	store := newTestStore(t)
	lines := []string{
		`{"role":"assistant","content":"intro"}`,
		`{"role":"user","content":"step 1"}`,
		`{"role":"assistant","content":"response 1"}`,
		`{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"result 1"}]}`,
		`{"role":"assistant","content":"response 1b"}`,
		`{"role":"user","content":"step 2"}`,
		`{"role":"assistant","content":"response 2"}`,
		`{"role":"user","content":"step 3"}`,
	}
	writeConvRaw(t, store, lines)

	cfg := DefaultConfig()
	cfg.DPEFixed = 10
	cfg.DPFixed = 3.0
	cfg.DPVPrefix = 0
	cfg.DPSummaryLen = 0.001 // 非零小值，避免被默认值 400 覆盖
	cfg.DPBeta = 0.001
	cfg.DPQualityPenalty = 0.001 // 非零小值，避免被默认值 0.2 覆盖
	n, err := store.CompactDPDecision(cfg)
	if err != nil {
		t.Fatalf("CompactDPDecision: %v", err)
	}
	// 期望保留 3 或 4 行（对齐到 user 边界）
	if n != 3 && n != 4 {
		t.Errorf("turn alignment: got %d, want 3 or 4", n)
	}
}

// ─── 辅助函数 ───

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > 0 && containsHelper(s, substr))
}

func containsHelper(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
