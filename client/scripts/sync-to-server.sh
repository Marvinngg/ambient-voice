#!/bin/bash
# 同步 ~/.we/ 数据到训练服务器 + 运行 Gemini 蒸馏
# 配置从 ~/.we/config.json 读取（distill + sync 段）
# 由 launchd 监听文件变化自动触发，也可手动执行: make sync

set -euo pipefail

LOCAL_DIR="$HOME/.we"
CONFIG="$LOCAL_DIR/config.json"
LOG="$LOCAL_DIR/sync.log"
DISTILL_SCRIPT="$(dirname "$0")/../../server/gen_distill_gemini.py"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# 读取 config.json 字段（纯 python 单行，不引入 jq 依赖）
cfg() { python3 -c "import json,sys; d=json.load(open('$CONFIG')); print(d.get('$1',{}).get('$2','$3'))" 2>/dev/null || echo "$3"; }

# === Gemini 蒸馏（增量，含词典） ===
DISTILL_ENABLED=$(cfg distill enabled false)
if [ "$DISTILL_ENABLED" = "True" ] || [ "$DISTILL_ENABLED" = "true" ]; then
    if [ -f "$LOCAL_DIR/voice-history.jsonl" ] && [ -f "$DISTILL_SCRIPT" ]; then
        DISTILL_URL=$(cfg distill base_url "https://generativelanguage.googleapis.com/v1beta/openai")
        DISTILL_KEY=$(cfg distill api_key "")
        DISTILL_MODEL=$(cfg distill model "gemini-2.5-flash")
        DICTIONARY_PATH=$(cfg distill dictionary "$LOCAL_DIR/dictionary.json")

        if [ -n "$DISTILL_KEY" ]; then
            DISTILL_ARGS=(
                --input "$LOCAL_DIR/voice-history.jsonl"
                --output "$LOCAL_DIR/distill-gemini.jsonl"
                --base-url "$DISTILL_URL"
                --api-key "$DISTILL_KEY"
                --model "$DISTILL_MODEL"
                --incremental
            )
            if [ -f "$DICTIONARY_PATH" ]; then
                DISTILL_ARGS+=(--dictionary "$DICTIONARY_PATH")
            fi

            result=$(python3 "$DISTILL_SCRIPT" "${DISTILL_ARGS[@]}" 2>&1) || true
            if echo "$result" | grep -q "No new entries"; then
                : # 无新数据，静默
            elif echo "$result" | grep -q "Done:"; then
                pairs=$(echo "$result" | grep "Done:" | head -1)
                log "DISTILL: $pairs"
            else
                log "DISTILL: error - $(echo "$result" | tail -1)"
            fi
        else
            log "DISTILL: skipped (no api_key in config)"
        fi
    fi
else
    : # 蒸馏未启用，静默
fi

# === 同步到服务器 ===
SYNC_ENABLED=$(cfg sync enabled false)
if [ "$SYNC_ENABLED" != "True" ] && [ "$SYNC_ENABLED" != "true" ]; then
    exit 0
fi

SERVER=$(cfg sync server "")
REMOTE_DIR=$(cfg sync remote_dir "~/we-data")

if [ -z "$SERVER" ]; then
    log "SKIP: sync.server not configured"
    exit 0
fi

# 检查连通性
if ! ssh -o ConnectTimeout=3 -o BatchMode=yes "$SERVER" true 2>/dev/null; then
    log "SKIP: server unreachable ($SERVER)"
    exit 0
fi

# 同步 voice-history
rsync -az "$LOCAL_DIR/voice-history.jsonl" "$SERVER:$REMOTE_DIR/" 2>/dev/null && \
    log "OK: voice-history.jsonl" || log "FAIL: voice-history.jsonl"

# 同步 Gemini 蒸馏结果到服务器
if [ -f "$LOCAL_DIR/distill-gemini.jsonl" ]; then
    rsync -az "$LOCAL_DIR/distill-gemini.jsonl" "$SERVER:$REMOTE_DIR/" 2>/dev/null && \
        log "OK: distill-gemini.jsonl" || log "FAIL: distill-gemini.jsonl"
fi

# 同步词典到服务器
DICTIONARY_PATH=$(cfg distill dictionary "$LOCAL_DIR/dictionary.json")
if [ -f "$DICTIONARY_PATH" ]; then
    rsync -az "$DICTIONARY_PATH" "$SERVER:$REMOTE_DIR/dictionary.json" 2>/dev/null && \
        log "OK: dictionary.json" || log "FAIL: dictionary.json"
fi
