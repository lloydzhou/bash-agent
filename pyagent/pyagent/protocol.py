"""SSE protocol parsing — async generator consuming lines, yielding ParsedEvents."""
import json
from dataclasses import dataclass


@dataclass
class ParsedEvent:
    """Normalized event from SSE stream."""
    event_type: str = ""       # text_delta | tool_use | thinking | message_start | message_delta | message_stop | error
    text: str = ""
    thinking: str = ""
    tool_name: str = ""
    tool_id: str = ""
    tool_input_json: str = ""
    usage_input: int = 0
    usage_output: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0
    stop_reason: str = ""
    error_msg: str = ""


def parse_sse_line_claude(event_name: str, data: str) -> ParsedEvent | None:
    """Parse a single SSE event from Claude's streaming API (pure, sync)."""
    if not data or data == "[DONE]":
        return None
    try:
        obj = json.loads(data)
    except json.JSONDecodeError:
        return None

    evt = ParsedEvent()

    if event_name == "message_start":
        evt.event_type = "message_start"
        msg = obj.get("message", obj)
        usage = msg.get("usage", {})
        evt.usage_input = usage.get("input_tokens", 0)
        evt.usage_output = usage.get("output_tokens", 0)
        evt.cache_read_tokens = usage.get("cache_read_input_tokens", 0)
        evt.cache_creation_tokens = usage.get("cache_creation_input_tokens", 0)
        return evt

    if event_name == "content_block_start":
        block = obj.get("content_block", {})
        btype = block.get("type", "")
        if btype == "tool_use":
            evt.event_type = "tool_use"
            evt.tool_name = block.get("name", "")
            evt.tool_id = block.get("id", "")
            evt.tool_input_json = ""
            return evt
        if btype == "thinking":
            evt.event_type = "thinking"
            return evt
        return None

    if event_name == "content_block_delta":
        delta = obj.get("delta", {})
        dtype = delta.get("type", "")
        if dtype == "text_delta":
            evt.event_type = "text_delta"
            evt.text = delta.get("text", "")
            return evt
        if dtype == "thinking_delta":
            evt.event_type = "thinking"
            evt.thinking = delta.get("thinking", "")
            return evt
        if dtype == "input_json_delta":
            evt.event_type = "tool_use_delta"
            evt.tool_input_json = delta.get("partial_json", "")
            return evt
        return None

    if event_name == "content_block_stop":
        evt.event_type = "content_block_stop"
        return evt

    if event_name == "message_delta":
        evt.event_type = "message_delta"
        delta = obj.get("delta", {})
        evt.stop_reason = delta.get("stop_reason", "")
        usage = obj.get("usage", {})
        evt.usage_output = usage.get("output_tokens", 0)
        evt.cache_read_tokens = usage.get("cache_read_input_tokens", 0)
        evt.cache_creation_tokens = usage.get("cache_creation_input_tokens", 0)
        return evt

    if event_name == "message_stop":
        evt.event_type = "message_stop"
        return evt

    if event_name == "error":
        evt.event_type = "error"
        evt.error_msg = obj.get("error", {}).get("message", str(obj))
        return evt

    return None


def parse_sse_line_openai(event_name: str, data: str) -> ParsedEvent | None:
    """Parse a single SSE event from OpenAI-compatible streaming API (pure, sync)."""
    if not data or data == "[DONE]":
        return None
    try:
        obj = json.loads(data)
    except json.JSONDecodeError:
        return None

    evt = ParsedEvent()
    choices = obj.get("choices", [])
    if not choices:
        return None

    choice = choices[0]
    delta = choice.get("delta", {})
    finish_reason = choice.get("finish_reason")

    if finish_reason == "stop":
        evt.event_type = "message_stop"
        evt.stop_reason = "stop"
        return evt

    if finish_reason == "tool_calls":
        evt.event_type = "message_stop"
        evt.stop_reason = "tool_calls"
        return evt

    if "content" in delta and delta["content"] is not None:
        evt.event_type = "text_delta"
        evt.text = delta["content"]
        return evt

    if "tool_calls" in delta:
        tcs = delta["tool_calls"]
        for tc in tcs:
            if "function" in tc:
                fn = tc["function"]
                if "name" in fn and fn["name"]:
                    evt.event_type = "tool_use"
                    evt.tool_name = fn["name"]
                    evt.tool_id = tc.get("id", "")
                    evt.tool_input_json = ""
                    return evt
                if "arguments" in fn and fn["arguments"]:
                    evt.event_type = "tool_use_delta"
                    evt.tool_input_json = fn["arguments"]
                    return evt
        return None

    if "role" in delta:
        evt.event_type = "message_start"
        return evt

    return None


async def parse_sse_lines(provider: str, line_iter):
    """Async generator: consume async iterable of SSE text lines, yield ParsedEvent."""
    current_event = ""
    current_data_parts: list[str] = []
    parser = parse_sse_line_claude if provider == "claude" else parse_sse_line_openai

    async for raw_line in line_iter:
        line = raw_line.rstrip("\n").rstrip("\r")

        if line.startswith("event:"):
            current_event = line[6:].strip()
            current_data_parts = []
            continue

        if line.startswith("data:"):
            current_data_parts.append(line[5:].strip())
            continue

        if line == "":
            # end of SSE event
            if current_data_parts:
                data_str = "\n".join(current_data_parts)
                evt = parser(current_event, data_str)
                if evt:
                    yield evt
            current_event = ""
            current_data_parts = []
            continue

        # non-prefixed line
        if line and not line.startswith(":"):
            current_data_parts.append(line)

    # flush last event
    if current_data_parts:
        data_str = "\n".join(current_data_parts)
        evt = parser(current_event, data_str)
        if evt:
            yield evt
