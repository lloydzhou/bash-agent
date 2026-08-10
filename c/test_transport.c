/* test_transport.c — Responses transport focused tests */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Include implementation to exercise the private Responses SSE adapter directly. */
#include "transport.c"

typedef struct {
    SseEvent events[8];
    int count;
} Capture;

static void capture_event(void *ctx, const SseEvent *evt) {
    Capture *capture = ctx;
    if (capture->count >= 8) return;
    SseEvent *out = &capture->events[capture->count++];
    *out = *evt;
    out->content = evt->content ? util_strdup(evt->content) : NULL;
    out->tool_id = evt->tool_id ? util_strdup(evt->tool_id) : NULL;
    out->tool_name = evt->tool_name ? util_strdup(evt->tool_name) : NULL;
    out->tool_input = evt->tool_input ? util_strdup(evt->tool_input) : NULL;
}

static void capture_free(Capture *capture) {
    for (int i = 0; i < capture->count; i++) {
        FREE_PTR(capture->events[i].content);
        FREE_PTR(capture->events[i].tool_id);
        FREE_PTR(capture->events[i].tool_name);
        FREE_PTR(capture->events[i].tool_input);
    }
}

static int failures = 0;

static void check(int condition, const char *label) {
    if (condition) {
        printf("PASS: %s\n", label);
    } else {
        fprintf(stderr, "FAIL: %s\n", label);
        failures++;
    }
}

int main(void) {
    Capture capture = {0};
    StreamCtx stream = {0};
    stream.callback = capture_event;
    stream.ctx = &capture;

    const char *item = "{\"output_index\":2,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"Read\"}}";
    const char *delta = "{\"item_id\":\"item_1\",\"delta\":\"{\\\"path\\\":\\\"/tmp/a\\\"}\"}";
    const char *completed = "{\"response\":{\"usage\":{\"input_tokens\":15,\"output_tokens\":8,\"cached_tokens\":4,\"input_tokens_details\":{\"cached_tokens\":6}}}}";
    parse_responses_sse_event(&stream, "response.output_item.added", item, strlen(item));
    parse_responses_sse_event(&stream, "response.function_call_arguments.delta", delta, strlen(delta));
    parse_responses_sse_event(&stream, "response.completed", completed, strlen(completed));

    check(capture.count == 3, "Responses completed emits tool, usage, stop");
    check(capture.events[0].type == SSE_TOOL_CALL && strcmp(capture.events[0].tool_name, "Read") == 0 && strcmp(capture.events[0].tool_id, "call_1") == 0 && strcmp(capture.events[0].tool_input, "{\"path\":\"/tmp/a\"}") == 0, "Responses maps item id and argument delta");
    check(capture.events[1].type == SSE_USAGE && capture.events[1].in_tokens == 9 && capture.events[1].out_tokens == 8 && capture.events[1].cache_read_tokens == 6, "Responses prefers nested cached tokens");
    check(capture.events[2].type == SSE_STOP && strcmp(capture.events[2].content, "tool_use") == 0, "Responses completed stops with tool use");
    capture_free(&capture);
    streamctx_free_openai_tools(&stream);

    memset(&capture, 0, sizeof(capture));
    memset(&stream, 0, sizeof(stream));
    stream.callback = capture_event;
    stream.ctx = &capture;
    const char *error = "{\"reason\":\"upstream failed\"}";
    parse_responses_sse_event(&stream, "error", error, strlen(error));
    check(capture.count == 3, "Responses error emits error, usage, stop");
    check(capture.events[0].type == SSE_ERROR && strcmp(capture.events[0].content, "upstream failed") == 0, "Responses error uses reason fallback");
    check(capture.events[1].type == SSE_USAGE, "Responses error emits usage event");
    check(capture.events[2].type == SSE_STOP && strcmp(capture.events[2].content, "error") == 0, "Responses error stops");
    capture_free(&capture);
    streamctx_free_openai_tools(&stream);

    memset(&capture, 0, sizeof(capture));
    memset(&stream, 0, sizeof(stream));
    stream.callback = capture_event;
    stream.ctx = &capture;
    const char *bare_error = "{}";
    parse_responses_sse_event(&stream, "error", bare_error, strlen(bare_error));
    check(capture.count == 3, "Responses bare error emits error, usage, stop");
    check(capture.events[0].type == SSE_ERROR && strcmp(capture.events[0].content, "Stream error") == 0, "Responses bare error uses stream error fallback");
    check(capture.events[1].type == SSE_USAGE, "Responses bare error emits zero usage event");
    check(capture.events[2].type == SSE_STOP && strcmp(capture.events[2].content, "error") == 0, "Responses bare error stops");
    capture_free(&capture);
    streamctx_free_openai_tools(&stream);

    return failures == 0 ? 0 : 1;
}
