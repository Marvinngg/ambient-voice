#!/bin/bash
# 部署服务器端：同步代码 + 安装 pipeline cron
# 在本地 Mac 上运行

set -euo pipefail

SERVER="${WE_SERVER:-user@your-gpu-server}"
REMOTE_CODE="~/antigravity/we/server"
LOCAL_SERVER="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1. 同步服务器代码 ==="
ssh "$SERVER" "mkdir -p $REMOTE_CODE/scripts"
rsync -az --exclude='__pycache__' --exclude='eval' "$LOCAL_SERVER/" "$SERVER:$REMOTE_CODE/"
echo "Done: code synced"

echo ""
echo "=== 2. 安装 pipeline cron（每 10 分钟，自动扫描所有用户） ==="
ssh "$SERVER" bash -s <<'CRON'
CRON_CMD="*/10 * * * * bash ~/antigravity/we/server/scripts/pipeline.sh"
(crontab -l 2>/dev/null | grep -v "run_whisper_distill\|pipeline.sh" ; echo "$CRON_CMD") | crontab -
echo "Cron installed:"
crontab -l | grep pipeline
CRON

echo ""
echo "=== Done ==="
echo "Server will auto-run pipeline (merge) every 10 minutes."
