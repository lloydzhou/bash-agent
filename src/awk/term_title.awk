# Read stats file and format terminal title: \033]0;... \007
# Usage: awk -v model="..." -f term_title.awk stats_file
BEGIN { FS = "\t" }
$1 == "current_turn_count"       { t = $2 + 0 }
$1 == "agent_request_count"      { r = $2 + 0 }
$1 == "total_input_tokens"       { i = $2 + 0 }
$1 == "total_output_tokens"      { o = $2 + 0 }
$1 == "current_context_tokens"   { c = $2 + 0 }
$1 == "total_cache_read_tokens"  { cr = $2 + 0 }
END {
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
    printf "\033]0;%s T:%s R:%s I:%s(%s) O:%s C:%s\007", \
        model, fmt(t), fmt(r), fmt(i+cr), pct(cr, cr+i), fmt(o), fmt(c) > "/dev/stderr"
}
