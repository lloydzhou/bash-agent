"""Session directory and conversation JSONL management."""
import os
import re
import json
from datetime import datetime

from pyagent.config import Config
from pyagent.util import new_session_id


def get_session_dir(cfg: Config) -> str:
    """Return project-specific session directory path."""
    cwd = os.path.abspath(os.getcwd())
    project_key = cwd.strip("/").replace("/", "-")
    project_key = re.sub(r"[^A-Za-z0-9._-]", "-", project_key)
    project_key = re.sub(r"-+", "-", project_key).strip("-")
    # Match bash-agent: prepend '-'
    project_key = f"-{project_key}"
    return os.path.join(cfg.bash_agent_home, ".bash-agent", "projects", project_key)


def get_latest_session_dir(cfg: Config) -> str | None:
    """Return the session ID of the most recently modified session."""
    project_dir = get_session_dir(cfg)
    if not os.path.isdir(project_dir):
        return None
    latest = None
    latest_ts = 0
    for entry in os.scandir(project_dir):
        if not entry.is_dir():
            continue
        try:
            ts = entry.stat().st_mtime
        except OSError:
            ts = 0
        if ts > latest_ts:
            latest_ts = ts
            latest = entry.name
    return latest


def conv_init(cfg: Config):
    """Initialize session directory and files."""
    if not cfg.session_id:
        cfg.session_id = new_session_id()
    project_dir = get_session_dir(cfg)
    session_dir = os.path.join(project_dir, cfg.session_id)
    os.makedirs(session_dir, exist_ok=True)

    cfg.conv_file = os.path.join(session_dir, "conversation.jsonl")
    cfg.session_event_file = os.path.join(session_dir, "events.jsonl")
    cfg.context_summary_file = os.path.join(session_dir, "summary.txt")
    cfg.todo_file = os.path.join(session_dir, "todo.md")
    cfg.plan_file = os.path.join(session_dir, "plan.md")
    cfg.stats_file = os.path.join(session_dir, "stats.json")

    new_session = (not os.path.exists(cfg.session_event_file)
                   or os.path.getsize(cfg.session_event_file) == 0)
    for f in [cfg.conv_file, cfg.session_event_file,
              cfg.context_summary_file, cfg.todo_file, cfg.plan_file]:
        if not os.path.exists(f):
            open(f, "a").close()

    from datetime import datetime, timezone
    if new_session:
        session_append_line(cfg, json.dumps(
            {"type": "session_start", "session_id": cfg.session_id},
            separators=(",", ":")))
        _init_stats(cfg.stats_file)
    elif not os.path.exists(cfg.stats_file) or os.path.getsize(cfg.stats_file) == 0:
        _init_stats(cfg.stats_file)


def session_append_line(cfg: Config, line: str):
    if cfg.session_event_file:
        with open(cfg.session_event_file, "a", encoding="utf-8") as f:
            # Normalize to compact JSON (no spaces after separators)
            try:
                obj = json.loads(line)
                line = json.dumps(obj, separators=(",", ":"))
            except (json.JSONDecodeError, TypeError):
                pass
            f.write(line + "\n")


def conv_add_user(cfg: Config, content: str):
    with open(cfg.conv_file, "a", encoding="utf-8") as f:
        f.write(json.dumps({"role": "user", "content": content}, separators=(",", ":")) + "\n")


def conv_add_assistant(cfg: Config, text: str, thinking: str, tool_calls: list):
    """Append assistant message. tool_calls is list of (name, id, input_json_str)."""
    content = []
    # Always include thinking block (matches bash-agent build_assistant_content_json)
    content.append({"type": "thinking", "thinking": thinking})
    if text:
        content.append({"type": "text", "text": text})
    for name, tid, inp in tool_calls:
        parsed = json.loads(inp) if isinstance(inp, str) else inp
        if cfg.provider == "claude":
            content.append({"type": "tool_use", "id": tid, "name": name, "input": parsed})
        else:
            content.append({"name": name, "id": tid, "input": parsed})
    with open(cfg.conv_file, "a", encoding="utf-8") as f:
        f.write(json.dumps({"role": "assistant", "content": content}, separators=(",", ":")) + "\n")


def conv_add_tool_results(cfg: Config, results: list):
    """results is list of (tool_use_id, result_text)."""
    content = []
    for tid, result in results:
        content.append({"type": "tool_result", "tool_use_id": tid, "content": result})
    with open(cfg.conv_file, "a", encoding="utf-8") as f:
        f.write(json.dumps({"role": "user", "content": content}, separators=(",", ":")) + "\n")


def conv_get_messages(cfg: Config) -> list:
    """Read conversation.jsonl and return list of message dicts."""
    messages = []
    if not os.path.exists(cfg.conv_file):
        return messages
    with open(cfg.conv_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                messages.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return messages


def conv_get_messages_json(cfg: Config) -> str:
    return json.dumps(conv_get_messages(cfg))


def list_sessions(cfg: Config):
    """Print all sessions for current project — matches bash-agent list_sessions."""
    project_dir = get_session_dir(cfg)
    if not os.path.isdir(project_dir):
        print("No sessions found.")
        return

    print(f"{'NAME':<40} {'MODIFIED':<20} PREVIEW")
    for entry in sorted(os.scandir(project_dir), key=lambda e: e.stat(follow_symlinks=False).st_mtime, reverse=True):
        if not entry.is_dir():
            continue
        name = entry.name
        try:
            mtime = entry.stat().st_mtime
            mod = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
        except OSError:
            mod = "?"
        summary_file = os.path.join(entry.path, "summary.txt")
        preview = ""
        if os.path.isfile(summary_file):
            try:
                with open(summary_file, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        if line.strip():
                            preview = line.strip()
                            break
            except Exception:
                pass
        if len(preview) > 60:
            preview = preview[:57] + "..."
        print(f"{name:<40} {mod:<20} {preview}")


def _init_stats(stats_file: str):
    """Initialize stats.json with zero counters."""
    from datetime import datetime, timezone
    stats = {
        "last_updated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "agent_request_count": 0,
        "compact_request_count": 0,
        "total_input_tokens": 0,
        "total_output_tokens": 0,
        "total_cache_read_tokens": 0,
        "total_cache_creation_tokens": 0,
        "current_context_tokens": 0,
    }
    with open(stats_file, "w") as f:
        json.dump(stats, f, separators=(",", ":"))
        f.write("\n")


def stats_update(cfg: Config, **kwargs):
    """Update stats.json fields incrementally.

    Keyword args: field_name=value (value prefixed with + for increment).
    """
    if not cfg.stats_file or not os.path.exists(cfg.stats_file):
        return
    from datetime import datetime, timezone
    with open(cfg.stats_file, "r") as f:
        stats = json.load(f)
    for key, val in kwargs.items():
        if isinstance(val, str) and val.startswith("+"):
            stats[key] = stats.get(key, 0) + int(val[1:])
        else:
            stats[key] = val
    stats["last_updated"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(cfg.stats_file, "w") as f:
        json.dump(stats, f, separators=(",", ":"))
        f.write("\n")


def stats_show(cfg: Config):
    """Print session statistics — matches bash-agent stats_show."""
    if not cfg.stats_file or not os.path.exists(cfg.stats_file):
        print("\033[33mNo stats available (not in a session).\033[0m")
        return
    with open(cfg.stats_file, "r") as f:
        stats = json.load(f)
    print("\033[1mSession Statistics\033[0m")
    print("\033[90m\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\u2500\033[0m")
    print(f"  {'Agent Requests:':<30} {stats.get('agent_request_count', 0)}")
    print(f"  {'Compact Requests:':<30} {stats.get('compact_request_count', 0)}")
    print(f"  {'Total Input Tokens:':<30} {stats.get('total_input_tokens', 0)}")
    print(f"  {'Total Output Tokens:':<30} {stats.get('total_output_tokens', 0)}")
    print(f"  {'Total Cache Read Tokens:':<30} {stats.get('total_cache_read_tokens', 0)}")
    print(f"  {'Total Cache Creation Tokens:':<30} {stats.get('total_cache_creation_tokens', 0)}")
    print(f"  {'Current Context Tokens:':<30} {stats.get('current_context_tokens', 0)}")
    updated = stats.get("last_updated", "")
    if updated:
        print(f"  {'Last Updated:':<30} {updated}")
