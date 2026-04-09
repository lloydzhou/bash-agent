BEGIN {
    valid = 1
    count = 0
}

{
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^[[:space:]]*$/) {
        next
    }
    if (line !~ /^- \[[ xX]\] .+/) {
        valid = 0
        next
    }
    gsub(/^- \[X\] /, "- [x] ", line)
    lines[++count] = line
}

END {
    if (!valid || count == 0) {
        exit 1
    }
    for (i = 1; i <= count; i++) {
        print lines[i]
    }
}
