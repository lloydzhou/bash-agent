BEGIN {
    if (json_input == "") {
        if ((getline json_input) < 0) json_input = ""
    }

    RS = sprintf("%c", 1)
    ORS = ""

    path = extract_str(json_input, "path")
    old = extract_str(json_input, "old_string")
    new = extract_str(json_input, "new_string")

    if (path == "") {
        print "no path provided" > "/dev/stderr"
        exit 2
    }
    if (old == "") {
        print "empty old_string" > "/dev/stderr"
        exit 2
    }

    rc = (getline data < path)
    close(path)
    if (rc < 0) {
        print "file not found: " path > "/dev/stderr"
        exit 2
    }

    i = index(data, old)
    if (i == 0) {
        print "old_string not found in " path ". Hint: use Grep to locate the target lines, then Read the relevant portion (with offset/limit) to copy the exact text before retrying Edit." > "/dev/stderr"
        exit 2
    }

    printf "%s%s%s", substr(data, 1, i - 1), new, substr(data, i + length(old))
    exit 0
}
