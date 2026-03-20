#!/usr/bin/env python3
"""
LLM-as-Judge 数据集质量评估

用强模型（gpt-4o）评估每条训练对的质量。
输入：merged-pairs.jsonl
输出：每条的质量分 + 整体报告

用法:
    python3 judge_data_quality.py \
        --data merged-pairs.jsonl \
        --endpoint http://127.0.0.1:8045 \
        --api-key sk-xxx \
        --model gpt-4o \
        --output data_quality_report.json
"""

import json
import os
import sys
import time
import argparse
import urllib.request
import urllib.error

JUDGE_PROMPT = """你是 ASR（语音识别）后处理训练数据的质量评估专家。

我会给你一条训练数据对：
- input：语音识别引擎的原始输出（可能有错字、漏字、多字、口水词）
- output：纠正后的目标文本（用于训练模型学习纠错）

请从以下三个维度评分（每个 0-1，保留两位小数）：

1. **correctness**（纠错准确度）：output 是否正确修正了 input 中的语音识别错误？没有引入新错误？
2. **fidelity**（语义保真度）：output 是否保持了 input 的原意？没有过度改写、删减或添加原文没有的信息？
3. **naturalness**（自然流畅度）：output 是否是自然流畅的书面语？标点是否合理？

同时判断这条数据是否适合用于训练（suitable: true/false）。
不适合的情况：output 明显比 input 更差、output 被截断不完整、input 和 output 完全一样但明显有错。

只输出 JSON，不要解释：
{"correctness": 0.8, "fidelity": 0.9, "naturalness": 0.7, "suitable": true, "reason": "简短说明"}"""


def call_judge(endpoint: str, api_key: str, model: str,
               input_text: str, output_text: str, source: str,
               timeout: int = 30) -> dict:
    """调用 Judge 模型评估一条训练对"""
    url = endpoint.rstrip("/")
    if "/v1/" not in url:
        url += "/v1/chat/completions"

    user_msg = f"来源：{source}\ninput：{input_text}\noutput：{output_text}"

    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": JUDGE_PROMPT},
            {"role": "user", "content": user_msg}
        ],
        "temperature": 0,
        "max_tokens": 200
    }).encode()

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    start = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    elapsed = time.time() - start

    content = data["choices"][0]["message"]["content"].strip()

    # 解析 JSON 响应
    try:
        # 处理可能的 markdown 包裹
        if content.startswith("```"):
            content = content.split("\n", 1)[1].rsplit("```", 1)[0]
        scores = json.loads(content)
    except json.JSONDecodeError:
        scores = {"correctness": 0, "fidelity": 0, "naturalness": 0,
                  "suitable": False, "reason": f"JSON parse error: {content[:100]}"}

    scores["latency_s"] = round(elapsed, 2)
    return scores


def main():
    parser = argparse.ArgumentParser(description="LLM-as-Judge Data Quality Evaluator")
    parser.add_argument("--data", required=True, help="merged-pairs.jsonl path")
    parser.add_argument("--endpoint", required=True, help="API endpoint")
    parser.add_argument("--api-key", default="", help="API key")
    parser.add_argument("--model", default="gpt-4o", help="Judge model")
    parser.add_argument("--max-samples", type=int, default=0, help="Max samples (0=all)")
    parser.add_argument("--rate-limit", type=float, default=0.3, help="Seconds between calls")
    parser.add_argument("--output", required=True, help="Output JSON path")
    args = parser.parse_args()

    # 加载数据
    pairs = []
    with open(args.data) as f:
        for line in f:
            pairs.append(json.loads(line.strip()))

    if args.max_samples > 0:
        pairs = pairs[:args.max_samples]

    print(f"Data: {args.data} ({len(pairs)} pairs)")
    print(f"Judge: {args.model} @ {args.endpoint}")
    print()

    # 逐条评估
    results = []
    errors = 0

    for i, pair in enumerate(pairs):
        inp = pair.get("input", "")
        out = pair.get("output", "")
        source = pair.get("source", "unknown")
        conflict = pair.get("conflict", False)

        try:
            scores = call_judge(args.endpoint, args.api_key, args.model,
                               inp, out, source)
        except Exception as e:
            errors += 1
            if errors <= 5:
                print(f"  [{i}] ERROR: {e}")
            scores = {"correctness": 0, "fidelity": 0, "naturalness": 0,
                      "suitable": False, "reason": f"API error: {str(e)[:50]}"}

        result = {
            "index": i,
            "input": inp,
            "output": out,
            "source": source,
            "conflict": conflict,
            "sample_weight": pair.get("sample_weight", 1.0),
            **scores
        }
        results.append(result)

        avg_score = (scores.get("correctness", 0) + scores.get("fidelity", 0) + scores.get("naturalness", 0)) / 3
        suitable = "✓" if scores.get("suitable", False) else "✗"

        if (i + 1) % 10 == 0 or not scores.get("suitable", True):
            print(f"  [{i+1}/{len(pairs)}] {suitable} avg={avg_score:.2f} src={source}"
                  f"{' CONFLICT' if conflict else ''}"
                  f" | {inp[:30]}→{out[:30]}")

        if args.rate_limit > 0:
            time.sleep(args.rate_limit)

    # 汇总
    n = len(results)
    suitable_count = sum(1 for r in results if r.get("suitable", False))
    conflict_count = sum(1 for r in results if r.get("conflict", False))
    avg_correctness = sum(r.get("correctness", 0) for r in results) / max(n, 1)
    avg_fidelity = sum(r.get("fidelity", 0) for r in results) / max(n, 1)
    avg_naturalness = sum(r.get("naturalness", 0) for r in results) / max(n, 1)

    # 按来源分组
    by_source = {}
    for r in results:
        src = r["source"]
        if src not in by_source:
            by_source[src] = []
        by_source[src].append(r)

    print(f"\n{'='*70}")
    print(f"{'Source':<12} {'N':>4} {'Suitable':>9} {'Correct':>8} {'Fidelity':>9} {'Natural':>8}")
    print(f"{'-'*70}")
    for src in sorted(by_source.keys()):
        items = by_source[src]
        sn = len(items)
        ss = sum(1 for r in items if r.get("suitable", False))
        sc = sum(r.get("correctness", 0) for r in items) / sn
        sf = sum(r.get("fidelity", 0) for r in items) / sn
        sna = sum(r.get("naturalness", 0) for r in items) / sn
        print(f"{src:<12} {sn:>4} {ss:>5}/{sn:<3} {sc:>7.2f} {sf:>8.2f} {sna:>7.2f}")
    print(f"{'-'*70}")
    print(f"{'TOTAL':<12} {n:>4} {suitable_count:>5}/{n:<3} {avg_correctness:>7.2f} {avg_fidelity:>8.2f} {avg_naturalness:>7.2f}")
    print(f"{'='*70}")
    print(f"Conflicts: {conflict_count}")
    print(f"Errors: {errors}")

    # 列出不适合训练的对
    unsuitable = [r for r in results if not r.get("suitable", False)]
    if unsuitable:
        print(f"\n不适合训练的数据对 ({len(unsuitable)} 条):")
        for r in unsuitable[:10]:
            print(f"  [{r['index']}] {r['source']} | {r['input'][:40]} → {r['output'][:40]}")
            print(f"       reason: {r.get('reason', '')}")

    # 保存
    summary = {
        "judge_model": args.model,
        "data_file": args.data,
        "n_pairs": n,
        "n_suitable": suitable_count,
        "n_unsuitable": n - suitable_count,
        "n_conflicts": conflict_count,
        "avg_correctness": round(avg_correctness, 3),
        "avg_fidelity": round(avg_fidelity, 3),
        "avg_naturalness": round(avg_naturalness, 3),
        "by_source": {
            src: {
                "n": len(items),
                "suitable": sum(1 for r in items if r.get("suitable", False)),
                "avg_correctness": round(sum(r.get("correctness", 0) for r in items) / len(items), 3),
                "avg_fidelity": round(sum(r.get("fidelity", 0) for r in items) / len(items), 3),
                "avg_naturalness": round(sum(r.get("naturalness", 0) for r in items) / len(items), 3),
            }
            for src, items in by_source.items()
        },
        "results": results
    }

    with open(args.output, "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
    print(f"\nReport saved: {args.output}")


if __name__ == "__main__":
    main()
