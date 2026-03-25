#!/bin/bash
# 服务器端统一 pipeline
# 自动扫描 data/ 下所有用户目录，有数据就跑合并
# cron: */10 * * * * bash ~/antigravity/we/server/scripts/pipeline.sh

set -euo pipefail

BASE_DIR="$HOME/antigravity/we"
DATA_DIR="$BASE_DIR/data"
SERVER_DIR="$BASE_DIR/server"
VENV="$HOME/we-env"

if [ -f "$VENV/bin/python3" ]; then
    PYTHON="$VENV/bin/python3"
else
    PYTHON=python3
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $2" >> "$1/pipeline.log"
}

process_user() {
    local user_dir="$1"
    local user_name=$(basename "$user_dir")

    [ -f "$user_dir/voice-history.jsonl" ] || return 0
    [ -f "$user_dir/distill-gemini.jsonl" ] || return 0

    # 合并（distill-gemini 是唯一的训练数据来源）
    local merge_result=$($PYTHON "$SERVER_DIR/merge_pairs.py"         --inputs "$user_dir/distill-gemini.jsonl"         --output "$user_dir/merged-pairs.jsonl" 2>&1) || true

    if echo "$merge_result" | grep -q "Merged:"; then
        local merged=$(echo "$merge_result" | grep "Merged:" | head -1)
        log "$user_dir" "[$user_name] MERGE: $merged"
    fi
}

for user_dir in "$DATA_DIR"/*/; do
    [ -d "$user_dir" ] || continue
    process_user "$user_dir"
done
