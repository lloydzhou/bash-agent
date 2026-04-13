BEGIN {
    if (json_input == "") {
        if ((getline json_input) < 0) json_input = ""
    }

    RS = "\0"
    ORS = ""

    path = extract_str(json_input, "path")
    old = extract_str(json_input, "old_string")
    new = extract_str(json_input, "new_string")

    if (path == "") {
        print "Error: no path provided" > "/dev/stderr"
        exit 2
    }
    if (old == "") {
        print "Error: empty old_string" > "/dev/stderr"
        exit 2
    }

    rc = (getline data < path)
    close(path)
    if (rc < 0) {
        print "Error: file not found: " path > "/dev/stderr"
        exit 2
    }

    if (length(data) > max_bytes) {
        print "Error: file too large for edit_file (" length(data) " bytes > " max_bytes " bytes)" > "/dev/stderr"
        exit 2
    }

    i = index(data, old)
    if (i == 0) {
        print "Error: old_string not found in " path ". Hint: Read the file and copy exact bytes (including whitespace/indent/newlines) before retrying Edit." > "/dev/stderr"
        exit 2
    }

    if (meta_file != "") {
        print path > meta_file
        close(meta_file)
    }

    printf "%s%s%s", substr(data, 1, i - 1), new, substr(data, i + length(old))
    exit 0
}
