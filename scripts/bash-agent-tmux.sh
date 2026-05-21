#!/usr/bin/env bash
# bash-agent-tmux.sh — 用 tmux 模拟类 Chat 界面
#
# 布局:
#   ┌──────────┬──────────────────────────────┐
#   │          │  tail -f <输出文件>          │
#   │  watch   │                              │
#   │  list-   ├──────────────────────────────┤
#   │  sessions│  bash-agent -i 2>&1 | tee …  │
#   └──────────┴──────────────────────────────┘
#
# 用法:
#   ./scripts/bash-agent-tmux.sh              # 默认用 bash-agent
#   ./scripts/bash-agent-tmux.sh goagent      # 用 goagent
#   ./scripts/bash-agent-tmux.sh rustagent    # 用 rustagent

set -euo pipefail

AGENT="${1:-bash-agent}"
SESSION="bash-agent-tmux-$$"
OUTFILE=$(mktemp "${TMPDIR:-/tmp}/bash-agent-tmux.XXXXXX")
trap 'rm -f "$OUTFILE"' EXIT
trap 'rm -f "$OUTFILE"; tmux kill-session -t "$SESSION" 2>/dev/null || true' INT TERM

# 清理残留
tmux kill-session -t "$SESSION" 2>/dev/null || true

# 创建后台 session
tmux new-session -d -s "$SESSION" 2>/dev/null

# ─── Pane 0: 左侧 — watch list-sessions ───
tmux send-keys -t "$SESSION:0.0" \
  "watch -n 2 $AGENT --list-sessions 2>/dev/null || echo 'list-sessions 不可用'" Enter

# ─── 分割右侧 (左 30% / 右 70%) ───
# -p 70: 新 pane（右）占 70%，原 pane（左）留 30%
tmux split-window -h -t "$SESSION:0.0" -p 70

# ─── 分割右下 (上 70% / 下 30%) ───
# -p 30: 新 pane（下）占 30%，原 pane（上）留 70%
tmux split-window -v -t "$SESSION:0.1" -p 30

# ─── Pane 1: 右上 — tail -f 输出文件 ───
tmux send-keys -t "$SESSION:0.1" "tail -f $OUTFILE" Enter

# ─── Pane 2: 右下 — 运行 agent ───
tmux send-keys -t "$SESSION:0.2" \
  "echo '>>> 启动 ${AGENT}，输出写入 ${OUTFILE}' && ${AGENT} -i 2>&1 | tee ${OUTFILE}" Enter

# 聚焦到输入 pane
tmux select-pane -t "$SESSION:0.2"

# 设置 pane 标题（方便辨识）
tmux set-option -t "$SESSION" pane-border-status top 2>/dev/null || true
tmux set-option -t "$SESSION" pane-border-format "#{pane_index} #{pane_title}" 2>/dev/null || true
tmux select-pane -T "watch:list-sessions" -t "$SESSION:0.0" 2>/dev/null || true
tmux select-pane -T "输出窗口"           -t "$SESSION:0.1" 2>/dev/null || true
tmux select-pane -T "输入窗口"           -t "$SESSION:0.2" 2>/dev/null || true

echo "tmux session: $SESSION"
echo "输出文件: $OUTFILE"
echo "按 Ctrl+B D 分离，Ctrl+C 停止。"
echo "重新附加: tmux attach -t $SESSION"
echo "删除: tmux kill-session -t $SESSION"

tmux attach -t "$SESSION"
