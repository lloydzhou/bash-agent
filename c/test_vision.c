/* test_vision.c — Vision image block expansion and provider conversion tests */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "util.h"
#include "json.h"
#include "transport.h"

static int failures = 0;

static void check(int condition, const char *label) {
    if (condition) printf("PASS: %s\n", label);
    else { fprintf(stderr, "FAIL: %s\n", label); failures++; }
}

static void test_base64_roundtrip(void) {
    const char raw[] = "\x89PNG\r\n\x1a\nhello";
    size_t raw_len = sizeof(raw) - 1;
    char *b64 = util_base64_encode((const unsigned char *)raw, raw_len);
    check(b64 && strcmp(b64, "iVBORw0KGgpoZWxsbw==") == 0, "base64 编码结果正确");
    free(b64);
}

static void test_build_claude_request_vision_off(void) {
    char *lines[] = {
        "{\"role\":\"user\",\"content\":\"hello\"}"
    };
    char *out = build_claude_request("claude-test", "sys", "[]", lines, 1, 1024, "disabled", NULL, "off");
    check(out != NULL && strstr(out, "hello") != NULL, "vision off 时原样输出");
    free(out);
}

static void test_build_claude_request_no_mapping(void) {
    char *lines[] = {
        "{\"role\":\"user\",\"content\":\"no images here\"}"
    };
    char *out = build_claude_request("claude-test", "sys", "[]", lines, 1, 1024, "disabled", NULL, "on");
    check(out != NULL && strstr(out, "no images here") != NULL, "无映射消息不被改写");
    free(out);
}

static void test_build_claude_request_missing_image_fails(void) {
    char *lines[] = {
        "{\"role\":\"user\",\"content\":\"look\\n\\n<attached-images>\\n[Image #1] => /tmp/nonexistent/images/1.png\\n</attached-images>\"}"
    };
    char *out = build_claude_request("claude-test", "sys", "[]", lines, 1, 1024, "disabled", NULL, "on");
    check(out == NULL, "附件读取失败整体返回 NULL");
}

static void test_convert_to_openai_with_image(void) {
    const char *claude_body = "{\"model\":\"claude-test\",\"max_tokens\":1024,\"stream\":true,\"system\":\"sys\",\"tools\":[],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"look\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"ABC\"}}]}]}";
    char *out = convert_to_openai(claude_body);
    check(out != NULL && strstr(out, "image_url") != NULL && strstr(out, "data:image/png;base64,ABC") != NULL, "OpenAI 转换含 image_url 数据 URL");
    free(out);
}

static void test_convert_to_responses_with_image(void) {
    const char *claude_body = "{\"model\":\"claude-test\",\"max_tokens\":1024,\"stream\":true,\"system\":\"sys\",\"tools\":[],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"look\"},{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"ABC\"}}]}]}";
    char *out = convert_to_responses(claude_body);
    check(out != NULL && strstr(out, "input_image") != NULL && strstr(out, "data:image/png;base64,ABC") != NULL, "Responses 转换含 input_image 数据 URL");
    free(out);
}

int main(void) {
    test_base64_roundtrip();
    test_build_claude_request_vision_off();
    test_build_claude_request_no_mapping();
    test_build_claude_request_missing_image_fails();
    test_convert_to_openai_with_image();
    test_convert_to_responses_with_image();
    if (failures) { fprintf(stderr, "\n%d 个测试失败\n", failures); return 1; }
    printf("\n全部通过\n");
    return 0;
}
