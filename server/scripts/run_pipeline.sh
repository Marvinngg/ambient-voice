#!/bin/bash
set -euo pipefail

# WE 完整闭环：蒸馏 → 训练 → 评估 → 部署
# 用法: ./run_pipeline.sh --gemini-key <key> [--dictionary <path>] [--skip-distill] [--skip-train] [--deploy]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="${HOME}/we-data"
WORK_DIR="${PROJECT_DIR}/workdir/$(date +%Y%m%d-%H%M%S)"

GEMINI_KEY=""
SKIP_DISTILL=false
SKIP_TRAIN=false
DO_DEPLOY=false
BASE_MODEL="Qwen/Qwen3-0.6B"
MODEL_NAME="we-polish"
DICTIONARY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --gemini-key) GEMINI_KEY="$2"; shift 2 ;;
        --skip-distill) SKIP_DISTILL=true; shift ;;
        --skip-train) SKIP_TRAIN=true; shift ;;
        --deploy) DO_DEPLOY=true; shift ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --base-model) BASE_MODEL="$2"; shift 2 ;;
        --model-name) MODEL_NAME="$2"; shift 2 ;;
        --dictionary) DICTIONARY="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# 默认词典路径
if [ -z "$DICTIONARY" ] && [ -f "$DATA_DIR/dictionary.json" ]; then
    DICTIONARY="$DATA_DIR/dictionary.json"
fi

mkdir -p "$WORK_DIR"
echo "============================================"
echo "  WE Pipeline - $(date)"
echo "============================================"
echo "Work dir:   $WORK_DIR"
echo "Data dir:   $DATA_DIR"
echo "Base model: $BASE_MODEL"
echo ""

# 检查数据
VOICE_HISTORY="$DATA_DIR/voice-history.jsonl"
CORRECTIONS="$DATA_DIR/corrections.jsonl"

if [ ! -f "$VOICE_HISTORY" ]; then
    echo "Error: $VOICE_HISTORY not found"
    echo "Run sync from client first"
    exit 1
fi

SAMPLE_COUNT=$(wc -l < "$VOICE_HISTORY")
echo "Voice history: $SAMPLE_COUNT samples"
echo ""

# ========== 1. 蒸馏 ==========
if [ "$SKIP_DISTILL" = false ]; then
    if [ -z "$GEMINI_KEY" ]; then
        echo "Error: --gemini-key required (or use --skip-distill)"
        exit 1
    fi

    echo "=== [1/4] Gemini distillation ==="

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

    # 合并
    echo ""
    echo "=== Merging ==="
    MERGE_ARGS=(
        --inputs "${WORK_DIR}/pairs_gemini.jsonl"
        --output "${WORK_DIR}/training_data.jsonl"
    )
    if [ -f "$CORRECTIONS" ]; then
        MERGE_ARGS+=(--corrections "$CORRECTIONS")
        echo "Including human corrections"
    fi
    python3 "${PROJECT_DIR}/merge_pairs.py" "${MERGE_ARGS[@]}"
else
    echo "=== [1/4] Distillation: SKIPPED ==="
    # 如果跳过蒸馏，查找最新的 training_data
    LATEST=$(ls -t "${PROJECT_DIR}"/workdir/*/training_data.jsonl 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        cp "$LATEST" "${WORK_DIR}/training_data.jsonl"
        echo "Using existing: $LATEST"
    else
        echo "Error: no training_data.jsonl found"
        exit 1
    fi
fi

TRAIN_DATA="${WORK_DIR}/training_data.jsonl"
PAIR_COUNT=$(wc -l < "$TRAIN_DATA")
echo ""
echo "Training data: $PAIR_COUNT pairs"

# ========== 2. 训练 ==========
if [ "$SKIP_TRAIN" = false ]; then
    echo ""
    echo "=== [2/4] QLoRA Training ==="

    if [ "$PAIR_COUNT" -lt 10 ]; then
        echo "Warning: only $PAIR_COUNT pairs, minimum 10 needed"
        echo "Collect more data and try again"
        exit 1
    fi

    python3 "${PROJECT_DIR}/train_qlora.py" \
        --data "$TRAIN_DATA" \
        --base-model "$BASE_MODEL" \
        --output-dir "${WORK_DIR}/checkpoints"
else
    echo ""
    echo "=== [2/4] Training: SKIPPED ==="
fi

# ========== 3. 评估 ==========
ADAPTER_DIR="${WORK_DIR}/checkpoints/adapter"
if [ -d "$ADAPTER_DIR" ]; then
    echo ""
    echo "=== [3/4] Evaluation ==="
    python3 "${PROJECT_DIR}/eval_model.py" \
        --data "$TRAIN_DATA" \
        --model-path "$ADAPTER_DIR" \
        --base-model "$BASE_MODEL" \
        --max-samples 100 \
        --output "${WORK_DIR}/eval_results.jsonl"
else
    echo ""
    echo "=== [3/4] Evaluation: SKIPPED (no adapter found) ==="
fi

# ========== 4. 部署 ==========
if [ "$DO_DEPLOY" = true ] && [ -d "$ADAPTER_DIR" ]; then
    echo ""
    echo "=== [4/4] Deploy ==="
    bash "${SCRIPT_DIR}/deploy_model.sh" \
        --adapter "$ADAPTER_DIR" \
        --base-model "$BASE_MODEL" \
        --model-name "$MODEL_NAME"
else
    echo ""
    echo "=== [4/4] Deploy: SKIPPED ==="
    if [ -d "$ADAPTER_DIR" ]; then
        echo "To deploy: bash ${SCRIPT_DIR}/deploy_model.sh --adapter $ADAPTER_DIR"
    fi
fi

echo ""
echo "============================================"
echo "  Pipeline complete"
echo "  Work dir: $WORK_DIR"
echo "============================================"
