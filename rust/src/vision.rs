// 视觉消息展开：与 Bash 版 src/awk/vision_body.awk 语义逐条对齐。
// 仅处理 role=user；content 为字符串或块数组中的 text 块；扫描 attached-images
// 区块，映射行读文件 base64（无换行）转 image 块；仅当该消息至少编码一张图时
// 才重写 content；任一附件读取失败整体报错，调用方不得发送请求。

use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::fs;

pub fn expand_vision_messages(messages: &mut [Value]) -> Result<()> {
    for msg in messages.iter_mut() {
        if msg.get("role").and_then(Value::as_str) != Some("user") {
            continue;
        }
        let Some(content) = msg.get("content") else { continue };
        let mut images: Vec<Value> = Vec::new();
        let new_content = if let Some(text) = content.as_str() {
            let new_text = convert_vision_text(text, &mut images)?;
            if images.is_empty() {
                continue;
            }
            let mut parts: Vec<Value> = Vec::new();
            if !new_text.is_empty() {
                parts.push(json!({"type":"text","text":new_text}));
            }
            parts.extend(images);
            Value::Array(parts)
        } else if let Some(blocks) = content.as_array() {
            let mut new_blocks: Vec<Value> = Vec::new();
            for block in blocks {
                if block.get("type").and_then(Value::as_str) != Some("text") {
                    new_blocks.push(block.clone());
                    continue;
                }
                let text = block.get("text").and_then(Value::as_str).unwrap_or("");
                let new_text = convert_vision_text(text, &mut images)?;
                if new_text.is_empty() {
                    continue;
                }
                if new_text != text {
                    new_blocks.push(json!({"type":"text","text":new_text}));
                } else {
                    new_blocks.push(block.clone());
                }
            }
            if images.is_empty() {
                continue;
            }
            let mut all = new_blocks;
            all.extend(images);
            Value::Array(all)
        } else {
            continue;
        };
        msg["content"] = new_content;
    }
    Ok(())
}

const VISION_BLOCK_OPEN: &str = "<attached-images>\n";
const VISION_BLOCK_CLOSE: &str = "</attached-images>";

// 对齐 awk 正则 ^\[Image #[0-9]+\] => /.*\/images/[0-9]+\.png$
fn is_mapping_line(line: &str) -> bool {
    let Some(rest) = line.strip_prefix("[Image #") else { return false };
    let Some(hash) = rest.find(']') else { return false };
    if hash == 0 || !rest[..hash].chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let Some(rest) = rest[hash + 1..].strip_prefix(" => /") else { return false };
    if !rest.ends_with(".png") {
        return false;
    }
    let Some(slash) = rest.rfind("/images/") else { return false };
    let num = &rest[slash + 8..rest.len() - 4];
    !num.is_empty() && num.chars().all(|c| c.is_ascii_digit())
}

// 对齐 awk convert_text：逐个处理区块，无匹配行的区块原样保留。
fn convert_vision_text(text: &str, images: &mut Vec<Value>) -> Result<String> {
    use base64::Engine;
    let mut rest = text;
    let mut cleaned = String::new();
    loop {
        let Some(start) = rest.find(VISION_BLOCK_OPEN) else { break };
        let before = &rest[..start];
        let section = &rest[start + VISION_BLOCK_OPEN.len()..];
        let Some(stop) = section.find(VISION_BLOCK_CLOSE) else { break };
        let mut found = false;
        for line in section[..stop].split('\n') {
            if !is_mapping_line(line) {
                continue;
            }
            let path = &line[line.find(" => ").map(|i| i + 4).unwrap_or(0)..];
            let data = fs::read(path).map_err(|_| anyhow!("无法读取有效的 PNG 附件：{}", path))?;
            let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
            images.push(json!({"type":"image","source":{"type":"base64","media_type":"image/png","data":b64}}));
            found = true;
        }
        if found {
            cleaned.push_str(before.strip_suffix("\n\n").unwrap_or(before));
        } else {
            cleaned.push_str(before);
            cleaned.push_str(VISION_BLOCK_OPEN);
            cleaned.push_str(&section[..stop]);
            cleaned.push_str(VISION_BLOCK_CLOSE);
        }
        rest = &section[stop + VISION_BLOCK_CLOSE.len()..];
    }
    cleaned.push_str(rest);
    Ok(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_png(dir: &std::path::Path, n: &str, content: &[u8]) -> String {
        let p = dir.join("images").join(format!("{}.png", n));
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(&p, content).unwrap();
        p.to_string_lossy().to_string()
    }

    #[test]
    fn expands_two_images_and_keeps_assistant() {
        let dir = std::env::temp_dir().join(format!("rustvision{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p1 = write_png(&dir, "1", b"\x89PNG one");
        let p2 = write_png(&dir, "2", b"\x89PNG two");
        let text = format!("看图\n<attached-images>\n说明\n[Image #1] => {}\n[Image #2] => {}\n</attached-images>", p1, p2);
        let mut msgs = vec![
            json!({"role":"user","content":text}),
            json!({"role":"assistant","content":"ok"}),
        ];
        expand_vision_messages(&mut msgs).unwrap();
        let blocks = msgs[0]["content"].as_array().unwrap();
        assert_eq!(blocks.len(), 3);
        assert_eq!(blocks[0]["type"], "text");
        assert_eq!(blocks[0]["text"], "看图\n");
        assert_eq!(blocks[1]["source"]["data"], "iVBORyBvbmU=");
        assert_eq!(blocks[2]["source"]["data"], "iVBORyB0d28=");
        assert_eq!(msgs[1]["content"], "ok");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn keeps_message_without_mapping() {
        let mut msgs = vec![json!({"role":"user","content":"纯文本"})];
        expand_vision_messages(&mut msgs).unwrap();
        assert_eq!(msgs[0]["content"], "纯文本");
        let bad = json!({"role":"user","content":"x\n<attached-images>\n[Image #1] => /etc/passwd\n</attached-images>"});
        let mut msgs2 = vec![bad.clone()];
        expand_vision_messages(&mut msgs2).unwrap();
        assert_eq!(msgs2[0], bad);
    }

    #[test]
    fn fails_on_missing_file() {
        let mut msgs = vec![json!({"role":"user","content":"x\n<attached-images>\n[Image #1] => /nonexistent/images/99.png\n</attached-images>"})];
        assert!(expand_vision_messages(&mut msgs).is_err());
    }

    #[test]
    fn text_blocks_array_keeps_tool_result() {
        let dir = std::env::temp_dir().join(format!("rustvisionblk{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let p1 = write_png(&dir, "1", b"blk");
        let text = format!("<attached-images>\n[Image #1] => {}\n</attached-images>", p1);
        let mut msgs = vec![json!({
            "role":"user",
            "content":[
                {"type":"text","text":text},
                {"type":"tool_result","tool_use_id":"a","content":"keep"}
            ]
        })];
        expand_vision_messages(&mut msgs).unwrap();
        let blocks = msgs[0]["content"].as_array().unwrap();
        assert_eq!(blocks.len(), 2);
        assert_eq!(blocks[0]["type"], "tool_result");
        assert_eq!(blocks[1]["source"]["data"], "Ymxr");
        let _ = fs::remove_dir_all(&dir);
    }
}
