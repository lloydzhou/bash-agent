package agent

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// 视觉消息展开：与 Bash 版 src/awk/vision_body.awk 语义逐条对齐。
// - 仅处理 role=user；content 为字符串或块数组中的 text 块
// - 扫描 <attached-images> 区块，映射行正则匹配后读文件 base64 编码（无换行）
// - 仅当该消息至少编码一张图时才重写 content；无图消息字节原样（KV cache 前缀稳定）
// - 任一附件读取失败整体报错，调用方不得发送请求

var (
	visionMappingLine = regexp.MustCompile(`^\[Image #[0-9]+\] => /.*\/images/[0-9]+\.png$`)
	visionMappingHead = regexp.MustCompile(`^\[Image #[0-9]+\] => `)
)

const (
	visionBlockOpen  = "<attached-images>\n"
	visionBlockClose = "</attached-images>"
)

// ExpandVisionMessages 展开消息数组中的附件映射，返回新 JSON 数组字符串。
func ExpandVisionMessages(messages string) (string, error) {
	var msgs []json.RawMessage
	if err := json.Unmarshal([]byte(messages), &msgs); err != nil {
		return "", err
	}
	out := make([]string, len(msgs))
	for i, raw := range msgs {
		line, err := expandVisionMessage(string(raw))
		if err != nil {
			return "", err
		}
		out[i] = line
	}
	return "[" + strings.Join(out, ",") + "]", nil
}

func expandVisionMessage(line string) (string, error) {
	var msg map[string]json.RawMessage
	if err := json.Unmarshal([]byte(line), &msg); err != nil {
		return line, nil
	}
	if role, _ := extractJSONString(msg, "role"); role != "user" {
		return line, nil
	}
	content, ok := msg["content"]
	if !ok || len(content) == 0 {
		return line, nil
	}
	var images []string
	var newContent string
	if content[0] == '"' {
		var text string
		if err := json.Unmarshal(content, &text); err != nil {
			return line, nil
		}
		newText, err := convertVisionText(text, &images)
		if err != nil {
			return "", err
		}
		if len(images) == 0 {
			return line, nil
		}
		parts := make([]string, 0, len(images)+1)
		if newText != "" {
			tb, _ := json.Marshal(newText)
			parts = append(parts, `{"type":"text","text":`+string(tb)+`}`)
		}
		parts = append(parts, images...)
		newContent = "[" + strings.Join(parts, ",") + "]"
	} else if content[0] == '[' {
		var blocks []json.RawMessage
		if err := json.Unmarshal(content, &blocks); err != nil {
			return line, nil
		}
		newBlocks := make([]json.RawMessage, 0, len(blocks))
		for _, block := range blocks {
			var bm map[string]json.RawMessage
			if err := json.Unmarshal(block, &bm); err != nil {
				newBlocks = append(newBlocks, block)
				continue
			}
			if tp, _ := extractJSONString(bm, "type"); tp != "text" {
				newBlocks = append(newBlocks, block)
				continue
			}
			var text string
			if err := json.Unmarshal(bm["text"], &text); err != nil {
				newBlocks = append(newBlocks, block)
				continue
			}
			newText, err := convertVisionText(text, &images)
			if err != nil {
				return "", err
			}
			if newText == "" {
				continue
			}
			if newText != text {
				tb, _ := json.Marshal(newText)
				block = json.RawMessage(`{"type":"text","text":` + string(tb) + `}`)
			}
			newBlocks = append(newBlocks, block)
		}
		if len(images) == 0 {
			return line, nil
		}
		all := append(newBlocks, json.RawMessage(strings.Join(images, ",")))
		cb, _ := json.Marshal(all)
		newContent = string(cb)
	} else {
		return line, nil
	}
	msg["content"] = json.RawMessage(newContent)
	nb, err := json.Marshal(msg)
	if err != nil {
		return "", err
	}
	return string(nb), nil
}

// convertVisionText 对齐 awk convert_text：逐个处理 attached-images 区块，
// 映射行编码为 image 块追加到 images；无匹配行的区块原样保留。
func convertVisionText(text string, images *[]string) (string, error) {
	rest := text
	cleaned := ""
	for {
		start := strings.Index(rest, visionBlockOpen)
		if start < 0 {
			break
		}
		before := rest[:start]
		section := rest[start+len(visionBlockOpen):]
		stop := strings.Index(section, visionBlockClose)
		if stop < 0 {
			break
		}
		found := false
		for _, mapping := range strings.Split(section[:stop], "\n") {
			if !visionMappingLine.MatchString(mapping) {
				continue
			}
			path := visionMappingHead.ReplaceAllString(mapping, "")
			data, err := os.ReadFile(path)
			if err != nil {
				return "", fmt.Errorf("无法读取有效的 PNG 附件：%s", path)
			}
			*images = append(*images, `{"type":"image","source":{"type":"base64","media_type":"image/png","data":"`+base64.StdEncoding.EncodeToString(data)+`"}}`)
			found = true
		}
		if found {
			cleaned += strings.TrimSuffix(before, "\n\n")
		} else {
			cleaned += before + visionBlockOpen + section[:stop] + visionBlockClose
		}
		rest = section[stop+len(visionBlockClose):]
	}
	return cleaned + rest, nil
}
