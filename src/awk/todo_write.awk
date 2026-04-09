# Normalize todo_write input into a markdown checklist.
# Expects json_input to be the raw tool input object.

function parse_todos_array(arr,    i, c, depth, in_str, item, content, status, out, bs, in_progress_count) {
    out = ""
    depth = 0
    in_str = 0
    bs = 0
    item = ""
    in_progress_count = 0

    for (i = 2; i <= length(arr) - 1; i++) {
        c = substr(arr, i, 1)

        if (in_str) {
            item = item c
            if (c == "\\" && !bs) {
                bs = 1
            } else {
                if (c == "\"" && !bs) in_str = 0
                bs = 0
            }
            continue
        }

        if (c == "\"") {
            in_str = 1
            item = item c
            continue
        }

        if (c == "{") {
            depth++
            item = item c
            continue
        }

        if (c == "}") {
            depth--
            item = item c
            if (depth == 0) {
                content = extract_str(item, "content")
                status = extract_str(item, "status")
                if (content == "") {
                    print "Error: todo item content is required" > "/dev/stderr"
                    exit 1
                }
                if (status != "pending" && status != "in_progress" && status != "completed") {
                    print "Error: invalid todo status: " status > "/dev/stderr"
                    exit 1
                }
                if (status == "in_progress") in_progress_count++
                out = out "- [" ((status == "completed") ? "x" : " ") "] " content "\n"
                item = ""
            }
            continue
        }

        if (depth > 0) item = item c
    }

    if (in_progress_count > 1) {
        print "Error: todo_write allows at most one in_progress item" > "/dev/stderr"
        exit 1
    }

    sub(/\n$/, "", out)
    return out
}

BEGIN {
    if (json_input == "") {
        if ((getline json_input) < 0) json_input = ""
    }
    todos = extract_value(json_input, "todos")
    if (todos == "" || substr(todos, 1, 1) != "[") {
        print "Error: todos array is required" > "/dev/stderr"
        exit 1
    }
    print parse_todos_array(todos)
    exit 0
}
