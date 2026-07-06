#!/usr/bin/env bash
# watch.sh — 实时查看 agent session 进展
#
# Usage:
#   scripts/watch.sh <session>                      # 单 session
#   scripts/watch.sh <s1> <s2> [s3] ...             # 多 session → tmux 自动分屏
#
# 参数可以是：session_id | session_dir | events.jsonl 路径
#
# Example:
#   scripts/watch.sh sub_20260706-193403-a105
#   scripts/watch.sh sub_20260706-193403-a105 sub_20260706-193403-7e47

set -euo pipefail

# ── resolve: 参数 → events.jsonl 路径 ──
resolve_session() {
    local arg="$1"
    if [[ -f "$arg" ]]; then echo "$arg"
    elif [[ -d "$arg" ]]; then echo "$arg/events.jsonl"
    else
        local found
        found=$(find "${BASH_AGENT_HOME:-$HOME}/.bash-agent/projects" -type d -name "$arg" 2>/dev/null | head -1)
        [[ -n "$found" && -f "$found/events.jsonl" ]] && echo "$found/events.jsonl" || return 1
    fi
}

# ── watch_one ──
watch_one() {
    local f="$1" sid
    sid=$(basename "$(dirname "$f")")
    printf '\033[1m=== %s ===\033[0m\n\n' "$sid"
    tail -n +1 -f "$f" | python3 -c '
import json, sys
R="\033[0m"; D="\033[90m"; G="\033[32m"; Y="\033[33m"; C="\033[36m"; E="\033[31m"; M="\033[35m"; B="\033[1m"
def ts(inp):
    if isinstance(inp, dict):
        for v in inp.values():
            s=str(v)
            if s: return s[:80]
    elif isinstance(inp, str): return inp[:80]
    return ""
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: e=json.loads(line)
    except: continue
    t=e.get("type","")
    if t=="text": sys.stdout.write(e.get("content",""))
    elif t=="thinking":
        s=e.get("content","")
        if s: sys.stdout.write(D+s+R)
    elif t=="tool_call":
        sm=e.get("summary","") or ts(e.get("input",""))
        sys.stdout.write("\n"+M+"[tool] "+e.get("name","")+"("+sm+")"+R+"\n")
    elif t=="tool_result":
        ct=e.get("content","")
        if len(ct)>300: ct=ct[:300]+"..."
        col=G if e.get("exit_code",0)==0 else E
        sys.stdout.write(col+ct+R+"\n")
    elif t=="usage":
        i,o=e.get("input_tokens",0),e.get("output_tokens",0)
        cr,cc=e.get("cache_read_input_tokens",0),e.get("cache_creation_input_tokens",0)
        sys.stdout.write(D+"[tokens] in=%d out=%d cache_r=%d cache_w=%d (%s)"%(i,o,cr,cc,e.get("kind","agent"))+R+"\n")
    elif t=="sub_agent_start":
        sys.stdout.write("\n"+C+"started: "+e.get("session_id","")+R+"\n")
    elif t=="sub_agent_result":
        st=e.get("status","");sid=e.get("session_id","")
        i,o=e.get("input_tokens",0),e.get("output_tokens",0)
        tx=e.get("text","")
        col=C if st=="ok" else E
        sys.stdout.write(col+"done: %s [%s] (in=%d, out=%d)"%(sid,st,i,o)+R+"\n")
        if tx: sys.stdout.write(D+tx[:500]+R+"\n")
    elif t=="stop":
        sys.stdout.write("\n"+D+"-- "+e.get("reason","")+" --"+R+"\n")
    elif t=="error":
        sys.stdout.write("\n"+E+"error: "+e.get("message","")+R+"\n")
    elif t=="user_input":
        sys.stdout.write("\n"+G+"> "+e.get("content","")+R+"\n")
    elif t=="async_task_result":
        tid=e.get("task_id","");code=e.get("exit_code",0)
        col=C if code==0 else E
        sys.stdout.write(col+"bg-bash: %s exit=%d"%(tid,code)+R+"\n")
    elif t=="context_update":
        sys.stdout.write(C+"[compact] "+e.get("trigger","")+R+"\n")
    elif t=="session_start":
        sys.stdout.write(B+"=== "+e.get("session_id","")+" ==="+R+"\n")
    sys.stdout.flush()
'
}

# ── main ──
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <session> [<session2> ...]"
    echo ""
    echo "参数: session_id | session_dir | events.jsonl 路径"
    echo "单 session: 直接格式化输出"
    echo "多 session: tmux 自动分屏（每个 pane 一个 session）"
    echo ""
    echo "Examples:"
    echo "  $0 sub_20260706-193403-a105"
    echo "  $0 sub_20260706-193403-a105 sub_20260706-193403-7e47"
    exit 1
fi

FILES=()
for arg in "$@"; do
    file=$(resolve_session "$arg") || {
        echo "Error: session not found: $arg" >&2
        echo "  Searched: ${BASH_AGENT_HOME:-$HOME}/.bash-agent/projects" >&2
        exit 1
    }
    FILES+=("$file")
done

if [[ ${#FILES[@]} -eq 1 ]]; then
    watch_one "${FILES[0]}"
    exit 0
fi

# 多 session: tmux 分屏
if [[ -z "${TMUX:-}" ]]; then
    echo "Error: 多 session 监控需要 tmux 环境" >&2
    echo "  请在 tmux 中运行，或分别开多个终端:" >&2
    for f in "${FILES[@]}"; do echo "    $0 $f" >&2; done
    exit 1
fi

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
TOTAL=${#FILES[@]}
for ((i=1; i<TOTAL; i++)); do
    if (( i % 2 == 1 )); then
        tmux split-window -h -p 50 "$SELF '${FILES[i]}'"
    else
        tmux split-window -v -p 50 "$SELF '${FILES[i]}'"
    fi
    sleep 0.1
done
tmux select-layout tiled 2>/dev/null || true

# 当前 pane 跑第一个
watch_one "${FILES[0]}"
