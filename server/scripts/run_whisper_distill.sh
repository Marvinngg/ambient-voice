#!/bin/bash
# 路线 A: Whisper 增量蒸馏（4090 服务器 cron 调用）
# 每次只处理新增的 voice-history 条目

set -euo pipefail

DATA_DIR="$HOME/we-data"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV="$HOME/we-env"
LOG="$DATA_DIR/distill.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# 检查数据文件
if [ ! -f "$DATA_DIR/voice-history.jsonl" ]; then
    exit 0
fi

# 激活 venv
if [ -f "$VENV/bin/python3" ]; then
    PYTHON="$VENV/bin/python3"
else
    PYTHON=python3
fi

# 运行增量 Whisper 蒸馏
result=$($PYTHON "$SCRIPT_DIR/gen_distill_whisper.py" \
    --input "$DATA_DIR/voice-history.jsonl" \
    --output "$DATA_DIR/distill-whisper.jsonl" \
    --audio-dir "$DATA_DIR/audio" \
    --incremental 2>&1) || true

if echo "$result" | grep -q "No new entries"; then
    : # 无新数据
elif echo "$result" | grep -q "Done:"; then
    pairs=$(echo "$result" | grep "Done:" | head -1)
    log "DISTILL-A: $pairs"
else
    log "DISTILL-A: error - $(echo "$result" | tail -1)"
fi
