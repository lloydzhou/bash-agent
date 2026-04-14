# skill_summary.awk — Extract a short summary from SKILL.md
# Simply grep the "description:" line - it's the fastest and most reliable

/^description:/ {
    sub(/^description:[[:space:]]*/, "")
    gsub(/^[[:space:]]*"[[:space:]]*|[[:space:]]*"[[:space:]]*$/, "")
    gsub(/^[[:space:]]*'"'"'[[:space:]]*|[[:space:]]*'"'"'[[:space:]]*$/, "")
    print $0
    exit
}
