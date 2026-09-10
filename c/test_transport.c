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

/* 走实际逐行解析器，分别检查提前 STOP、协议终结和最终 HTTP 门槛。 */
static void feed_stream(StreamCtx *stream, const char *wire) {
    check(stream_cb((char *)wire, 1, strlen(wire), stream) == strlen(wire), "流数据完整接收");
}

static void test_speed_completion(void) {
    SseAccumulator acc;
    sse_accum_init(&acc);
    StreamCtx stream = {0};
    stream.callback = sse_accum_callback;
    stream.ctx = &acc;
    stream.provider = "claude";
    sb_init(&stream.line_buf);

    feed_stream(&stream, "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":10}}\n\n");
    check(acc.stopped && !acc.speed_ready, "提前停止原因不是最终用量");
    check(!stream_speed_ready(&stream, CURLE_OK, 200), "Claude 有停止原因但缺少 message_stop 的提前 EOF 保留速度");
    feed_stream(&stream, "data: {\"type\":\"message_stop\"}\n\n");
    check(stream_speed_ready(&stream, CURLE_OK, 200), "Claude 完整终结且 HTTP 成功允许更新");
    check(!acc.speed_ready, "仅协议终结尚未发最终用量时不更新");
    check(!stream_speed_ready(&stream, CURLE_PARTIAL_FILE, 200), "协议完整但 HTTP 截断保留速度");
    check(!stream_speed_ready(&stream, CURLE_OK, 401), "HTTP 失败保留速度");
    volatile int cancelled = 1;
    stream.cancelled = &cancelled;
    check(!stream_speed_ready(&stream, CURLE_OK, 200), "协议终结后取消仍保留速度");
    check(!stream_speed_ready(&stream, CURLE_WRITE_ERROR, 200), "取消引发写入错误保留速度");
    emit_simple_event(stream.callback, stream.ctx, SSE_STOP, "interrupted");
    check(acc.stopped && !acc.speed_ready, "中断 STOP 不允许更新速度");
    stream.cancelled = NULL;

    SseEvent final_usage = {0};
    final_usage.type = SSE_USAGE;
    final_usage.speed_ready = stream_speed_ready(&stream, CURLE_OK, 200);
    final_usage.end_ms = 100;
    sse_accum_callback(&acc, &final_usage);
    check(acc.speed_ready && acc.out_tokens == 10, "最终用量允许更新且保留累计 token");
    emit_simple_event(stream.callback, stream.ctx, SSE_RETRY, NULL);
    check(!acc.speed_ready && acc.out_tokens == 0, "重试清除速度门槛及用量");
    sb_free(&stream.line_buf);

    /* 与传输重试一样，每次尝试使用全新的上下文。 */
    memset(&stream, 0, sizeof(stream));
    stream.callback = sse_accum_callback;
    stream.ctx = &acc;
    stream.provider = "openai";
    sb_init(&stream.line_buf);
    check(!stream_speed_ready(&stream, CURLE_OK, 200), "重试不继承协议终结状态");
    feed_stream(&stream, "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"finish_reason\":\"stop\"}]}\n\n");
    check(acc.stopped && !stream_speed_ready(&stream, CURLE_OK, 200), "OpenAI 有 finish_reason 但缺少 DONE 的提前 EOF 保留速度");
    feed_stream(&stream, "data: [DONE]\n\n");
    check(stream_speed_ready(&stream, CURLE_OK, 200), "OpenAI 完整终结允许更新");
    final_usage.speed_ready = stream_speed_ready(&stream, CURLE_OK, 200);
    sse_accum_callback(&acc, &final_usage);
    check(acc.speed_ready && acc.out_tokens == 0, "零用量成功仍允许清零速度");
    stream.protocol_complete = stream.openai_finished = 0;
    feed_stream(&stream, "data: [DONE]\n\n");
    check(!stream_speed_ready(&stream, CURLE_OK, 200), "仅 DONE 无 finish_reason 不更新");
    sb_free(&stream.line_buf);

    const char *failed_events[] = {"response.failed", "response.incomplete"};
    for (int i = 0; i < 2; i++) {
        memset(&stream, 0, sizeof(stream));
        stream.callback = sse_accum_callback;
        stream.ctx = &acc;
        parse_responses_sse_event(&stream, failed_events[i], "{}", 2);
        check(stream.responses_terminal && !stream_speed_ready(&stream, CURLE_OK, 200),
            "Responses 失败或不完整终结保留速度");
        streamctx_free_openai_tools(&stream);
    }
    sse_accum_free(&acc);
}

int main(void) {
    test_speed_completion();
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

    check(stream_speed_ready(&stream, CURLE_OK, 200), "Responses completed 允许最终用量更新速度");
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
    check(!stream_speed_ready(&stream, CURLE_OK, 200), "Responses 错误终结不更新速度");
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
