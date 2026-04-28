"""Display output — match bash-agent's human-readable and stream-json modes."""
import json
import sys

from pyagent.config import Config

# ── display state (module-level, like bash-agent's global vars) ──
DISPLAY_LAST_CHAR = "\n"
PREV_WAS_THINKING = False


def _reset_display_state():
    global DISPLAY_LAST_CHAR, PREV_WAS_THINKING
    DISPLAY_LAST_CHAR = "\n"
    PREV_WAS_THINKING = False


def _dim(text: str) -> str:
    return f"\033[90m{text}\033[0m"


def _yellow(text: str) -> str:
    return f"\033[33m{text}\033[0m"


def _green(text: str) -> str:
    return f"\033[32m{text}\033[0m"


def _cyan(text: str) -> str:
    return f"\033[36m{text}\033[0m"


def _red(text: str) -> str:
    return f"\033[31m{text}\033[0m"


def _ensure_newline():
    global DISPLAY_LAST_CHAR
    if DISPLAY_LAST_CHAR != "\n":
        sys.stdout.write("\n")
        DISPLAY_LAST_CHAR = "\n"


def _update_last_char(text: str):
    global DISPLAY_LAST_CHAR
    if text.endswith("\n"):
        DISPLAY_LAST_CHAR = "\n"
    elif text:
        DISPLAY_LAST_CHAR = text[-1]


# ── tool call summary (matches bash-agent's tool_call_summary) ──

_TOOL_SUMMARY_KEY = {
    "Read": "path", "Write": "path", "Edit": "path",
    "Bash": "command", "Glob": "pattern", "Grep": "pattern",
    "TodoWrite": "summary", "Skill": "name",
    "WebSearch": "query", "WebFetch": "url",
}


def tool_call_summary(name: str, params: dict | None = None) -> str:
    key = _TOOL_SUMMARY_KEY.get(name)
    label = ""
    if key and params:
        value = params.get(key, "")
        if name == "TodoWrite" and not value:
            # Compute summary from todos array (AWK layer does this in bash-agent)
            todos = params.get("todos", [])
            if isinstance(todos, list):
                total = len(todos)
                completed = sum(1 for t in todos if t.get("status") == "completed")
                value = f"{completed}/{total}"
        if name == "Bash" and value:
            value = value.replace("\n", " ")
            if len(value) > 80:
                value = value[:77] + "..."
        if value:
            label = value
    if label:
        return f"{name}({label})"
    return name


# ── stream-json output ──

def _emit_stream_json(event_type: str, data: dict):
    obj = {"type": event_type, **data}
    sys.stdout.write(json.dumps(obj, separators=(',', ':')) + "\n")
    sys.stdout.flush()


# ── public display API ──

def display_reset():
    _reset_display_state()


def display_user_message(cfg: Config, text: str):
    """Show user input line (green '> first line')."""
    global DISPLAY_LAST_CHAR
    if cfg.output_format == "stream-json":
        _emit_stream_json("user_input", {"content": text})
    else:
        _ensure_newline()
        first_line = text.split("\n")[0]
        if len(first_line) > 80:
            first_line = first_line[:77] + "..."
        sys.stdout.write(_green(f"> {first_line}") + "\n")
        sys.stdout.flush()
        DISPLAY_LAST_CHAR = "\n"


def display_text_delta(cfg: Config, text: str):
    global DISPLAY_LAST_CHAR, PREV_WAS_THINKING
    if not text:
        return
    if cfg.output_format == "stream-json":
        _emit_stream_json("text", {"content": text})
    else:
        # newline transition from thinking
        if PREV_WAS_THINKING and DISPLAY_LAST_CHAR != "\n":
            sys.stdout.write("\n")
            DISPLAY_LAST_CHAR = "\n"
        PREV_WAS_THINKING = False
        sys.stdout.write(text)
        sys.stdout.flush()
        _update_last_char(text)


def display_thinking(cfg: Config, thinking: str):
    global DISPLAY_LAST_CHAR, PREV_WAS_THINKING
    if not thinking:
        return
    if cfg.output_format == "stream-json":
        _emit_stream_json("thinking", {"content": thinking})
    else:
        sys.stdout.write(_dim(thinking))
        sys.stdout.flush()
        _update_last_char(thinking)
        PREV_WAS_THINKING = True


def display_tool_call(cfg: Config, tool_name: str, tool_id: str, params: dict | None = None):
    """Show tool call: yellow '[tool] Name(param_key=value)'."""
    global DISPLAY_LAST_CHAR
    if cfg.output_format == "stream-json":
        obj = {"name": tool_name, "id": tool_id}
        if params:
            obj["input"] = params
        _emit_stream_json("tool_call", obj)
    else:
        _ensure_newline()
        summary = tool_call_summary(tool_name, params)
        sys.stdout.write(_yellow(f"[tool] {summary}") + "\n")
        sys.stdout.flush()
        DISPLAY_LAST_CHAR = "\n"


def display_tool_result(cfg: Config, tool_name: str, tool_id: str, result: str):
    global DISPLAY_LAST_CHAR, PREV_WAS_THINKING
    if cfg.output_format == "stream-json":
        _emit_stream_json("tool_result", {
            "tool_use_id": tool_id,
            "name": tool_name,
            "content": result,
        })
    else:
        # newline transition from thinking
        if PREV_WAS_THINKING and DISPLAY_LAST_CHAR != "\n":
            sys.stdout.write("\n")
            DISPLAY_LAST_CHAR = "\n"
        PREV_WAS_THINKING = False

        if tool_name in ("Read", "Write"):
            # Show first line only (like bash-agent)
            text = result.split("\n")[0] if result else ""
        else:
            # Show full result (like bash-agent for Bash, Edit, etc.)
            text = result
        if text:
            sys.stdout.write(text.rstrip("\n") + "\n")
            sys.stdout.flush()
            DISPLAY_LAST_CHAR = "\n"


def display_stop(cfg: Config, reason: str = ""):
    if cfg.output_format == "stream-json":
        _emit_stream_json("stop", {"reason": reason})
    else:
        _ensure_newline()


def display_error(cfg: Config, msg: str):
    global DISPLAY_LAST_CHAR
    if cfg.output_format == "stream-json":
        _emit_stream_json("error", {"message": msg})
    else:
        _ensure_newline()
        sys.stderr.write(_red(f"Error: {msg}") + "\n")
        sys.stderr.flush()
        DISPLAY_LAST_CHAR = "\n"


def display_usage(cfg: Config, input_tokens: int, output_tokens: int, cache_read: int = 0, cache_creation: int = 0):
    if cfg.output_format == "stream-json":
        _emit_stream_json("usage", {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cache_read_input_tokens": cache_read,
            "cache_creation_input_tokens": cache_creation,
        })
    elif cfg.verbose:
        _ensure_newline()
        sys.stdout.write(_dim(f"  [tokens: {input_tokens} in, {output_tokens} out]") + "\n")
        sys.stdout.flush()


def display_banner(cfg: Config):
    """Show interactive mode banner."""
    if cfg.output_format != "stream-json":
        sys.stdout.write(_cyan("pyagent interactive mode (type 'exit' or Ctrl+D to quit)") + "\n")
        sys.stdout.flush()


def display_session_resume(cfg: Config, session_id: str):
    """Show session resume info."""
    if cfg.output_format != "stream-json":
        sys.stdout.write(_dim(f"Resumed session: {session_id}") + "\n")
        sys.stdout.flush()
