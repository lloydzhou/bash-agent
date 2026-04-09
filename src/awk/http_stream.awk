# http_stream.awk — Split curl's HTTP headers/body stream and normalize errors

BEGIN {
    http_code = ""
    in_body = 0
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
    if (http_code >= 400) {
        printf "ERROR:HTTP %s\n", http_code
        exit 1
    }
    in_body = 1
    next
}

!in_body { next }

# Handle non-SSE JSON error responses (e.g., {"code":500,"msg":"..."})
in_body && /^{/ && /"code"/ && /"msg"/ {
    printf "ERROR:API response body received\n"
    exit 1
}

{
    print
    fflush()
}
