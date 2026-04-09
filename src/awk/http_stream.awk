# http_stream.awk — Split curl's HTTP headers/body stream and normalize errors

BEGIN {
    http_code = ""
    in_body = 0
    body = ""
}

{
    sub(/\r$/, "")
}

/^curl: / {
    printf "ERROR:%s\n", $0
    exit 1
}

/^HTTP\// {
    http_code = $2
    next
}

/^[ \t]*$/ && !in_body {
    in_body = 1
    next
}

!in_body { next }

in_body && http_code >= 400 {
    if (body != "") body = body "\n"
    body = body $0
    next
}

{
    print
    fflush()
}

END {
    if (http_code >= 400) {
        if (body == "") body = "(empty)"
        gsub(/\r/, "", body)
        printf "ERROR:HTTP %s BODY:%s\n", http_code, body
        fflush()
        exit 1
    }
}
