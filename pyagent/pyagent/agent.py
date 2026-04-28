"""Agent loop — async orchestrate LLM calls, tool dispatch, display."""
import json
import sys

from pyagent.config import Config
from pyagent.protocol import parse_sse_lines
from pyagent.provider import llm_call_stream
from pyagent.session import (
    conv_add_user, conv_add_assistant, conv_add_tool_results,
    session_append_line, stats_update,
)
from pyagent.tools import dispatch_tool
from pyagent.display import (
    display_reset, display_text_delta, display_thinking,
    display_tool_call, display_tool_result, display_stop, display_error, display_usage,
)
from pyagent.compact import compact_if_needed
from pyagent.util import format_tool_result, tool_file_summary


def _emit_event(cfg: Config, event_obj: dict):
    """Write a single event to events.jsonl (matches bash-agent's msg_to_stream_event)."""
    if cfg.log_events and cfg.session_event_file:
        session_append_line(cfg, json.dumps(event_obj, separators=(",", ":")))


async def agent_loop(cfg: Config, user_input: str) -> str:
    """Run one agent loop: user_input → LLM → tools → ... → final text."""
    conv_add_user(cfg, user_input)
    _emit_event(cfg, {"type": "text", "content": user_input})

    display_reset()

    final_text = ""
    turn = 0

    while turn < cfg.max_turns:
        turn += 1
        text_parts: list[str] = []
        thinking_parts: list[str] = []
        tool_calls: list[tuple] = []          # (name, id, input_json)
        tool_conv_results: list[tuple] = []   # (tool_use_id, result_for_conv)
        current_tool_name = ""
        current_tool_id = ""
        current_tool_input = ""
        usage_input = 0
        usage_output = 0
        cache_read_tokens = 0
        cache_creation_tokens = 0
        stop_reason = ""

        try:
            stream = llm_call_stream(cfg)
        except Exception as e:
            display_error(cfg, str(e))
            _emit_event(cfg, {"type": "error", "message": str(e)})
            return final_text

        async for evt in parse_sse_lines(cfg.provider, stream):
            if cfg.interrupt_requested:
                cfg.interrupt_requested = False
                display_stop(cfg, "interrupted")
                _emit_event(cfg, {"type": "stop", "reason": "interrupted"})
                return final_text

            if evt.event_type == "text_delta":
                text_parts.append(evt.text)
                display_text_delta(cfg, evt.text)
                _emit_event(cfg, {"type": "text", "content": evt.text})

            elif evt.event_type == "thinking":
                thinking_parts.append(evt.thinking)
                display_thinking(cfg, evt.thinking)
                _emit_event(cfg, {"type": "thinking", "content": evt.thinking})

            elif evt.event_type == "tool_use":
                if current_tool_name:
                    tool_calls.append((current_tool_name, current_tool_id, current_tool_input))
                current_tool_name = evt.tool_name
                current_tool_id = evt.tool_id
                current_tool_input = evt.tool_input_json or ""

            elif evt.event_type == "tool_use_delta":
                current_tool_input += evt.tool_input_json

            elif evt.event_type == "content_block_stop":
                if current_tool_name:
                    tool_calls.append((current_tool_name, current_tool_id, current_tool_input))
                    try:
                        preview_params = json.loads(current_tool_input) if current_tool_input else {}
                    except json.JSONDecodeError:
                        preview_params = {}
                    display_tool_call(cfg, current_tool_name, current_tool_id, preview_params)
                    _emit_event(cfg, {
                        "type": "tool_call",
                        "name": current_tool_name,
                        "id": current_tool_id,
                        "input": current_tool_input,
                    })

                    # ── C1: Execute tool inline during streaming (like bash-agent) ──
                    try:
                        params = json.loads(current_tool_input) if current_tool_input else {}
                    except json.JSONDecodeError:
                        params = {}

                    result = await dispatch_tool(current_tool_name, params, cfg)

                    # C6: Apply format_tool_result uniformly
                    result = format_tool_result(result, cfg.tool_result_max_bytes)

                    # C5: For Edit, store only first line in conversation
                    result_for_conv = result
                    if current_tool_name == "Edit":
                        result_for_conv = result.split("\n")[0] if result else ""

                    tool_conv_results.append((current_tool_id, result_for_conv))

                    # Prepend file summary header for Read/Write
                    display_result = result
                    if current_tool_name in ("Read", "Write"):
                        summary_path = params.get("path", "")
                        summary = tool_file_summary(current_tool_name, summary_path)
                        if summary:
                            display_result = summary + "\n" + result

                    display_tool_result(cfg, current_tool_name, current_tool_id, display_result)
                    _emit_event(cfg, {
                        "type": "tool_result",
                        "tool_use_id": current_tool_id,
                        "name": current_tool_name,
                        "content": display_result,
                    })

                    current_tool_name = ""
                    current_tool_id = ""
                    current_tool_input = ""

            elif evt.event_type == "message_start":
                usage_input += evt.usage_input
                usage_output += evt.usage_output
                cache_read_tokens += getattr(evt, "cache_read_tokens", 0)
                cache_creation_tokens += getattr(evt, "cache_creation_tokens", 0)

            elif evt.event_type == "message_delta":
                usage_output += evt.usage_output
                cache_read_tokens += getattr(evt, "cache_read_tokens", 0)
                cache_creation_tokens += getattr(evt, "cache_creation_tokens", 0)
                stop_reason = evt.stop_reason or stop_reason

            elif evt.event_type == "message_stop":
                pass

            elif evt.event_type == "error":
                display_error(cfg, evt.error_msg)
                _emit_event(cfg, {"type": "error", "message": evt.error_msg})
                return final_text

        # Handle remaining tool (shouldn't happen, but safety)
        if current_tool_name:
            tool_calls.append((current_tool_name, current_tool_id, current_tool_input))

        text = "".join(text_parts)
        thinking = "".join(thinking_parts)
        final_text = text

        # Emit USAGE event with separate cache_read/cache_creation fields
        if usage_input or usage_output:
            display_usage(cfg, usage_input, usage_output, cache_read_tokens, cache_creation_tokens)
            _emit_event(cfg, {
                "type": "usage",
                "input_tokens": usage_input,
                "output_tokens": usage_output,
                "cache_read_input_tokens": cache_read_tokens,
                "cache_creation_input_tokens": cache_creation_tokens,
            })

        # C3: Fatal stop reasons exit immediately
        if stop_reason in ("max_tokens", "length"):
            display_error(cfg, "Response truncated (max_tokens reached)")
            _emit_event(cfg, {"type": "stop", "reason": stop_reason})
            return final_text

        # Emit STOP event
        display_stop(cfg, stop_reason)
        _emit_event(cfg, {"type": "stop", "reason": stop_reason})

        # Persist assistant message and tool results
        conv_add_assistant(cfg, text, thinking, tool_calls)
        if tool_conv_results:
            conv_add_tool_results(cfg, tool_conv_results)

        # Update stats and compact
        if usage_input or usage_output:
            context_tokens = usage_input + usage_output
            stats_update(cfg,
                         agent_request_count="+1",
                         total_input_tokens=f"+{usage_input}",
                         total_output_tokens=f"+{usage_output}",
                         total_cache_read_tokens=f"+{cache_read_tokens}",
                         total_cache_creation_tokens=f"+{cache_creation_tokens}",
                         current_context_tokens=context_tokens)
            compact_if_needed(cfg, context_tokens)

        # Continue only if stop reason is tool_use or tool_calls
        if stop_reason not in ("tool_use", "tool_calls"):
            return final_text

    display_error(cfg, f"Max turns ({cfg.max_turns}) reached")
    return final_text
