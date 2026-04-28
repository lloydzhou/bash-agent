"""Tool implementations — async handlers, Bash uses asyncio subprocess."""
import asyncio
import fnmatch
import json
import os
import re

from pyagent.config import Config
from pyagent.util import format_tool_result


# ── helpers ──

def _param(params: dict, key: str, default=None):
    return params.get(key, default)


def _required(params: dict, key: str) -> str:
    v = params.get(key)
    if v is None:
        raise ValueError(f"Missing required parameter: {key}")
    return v


# ── Read ──

async def tool_read(params: dict, cfg: Config) -> str:
    path = _required(params, "path")
    offset = _param(params, "offset")
    limit = _param(params, "limit")

    if not os.path.isfile(path):
        return f"Error: file not found: {path}"

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except Exception as e:
        return f"Error reading file: {e}"

    if offset is not None:
        start = max(1, int(offset)) - 1
    else:
        start = 0

    if limit is not None:
        end = start + int(limit)
    else:
        end = len(lines)

    selected = lines[start:end]
    result = "".join(selected)
    return format_tool_result(result, cfg.tool_result_max_bytes)


# ── Write ──

async def tool_write(params: dict, cfg: Config) -> str:
    path = _required(params, "path")
    content = _required(params, "content")

    if len(content.encode("utf-8")) > cfg.file_write_max_bytes:
        return f"Error: content exceeds max write size ({cfg.file_write_max_bytes} bytes)"

    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    except Exception as e:
        return f"Error writing file: {e}"

    try:
        with open(path, "rb") as f:
            wrote_bytes = len(f.read())
    except Exception:
        wrote_bytes = "?"
    return f"OK: wrote {wrote_bytes} bytes to {path}"


# ── Edit ──

async def tool_edit(params: dict, cfg: Config) -> str:
    import tempfile

    path = _required(params, "path")
    old_string = _required(params, "old_string")
    new_string = _required(params, "new_string")

    if not os.path.isfile(path):
        return f"Error: file not found: {path}"

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except Exception as e:
        return f"Error reading file: {e}"

    # Check file size before editing (like bash-agent's edit_file.awk)
    file_size = len(content.encode("utf-8"))
    if file_size > cfg.file_write_max_bytes:
        return f"Error: file too large for edit_file ({file_size} bytes > {cfg.file_write_max_bytes} bytes)"

    count = content.count(old_string)
    if count == 0:
        return "Error: old_string not found in file"
    if count > 1:
        return f"Error: old_string found {count} times — must be unique"

    new_content = content.replace(old_string, new_string, 1)

    if len(new_content.encode("utf-8")) > cfg.file_write_max_bytes:
        return f"Error: content exceeds max write size ({cfg.file_write_max_bytes} bytes)"

    if not new_content:
        return "Error: edit produced empty result"

    # Write new content to temp file for diff
    tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".tmp", delete=False, encoding="utf-8")
    try:
        tmp.write(new_content)
        tmp.close()

        # Run diff like bash-agent: diff -u --color=always --label a/path --label b/path
        label = path.lstrip("/")
        diff_output = ""
        try:
            proc = await asyncio.create_subprocess_exec(
                "diff", "-u", "--color=always",
                "--label", f"a/{label}", "--label", f"b/{label}",
                path, tmp.name,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=10)
            diff_output = stdout.decode("utf-8", errors="replace")
            stderr_text = stderr.decode("utf-8", errors="replace")
            # Fallback if --color=always not supported
            if "unsupported" in stderr_text or "unrecognized" in stderr_text:
                proc = await asyncio.create_subprocess_exec(
                    "diff", "-u",
                    "--label", f"a/{label}", "--label", f"b/{label}",
                    path, tmp.name,
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
                diff_output = stdout.decode("utf-8", errors="replace")
        except FileNotFoundError:
            diff_output = ""
        except asyncio.TimeoutError:
            diff_output = ""

        # Count added/removed lines (skip diff header lines starting with --- or +++ or @@)
        added = 0
        removed = 0
        for line in diff_output.split("\n"):
            if line.startswith("+") and not line.startswith("+++"):
                added += 1
            elif line.startswith("-") and not line.startswith("---"):
                removed += 1

        # Write final content
        with open(path, "w", encoding="utf-8") as f:
            f.write(new_content)

        result = f"Edit({path}) [+{added} -{removed} lines]"
        if diff_output:
            result += "\n" + diff_output
        return result
    finally:
        os.unlink(tmp.name)


# ── Bash (async subprocess) ──

async def tool_bash(params: dict, cfg: Config) -> str:
    command = _required(params, "command")
    timeout = _param(params, "timeout")
    if timeout is not None:
        timeout = int(timeout)

    from pyagent.safety import deny_bash_command_reason
    reason = deny_bash_command_reason(command)
    if reason:
        return f"Error: command blocked by bash safety policy ({reason})"

    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", "-lc", command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=os.getcwd(),
        )
        stdout_bytes, stderr_bytes = await asyncio.wait_for(
            proc.communicate(),
            timeout=timeout or cfg.tool_timeout_secs,
        )
        output = ""
        if stdout_bytes:
            output += stdout_bytes.decode("utf-8", errors="replace")
        if stderr_bytes:
            if output:
                output += "\n"
            output += stderr_bytes.decode("utf-8", errors="replace")
        # bash-agent returns raw output, no exit code annotation
        return format_tool_result(output, cfg.tool_result_max_bytes)
    except asyncio.TimeoutError:
        timeout_val = timeout or cfg.tool_timeout_secs
        return f"[... command timed out after {timeout_val} seconds ...]"
    except Exception as e:
        return f"Error executing command: {e}"


# ── Glob ──

async def tool_glob(params: dict, cfg: Config) -> str:
    pattern = _required(params, "pattern")
    path = _param(params, "path", ".")

    if not os.path.isdir(path):
        return f"Error: directory not found: {path}"

    try:
        proc = await asyncio.create_subprocess_exec(
            "rg", "--files", path, "-g", pattern,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
        output = stdout.decode("utf-8", errors="replace").strip()
        if not output:
            return "(no matches)"
        return output
    except FileNotFoundError:
        return "Error: rg is required for glob"
    except asyncio.TimeoutError:
        return "Error: glob timed out"
    except Exception as e:
        return f"Error: {e}"


# ── Grep ──

async def tool_grep(params: dict, cfg: Config) -> str:
    pattern = _required(params, "pattern")
    path = _param(params, "path", ".")
    context = _param(params, "context")
    glob_pattern = _param(params, "glob")

    if not os.path.exists(path):
        return f"Error: path not found: {path}"

    try:
        args = ["rg", "-n", "--color", "never"]
        if context and str(context).isdigit():
            args += ["-C", str(context)]
        if glob_pattern:
            args += ["--glob", glob_pattern]
        args += ["--", pattern, path]

        proc = await asyncio.create_subprocess_exec(
            *args,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
        output = stdout.decode("utf-8", errors="replace").strip()
        if not output:
            return "(no matches)"
        return format_tool_result(output, cfg.tool_result_max_bytes)
    except FileNotFoundError:
        return "Error: rg is required for grep"
    except asyncio.TimeoutError:
        return "Error: grep timed out"
    except Exception as e:
        return f"Error: {e}"


# ── TodoWrite ──

def _parse_todos_to_markdown(todos: list) -> tuple[str, int, int, int]:
    """Parse todos array to markdown checklist, return (markdown, completed, total, in_progress)."""
    lines = []
    completed = 0
    total = 0
    in_progress = 0
    for item in todos:
        content = item.get("content", "")
        status = item.get("status", "pending")
        if not content:
            continue
        if status not in ("pending", "in_progress", "completed"):
            continue
        total += 1
        if status == "completed":
            completed += 1
            lines.append(f"- [x] {content}")
        elif status == "in_progress":
            in_progress += 1
            lines.append(f"- [>] {content}")
        else:
            lines.append(f"- [ ] {content}")
    return "\n".join(lines), completed, total, in_progress


async def tool_todo_write(params: dict, cfg: Config) -> str:
    todos = _required(params, "todos")

    if isinstance(todos, str):
        import json as _json
        try:
            todos = _json.loads(todos)
        except _json.JSONDecodeError:
            return "Error: todos must be a JSON array"

    if not isinstance(todos, list):
        return "Error: todos must be a JSON array"

    markdown, completed, total, in_progress = _parse_todos_to_markdown(todos)

    try:
        with open(cfg.todo_file, "w", encoding="utf-8") as f:
            f.write(markdown + "\n")
    except Exception as e:
        return f"Error writing todo file: {e}"

    # Store summary for display
    cfg._todo_summary = f"{completed}/{total}"

    # Emit todo_update event
    if cfg.log_events and cfg.session_event_file:
        from pyagent.session import session_append_line
        import json as _json
        session_append_line(cfg, _json.dumps({"type": "todo_update", "content": markdown}))

    # Stream-json: emit todo_update event
    if cfg.output_format == "stream-json":
        from pyagent.util import json_escape
        import sys
        sys.stdout.write(f'{{"type":"todo_update","content":"{json_escape(markdown)}"}}\n')
        sys.stdout.flush()

    return markdown


# ── Skill ──

def _find_skill_base_dirs() -> list[str]:
    """Match bash-agent's find_skill_base_dirs: cwd/.claude/skills, cwd/skills, ~/.claude/skills."""
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


async def tool_skill(params: dict, cfg: Config) -> str:
    name = _required(params, "name").strip()
    if not name:
        return "Error: no skill name provided"

    for base_dir in _find_skill_base_dirs():
        skill_dir = os.path.join(base_dir, name)
        skill_file = os.path.join(skill_dir, "SKILL.md")
        if os.path.isfile(skill_file):
            with open(skill_file, "r", encoding="utf-8", errors="replace") as f:
                content = f.read()
            # Replace ${BASH_AGENT_SKILL_DIR} with actual directory
            content = content.replace("${BASH_AGENT_SKILL_DIR}", skill_dir)
            skill_content = f"Base directory: {skill_dir}\n\n{content}"
            return f"Skill: {name}\n{skill_content}"

    return f"Error: skill not found: {name}"


# ── WebSearch (Jina API) ──

async def tool_web_search(params: dict, cfg: Config) -> str:
    import aiohttp

    query = _required(params, "query")
    jina_key = os.environ.get("JINA_API_KEY", "")

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                "https://s.jina.ai/",
                params={"q": query},
                headers={
                    "Authorization": f"Bearer {jina_key}",
                    "X-Respond-With": "no-content",
                },
                timeout=aiohttp.ClientTimeout(total=30, connect=10),
            ) as resp:
                return await resp.text()
    except Exception as e:
        return f"Error: web search failed: {e}"


# ── WebFetch (Jina API) ──

async def tool_web_fetch(params: dict, cfg: Config) -> str:
    import aiohttp

    url = _required(params, "url")
    jina_key = os.environ.get("JINA_API_KEY", "")

    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                "https://r.jina.ai/",
                params={"url": url},
                headers={"Authorization": f"Bearer {jina_key}"},
                timeout=aiohttp.ClientTimeout(total=60, connect=10),
            ) as resp:
                return await resp.text()
    except Exception as e:
        return f"Error: web fetch failed: {e}"


# ── Dispatch ──

TOOL_DISPATCH = {
    "Read": tool_read,
    "Write": tool_write,
    "Edit": tool_edit,
    "Bash": tool_bash,
    "Glob": tool_glob,
    "Grep": tool_grep,
    "TodoWrite": tool_todo_write,
    "Skill": tool_skill,
    "WebSearch": tool_web_search,
    "WebFetch": tool_web_fetch,
}


async def dispatch_tool(name: str, params: dict, cfg: Config) -> str:
    """Execute a tool by name, return output string."""
    handler = TOOL_DISPATCH.get(name)
    if not handler:
        return f"Error: unknown tool: {name}"
    try:
        return await handler(params, cfg)
    except Exception as e:
        return f"Error: tool execution failed: {e}"
