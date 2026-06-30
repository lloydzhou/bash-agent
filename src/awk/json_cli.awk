# json_cli.awk — Small CLI-style entrypoints built on top of json.awk helpers.

BEGIN {
    if (json_mode == "escape_string") {
        if ((getline json_input) < 0) {
            json_input = ""
        } else {
            while ((getline _line) > 0) {
                json_input = json_input "\n" _line
            }
        }
        printf "%s", escape_json_string(json_input)
        exit 0
    }

    if (json_mode == "extract_field") {
        if (json_input == "") {
            if ((getline json_input) < 0) json_input = ""
        }
        raw = extract_value(json_input, json_field_key)
        if (raw == "") {
            print ""
            exit 0
        }
        if (substr(raw, 1, 1) == "\"" && substr(raw, length(raw), 1) == "\"") {
            print unescape_json_string(substr(raw, 2, length(raw) - 2))
        } else {
            print json_trim(raw)
        }
        exit 0
    }

    if (json_mode == "extract_field_raw") {
        if (json_input == "") {
            if ((getline json_input) < 0) json_input = ""
        }
        raw = extract_value(json_input, json_field_key)
        if (raw == "") {
            print ""
            exit 0
        }
        print json_trim(raw)
        exit 0
    }
}
