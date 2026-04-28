"""CLI — argument parsing, validation, async entry point."""
import argparse
import asyncio
import json
import os
import signal
import sys

from pyagent.config import Config
from pyagent.util import die, parse_size_bytes
from pyagent.prompt import load_tool_definitions


def parse_args(argv: list[str] | None = None) -> Config:
    parser = argparse.ArgumentParser(
        prog="pyagent",
        description="AI coding agent (Python port of bash-agent)",
    )
    parser.add_argument("input", nargs="?", help="User input prompt (or omit for interactive)")
    parser.add_argument("-p", "--provider", choices=["claude", "openai"], default=None,
                        help="LLM provider")
    parser.add_argument("-m", "--model", default=None, help="Model name")
    parser.add_argument("--max-tokens", type=int, default=None, help="Max output tokens")
    parser.add_argument("--tool-timeout", type=int, default=None, help="Tool timeout seconds")
    parser.add_argument("--max-turns", type=int, default=None, help="Max agent turns per prompt")
    parser.add_argument("--max-context-bytes", type=str, default=None,
                        help="Max context window bytes (e.g. 200k)")
    parser.add_argument("--max-context-tokens", type=int, default=None,
                        help="Max context tokens before compact (default: 100000)")
    parser.add_argument("-v", "--verbose", action="store_true", default=False)
    parser.add_argument("--output", choices=["human", "stream-json"], default=None,
                        help="Output format")
    parser.add_argument("--print", dest="print_mode", action="store_true", default=False,
                        help="Alias for --output stream-json")
    parser.add_argument("--api-key", default=None, help="API key")
    parser.add_argument("--base-url", default=None, help="API base URL override")
    parser.add_argument("--api-url", default=None, help="Full API URL override")
    parser.add_argument("--session", default=None, nargs="?", const="",
                        help="Session ID to resume (generates new ID if no arg)")
    parser.add_argument("--continue", dest="continue_session", action="store_true", default=False,
                        help="Continue most recent session")
    parser.add_argument("--list-sessions", action="store_true", default=False,
                        help="List all saved sessions")
    parser.add_argument("--stats", action="store_true", default=False,
                        help="Show statistics for current session")
    parser.add_argument("--no-log", action="store_true", default=False,
                        help="Disable session logging")
    parser.add_argument("--thinking-budget", type=int, default=None,
                        help="Thinking budget tokens (Claude)")
    parser.add_argument("--skill", action="append", default=None,
                        help="Skill to load (repeatable)")

    args = parser.parse_args(argv)

    cfg = Config()

    if args.provider:
        cfg.provider = args.provider
    if args.model:
        cfg.model = args.model
    if args.max_tokens is not None:
        cfg.max_tokens = args.max_tokens
    if args.tool_timeout is not None:
        cfg.tool_timeout_secs = args.tool_timeout
    if args.max_turns is not None:
        cfg.max_turns = args.max_turns
    if args.max_context_bytes is not None:
        cfg.max_context_bytes = parse_size_bytes(args.max_context_bytes)
    if args.max_context_tokens is not None:
        cfg.max_context_tokens = args.max_context_tokens
    if args.verbose:
        cfg.verbose = True
    if args.print_mode:
        cfg.output_format = "stream-json"
    elif args.output:
        cfg.output_format = args.output
    if args.api_key:
        cfg.api_key = args.api_key
    if args.base_url:
        cfg.base_url = args.base_url
        if cfg.provider == "claude":
            cfg.anthropic_base_url = args.base_url
        else:
            cfg.openai_base_url = args.base_url
    if args.api_url:
        cfg.api_url = args.api_url
    if args.session is not None:
        if args.session == "":
            # --session without arg: generate new ID
            from pyagent.util import new_session_id
            cfg.session_id = new_session_id()
        else:
            cfg.session_id = args.session
    if args.no_log:
        cfg.log_events = False
    if args.thinking_budget is not None:
        cfg.thinking_budget = args.thinking_budget
    if args.skill:
        cfg.skill_names = args.skill

    cfg.user_input = args.input or ""
    cfg.interactive = not args.input

    # F1: stdin pipe handling — if no input arg and stdin is piped, read from stdin
    if not args.input and not sys.stdin.isatty():
        cfg.user_input = sys.stdin.read().strip()
        cfg.interactive = False

    # --list-sessions: print and exit (no API key needed)
    if args.list_sessions:
        from pyagent.session import list_sessions
        list_sessions(cfg)
        sys.exit(0)

    # --stats: print stats and exit
    if args.stats:
        from pyagent.session import get_latest_session_dir, conv_init, stats_show
        latest = get_latest_session_dir(cfg)
        if not latest:
            print("\033[33mNo sessions found.\033[0m")
            sys.exit(0)
        cfg.session_id = latest
        conv_init(cfg)
        stats_show(cfg)
        sys.exit(0)

    # --continue: resolve latest session
    if args.continue_session and not cfg.session_id:
        from pyagent.session import get_latest_session_dir
        latest = get_latest_session_dir(cfg)
        if latest:
            cfg.session_id = latest
        else:
            die("No existing sessions found for --continue")

    return cfg


def validate_config(cfg: Config):
    if cfg.provider == "claude":
        key = cfg.api_key or cfg.anthropic_api_key
        if not key:
            die("No API key. Set ANTHROPIC_API_KEY or use --api-key")
        cfg.anthropic_api_key = key
    else:
        key = cfg.api_key or cfg.openai_api_key
        if not key:
            die("No API key. Set OPENAI_API_KEY or use --api-key")
        cfg.openai_api_key = key

    cfg.tool_def_json = load_tool_definitions(cfg)
    if not cfg.tool_def_json:
        print("Warning: tools.json not found", file=sys.stderr)
        cfg.tool_def_json = "[]"


async def async_main(cfg: Config):
    if cfg.interactive:
        from pyagent.interactive import interactive_loop
        await interactive_loop(cfg)
    else:
        from pyagent.session import conv_init
        from pyagent.agent import agent_loop

        conv_init(cfg)

        def handler(signum, frame):
            cfg.interrupt_requested = True
        signal.signal(signal.SIGINT, handler)

        await agent_loop(cfg, cfg.user_input)


def main(argv: list[str] | None = None):
    cfg = parse_args(argv)
    validate_config(cfg)
    asyncio.run(async_main(cfg))
