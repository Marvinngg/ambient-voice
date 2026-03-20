#!/bin/bash
# 层 B 说话人分离评估 — AliMeeting Eval (中文)
# 1. 用 fluidaudiocli process 跑离线分离，输出 sys RTTM
# 2. 用 spyder（标准 DER 工具）对比 ref RTTM 计算 DER
#
# 依赖: pip install spy-der
# 用法: ./run_alimeeting_diarization.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$EVAL_DIR/datasets/Eval_Ali"
MONO_DIR="$DATA_DIR/mono"
REF_RTTM_DIR="$DATA_DIR/rttm"
RESULTS_DIR="$EVAL_DIR/results/alimeeting_diarization"
CLI=""

find_cli() {
    local candidates=(
        "/tmp/FluidAudio/.build/release/fluidaudiocli"
        "$HOME/.local/bin/fluidaudiocli"
    )
    for c in "${candidates[@]}"; do
        if [ -x "$c" ]; then CLI="$c"; return; fi
    done
    echo "ERROR: fluidaudiocli not found."
    echo "Run: cd /tmp && git clone --depth 1 https://github.com/FluidInference/FluidAudio.git && cd FluidAudio && swift build -c release"
    exit 1
}

verify() {
    command -v spyder >/dev/null 2>&1 || { echo "ERROR: spyder not found. Run: pip install spy-der"; exit 1; }
    [ -d "$MONO_DIR" ] || { echo "ERROR: $MONO_DIR not found"; exit 1; }
    [ -d "$REF_RTTM_DIR" ] || { echo "ERROR: $REF_RTTM_DIR not found"; exit 1; }
}

run_diarization() {
    echo "=== Step 1: FluidAudio offline diarization ==="
    for wav in "$MONO_DIR"/*.wav; do
        local filename=$(basename "$wav" .wav)
        local meeting_id=$(echo "$filename" | sed 's/_MS[0-9]*//')
        local sys_rttm="$RESULTS_DIR/${meeting_id}_sys.rttm"

        if [ -f "$sys_rttm" ]; then
            echo "  SKIP: $meeting_id (exists)"
            continue
        fi

        echo -n "  $meeting_id ... "
        "$CLI" process "$wav" --mode offline --rttm "$sys_rttm" 2>>"$RESULTS_DIR/stderr.log"

        if [ -f "$sys_rttm" ]; then
            echo "$(wc -l < "$sys_rttm" | tr -d ' ') segments"
        else
            echo "FAILED"
        fi
    done
}

compute_der() {
    echo ""
    echo "=== Step 2: DER evaluation (spyder) ==="

    # 合并所有 ref RTTM 和 sys RTTM 为单文件（spyder 支持多 recording）
    cat "$REF_RTTM_DIR"/*.rttm > "$RESULTS_DIR/all_ref.rttm"

    # 合并 sys RTTM，统一 file_id 和 ref 一致
    > "$RESULTS_DIR/all_sys.rttm"
    for ref_rttm in "$REF_RTTM_DIR"/*.rttm; do
        meeting_id=$(basename "$ref_rttm" .rttm)
        sys_rttm="$RESULTS_DIR/${meeting_id}_sys.rttm"
        if [ -f "$sys_rttm" ]; then
            cat "$sys_rttm" >> "$RESULTS_DIR/all_sys.rttm"
        fi
    done

    # 用 spyder 计算 DER（collar=0.25s 是默认值）
    echo "Per-recording DER:"
    spyder "$RESULTS_DIR/all_ref.rttm" "$RESULTS_DIR/all_sys.rttm" --per-file 2>&1 | tee "$RESULTS_DIR/der_results.txt"
}

# Main
find_cli
verify
mkdir -p "$RESULTS_DIR"

echo "CLI: $CLI"
echo "Data: $MONO_DIR → $REF_RTTM_DIR"
echo "Results: $RESULTS_DIR"
echo ""

run_diarization
compute_der
