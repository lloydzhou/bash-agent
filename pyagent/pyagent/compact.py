"""Context window compaction — summarize old messages when context grows too large."""
import json
import os

from pyagent.config import Config
from pyagent.session import conv_get_messages


def estimate_context_bytes(messages: list) -> int:
    """Rough byte estimate of all messages."""
    total = 0
    for msg in messages:
        total += len(json.dumps(msg, ensure_ascii=False))
    return total


def _find_keep_from_turn_boundary(messages: list, target_keep_bytes: int) -> int:
    """Find how many messages to keep from the end, aligned to a user-message turn boundary.

    Matches bash-agent's compact_keep_lines: scans from end accumulating bytes
    until exceeding target, then advances to next user message boundary.
    Returns the number of messages to keep.
    """
    n = len(messages)
    if n == 0:
        return 0

    # Scan from end, accumulating bytes
    keep = 0
    total_bytes = 0
    for i in range(n - 1, -1, -1):
        msg_bytes = len(json.dumps(messages[i], ensure_ascii=False)) + 1
        if keep > 0 and total_bytes + msg_bytes > target_keep_bytes:
            break
        total_bytes += msg_bytes
        keep += 1

    if keep == 0:
        keep = 1

    # Adjust start to align to next user message boundary
    start = n - keep
    adjusted = start
    while adjusted < n:
        msg = messages[adjusted]
        role = msg.get("role", "")
        content = msg.get("content", "")
        # User message with string content starts a turn
        if role == "user" and isinstance(content, str):
            break
        if role == "user" and isinstance(content, list):
            # User message with tool results — also a valid boundary
            break
        adjusted += 1

    if adjusted < n:
        start = adjusted

    return n - start


def compact_if_needed(cfg: Config, context_tokens: int | None = None) -> bool:
    """Check if context is too large; if so, summarize older messages.

    Uses context_tokens (input_tokens + output_tokens from last API call)
    as the threshold metric. Returns True if compaction was performed.

    When context_tokens is None or 0, skip compact (new session).
    """
    if context_tokens is None or context_tokens <= 0:
        return False

    if context_tokens <= cfg.max_context_tokens:
        return False

    messages = conv_get_messages(cfg)
    if not messages:
        return False

    # Read existing summary
    summary = ""
    if os.path.exists(cfg.context_summary_file):
        with open(cfg.context_summary_file, "r", encoding="utf-8") as f:
            summary = f.read()

    # Find keep count aligned to turn boundaries
    target_keep_bytes = cfg.max_context_bytes * cfg.max_context_keep_pct // 100
    keep_count = _find_keep_from_turn_boundary(messages, target_keep_bytes)
    keep_count = max(2, keep_count)

    old_messages = messages[:-keep_count]
    recent_messages = messages[-keep_count:]

    if not old_messages:
        return False

    # Build summary of old messages
    old_text_parts = []
    for msg in old_messages:
        role = msg.get("role", "")
        content = msg.get("content", "")
        if isinstance(content, str):
            old_text_parts.append(f"[{role}]: {content[:500]}")
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    btype = block.get("type", "text")
                    if btype == "text":
                        old_text_parts.append(f"[{role}]: {block.get('text', '')[:500]}")
                    elif btype == "tool_result":
                        old_text_parts.append(f"[tool_result]: {block.get('content', '')[:300]}")
                    elif btype == "tool_use":
                        old_text_parts.append(f"[tool_use:{block.get('name', '')}]")

    old_summary = "\n".join(old_text_parts)
    new_summary = (summary + "\n\n--- Compacted ---\n" + old_summary) if summary else old_summary

    # Write summary file
    with open(cfg.context_summary_file, "w", encoding="utf-8") as f:
        f.write(new_summary)

    # Rewrite conversation file with only recent messages
    with open(cfg.conv_file, "w", encoding="utf-8") as f:
        for msg in recent_messages:
            f.write(json.dumps(msg, ensure_ascii=False) + "\n")

    return True
