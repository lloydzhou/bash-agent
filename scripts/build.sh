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

def strip_comments(text):
    """Strip leading comment lines from awk source."""
    lines = text.split("\n")
    stripped = []
    for line in lines:
        if line.startswith("#") and not stripped:
            continue
        stripped.append(line)
    return "\n".join(stripped).strip()

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
    "http_stream": ("http_stream.awk", "_AWK_HTTP_STREAM"),
    "edit_file": ("edit_file.awk", "_AWK_EDIT_FILE"),
    "claude_sse": ("claude_sse.awk", "_AWK_CLAUDE_SSE"),
    "openai_sse": ("openai_sse.awk", "_AWK_OPENAI_SSE"),
    "convert_messages": ("convert_messages.awk", "_AWK_CONVERT_MESSAGES"),
    "convert_tools": ("convert_tools.awk", "_AWK_CONVERT_TOOLS"),
}

awk_bodies = {}
for key, (filename, varname) in awk_files.items():
    path = os.path.join(awk_dir, filename)
    with open(path) as f:
        raw = f.read()
    body = strip_comments(raw)
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

# Insert after the PROMPT="" line (end of config section)
marker = 'PROMPT=""\n'
idx = content.find(marker)
if idx != -1:
    content = content[:idx + len(marker)] + var_block + content[idx + len(marker):]

# --- Replace each awk function to use variable concatenation ---
functions = [
    ("extract_json_field", "_AWK_JSON", "", ""),
    ("parse_http_stream", "", "_AWK_HTTP_STREAM", ""),
    ("run_edit_file_awk", "_AWK_JSON", "_AWK_EDIT_FILE", r'-v json_input="$input" -v max_bytes="$max_bytes" -v meta_file="$meta_file"'),
    ("parse_sse", "_AWK_JSON", "", ""),
    ("convert_messages_to_openai", "_AWK_JSON", "_AWK_CONVERT_MESSAGES", ""),
    ("convert_tools_to_openai", "_AWK_JSON", "_AWK_CONVERT_TOOLS", ""),
    ("generate_tool_defs", "", "", ""),
]

for func_name, json_var, specific_var, extra_args in functions:
    if func_name == "extract_json_field":
        replacement = (
            "extract_json_field() {\n"
            "    local json=\"$1\" key=\"$2\"\n"
            "    printf '%s' \"$json\" | awk -v json_mode=\"extract_field\" -v json_field_key=\"$key\" \"${_AWK_JSON}\"\n"
            "}\n"
        )
    elif func_name == "run_edit_file_awk":
        replacement = (
            "run_edit_file_awk() {\n"
            "    local input=\"$1\" max_bytes=\"$2\" meta_file=\"$3\"\n"
            "    awk -v json_input=\"$input\" -v max_bytes=\"$max_bytes\" -v meta_file=\"$meta_file\" \"${_AWK_JSON}\n${_AWK_EDIT_FILE}\"\n"
            "}\n"
        )
    elif func_name == "parse_sse":
        replacement = (
            "parse_sse() {\n"
            "    case \"$PROVIDER\" in\n"
            "        claude) awk -v verbose=\"${VERBOSE:-false}\" \"${_AWK_JSON}\n${_AWK_CLAUDE_SSE}\" ;;\n"
            "        openai) awk \"${_AWK_JSON}\n${_AWK_OPENAI_SSE}\" ;;\n"
            "    esac\n"
            "}\n"
        )
    elif func_name == "generate_tool_defs":
        replacement = (
            "generate_tool_defs() {\n"
            "    local tmp\n"
            "    tmp=$(mktemp \"${AGENT_TMPDIR}/tools.XXXXXX\")\n"
            "    printf '%s\\n' \"$_TOOLS_JSON\" > \"$tmp\"\n"
            "    printf '%s' \"$tmp\"\n"
            "}\n"
        )
    else:
        # Build: awk [-v ...] "${_AWK_JSON}
        # ${_AWK_XXX}"
        awk_call = '    awk '
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
content = content.replace('TOOLS_JSON_FILE=""\n', "")

# --- Write output ---
with open(output_path, 'w') as f:
    f.write(content)

os.chmod(output_path, 0o755)

lines = content.count('\n')
size = len(content)
print(f"Done: {output_path} ({lines} lines, {size} bytes)")
PYEOF
