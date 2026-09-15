# 每条会话记录只读取一次；编码后的图片不再进入本层结构解析。
function convert_text(text,    rest, cleaned, start, stop, section, lines, mapping, j, path, encoded, found, before) {
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
            encoded = encode_image(path)
            images = images ",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"" encoded "\"}}"
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
BEGIN {
    first = 1
    printf "["
    # 固定命令，仅经 shell 展开环境变量；root 只作位置参数，先做单引号转义。
    encoder = "bash -c \"$VISION_ENCODE_CODE\" _ "
    root = ENVIRON["VISION_ROOT"]
    qroot = shq(root)
}
length($0) {
    msg = $0
    if (vision != "on") {
        printf "%s%s", (first ? "" : ","), msg
        first = 0
        next
    }
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
    printf "%s%s", (first ? "" : ","), msg
    first = 0
}
END { if (!failed) printf "]" }

function encode_image(path,    data, cmd, status, rc) {
    # 附件路径被单引号包裹后仅作为位置参数，绝不进入命令语法位置。
    cmd = encoder qroot " " shq(path)
    # 读到数据不代表编码成功：还须检查子进程退出状态，防止发送截断图片。
    status = (cmd | getline data)
    rc = close(cmd)
    if (status != 1 || rc != 0 || data == "") {
        failed = 1
        exit 1
    }
    return data
}

# 将任意字符串安全包裹为单引号字面量：内嵌单引号替换为 '\''，shell 元字符全部字面化。
function shq(s,    t, head) {
    t = ""
    while ((head = index(s, "'"))) {
        t = t substr(s, 1, head - 1) "'\\''"
        s = substr(s, head + 1)
    }
    return "'" t s "'"
}
