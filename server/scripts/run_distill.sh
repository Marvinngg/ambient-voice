#!/bin/bash
set -euo pipefail

# Gemini 蒸馏 + 合并
# 用法: ./run_distill.sh --gemini-key <key> [--dictionary <path>] [--voice-history <path>] [--corrections <path>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="${PROJECT_DIR}/workdir/$(date +%Y%m%d-%H%M%S)"

# 默认路径
VOICE_HISTORY="${HOME}/.we/voice-history.jsonl"
CORRECTIONS="${HOME}/.we/corrections.jsonl"
GEMINI_KEY=""
DICTIONARY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --gemini-key) GEMINI_KEY="$2"; shift 2 ;;
        --voice-history) VOICE_HISTORY="$2"; shift 2 ;;
        --corrections) CORRECTIONS="$2"; shift 2 ;;
        --dictionary) DICTIONARY="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ -z "$GEMINI_KEY" ]; then
    echo "Error: --gemini-key required"
    exit 1
fi

# 默认词典路径
if [ -z "$DICTIONARY" ] && [ -f "${HOME}/.we/dictionary.json" ]; then
    DICTIONARY="${HOME}/.we/dictionary.json"
fi

mkdir -p "$WORK_DIR"
echo "Work dir: $WORK_DIR"
echo "Voice history: $VOICE_HISTORY"
echo ""

# ========== 1. Gemini 蒸馏 ==========
echo "=== Starting Gemini distillation ==="

GEMINI_ARGS=(
    --input "$VOICE_HISTORY"
    --output "${WORK_DIR}/pairs_gemini.jsonl"
    --api-key "$GEMINI_KEY"
)
if [ -n "$DICTIONARY" ] && [ -f "$DICTIONARY" ]; then
    GEMINI_ARGS+=(--dictionary "$DICTIONARY")
    echo "Using dictionary: $DICTIONARY"
fi

python3 "${PROJECT_DIR}/gen_distill_gemini.py" "${GEMINI_ARGS[@]}"
echo "Gemini done"

# ========== 2. 合并 ==========
echo ""
echo "=== Merging training data ==="

MERGE_ARGS=(
    --inputs "${WORK_DIR}/pairs_gemini.jsonl"
    --output "${WORK_DIR}/training_data.jsonl"
)

# 如果有人工纠错数据，加入合并
if [ -f "$CORRECTIONS" ]; then
    MERGE_ARGS+=(--corrections "$CORRECTIONS")
    echo "Including human corrections: $CORRECTIONS"
fi

python3 "${PROJECT_DIR}/merge_pairs.py" "${MERGE_ARGS[@]}"

# ========== 3. 统计 ==========
echo ""
echo "=== Summary ==="
if [ -f "${WORK_DIR}/pairs_gemini.jsonl" ]; then
    echo "Gemini pairs:  $(wc -l < "${WORK_DIR}/pairs_gemini.jsonl")"
fi
echo "Merged total:  $(wc -l < "${WORK_DIR}/training_data.jsonl")"
echo ""
echo "Training data ready at: ${WORK_DIR}/training_data.jsonl"
echo "Next step: python3 train_qlora_0.6b.py --data ${WORK_DIR}/training_data.jsonl"
