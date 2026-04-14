# skill_summary.awk — Extract a short summary from SKILL.md
# Prefer explicit `description:`; fallback to first meaningful body line.

{
    line = $0
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line == "") next

    if (line ~ /^description:/) {
        sub(/^description:[[:space:]]*/, "", line)
        gsub(/^[[:space:]]*"[[:space:]]*|[[:space:]]*"[[:space:]]*$/, "", line)
        gsub(/^[[:space:]]*'"'"'[[:space:]]*|[[:space:]]*'"'"'[[:space:]]*$/, "", line)
        print line
        found = 1
        exit
    }

    if (fallback == "" && line !~ /^#/ && line !~ /^---$/ && line !~ /^```/) {
        fallback = line
    }
}

END {
    if (!found && fallback != "") {
        print fallback
    }
}
