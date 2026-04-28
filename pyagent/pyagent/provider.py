"""Provider: build HTTP requests, call API with async streaming via aiohttp."""
import json

import aiohttp

from pyagent.config import Config
from pyagent.session import conv_get_messages
from pyagent.prompt import build_system_prompt, get_tool_defs_for_api


def resolve_api_url(cfg: Config) -> str:
    if cfg.api_url:
        return cfg.api_url
    if cfg.provider == "claude":
        if cfg.anthropic_base_url:
            return f"{cfg.anthropic_base_url.rstrip('/')}/messages"
        return "https://api.anthropic.com/v1/messages"
    else:
        if cfg.openai_base_url:
            return f"{cfg.openai_base_url.rstrip('/')}/chat/completions"
        return "https://api.openai.com/v1/chat/completions"


def resolve_api_key(cfg: Config) -> str:
    if cfg.api_key:
        return cfg.api_key
    if cfg.provider == "claude":
        return cfg.anthropic_api_key
    return cfg.openai_api_key


def resolve_model(cfg: Config) -> str:
    if cfg.model:
        return cfg.model
    if cfg.provider == "claude":
        return "claude-sonnet-4-20250514"
    return "gpt-4o"


def build_request_claude(cfg: Config, messages: list) -> dict:
    model = resolve_model(cfg)
    tools = get_tool_defs_for_api(cfg)
    body: dict = {
        "model": model,
        "max_tokens": cfg.max_tokens,
        "stream": True,
        "messages": messages,
    }
    if tools:
        body["tools"] = tools
    if cfg.thinking_budget > 0:
        body["thinking"] = {"type": "enabled", "budget_tokens": cfg.thinking_budget}
    return body


def build_request_openai(cfg: Config, messages: list) -> dict:
    model = resolve_model(cfg)
    tools = get_tool_defs_for_api(cfg)

    openai_msgs = []
    for msg in messages:
        role = msg["role"]
        content = msg.get("content", "")
        if role == "user" and isinstance(content, str):
            openai_msgs.append({"role": "user", "content": content})
            continue
        if role == "user" and isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    openai_msgs.append({
                        "role": "tool",
                        "tool_call_id": block["tool_use_id"],
                        "content": block["content"],
                    })
                elif isinstance(block, str):
                    openai_msgs.append({"role": "user", "content": block})
            continue
        if role == "assistant":
            if isinstance(content, str):
                openai_msgs.append({"role": "assistant", "content": content})
                continue
            text_parts = []
            tool_calls = []
            for block in content:
                if isinstance(block, str):
                    text_parts.append(block)
                elif isinstance(block, dict):
                    btype = block.get("type", "")
                    if btype == "text":
                        text_parts.append(block["text"])
                    elif btype == "tool_use":
                        tool_calls.append({
                            "id": block["id"],
                            "type": "function",
                            "function": {
                                "name": block["name"],
                                "arguments": json.dumps(block.get("input", {})),
                            }
                        })
                    elif "name" in block:
                        tool_calls.append({
                            "id": block.get("id", ""),
                            "type": "function",
                            "function": {
                                "name": block["name"],
                                "arguments": json.dumps(block.get("input", {})),
                            }
                        })
            msg_out: dict = {"role": "assistant"}
            if text_parts:
                msg_out["content"] = "\n".join(text_parts)
            if tool_calls:
                msg_out["tool_calls"] = tool_calls
            openai_msgs.append(msg_out)
            continue
        openai_msgs.append(msg)

    body: dict = {
        "model": model,
        "max_tokens": cfg.max_tokens,
        "stream": True,
        "messages": openai_msgs,
    }
    if tools:
        body["tools"] = tools
    if cfg.thinking_budget > 0:
        body["reasoning_effort"] = "high"
    return body


def _build_headers(cfg: Config) -> dict:
    key = resolve_api_key(cfg)
    if not key:
        raise RuntimeError(f"No API key configured for provider '{cfg.provider}'")

    headers = {
        "Content-Type": "application/json",
        "User-Agent": "claude-cli/1.0.33 (max, cli)",
        "x-app": "cli",
    }
    if cfg.provider == "claude":
        headers["x-api-key"] = key
        headers["anthropic-version"] = "2023-06-01"
    else:
        headers["Authorization"] = f"Bearer {key}"
    return headers


async def llm_call_stream(cfg: Config):
    """Async generator: build request, stream SSE, yield decoded text lines."""
    system_prompt = build_system_prompt(cfg)
    messages = conv_get_messages(cfg)

    if cfg.provider == "claude":
        body = build_request_claude(cfg, messages)
        body["system"] = system_prompt
    else:
        all_msgs = [{"role": "system", "content": system_prompt}] + messages
        body = build_request_openai(cfg, all_msgs)

    url = resolve_api_url(cfg)
    headers = _build_headers(cfg)

    async with aiohttp.ClientSession() as session:
        async with session.post(url, json=body, headers=headers) as resp:
            if resp.status != 200:
                text = await resp.text()
                raise RuntimeError(f"API HTTP {resp.status}: {text}")

            buf = b""
            async for chunk in resp.content.iter_any():
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    yield line.decode("utf-8", errors="replace")
            if buf:
                yield buf.decode("utf-8", errors="replace")
