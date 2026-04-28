"""Mutable global configuration — mirrors bash-agent's global vars."""
import os


class Config:
    def __init__(self):
        # user options
        self.provider = "claude"
        self.model = ""
        self.max_tokens = 4096
        self.summary_max_tokens = 1024
        self.tool_timeout_secs = 600
        self.tool_result_max_bytes = int(os.environ.get("TOOL_RESULT_MAX_BYTES", "50000"))
        self.file_write_max_bytes = 1048576
        self.output_format = "human"
        self.verbose = False
        self.api_key = ""
        self.base_url = ""
        self.user_input = ""
        self.max_turns = 40
        self.max_context_bytes = 200000
        self.max_context_keep_pct = 25
        self.max_context_tokens = 100000
        self.skill_names: list[str] = []
        self.thinking_budget = int(os.environ.get("THINKING_BUDGET", "2048"))

        # runtime mode & session state
        self.interactive = False
        self.session_id = ""
        self.session_event_file = ""
        self.stats_file = ""
        self.context_summary_file = ""
        self.todo_file = ""
        self.plan_file = ""
        self.log_events = True

        # internal runtime state
        self.conv_file = ""
        self.tool_def_json = ""
        self.api_url = ""
        self.interrupt_requested = False

        # env defaults
        self.anthropic_api_key = os.environ.get("ANTHROPIC_API_KEY", "")
        self.openai_api_key = os.environ.get("OPENAI_API_KEY", "")
        self.anthropic_base_url = os.environ.get("ANTHROPIC_BASE_URL", "")
        self.openai_base_url = os.environ.get("OPENAI_BASE_URL", "")
        self.bash_agent_home = os.environ.get("BASH_AGENT_HOME", os.path.expanduser("~"))

        # script directory (for tools.json etc.)
        self.script_dir = os.path.dirname(os.path.abspath(__file__))
