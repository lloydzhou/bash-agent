# extract_sub_result.awk — Extract text content from sub-agent result
# Usage: echo '<json>' | awk -f json.awk -f extract_sub_result.awk

{ arr = $0 }
END {
    n = split_top_level_objects(arr, blocks)
    for (i = 1; i <= n; i++) {
        t = extract_str(blocks[i], "type")
        if (t == "text") {
            txt = extract_str(blocks[i], "text")
            if (txt != "") {
                if (out != "") out = out "\n"
                out = out txt
            }
        }
    }
    print out
}
