"""Utility functions — json escaping, formatting, size parsing."""
import json


def json_escape(s: str) -> str:
    """Escape a string for embedding inside a JSON string literal."""
    return json.dumps(s)[1:-1]


def parse_size_bytes(raw: str) -> int:
    """Parse human size like '200k', '10m', '1g' into bytes."""
    raw = raw.strip().lower()
    if raw.endswith("k"):
        return int(raw[:-1]) * 1000
    if raw.endswith("m"):
        return int(raw[:-1]) * 1000 * 1000
    if raw.endswith("g"):
        return int(raw[:-1]) * 1000 * 1000 * 1000
    return int(raw)


def format_tool_result(output: str, max_bytes: int = 50000) -> str:
    """Truncate tool output if too large, keeping head + tail with marker."""
    size = len(output)
    if size <= max_bytes:
        return output
    tail_lines = output.split("\n")
    tail_text = "\n".join(tail_lines[-5:])
    tail_len = len(tail_text)
    marker = f"\n\n[... truncated: showing first/last portions of {size} bytes ...]\n\n"
    marker_len = len(marker) + 20
    head_len = max_bytes - marker_len - tail_len
    if head_len <= 0:
        head_len = max_bytes // 2
    return output[:head_len] + marker + tail_text


def tool_file_summary(kind: str, path: str) -> str:
    """Return 'Read(path) [N lines, M bytes]' summary."""
    import os
    if not path or not os.path.isfile(path):
        return f"{kind}({path})"
    try:
        with open(path, "rb") as f:
            content = f.read()
        bytes_count = len(content)
        lines_count = content.count(b"\n") + (0 if content.endswith(b"\n") else 1)
    except Exception:
        bytes_count = 0
        lines_count = 0
    return f"{kind}({path}) [{lines_count} lines, {bytes_count} bytes]"


def new_session_id() -> str:
    from datetime import datetime
    import random
    now = datetime.now().strftime("%Y%m%d-%H%M%S")
    rand_part = format(random.randint(0, 0xFFFF), "04x")
    return f"{now}-{rand_part}"


def die(msg: str):
    import sys
    print(f"\033[31mError: {msg}\033[0m", file=sys.stderr)
    sys.exit(1)


def is_stream_json_mode(cfg) -> bool:
    return cfg.output_format == "stream-json"
