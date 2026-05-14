BEGIN {
    _init_fields()

    if (action == "get" && ARGC > 1) {
        filepath = ARGV[1]
        ARGV[1] = ""
        _read_file(filepath)
        if (key != "") {
            print _vals[key]
        }
        exit
    }

    if (action == "dump" && ARGC > 1) {
        _read_file(ARGV[1])
        _dump()
        ARGV[1] = ""
        exit
    }

    if (action == "sync" && ARGC > 1) {
        filepath = ARGV[1]
        ARGV[1] = ""
        for (i = 1; i <= _field_count; i++) {
            if ((getline line) > 0) {
                _vals[_field_keys[i]] = (line ~ /^[0-9]+$/) ? line + 0 : line
            }
        }
        _vals["last_updated"] = _now()
        _write_file(filepath)
        exit
    }

    if (action == "update" && ARGC > 1) {
        filepath = ARGV[1]
        ARGV[1] = ""
        _read_file(filepath)
        while ((getline line) > 0) {
            if (line == "") continue
            idx = index(line, "=")
            if (idx == 0) continue
            key = substr(line, 1, idx - 1)
            val = substr(line, idx + 1)
            if (substr(val, 1, 1) == "+") {
                _vals[key] += substr(val, 2) + 0
            } else if (val ~ /^[0-9]+$/) {
                _vals[key] = val + 0
            } else {
                _vals[key] = val
            }
        }
        _vals["last_updated"] = _now()
        _write_file(filepath)
        exit
    }
}

function _init_fields() {
    _field_keys[1] = "current_turn_count"
    _field_keys[2] = "agent_request_count"
    _field_keys[3] = "compact_request_count"
    _field_keys[4] = "total_input_tokens"
    _field_keys[5] = "total_output_tokens"
    _field_keys[6] = "total_cache_read_tokens"
    _field_keys[7] = "total_cache_creation_tokens"
    _field_keys[8] = "current_context_tokens"
    _field_keys[9] = "sub_agent_request_count"
    _field_keys[10] = "last_updated"
    _field_count = 10

    for (i = 1; i <= _field_count; i++) {
        _vals[_field_keys[i]] = (_field_keys[i] == "last_updated") ? "" : 0
    }
}

function _dump() {
    for (i = 1; i <= _field_count; i++) {
        print _field_keys[i] "\t" _vals[_field_keys[i]]
    }
}

function _read_file(file) {
    if ((getline line < file) <= 0) {
        close(file)
        return
    }
    close(file)
    for (i = 1; i <= _field_count; i++) {
        k = _field_keys[i]
        if (match(line, "\"" k "\":\"[^\"]*\"")) {
            vstart = RSTART + length(k) + 4
            _vals[k] = substr(line, vstart, RLENGTH - length(k) - 5)
        } else if (match(line, "\"" k "\":[0-9]+")) {
            vstart = RSTART + length(k) + 3
            _vals[k] = substr(line, vstart, RLENGTH - length(k) - 3) + 0
        }
    }
}

function _write_file(file) {
    line = "{"
    first = 1
    for (i = 1; i <= _field_count; i++) {
        k = _field_keys[i]
        v = _vals[k]
        if (!first) line = line ","
        first = 0
        if (k == "last_updated") {
            line = line "\"" k "\":\"" v "\""
        } else {
            line = line "\"" k "\":" v
        }
    }
    line = line "}"
    print line > file
    close(file)
}

function _now() {
    "date -u +%Y-%m-%dT%H:%M:%SZ" | getline ts
    close("date")
    if (ts == "") ts = "unknown"
    return ts
}
