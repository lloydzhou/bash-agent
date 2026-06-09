# sanitize_utf8.awk — 过滤非法 UTF-8 字节，替换为占位符
# 输入：可能包含任意字节的文本（LC_ALL=C 模式逐字节处理）
# 输出：合法 UTF-8 文本（非法字节替换为 \ufffd）
# 用途：tool_bash 输出过滤，防止二进制数据破坏后续 JSON 序列化
BEGIN { ORS = "" }
{
    n = split($0, bytes, "")
    i = 1
    while (i <= n) {
        b = bytes[i]
        if (b < "\200") {
            # ASCII (0x00-0x7F): 直接输出
            printf "%s", b
            i++
        } else if (b >= "\302" && b <= "\337") {
            # 2 字节序列: C2-DF + 80-BF
            if (i + 1 <= n && bytes[i + 1] >= "\200" && bytes[i + 1] <= "\277") {
                printf "%s%s", b, bytes[i + 1]
                i += 2
            } else {
                printf "\\ufffd"
                i++
            }
        } else if (b >= "\340" && b <= "\357") {
            # 3 字节序列: E0-EF + 80-BF + 80-BF
            if (i + 2 <= n && bytes[i + 1] >= "\200" && bytes[i + 1] <= "\277" && bytes[i + 2] >= "\200" && bytes[i + 2] <= "\277") {
                printf "%s%s%s", b, bytes[i + 1], bytes[i + 2]
                i += 3
            } else {
                printf "\\ufffd"
                i++
            }
        } else if (b >= "\360" && b <= "\364") {
            # 4 字节序列: F0-F4 + 80-BF + 80-BF + 80-BF
            if (i + 3 <= n && bytes[i + 1] >= "\200" && bytes[i + 1] <= "\277" && bytes[i + 2] >= "\200" && bytes[i + 2] <= "\277" && bytes[i + 3] >= "\200" && bytes[i + 3] <= "\277") {
                printf "%s%s%s%s", b, bytes[i + 1], bytes[i + 2], bytes[i + 3]
                i += 4
            } else {
                printf "\\ufffd"
                i++
            }
        } else {
            # 非法字节: C0-C1(过长编码), 80-BF(孤立 continuation), F5-FF(超范围)
            printf "\\ufffd"
            i++
        }
    }
    printf "\n"
}
