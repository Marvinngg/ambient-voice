#!/bin/bash
# 层 B 说话人分离评估
# 使用 FluidAudio CLI 跑 AMI 数据集 benchmark
# 输出 JSON 结果到 results/ 目录
#
# 用法:
#   ./run_diarization_benchmark.sh            # 跑全部 AMI test set (16 场)
#   ./run_diarization_benchmark.sh ES2004a    # 跑单场

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
CLI=""

# 查找 fluidaudiocli
find_cli() {
    # 优先用已编译的
    local candidates=(
        "/tmp/FluidAudio/.build/release/fluidaudiocli"
        "$HOME/.local/bin/fluidaudiocli"
    )
    for c in "${candidates[@]}"; do
        if [ -x "$c" ]; then
            CLI="$c"
            return
        fi
    done

    # 没找到，需要编译
    echo "fluidaudiocli not found, building..."
    if [ ! -d "/tmp/FluidAudio" ]; then
        git clone --depth 1 https://github.com/FluidInference/FluidAudio.git /tmp/FluidAudio
    fi
    cd /tmp/FluidAudio && swift build -c release
    CLI="/tmp/FluidAudio/.build/release/fluidaudiocli"
}

# AMI test set 会议列表（从 UEM 验证）
AMI_TEST_MEETINGS=(
    EN2002a EN2002b EN2002c EN2002d
    ES2004a ES2004b ES2004c ES2004d
    IS1009a IS1009b IS1009c IS1009d
    TS3003a TS3003b TS3003c TS3003d
)

# 跑单场 AMI offline benchmark
run_single() {
    local meeting="$1"
    local output="$RESULTS_DIR/ami_offline_${meeting}.json"

    if [ -f "$output" ]; then
        echo "SKIP: $meeting (result exists: $output)"
        return
    fi

    echo "RUN: $meeting ..."
    "$CLI" diarization-benchmark \
        --mode offline \
        --single-file "$meeting" \
        --auto-download \
        --output "$output" \
        2>>"$RESULTS_DIR/stderr.log"

    if [ -f "$output" ]; then
        # 从 JSON 提取关键指标
        local der rtfx spk_det spk_gt proc_time
        der=$(python3 -c "import json; d=json.load(open('$output'))[0]; print(f\"{d['der']:.1f}\")")
        rtfx=$(python3 -c "import json; d=json.load(open('$output'))[0]; print(f\"{d['rtfx']:.1f}\")")
        spk_det=$(python3 -c "import json; d=json.load(open('$output'))[0]; print(d['detectedSpeakers'])")
        spk_gt=$(python3 -c "import json; d=json.load(open('$output'))[0]; print(d['groundTruthSpeakers'])")
        proc_time=$(python3 -c "import json; d=json.load(open('$output'))[0]; print(f\"{d['processingTime']:.2f}\")")
        echo "  OK: DER=${der}% RTFx=${rtfx}x Speakers=${spk_det}/${spk_gt} Time=${proc_time}s"
    else
        echo "  FAIL: no output file"
    fi
}

# 汇总所有结果
summarize() {
    local summary="$RESULTS_DIR/ami_offline_summary.json"

    python3 - "$RESULTS_DIR" "$summary" << 'PYTHON'
import json, sys, os, glob

results_dir = sys.argv[1]
output_path = sys.argv[2]

files = sorted(glob.glob(os.path.join(results_dir, "ami_offline_*.json")))
files = [f for f in files if "summary" not in f]

all_results = []
for f in files:
    with open(f) as fh:
        data = json.load(fh)
        if isinstance(data, list):
            all_results.extend(data)
        else:
            all_results.append(data)

if not all_results:
    print("No results found")
    sys.exit(1)

# 汇总
n = len(all_results)
avg_der = sum(r["der"] for r in all_results) / n
avg_rtfx = sum(r["rtfx"] for r in all_results) / n
avg_jer = sum(r["jer"] for r in all_results) / n
total_proc = sum(r["processingTime"] for r in all_results)

# 按会议排序输出
print(f"\n{'Meeting':<12} {'DER%':>6} {'JER%':>6} {'Miss%':>6} {'FA%':>6} {'SE%':>6} {'Spk':>7} {'RTFx':>8} {'Time':>7}")
print("-" * 78)
for r in sorted(all_results, key=lambda x: x["der"]):
    spk = f"{r['detectedSpeakers']}/{r['groundTruthSpeakers']}"
    print(f"{r['meeting']:<12} {r['der']:6.1f} {r['jer']:6.1f} {r['missRate']:6.1f} "
          f"{r['falseAlarmRate']:6.1f} {r['speakerErrorRate']:6.1f} {spk:>7} {r['rtfx']:8.1f} {r['processingTime']:7.2f}s")
print("-" * 78)
print(f"{'AVERAGE':<12} {avg_der:6.1f} {avg_jer:6.1f} {'':>6} {'':>6} {'':>6} {'':>7} {avg_rtfx:8.1f} {total_proc:7.2f}s")

# 写 JSON
summary = {
    "dataset": "AMI",
    "split": "test",
    "mode": "offline",
    "n_meetings": n,
    "avg_der": round(avg_der, 2),
    "avg_jer": round(avg_jer, 2),
    "avg_rtfx": round(avg_rtfx, 2),
    "total_processing_time_s": round(total_proc, 2),
    "results": all_results
}
with open(output_path, "w") as f:
    json.dump(summary, f, indent=2, ensure_ascii=False)

print(f"\nSummary saved to: {output_path}")
PYTHON
}

# Main
find_cli
mkdir -p "$RESULTS_DIR"
echo "CLI: $CLI"
echo "Results: $RESULTS_DIR"
echo ""

if [ $# -ge 1 ]; then
    # 指定单场
    run_single "$1"
else
    # 跑全部
    echo "Running AMI test set (${#AMI_TEST_MEETINGS[@]} meetings)..."
    echo ""
    for meeting in "${AMI_TEST_MEETINGS[@]}"; do
        run_single "$meeting"
    done
    echo ""
    summarize
fi
