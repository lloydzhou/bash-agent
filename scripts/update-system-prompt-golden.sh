#!/usr/bin/env bash
# update-system-prompt-golden.sh — 从 bash 参考版本生成 golden 模板
#
# 运行 mock server → 用 bash agent 输出 system prompt → 替换路径为占位符
# → 覆盖写入 tests/fixtures/system_prompt_expected.txt
#
# 用法: bash scripts/update-system-prompt-golden.sh

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="${AGENT:-$ROOT_DIR/src/agent.sh}"
MOCK_SERVER="$ROOT_DIR/tests/fixtures/mock_server.py"
FIXTURE_EN="$ROOT_DIR/tests/fixtures/system_prompt_expected.txt"
FIXTURE_ZH="$ROOT_DIR/tests/fixtures/system_prompt_expected_zh_CN.txt"
PORT=9889  # 避免与 test.sh 默认端口冲突

# 清理函数
cleanup() {
    [[ -n "${MOCK_PID:-}" ]] && kill "$MOCK_PID" 2>/dev/null
    [[ -n "${_TEST_HOME:-}" ]] && rm -rf "$_TEST_HOME"
}
trap cleanup EXIT

# 计算 project_key（与 test.sh 保持一致）
project_key() {
    local cwd="$1"
    cwd="${cwd#/}"
    cwd="${cwd//\//-}"
    cwd=$(printf '%s' "$cwd" | awk '{ gsub(/[^A-Za-z0-9._-]/, "-"); gsub(/-+/, "-", $0); sub(/^-+/, "", $0); sub(/-+$/, "", $0); print }')
    printf -- '-%s' "$cwd"
}

generate_golden() {
    local locale_name="$1" locale_value="$2" marker="$3" fixture_file="$4"

    echo "--- Generating $locale_name golden ($fixture_file) ---"

    # 设置 fixture 环境
    local home_dir project_dir session_id project_key_value project_storage
    home_dir=$(mktemp -d "${TMPDIR:-/tmp}/bash-agent-golden.XXXXXX")
    _TEST_HOME="$home_dir"
    project_dir="$home_dir/project"
    session_id="system-prompt-parity"
    mkdir -p "$project_dir" "$home_dir/.bash-agent"
    project_dir="$(cd "$project_dir" && pwd -P)"
    mkdir -p "$project_dir/skills/parity-skill"

    # AGENTS.md
    cat > "$project_dir/AGENTS.md" <<'EOF'
Project instruction fixture.
Keep this text stable for system prompt parity checks.
EOF

    # Skill
    cat > "$project_dir/skills/parity-skill/SKILL.md" <<'EOF'
# Parity Skill

Use this fixture skill only for system prompt parity tests.
Base path token: ${BASH_AGENT_SKILL_DIR}
EOF

    project_key_value="$(cd "$project_dir" && project_key "$project_dir")"
    project_storage="$home_dir/.bash-agent/projects/$project_key_value/$session_id"
    mkdir -p "$project_storage"

    # plan.md
    cat > "$project_storage/plan.md" <<'EOF'
1. Keep the fixture plan stable.
2. Compare generated system prompts exactly.
EOF

    # summary.txt
    cat > "$project_storage/summary.txt" <<'EOF'
Task focus: system prompt parity fixture.
Latest request: compare prompt construction across runtimes.
Progress: fixture seeded before agent execution.
Tool evidence: none.
Reflections: exact prompt drift must fail this test.
EOF

    : > "$project_storage/conversation.jsonl"
    : > "$project_storage/events.jsonl"
    : > "$project_storage/plan.draft"
    : > "$project_storage/stats.json"

    local platform prompt_shell
    platform="$(uname -s 2>/dev/null || echo unknown)"
    prompt_shell="${SHELL:-/bin/sh}"

    # 启动 mock server
    BASH_AGENT_TEST_PORT="$PORT" python3 "$MOCK_SERVER" &
    MOCK_PID=$!
    sleep 1
    if ! curl -sS "http://localhost:$PORT/" 2>/dev/null | grep -q ok; then
        echo "ERROR: Failed to start mock server on port $PORT"
        return 1
    fi

    # 运行 bash agent
    local candidate_err
    candidate_err="$home_dir/candidate.err"
    (
        cd "$project_dir" &&
        BASH_AGENT_HOME="$home_dir" HOME="$home_dir" SHELL="$prompt_shell" \
        LANG="$locale_value" LC_ALL="$locale_value" \
        "$AGENT" -p claude --base-url "http://localhost:$PORT/v1" -m test --api-key test \
            --session "$session_id" --skill parity-skill "$marker" \
            >/dev/null 2>"$candidate_err"
    ) || true

    # 从 mock server 提取 system prompt
    local captured_prompt
    captured_prompt=$(curl -sS "http://localhost:$PORT/last-request" 2>/dev/null | EXPECTED_MARKER="$marker" python3 -c '
import json, os, sys
try:
    captured = json.load(sys.stdin)
    body = json.loads(captured.get("body", "{}"))
except Exception as exc:
    print(f"failed to parse captured request: {exc}", file=sys.stderr)
    sys.exit(1)
marker = os.environ["EXPECTED_MARKER"]
if marker not in json.dumps(body.get("messages", []), ensure_ascii=False):
    print("captured request did not contain expected marker", file=sys.stderr)
    sys.exit(1)
system = body.get("system")
if not isinstance(system, str) or not system:
    print("captured request has no top-level system prompt", file=sys.stderr)
    sys.exit(1)
sys.stdout.write(system)
')

    if [[ -z "$captured_prompt" ]]; then
        echo "ERROR: Failed to capture system prompt"
        cat "$candidate_err" 2>/dev/null
        return 1
    fi

    # 用 Python 将实际路径替换回占位符
    local golden_output
    golden_output=$(EXPECTED_HOME="$home_dir" \
        EXPECTED_PROJECT="$project_dir" \
        EXPECTED_PROJECT_KEY="$project_key_value" \
        EXPECTED_PLATFORM="$platform" \
        EXPECTED_SHELL="$prompt_shell" \
        python3 -c '
import os, sys

prompt = sys.stdin.read()

# 按长度降序替换，避免部分匹配
replacements = [
    (os.environ["EXPECTED_PROJECT"], "__PROJECT__"),
    (os.environ["EXPECTED_HOME"], "__HOME__"),
    (os.environ["EXPECTED_PROJECT_KEY"], "__PROJECT_KEY__"),
    (os.environ["EXPECTED_PLATFORM"], "__PLATFORM__"),
    (os.environ["EXPECTED_SHELL"], "__SHELL__"),
]
replacements.sort(key=lambda x: len(x[0]), reverse=True)

for actual, placeholder in replacements:
    prompt = prompt.replace(actual, placeholder)

sys.stdout.write(prompt)
' <<< "$captured_prompt") || {
        echo "ERROR: Failed to convert to placeholder template"
        return 1
    }

    # 写入 fixture 文件（强制尾随一个换行，与 golden 模板格式一致）
    printf '%s\n' "$golden_output" > "$fixture_file"
    echo "Written to $fixture_file ($(wc -l < "$fixture_file") lines)"

    # 清理
    kill "$MOCK_PID" 2>/dev/null
    MOCK_PID=""
    rm -rf "$home_dir"
    _TEST_HOME=""
}

generate_golden "en_US" "en_US.UTF-8" "SYSTEM_PROMPT_GOLDEN_EN" "$FIXTURE_EN" || {
    echo "FAILED: en_US golden"
    exit 1
}

generate_golden "zh_CN" "zh_CN.UTF-8" "SYSTEM_PROMPT_GOLDEN_ZH" "$FIXTURE_ZH" || {
    echo "FAILED: zh_CN golden"
    exit 1
}

echo ""
echo "Done. Both golden templates updated."
echo "Run 'make test-bash' to verify against the new golden."
