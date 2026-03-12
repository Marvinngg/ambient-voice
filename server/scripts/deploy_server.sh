#!/bin/bash
# 部署服务器端：同步代码 + 安装 Whisper cron + 安装依赖
# 在本地 Mac 上运行

set -euo pipefail

SERVER="${WE_SERVER:-user@your-gpu-server}"
REMOTE_CODE="~/antigravity/we/server"
LOCAL_SERVER="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== 1. 同步服务器代码 ==="
ssh "$SERVER" "mkdir -p $REMOTE_CODE/scripts"
rsync -az --exclude='__pycache__' "$LOCAL_SERVER/" "$SERVER:$REMOTE_CODE/"
echo "Done: code synced"

echo ""
echo "=== 2. 安装 Python 依赖（venv） ==="
ssh "$SERVER" bash -s <<'DEPS'
cd ~/we-env 2>/dev/null || python3 -m venv ~/we-env
source ~/we-env/bin/activate
pip install -q openai-whisper 2>/dev/null && echo "whisper: ok" || echo "whisper: already installed or error"
DEPS

echo ""
echo "=== 3. 安装 Whisper cron（每 10 分钟） ==="
ssh "$SERVER" bash -s <<'CRON'
CRON_CMD="*/10 * * * * bash ~/antigravity/we/server/scripts/run_whisper_distill.sh"
(crontab -l 2>/dev/null | grep -v "run_whisper_distill" ; echo "$CRON_CMD") | crontab -
echo "Cron installed:"
crontab -l | grep whisper
CRON

echo ""
echo "=== Done ==="
echo "Server will auto-run Whisper distillation every 10 minutes on new data."
