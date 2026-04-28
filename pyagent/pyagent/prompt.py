"""System prompt assembly — mirrors bash-agent's build_system_prompt() exactly."""
import json
import os
from importlib.resources import files

from pyagent.config import Config


def read_file_if_exists(path: str) -> str:
    if not os.path.isfile(path):
        return ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except Exception:
        return ""


def _append_section(output: str, tag: str, content: str, name: str = "") -> str:
    """Mirror bash-agent's append_section: skip empty content."""
    if not content:
        return output
    header = f"<{tag}"
    if name:
        header += f' name="{name}"'
    header += ">"
    return output + f"\n{header}\n{content}\n</{tag}>\n"


# ── Instruction files ──

def _find_instruction_file_in_dir(dir_path: str) -> str:
    """Mirror bash-agent's find_instruction_file_in_dir."""
    if not dir_path or not os.path.isdir(dir_path):
        return ""
    for candidate in [
        os.path.join(dir_path, "AGENTS.md"),
        os.path.join(dir_path, "AGENT.md"),
        os.path.join(dir_path, "CLAUDE.md"),
        os.path.join(dir_path, ".claude", "CLAUDE.md"),
    ]:
        if os.path.isfile(candidate):
            return candidate
    return ""


def _build_instruction_files_section(cfg: Config) -> str:
    """Mirror bash-agent's build_instruction_files_section."""
    output = ""
    home = os.path.expanduser("~")

    global_file = _find_instruction_file_in_dir(os.path.join(home, ".bash-agent"))
    project_file = _find_instruction_file_in_dir(os.getcwd())

    if global_file:
        content = read_file_if_exists(global_file)
        output = _append_section(output, "instruction-file", content, "global")

    if project_file:
        content = read_file_if_exists(project_file)
        output = _append_section(output, "instruction-file", content, "project")

    return output


# ── Skill index ──

def _find_skill_base_dirs() -> list[str]:
    """Mirror bash-agent's find_skill_base_dirs."""
    cwd = os.getcwd()
    home = os.path.expanduser("~")
    dirs = []
    for d in [
        os.path.join(cwd, ".claude", "skills"),
        os.path.join(cwd, "skills"),
        os.path.join(home, ".claude", "skills"),
    ]:
        if os.path.isdir(d):
            dirs.append(d)
    return dirs


def _extract_skill_summary(skill_content: str) -> str:
    """Extract first non-empty, non-heading line as summary."""
    for line in skill_content.split("\n"):
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and not stripped.startswith("---"):
            return stripped[:120]
    return ""


def _build_skill_index_section() -> str:
    """Mirror bash-agent's build_skill_index_section."""
    output = ""
    seen = set()
    for base in _find_skill_base_dirs():
        if not os.path.isdir(base):
            continue
        try:
            entries = sorted(os.listdir(base))
        except OSError:
            continue
        for entry in entries:
            skill_file = os.path.join(base, entry, "SKILL.md")
            if not os.path.isfile(skill_file):
                continue
            if entry in seen:
                continue
            seen.add(entry)
            content = read_file_if_exists(skill_file)
            summary = _extract_skill_summary(content)
            line = f"- {entry}"
            if summary:
                line += f": {summary}"
            output += line + "\n"
    return output.rstrip("\n")


# ── Selected skills ──

def _build_selected_skills_section(cfg: Config) -> str:
    """Mirror bash-agent's build_selected_skills_section."""
    if not cfg.skill_names:
        return ""
    output = ""
    for skill_name in cfg.skill_names:
        found = False
        for base in _find_skill_base_dirs():
            skill_dir = os.path.join(base, skill_name)
            skill_file = os.path.join(skill_dir, "SKILL.md")
            if os.path.isfile(skill_file):
                content = read_file_if_exists(skill_file)
                content = content.replace("${BASH_AGENT_SKILL_DIR}", skill_dir)
                header = f"Base directory: {skill_dir}\n\n{content}"
                output = _append_section(output, "skill", header, skill_name)
                found = True
                break
        if not found:
            output = _append_section(output, "skill", f"Error: skill not found: {skill_name}", skill_name)
    return output


# ── Tools ──

def _find_tools_json() -> str:
    """Locate tools.json: package data first, then filesystem fallbacks."""
    try:
        pkg = files("pyagent")
        p = pkg.joinpath("tools.json")
        if p.is_file():
            return str(p)
    except Exception:
        pass
    pkg_dir = os.path.dirname(os.path.abspath(__file__))
    candidate = os.path.join(pkg_dir, "tools.json")
    if os.path.isfile(candidate):
        return candidate
    return ""


def load_tool_definitions(cfg: Config) -> str:
    """Load tools.json raw JSON string."""
    path = _find_tools_json()
    if path:
        return read_file_if_exists(path)
    return ""


# ── Main prompt assembly ──

def build_system_prompt(cfg: Config) -> str:
    """Assemble the full system prompt — mirrors bash-agent's build_system_prompt()."""
    agent_identity = "You are bash-agent, a lightweight coding agent that works in a terminal."

    core_rules = """- Be concise and concrete.
- Prefer safe, exact edits.
- Report failures clearly.
- No pleasantries. No explanations unless asked. Raw results only."""

    tool_guidance = """- Use Read for a single file. If you need multiple files, call Read multiple times.
- For large files, use Read with offset/limit instead of reading the whole file.
- Use Glob and Grep for one pattern at a time.
- Use multiple tool calls in one response when they are independent.
- Prefer dedicated tools over Bash when a dedicated tool fits the task.
- For Edit, Read first and copy old_string exactly (including whitespace/indent/newlines).
- For skills, first check the skill-index section, then use Skill(name) for the matching skill."""

    todo_guidance = """- Use TodoWrite proactively for complex multi-step implementation, debugging, refactoring, review, or multi-file tasks.
- Do not use TodoWrite for trivial single-step, single-command, or purely informational requests.
- After receiving a non-trivial task, create an initial checklist before or as you begin work.
- When you use TodoWrite, write the full updated checklist for the current session, not a partial diff.
- Keep the checklist short, concrete, and actionable.
- Prefer exactly one in_progress item when work is actively underway.
- Mark items completed immediately after finishing them, and remove stale items that no longer matter."""

    plan_file = getattr(cfg, "plan_file", "") or ""
    plan_lifecycle_guidance = f"""- **PLANNING WORKFLOW** — For complex multi-step tasks (3+ steps OR multi-file OR user requests planning)
- **Step-by-step**:
  1. Write plan to PLAN_FILE using Edit (markdown: goal, analysis, steps, notes)
  2. Ask user to confirm the plan before execution
  3. After user confirms, create TodoWrite checklist based on plan
  4. Execute tasks following todo checklist (update progress in TodoWrite)
  5. When all tasks complete, clear plan: Bash ": > PLAN_FILE"
- **Plan vs Todo separation**:
  - PLAN_FILE: planning document for analysis and strategy
  - TodoWrite: execution checklist for real-time progress tracking
  - Do NOT mix todo checkboxes into plan file
- **PLAN_FILE**: {plan_file or '<not set>'}"""

    # Collect dynamic sections
    instruction_files = _build_instruction_files_section(cfg)
    skill_index = _build_skill_index_section()
    selected_skills = _build_selected_skills_section(cfg)
    plan = read_file_if_exists(plan_file) if plan_file else ""
    stable_context = read_file_if_exists(getattr(cfg, "context_summary_file", "") or "")
    todo = read_file_if_exists(getattr(cfg, "todo_file", "") or "")

    # Assemble
    output = ""
    output = _append_section(output, "agent-identity", agent_identity)
    output = _append_section(output, "rules", core_rules)
    output = _append_section(output, "using-your-tools", tool_guidance)
    output = _append_section(output, "todo-guidance", todo_guidance)
    output = _append_section(output, "plan-lifecycle-guidance", plan_lifecycle_guidance)
    output = _append_section(output, "instruction-files", instruction_files)
    output = _append_section(output, "skill-index", skill_index)
    output = _append_section(output, "selected-skills", selected_skills)
    output = _append_section(output, "current-plan", plan, plan_file if plan else "")
    output = _append_section(output, "context-summary", stable_context)
    output = _append_section(output, "current-todo", todo)

    return output.rstrip("\n")


def get_tool_defs_for_api(cfg: Config) -> list:
    """Parse tools.json and return tool definitions in the format needed by the API."""
    raw = cfg.tool_def_json or load_tool_definitions(cfg)
    if not raw:
        return []
    try:
        tools = json.loads(raw)
    except json.JSONDecodeError:
        return []

    if cfg.provider == "claude":
        return tools  # assume already in Claude format
    else:
        # convert Claude format to OpenAI format
        result = []
        for t in tools:
            result.append({
                "type": "function",
                "function": {
                    "name": t["name"],
                    "description": t.get("description", ""),
                    "parameters": t.get("input_schema", t.get("parameters", {})),
                }
            })
        return result
