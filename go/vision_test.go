package agent

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeTestPNG(t *testing.T, dir string, n int, content []byte) string {
	t.Helper()
	p := filepath.Join(dir, "images", string(rune('0'+n))+".png")
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, content, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestExpandVisionMessagesTwoImages(t *testing.T) {
	dir := t.TempDir()
	p1 := writeTestPNG(t, dir, 1, []byte("\x89PNG one"))
	p2 := writeTestPNG(t, dir, 2, []byte("\x89PNG two"))
	text := "看图\n<attached-images>\n说明\n[Image #1] => " + p1 + "\n[Image #2] => " + p2 + "\n</attached-images>"
	conv := `[{"role":"user","content":` + mustJSON(t, text) + `},{"role":"assistant","content":"ok"}]`
	out, err := ExpandVisionMessages(conv)
	if err != nil {
		t.Fatal(err)
	}
	var msgs []map[string]json.RawMessage
	if err := json.Unmarshal([]byte(out), &msgs); err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("messages = %d", len(msgs))
	}
	var blocks []map[string]json.RawMessage
	if err := json.Unmarshal(msgs[0]["content"], &blocks); err != nil {
		t.Fatal(err)
	}
	if len(blocks) != 3 || string(blocks[0]["type"]) != `"text"` {
		t.Fatalf("blocks = %s", msgs[0]["content"])
	}
	if got := unescapeSrcData(t, blocks[1]); got != "\x89PNG one" {
		t.Fatalf("img1 = %q", got)
	}
	if got := unescapeSrcData(t, blocks[2]); got != "\x89PNG two" {
		t.Fatalf("img2 = %q", got)
	}
	// assistant 原样
	if string(msgs[1]["content"]) != `"ok"` {
		t.Fatalf("assistant changed: %s", msgs[1]["content"])
	}
}

func TestExpandVisionMessagesNoMatchKeepsOriginal(t *testing.T) {
	conv := `[{"role":"user","content":"纯文本，无区块"}]`
	out, err := ExpandVisionMessages(conv)
	if err != nil {
		t.Fatal(err)
	}
	if out != conv {
		t.Fatalf("no-attachment message changed:\n%s\n%s", conv, out)
	}
	// 区块内映射行路径不匹配正则（非 images 目录）→ 原样
	conv2 := `[{"role":"user","content":"x\n<attached-images>\n[Image #1] => /etc/passwd\n</attached-images>"}]`
	out2, err := ExpandVisionMessages(conv2)
	if err != nil {
		t.Fatal(err)
	}
	if out2 != conv2 {
		t.Fatalf("non-mapping block changed:\n%s\n%s", conv2, out2)
	}
}

func TestExpandVisionMessagesMissingFileFails(t *testing.T) {
	conv := `[{"role":"user","content":"x\n<attached-images>\n[Image #1] => /nonexistent/images/99.png\n</attached-images>"}]`
	if _, err := ExpandVisionMessages(conv); err == nil {
		t.Fatal("expected error for missing file")
	}
}

func TestExpandVisionMessagesTextBlocks(t *testing.T) {
	dir := t.TempDir()
	p1 := writeTestPNG(t, dir, 1, []byte("blk"))
	text := "<attached-images>\n[Image #1] => " + p1 + "\n</attached-images>"
	conv := `[{"role":"user","content":[{"type":"text","text":` + mustJSON(t, text) + `},{"type":"tool_result","tool_use_id":"a","content":"keep"}]}]`
	out, err := ExpandVisionMessages(conv)
	if err != nil {
		t.Fatal(err)
	}
	var msgs []map[string]json.RawMessage
	json.Unmarshal([]byte(out), &msgs)
	var blocks []map[string]json.RawMessage
	json.Unmarshal(msgs[0]["content"], &blocks)
	// text 块（区块清理后为空则删除）+ tool_result 原样 + image 追加
	if len(blocks) != 2 {
		t.Fatalf("blocks = %s", msgs[0]["content"])
	}
	if string(blocks[0]["type"]) != `"tool_result"` {
		t.Fatalf("tool_result not preserved: %s", msgs[0]["content"])
	}
	if got := unescapeSrcData(t, blocks[1]); got != "blk" {
		t.Fatalf("img = %q", got)
	}
}

func TestConvertImageBlocksOpenAI(t *testing.T) {
	raw := json.RawMessage(`{"role":"user","content":[{"type":"text","text":"hi"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"QUJD"}}]}`)
	var msg map[string]json.RawMessage
	json.Unmarshal(raw, &msg)
	var arr []json.RawMessage
	json.Unmarshal(msg["content"], &arr)
	out := convertImageBlocks(raw, msg, arr)
	var m map[string]json.RawMessage
	if err := json.Unmarshal(out, &m); err != nil {
		t.Fatal(err)
	}
	s := string(m["content"])
	if !strings.Contains(s, `{"type":"image_url","image_url":{"url":"data:image/png;base64,QUJD"}}`) {
		t.Fatalf("openai image conversion = %s", s)
	}
	if !strings.Contains(s, `"type":"text"`) {
		t.Fatalf("text block lost: %s", s)
	}
	// 无 image 块 → 原字节
	raw2 := json.RawMessage(`{"role":"user","content":[{"type":"text","text":"hi"}]}`)
	var msg2 map[string]json.RawMessage
	json.Unmarshal(raw2, &msg2)
	var arr2 []json.RawMessage
	json.Unmarshal(msg2["content"], &arr2)
	if out2 := convertImageBlocks(raw2, msg2, arr2); string(out2) != string(raw2) {
		t.Fatalf("no-image message changed: %s", out2)
	}
}

func mustJSON(t *testing.T, v string) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func unescapeSrcData(t *testing.T, block map[string]json.RawMessage) string {
	t.Helper()
	var src map[string]json.RawMessage
	if err := json.Unmarshal(block["source"], &src); err != nil {
		t.Fatal(err)
	}
	var data string
	if err := json.Unmarshal(src["data"], &data); err != nil {
		t.Fatal(err)
	}
	raw, err := base64.StdEncoding.DecodeString(data)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}
