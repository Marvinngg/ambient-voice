#!/usr/bin/env python3
"""
合并多条蒸馏路线的训练数据。
支持去重、冲突检测、人工纠错优先。
"""

import json
import argparse
from collections import defaultdict


def main():
    parser = argparse.ArgumentParser(description="Merge distillation pairs from multiple sources")
    parser.add_argument("--inputs", nargs="+", required=True, help="Input JSONL files")
    parser.add_argument("--corrections", default=None,
                        help="Human corrections JSONL (highest priority)")
    parser.add_argument("--output", required=True, help="Output merged JSONL")
    args = parser.parse_args()

    # 按 input 文本分组
    by_input: dict[str, list[dict]] = defaultdict(list)

    # 先加载人工纠错（最高优先级）
    if args.corrections:
        with open(args.corrections) as f:
            for line in f:
                entry = json.loads(line.strip())
                # 转换纠错格式到训练对格式
                pair = {
                    "input": entry.get("rawText") or entry.get("insertedText", ""),
                    "output": entry.get("userFinalText", ""),
                    "source": "human",
                    "quality": entry.get("quality", 1.0),
                    "sample_weight": 2.0  # 人工纠错权重翻倍
                }
                if pair["input"] and pair["output"]:
                    by_input[pair["input"]].append(pair)

    # 加载自动蒸馏数据
    for filepath in args.inputs:
        with open(filepath) as f:
            for line in f:
                pair = json.loads(line.strip())
                pair.setdefault("sample_weight", 1.0)
                by_input[pair["input"]].append(pair)

    # 合并策略
    merged = []
    conflicts = 0

    for input_text, pairs in by_input.items():
        # 如果有人工纠错，以人工为准
        human = [p for p in pairs if p["source"] == "human"]
        if human:
            merged.append(human[0])
            continue

        # 多条自动蒸馏：检查是否一致
        outputs = set(p["output"] for p in pairs)
        if len(outputs) == 1:
            # 一致，取第一条，权重可以叠加
            best = pairs[0]
            best["sample_weight"] = min(len(pairs), 2.0)  # 多路一致，加权
            merged.append(best)
        else:
            # 冲突：都保留，标记冲突，后续评估时关注
            conflicts += 1
            for p in pairs:
                p["conflict"] = True
                merged.append(p)

    with open(args.output, "w") as f:
        for pair in merged:
            f.write(json.dumps(pair, ensure_ascii=False) + "\n")

    sources = defaultdict(int)
    for p in merged:
        sources[p["source"]] += 1

    print(f"Merged: {len(merged)} pairs from {len(by_input)} unique inputs")
    print(f"Sources: {dict(sources)}")
    print(f"Conflicts: {conflicts}")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
