# skill_summary.awk — Extract a short summary from SKILL.md

BEGIN {
    heading = ""
    summary = ""
}

{
    line = $0

    if (heading == "" && line ~ /^#[[:space:]]+/) {
        sub(/^#[[:space:]]+/, "", line)
        heading = line
        next
    }

    if (line ~ /^[[:space:]]*$/) next

    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
    if (line != "") {
        summary = line
        exit
    }
}

END {
    if (summary != "") print summary
    else if (heading != "") print heading
}
