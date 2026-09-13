{ raw = raw $0 }
END {
    messages = extract_value(raw, "messages")
    n = split_top_level_objects(messages, msgs)
    result = "["
    for (i = 1; i <= n; i++) {
        msg = msgs[i]
        content = extract_value(msg, "content")
        content_pos = JSON_VALUE_END - length(content) + 1
        text = ""
        if (substr(content, 1, 1) == "\"") text = unescape_json_string(substr(content, 2, length(content) - 2))
        else {
            count = split_top_level_objects(content, blocks)
            for (j = 1; j <= count; j++)
                if (extract_str(blocks[j], "type") == "text") text = text "\n" extract_str(blocks[j], "text")
        }
        images = ""
        while (start = index(text, "<attached-images>\n")) {
            text = substr(text, start + length("<attached-images>\n"))
            stop = index(text, "</attached-images>")
            if (!stop) break
            section = substr(text, 1, stop - 1)
            text = substr(text, stop + length("</attached-images>"))
            lines = split(section, mapping, "\n")
            for (j = 1; j <= lines; j++) {
                if (mapping[j] !~ /^\[Image #[0-9]+\] => \/.*\/images\/[0-9]+\.png$/) continue
                path = mapping[j]
                sub(/^\[Image #[0-9]+\] => /, "", path)
                marker = prefix (++image_count) "~"
                print marker "\t" path
                images = images ",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"" marker "\"}}"
            }
        }
        if (images != "") {
            replacement = content
            if (substr(content, 1, 1) == "\"") replacement = "[{\"type\":\"text\",\"text\":" content "}]"
            replacement = substr(replacement, 1, length(replacement) - 1) images "]"
            pos = content_pos
            msg = substr(msg, 1, pos - 1) replacement substr(msg, pos + length(content))
        }
        result = result (i > 1 ? "," : "") msg
    }
    pos = index(raw, messages)
    print substr(raw, 1, pos - 1) result "]" substr(raw, pos + length(messages)) > (prefix "body")
}
