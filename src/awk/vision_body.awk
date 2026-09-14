function convert_text(text,    rest, cleaned, start, stop, section, lines, mapping, j, path, marker, found, before) {
    rest = text
    cleaned = ""
    while ((start = index(rest, "<attached-images>\n"))) {
        before = substr(rest, 1, start - 1)
        section = substr(rest, start + length("<attached-images>\n"))
        stop = index(section, "</attached-images>")
        if (!stop) break
        found = 0
        lines = split(substr(section, 1, stop - 1), mapping, "\n")
        for (j = 1; j <= lines; j++) {
            if (mapping[j] !~ /^\[Image #[0-9]+\] => \/.*\/images\/[0-9]+\.png$/) continue
            path = mapping[j]
            sub(/^\[Image #[0-9]+\] => /, "", path)
            marker = prefix (++image_count) "~"
            print marker "\t" path
            images = images ",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"" marker "\"}}"
            found = 1
        }
        if (found) {
            sub(/\n\n$/, "", before)
            cleaned = cleaned before
        } else cleaned = cleaned before "<attached-images>\n" substr(section, 1, stop + length("</attached-images>") - 1)
        rest = substr(section, stop + length("</attached-images>"))
    }
    return cleaned rest
}
{ raw = raw $0 }
END {
    messages = extract_value(raw, "messages")
    n = split_top_level_objects(messages, msgs)
    result = "["
    for (i = 1; i <= n; i++) {
        msg = msgs[i]
        content = extract_value(msg, "content")
        content_pos = JSON_VALUE_END - length(content) + 1
        images = ""
        if (extract_str(msg, "role") == "user") {
            if (substr(content, 1, 1) == "\"") {
                text = convert_text(unescape_json_string(substr(content, 2, length(content) - 2)))
                replacement = (text != "" ? "[{\"type\":\"text\",\"text\":\"" escape_json_string(text) "\"}]" : "[]")
            } else {
                count = split_top_level_objects(content, blocks)
                replacement = "["
                for (j = 1; j <= count; j++) {
                    block = blocks[j]
                    if (extract_str(block, "type") == "text") {
                        value = extract_value(block, "text")
                        pos = JSON_VALUE_END - length(value) + 1
                        text = convert_text(unescape_json_string(substr(value, 2, length(value) - 2)))
                        if (text == "") continue
                        block = substr(block, 1, pos - 1) "\"" escape_json_string(text) "\"" substr(block, pos + length(value))
                    }
                    replacement = replacement (replacement != "[" ? "," : "") block
                }
                replacement = replacement "]"
            }
        }
        if (images != "") {
            replacement = substr(replacement, 1, length(replacement) - 1) (replacement == "[]" ? substr(images, 2) : images) "]"
            pos = content_pos
            msg = substr(msg, 1, pos - 1) replacement substr(msg, pos + length(content))
        }
        result = result (i > 1 ? "," : "") msg
    }
    pos = index(raw, messages)
    print substr(raw, 1, pos - 1) result "]" substr(raw, pos + length(messages)) > (prefix "body")
}
