#!/bin/bash
# 层 A 转写质量评估 — AliMeeting Eval (中文)
# 1. 用 transcription-bench 逐个跑 mono WAV → SpeechAnalyzer 转写
# 2. 用 jiwer（标准 WER/CER 工具）计算 CER
#
# 依赖: pip install jiwer
# 用法: ./run_transcription.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EVAL_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$EVAL_DIR/datasets/Eval_Ali"
REF_DIR="$DATA_DIR/ref"
RESULTS_DIR="$EVAL_DIR/results/alimeeting_transcription"
BENCH_BIN="$EVAL_DIR/transcription-bench/.build/release/transcription-bench"

verify() {
    if [ ! -x "$BENCH_BIN" ]; then
        echo "Building transcription-bench..."
        (cd "$EVAL_DIR/transcription-bench" && swift build -c release)
    fi
    python3 -c "import jiwer" 2>/dev/null || { echo "ERROR: jiwer not found. Run: pip install jiwer"; exit 1; }
    [ -f "$REF_DIR/manifest.jsonl" ] || { echo "ERROR: manifest not found"; exit 1; }
}

run_transcription() {
    echo "=== Step 1: SpeechAnalyzer transcription ==="
    "$BENCH_BIN" --batch "$REF_DIR/manifest.jsonl" --output-dir "$RESULTS_DIR"
}

compute_cer() {
    echo ""
    echo "=== Step 2: CER evaluation (jiwer) ==="

    python3 - "$REF_DIR" "$RESULTS_DIR" << 'PYTHON'
import json, os, sys, glob
import jiwer

ref_dir = sys.argv[1]
hyp_dir = sys.argv[2]

# 加载所有 hypothesis
hyp_files = {}
for f in glob.glob(os.path.join(hyp_dir, "*.json")):
    if "_summary" in f:
        continue
    with open(f) as fh:
        data = json.load(fh)
        file_id = data.get("id", os.path.splitext(os.path.basename(f))[0])
        hyp_files[file_id] = data

# 加载 reference
ref_files = {}
for f in glob.glob(os.path.join(ref_dir, "*.json")):
    with open(f) as fh:
        data = json.load(fh)
        ref_files[data["id"]] = data

matched = sorted(set(hyp_files.keys()) & set(ref_files.keys()))
if not matched:
    print("No matching files found")
    sys.exit(1)

print(f"Evaluating {len(matched)} files (jiwer CER)...")
print(f"{'ID':<20} {'CER%':>7} {'RefChars':>9} {'HypChars':>9} {'RTFx':>6}")
print("-" * 58)

results = []
all_refs = []
all_hyps = []

for file_id in matched:
    ref_text = ref_files[file_id]["reference"]
    hyp_text = hyp_files[file_id].get("hypothesis", "")
    rtfx = hyp_files[file_id].get("rtfx", 0)

    # jiwer CER
    output = jiwer.process_characters(ref_text, hyp_text)

    all_refs.append(ref_text)
    all_hyps.append(hyp_text)

    result = {
        "id": file_id,
        "cer": round(output.cer * 100, 2),
        "substitutions": output.substitutions,
        "deletions": output.deletions,
        "insertions": output.insertions,
        "ref_chars": len(ref_text),
        "hyp_chars": len(hyp_text),
        "rtfx": rtfx
    }
    results.append(result)

    print(f"{file_id:<20} {result['cer']:7.1f} {result['ref_chars']:9d} {result['hyp_chars']:9d} {rtfx:6.1f}")

# 整体 CER（jiwer 对所有文件合并计算，而非简单平均）
overall = jiwer.process_characters(all_refs, all_hyps)
avg_cer_simple = sum(r["cer"] for r in results) / len(results)

print("-" * 58)
print(f"{'OVERALL':20} {overall.cer*100:7.1f}")
print(f"{'AVG (per-file)':20} {avg_cer_simple:7.1f}")

# 保存
summary = {
    "n_files": len(results),
    "overall_cer": round(overall.cer * 100, 2),
    "avg_cer": round(avg_cer_simple, 2),
    "tool": "jiwer",
    "results": results
}
summary_path = os.path.join(hyp_dir, "cer_summary.json")
with open(summary_path, "w") as f:
    json.dump(summary, f, indent=2, ensure_ascii=False)
print(f"\nSummary: {summary_path}")
PYTHON
}

# Main
verify
mkdir -p "$RESULTS_DIR"
echo "Tool: $BENCH_BIN"
echo "Data: $REF_DIR/manifest.jsonl"
echo "Results: $RESULTS_DIR"
echo ""

run_transcription
compute_cer
