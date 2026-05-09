# http_stream.awk — Split curl's HTTP headers/body stream and normalize errors
# Handles curl --retry: multiple HTTP responses may appear on stdout.
# When a second HTTP response is detected, emits RETRY: and resets state.
# Error from retried responses is swallowed; only the final response's error
# is emitted at EOF (because ERROR is just a type of terminal STOP).

BEGIN {
    http_code = ""
    in_body = 0
    error_body = ""
}

{
    sub(/\r$/, "")
}

/^curl: / {
    printf "ERROR:0\t%s\n", $0
    fflush()
    exit 1
}

/^HTTP\// {
    if (in_body) {
        # curl retry: second HTTP response detected while still in body
        printf "RETRY:\n"
        fflush()
    }
    http_code = $2
    in_body = 0
    error_body = ""
    next
}

/^[ \t]*$/ && !in_body {
    in_body = 1
    next
}

!in_body { next }

in_body && http_code >= 400 {
    if (error_body != "") error_body = error_body "\n"
    error_body = error_body $0
    next
}

{
    print
    fflush()
}

END {
    if (http_code >= 400) {
        if (error_body == "") error_body = "(empty)"
        printf "ERROR:%s\tHTTP %s: %s\n", http_code, http_code, error_body
        fflush()
    }
}
