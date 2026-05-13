#!/usr/bin/env bash
# build.sh — Inline awk files into agent.sh to produce a single all-in-one script
# Each awk file becomes a bash variable; functions concatenate them for awk.
# Usage: ./scripts/build.sh [output]
#   output  Output file path (default: dist/agent.sh)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT="${1:-$ROOT_DIR/dist/agent.sh}"
AGENT_SRC="$ROOT_DIR/src/agent.sh"
AWK_DIR="$ROOT_DIR/src/awk"

[[ ! -f "$AGENT_SRC" ]] && { echo "Error: $AGENT_SRC not found" >&2; exit 1; }
[[ ! -d "$AWK_DIR" ]] && { echo "Error: $AWK_DIR not found" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"

echo "Building all-in-one $OUTPUT ..."

python3 - "$AGENT_SRC" "$AWK_DIR" "$OUTPUT" << 'PYEOF'
import os, sys

agent_src = sys.argv[1]
awk_dir = sys.argv[2]
output_path = sys.argv[3]

with open(agent_src) as f:
    content = f.read()

def minify_awk_source(text):
    """Remove comment-only and empty lines from awk source for dist embedding."""
    out = []
    for line in text.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#"):
            continue
        out.append(line.rstrip())
    return "\n".join(out).strip()

def find_function_end(content, start):
    """Find the matching closing brace for a function starting at `start`."""
    depth = 0
    i = start
    while i < len(content):
        if content[i] == "{":
            depth += 1
        elif content[i] == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1

# --- Read all awk files and prepare bash variables ---
awk_files = {
    "json": ("json.awk", "_AWK_JSON"),
    "json_cli": ("json_cli.awk", "_AWK_JSON_CLI"),
    "protocol": ("protocol.awk", "_AWK_PROTOCOL"),
    "todo_protocol": ("todo_protocol.awk", "_AWK_TODO_PROTOCOL"),
    "http_stream": ("http_stream.awk", "_AWK_HTTP_STREAM"),
    "edit_file": ("edit_file.awk", "_AWK_EDIT_FILE"),
    "claude_sse": ("claude_sse.awk", "_AWK_CLAUDE_SSE"),
    "skill_summary": ("skill_summary.awk", "_AWK_SKILL_SUMMARY"),
    "transport_openai_body": ("transport_openai_body.awk", "_AWK_TRANSPORT_OPENAI_BODY"),
    "transport_openai_sse": ("transport_openai_sse.awk", "_AWK_TRANSPORT_OPENAI_SSE"),
    "event_replay": ("event_replay.awk", "_AWK_EVENT_REPLAY"),
    "stats": ("stats.awk", "_AWK_STATS"),
    "compact_dp": ("compact_dp.awk", "_AWK_COMPACT_DP"),
    "send_sub_result": ("send_sub_result.awk", "_AWK_SEND_SUB_RESULT"),
}

awk_bodies = {}
for key, (filename, varname) in awk_files.items():
    path = os.path.join(awk_dir, filename)
    with open(path) as f:
        raw = f.read()
    body = minify_awk_source(raw)
    # Escape single quotes for bash single-quoted assignment
    escaped = body.replace("'", "'\\''")
    awk_bodies[key] = escaped

tools_json_path = os.path.join(os.path.dirname(agent_src), "tools.json")
with open(tools_json_path) as f:
    tools_json_raw = f.read().strip()

# --- Insert bash variables after config section ---
var_block = ""
for key, (filename, varname) in awk_files.items():
    var_block += "\n" + varname + "='" + awk_bodies[key] + "'\n"
var_block += "\n_TOOLS_JSON='" + tools_json_raw.replace("'", "'\\''") + "'\n"

# Insert after the USER_INPUT="" line (end of config section)
marker = 'USER_INPUT=""\n'
idx = content.find(marker)
if idx != -1:
    content = content[:idx + len(marker)] + var_block + content[idx + len(marker):]

# --- Replace each awk function to use variable concatenation ---
functions = [
    ("json_escape", "_AWK_JSON", "", ""),
    ("load_tool_defs", "", "", ""),
]

for func_name, json_var, specific_var, extra_args in functions:
    if func_name == "json_escape":
        replacement = (
            "json_escape() {\n"
            "    local input=\"${1:-}\"\n"
            "    printf '%s' \"$input\" | awk_run -v json_mode=\"escape_string\" \"${_AWK_JSON}\n${_AWK_JSON_CLI}\"\n"
            "}\n"
        )
    elif func_name == "load_tool_defs":
        replacement = (
            "load_tool_defs() {\n"
            "    TOOL_DEF_JSON=\"$_TOOLS_JSON\"\n"
            "}\n"
        )
    else:
        # Build: awk_run [-v ...] "${_AWK_JSON}
        # ${_AWK_XXX}"
        awk_call = '    awk_run '
        if extra_args:
            awk_call += extra_args + ' '
        # Double-quoted string with embedded newline concatenates two variables
        if json_var and specific_var:
            awk_call += '"${' + json_var + '}\n${' + specific_var + '}"'
        elif json_var:
            awk_call += '"${' + json_var + '}"'
        else:
            awk_call += '"${' + specific_var + '}"'

        replacement = func_name + "() {\n" + awk_call + "\n}\n"

    # Find and replace the original function
    pattern = func_name + "() {"
    idx = content.find(pattern)
    if idx == -1:
        print(f"Warning: {pattern} not found", file=sys.stderr)
        continue

    end = find_function_end(content, idx)
    if end == -1:
        print(f"Warning: could not find end of {func_name}", file=sys.stderr)
        continue

    content = content[:idx] + replacement + content[end+1:]

# --- Remove find_awk_dir (not needed in all-in-one) ---
marker = "find_awk_dir() {"
idx = content.find(marker)
if idx != -1:
    end = find_function_end(content, idx)
    if end != -1:
        content = content[:idx] + content[end+1:]

content = content.replace("    find_awk_dir\n", "")
content = content.replace('AWK_DIR=""\n', "")
content = content.replace('awk_run -f "$AWK_DIR/skill_summary.awk" "$skill_file"', 'awk_run "${_AWK_SKILL_SUMMARY}" "$skill_file"')
content = content.replace('curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 --connect-timeout 5 --speed-limit 1 --speed-time 60 "${HEADER_ARGS[@]}" -d @- "$API_URL" 2>&1 | awk_run -f "$AWK_DIR/http_stream.awk"', 'curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 --connect-timeout 5 --speed-limit 1 --speed-time 60 "${HEADER_ARGS[@]}" -d @- "$API_URL" 2>&1 | awk_run "${_AWK_HTTP_STREAM}"')
content = content.replace('awk_run -v max_bytes="$FILE_WRITE_MAX_BYTES" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/edit_file.awk"', 'awk_run -v max_bytes="$FILE_WRITE_MAX_BYTES" "${_AWK_JSON}\n${_AWK_EDIT_FILE}"')
# --- Inline transport awk references in validate_config ---
content = content.replace('awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_body.awk"', 'awk_run "${_AWK_JSON}\n${_AWK_TRANSPORT_OPENAI_BODY}"')
content = content.replace('awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/transport_openai_sse.awk"', 'awk_run "${_AWK_JSON}\n${_AWK_TRANSPORT_OPENAI_SSE}"')
content = content.replace('awk_run -v verbose="${VERBOSE:-false}" -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/todo_protocol.awk" -f "$AWK_DIR/claude_sse.awk"', 'awk_run -v verbose="${VERBOSE:-false}" "${_AWK_JSON}\n${_AWK_PROTOCOL}\n${_AWK_TODO_PROTOCOL}\n${_AWK_CLAUDE_SSE}"')
# --- Inline event_replay.awk reference in interactive_mode ---
content = content.replace('awk_run -f "$AWK_DIR/json.awk" -f "$AWK_DIR/protocol.awk" -f "$AWK_DIR/event_replay.awk"', 'awk_run "${_AWK_JSON}\n${_AWK_PROTOCOL}\n${_AWK_EVENT_REPLAY}"')
# --- Inline stats.awk references ---
content = content.replace('awk_run -v action=update -f "$AWK_DIR/stats.awk"', 'awk_run -v action=update "${_AWK_STATS}"')
content = content.replace('awk_run -v action=dump -f "$AWK_DIR/stats.awk"', 'awk_run -v action=dump "${_AWK_STATS}"')
content = content.replace('awk_run -v action=sync -f "$AWK_DIR/stats.awk"', 'awk_run -v action=sync "${_AWK_STATS}"')
# --- Inline compact_dp.awk reference ---
content = content.replace('-f "$AWK_DIR/compact_dp.awk" "$CONV_FILE"', '"${_AWK_COMPACT_DP}" "$CONV_FILE"')
# --- Inline send_sub_result.awk reference ---
content = content.replace('-f "$AWK_DIR/json.awk" -f "$AWK_DIR/send_sub_result.awk"', '"${_AWK_JSON}\n${_AWK_SEND_SUB_RESULT}"')
# --- Write output ---
with open(output_path, 'w') as f:
    f.write(content)

os.chmod(output_path, 0o755)

lines = content.count('\n')
size = len(content)
print(f"Done: {output_path} ({lines} lines, {size} bytes)")
PYEOF
