"""Interactive mode — async REPL with readline (arrow keys, history)."""
import asyncio
import json
import os
import readline
import signal
import sys

from pyagent.config import Config
from pyagent.agent import agent_loop
from pyagent.display import _dim, display_banner, display_error
from pyagent.session import session_append_line, conv_init


def _setup_signal_handler(cfg: Config):
    def handler(signum, frame):
        cfg.interrupt_requested = True
    signal.signal(signal.SIGINT, handler)


def _setup_readline(history_file: str):
    readline.set_auto_history(True)
    readline.parse_and_bind("set editing-mode emacs")
    readline.parse_and_bind("Tab: self-insert")
    try:
        readline.read_history_file(history_file)
    except FileNotFoundError:
        pass
    readline.set_history_length(5000)


async def async_input(prompt_str: str) -> str:
    """Run input() in a thread so the event loop stays alive."""
    return await asyncio.to_thread(input, prompt_str)


async def interactive_loop(cfg: Config):
    """Async interactive REPL."""
    cfg.interactive = True
    conv_init(cfg)
    _setup_signal_handler(cfg)

    display_banner(cfg)

    # Replay recent 10 turns for resumed sessions (mirrors bash-agent)
    if cfg.session_event_file and os.path.isfile(cfg.session_event_file):
        try:
            with open(cfg.session_event_file, "r", encoding="utf-8", errors="replace") as f:
                event_lines = f.readlines()

            # Find the 10th-from-last user_input line
            user_input_lines = []
            for i, line in enumerate(event_lines):
                try:
                    ev = json.loads(line)
                    if ev.get("type") == "user_input":
                        user_input_lines.append(i)
                except json.JSONDecodeError:
                    continue

            if user_input_lines:
                from_line = user_input_lines[-10] if len(user_input_lines) > 10 else user_input_lines[0]
                for line in event_lines[from_line:]:
                    try:
                        ev = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    etype = ev.get("type")
                    if etype == "user_input":
                        content = ev.get("content", "")
                        print(f"\033[32m> \033[0m{content}")
                    elif etype == "tool_call":
                        tname = ev.get("tool_name", "?")
                        print(_dim(f"  [{tname}]"))
                    elif etype == "assistant_message":
                        text = ev.get("text_len", 0)
                        print(_dim(f"  (assistant: {text} chars)"))
                if user_input_lines:
                    print()
        except Exception:
            pass

    history_file = os.path.join(cfg.bash_agent_home, ".bash-agent", "history")
    os.makedirs(os.path.dirname(history_file), exist_ok=True)
    _setup_readline(history_file)

    prompt_str = "\033[32m> \033[0m"

    while True:
        try:
            user_input = await async_input(prompt_str)
        except EOFError:
            break
        except KeyboardInterrupt:
            print()
            continue

        if not user_input:
            continue

        stripped = user_input.strip()
        if stripped in ("exit", "quit"):
            break
        if stripped == "/help":
            print("Commands: exit, quit, /help")
            continue
        if stripped == "/compact":
            from pyagent.compact import compact_if_needed
            if compact_if_needed(cfg):
                print(_dim("Context compacted."))
            else:
                print(_dim("Context within limits."))
            continue
        if stripped == "/clear":
            open(cfg.conv_file, "w").close()
            print(_dim("Conversation cleared."))
            continue

        cfg.interrupt_requested = False
        try:
            await agent_loop(cfg, user_input)
        except KeyboardInterrupt:
            cfg.interrupt_requested = True
            print()
            continue
        except Exception as e:
            display_error(cfg, str(e))

    try:
        readline.write_history_file(history_file)
    except Exception:
        pass
    session_append_line(cfg, json.dumps({"type": "session_end"}))
    print(_dim("Goodbye."))
    if cfg.session_id:
        print(_dim(f"Resume with: --session {cfg.session_id}  or  --continue"))
