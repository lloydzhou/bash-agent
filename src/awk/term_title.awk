# Read stats.json and format terminal title: \033]0;... \007
# Usage: awk -v model="..." -f term_title.awk stats.json
function fmt(n,  s,r) {
    s = sprintf("%d", n)
    while (length(s) > 3) {
        r = "," substr(s, length(s)-2) r
        s = substr(s, 1, length(s)-3)
    }
    return s r
}
function pct(num, den) {
    if (den + 0 > 0) return sprintf("%.0f%%", num / den * 100)
    return "—"
}
function jnum(line, key,  pat) {
    pat = "\"" key "\":[0-9]+"
    if (match(line, pat))
        return substr(line, RSTART + length(key) + 3, RLENGTH - length(key) - 3) + 0
    return 0
}
BEGIN { }
NR == 1 {
    t  = jnum($0, "current_turn_count")
    r  = jnum($0, "agent_request_count")
    i  = jnum($0, "total_input_tokens")
    o  = jnum($0, "total_output_tokens")
    c  = jnum($0, "current_context_tokens")
    cr = jnum($0, "total_cache_read_tokens")
}
END {
    prefix = (status == "idle") ? "" : "⏳ "
    printf "\033]0;%s%s T:%s R:%s I:%s(%s) O:%s C:%s\007", \
        prefix, model, fmt(t), fmt(r), fmt(i+cr), pct(cr, cr+i), fmt(o), fmt(c) > "/dev/stderr"
}
