# todo_protocol.awk — TodoWrite-specific protocol formatting helpers.
# Uses positional wire format via emit1/emit/emit_flush from protocol.awk.

function parse_todos_array(arr,    i, c, depth, in_str, item, content, status, out, bs) {
    out = ""
    depth = 0
    in_str = 0
    bs = 0
    item = ""
    todo_completed_count = 0
    todo_total_count = 0
    todo_in_progress_count = 0

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
                todo_total_count++
                if (status == "completed") todo_completed_count++
                if (status == "in_progress") todo_in_progress_count++
                out = out "- [" ((status == "completed") ? "x" : " ") "] " content "\n"
                item = ""
            }
            continue
        }

        if (depth > 0) item = item c
    }

    if (todo_in_progress_count > 1) {
        print "Error: todo_write allows at most one in_progress item" > "/dev/stderr"
        exit 1
    }

    sub(/\n$/, "", out)
    return out
}

function emit_tool_call_record(name, id, input_json,    todos, checklist, summary) {
    if (name != "TodoWrite") {
        protocol_emit_tool_call_record(name, id, input_json)
        return
    }
    todos = extract_value(input_json, "todos")
    checklist = parse_todos_array(todos)
    summary = sprintf("%d/%d", todo_completed_count, todo_total_count)
    emit1("TOOL_CALL")
    emit(name)
    emit(id)
    emit(input_json)
    emit("checklist")
    emit(checklist)
    emit("summary")
    emit(summary)
    emit_flush()
}
