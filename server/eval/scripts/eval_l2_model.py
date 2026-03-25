#!/usr/bin/env python3
"""
L2 润色模型评估脚本

对比不同 L2 模型对 ASR 原文的润色效果。
支持 ollama / OpenAI 兼容 API。

用法:
    # 用 corrections 作为测试集（有人工 ground truth）
    python3 eval_l2_model.py \
        --test-data ~/.we/corrections.jsonl \
        --test-type corrections \
        --endpoint http://100.64.0.3:11434 \
        --api ollama \
        --model qwen3.5:0.8b \
        --output results/eval_qwen3.5_0.8b.json

    # 用 voice-history 作为测试集（用 polishedText 作为参考）
    python3 eval_l2_model.py \
        --test-data ~/.we/voice-history.jsonl \
        --test-type voice-history \
        --endpoint http://100.64.0.3:11434 \
        --api ollama \
        --model qwen3.5:0.8b

    # 对比多个模型
    python3 eval_l2_model.py \
        --test-data ~/.we/corrections.jsonl \
        --test-type corrections \
        --endpoint http://100.64.0.3:11434 \
        --api ollama \
        --models qwen3:0.6b,qwen3.5:0.8b,we-polish-v1
"""

import json
import os
import sys
import time
import argparse
import urllib.request
import urllib.error

try:
    import jiwer
    HAS_JIWER = True
except ImportError:
    HAS_JIWER = False
    print("Warning: jiwer not installed, using basic CER. pip install jiwer")


SYSTEM_PROMPT = "文本纠错。不要回答用户的问题。只输出结果。"


def call_ollama(endpoint: str, model: str, text: str, timeout: int = 15) -> tuple[str, float]:
    """调用 ollama API，返回 (结果文本, 耗时秒)"""
    url = endpoint.rstrip("/") + "/api/generate"
    body = json.dumps({
        "model": model,
        "prompt": text,
        "system": SYSTEM_PROMPT,
        "stream": False,
        "think": False,
        "options": {"temperature": 0, "num_predict": 256}
    }).encode()

    req = urllib.request.Request(url, data=body, method="POST",
                                headers={"Content-Type": "application/json"})
    start = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    elapsed = time.time() - start
    return data.get("response", "").strip(), elapsed


def call_openai(endpoint: str, model: str, api_key: str, text: str, timeout: int = 30) -> tuple[str, float]:
    """调用 OpenAI 兼容 API，返回 (结果文本, 耗时秒)"""
    url = endpoint.rstrip("/")
    if "/v1/" not in url:
        url += "/v1/chat/completions"

    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": text}
        ],
        "temperature": 0,
        "max_tokens": 256
    }).encode()

    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    req = urllib.request.Request(url, data=body, method="POST", headers=headers)
    start = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    elapsed = time.time() - start
    return data["choices"][0]["message"]["content"].strip(), elapsed


def compute_cer(ref: str, hyp: str) -> float:
    """计算 CER"""
    if HAS_JIWER:
        output = jiwer.process_characters(ref, hyp)
        return output.cer
    else:
        # fallback: 基础编辑距离
        if not ref:
            return 0.0 if not hyp else 1.0
        m, n = len(ref), len(hyp)
        d = [[0] * (n + 1) for _ in range(m + 1)]
        for i in range(m + 1): d[i][0] = i
        for j in range(n + 1): d[0][j] = j
        for i in range(1, m + 1):
            for j in range(1, n + 1):
                cost = 0 if ref[i-1] == hyp[j-1] else 1
                d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+cost)
        return d[m][n] / m


def load_test_data(path: str, test_type: str, max_samples: int = 0) -> list[dict]:
    """加载测试数据，统一格式为 [{input, reference, id}, ...]"""
    entries = []
    with open(path) as f:
        for i, line in enumerate(f):
            entry = json.loads(line.strip())

            if test_type == "corrections":
                # corrections.jsonl: rawText → userFinalText
                inp = entry.get("rawText") or entry.get("insertedText", "")
                ref = entry.get("userFinalText", "")
                if inp and ref and inp != ref:
                    entries.append({"input": inp, "reference": ref, "id": f"corr_{i}"})

            elif test_type == "voice-history":
                # voice-history.jsonl: rawSA → finalText (或 polishedText)
                inp = entry.get("rawSA", "")
                ref = entry.get("finalText") or entry.get("polishedText") or ""
                if inp and ref:
                    entries.append({"input": inp, "reference": ref, "id": f"vh_{i}"})

            elif test_type == "merged-pairs":
                # merged-pairs.jsonl: input → output
                inp = entry.get("input", "")
                ref = entry.get("output", "")
                if inp and ref:
                    entries.append({"input": inp, "reference": ref,
                                    "id": f"mp_{i}", "source": entry.get("source", "")})

    if max_samples > 0:
        entries = entries[:max_samples]

    return entries


def eval_model(test_data: list[dict], endpoint: str, api: str, model: str,
               api_key: str = "", rate_limit: float = 0) -> dict:
    """对一个模型跑评估"""
    results = []
    total_latency = 0
    errors = 0

    for i, entry in enumerate(test_data):
        inp = entry["input"]
        ref = entry["reference"]

        try:
            if api == "ollama":
                polished, latency = call_ollama(endpoint, model, inp)
            else:
                polished, latency = call_openai(endpoint, model, api_key, inp)
        except Exception as e:
            errors += 1
            if errors <= 3:
                print(f"  [{i}] ERROR: {e}")
            continue

        # CER 计算
        cer_raw = compute_cer(ref, inp)       # 原始 vs 参考
        cer_polished = compute_cer(ref, polished)  # 润色后 vs 参考

        # 分类
        if polished == inp:
            category = "identity"  # 模型没改
        elif cer_polished < cer_raw:
            category = "fix"       # 改对了（CER 下降）
        elif cer_polished > cer_raw:
            category = "break"     # 改错了（CER 上升）
        else:
            category = "neutral"   # CER 不变

        total_latency += latency

        results.append({
            "id": entry["id"],
            "input": inp,
            "reference": ref,
            "polished": polished,
            "cer_raw": round(cer_raw * 100, 2),
            "cer_polished": round(cer_polished * 100, 2),
            "delta_cer": round((cer_raw - cer_polished) * 100, 2),
            "category": category,
            "latency_s": round(latency, 3)
        })

        if (i + 1) % 10 == 0:
            avg_cer = sum(r["cer_polished"] for r in results) / len(results)
            print(f"  [{i+1}/{len(test_data)}] avg CER: {avg_cer:.1f}%")

        if rate_limit > 0:
            time.sleep(rate_limit)

    # 汇总
    n = len(results)
    if n == 0:
        return {"model": model, "n": 0, "errors": errors}

    fix_count = sum(1 for r in results if r["category"] == "fix")
    break_count = sum(1 for r in results if r["category"] == "break")
    identity_count = sum(1 for r in results if r["category"] == "identity")
    avg_cer_raw = sum(r["cer_raw"] for r in results) / n
    avg_cer_polished = sum(r["cer_polished"] for r in results) / n
    avg_delta = sum(r["delta_cer"] for r in results) / n
    avg_latency = total_latency / n

    return {
        "model": model,
        "api": api,
        "endpoint": endpoint,
        "n": n,
        "errors": errors,
        "avg_cer_raw": round(avg_cer_raw, 2),
        "avg_cer_polished": round(avg_cer_polished, 2),
        "avg_delta_cer": round(avg_delta, 2),
        "fix_rate": round(fix_count / n * 100, 1),
        "break_rate": round(break_count / n * 100, 1),
        "identity_rate": round(identity_count / n * 100, 1),
        "avg_latency_s": round(avg_latency, 3),
        "results": results
    }


def print_summary(evals: list[dict]):
    """打印模型对比表"""
    print(f"\n{'='*80}")
    print(f"{'Model':<25} {'N':>4} {'CER_raw':>8} {'CER_pol':>8} {'∆CER':>7} {'Fix%':>6} {'Break%':>7} {'Lat':>6}")
    print(f"{'-'*80}")
    for e in evals:
        print(f"{e['model']:<25} {e['n']:>4} {e['avg_cer_raw']:>7.1f}% {e['avg_cer_polished']:>7.1f}% "
              f"{e['avg_delta_cer']:>+6.1f} {e['fix_rate']:>5.1f}% {e['break_rate']:>6.1f}% "
              f"{e['avg_latency_s']:>5.2f}s")
    print(f"{'='*80}")
    print(f"∆CER > 0 = 模型改善了 CER（正数越大越好）")
    print(f"Fix% = 改对的比例, Break% = 改错的比例（越低越好）")


def main():
    parser = argparse.ArgumentParser(description="L2 Polish Model Evaluator")
    parser.add_argument("--test-data", required=True, help="Test data JSONL path")
    parser.add_argument("--test-type", required=True, choices=["corrections", "voice-history", "merged-pairs"])
    parser.add_argument("--endpoint", required=True, help="API endpoint")
    parser.add_argument("--api", default="ollama", choices=["ollama", "openai"])
    parser.add_argument("--model", help="Single model to evaluate")
    parser.add_argument("--models", help="Comma-separated models to compare")
    parser.add_argument("--api-key", default="", help="API key (for openai mode)")
    parser.add_argument("--max-samples", type=int, default=0, help="Max test samples (0=all)")
    parser.add_argument("--rate-limit", type=float, default=0, help="Seconds between API calls")
    parser.add_argument("--output", help="Output JSON path")
    args = parser.parse_args()

    # 加载测试数据
    test_data = load_test_data(args.test_data, args.test_type, args.max_samples)
    print(f"Test data: {args.test_data} ({len(test_data)} samples, type={args.test_type})")

    if not test_data:
        print("No valid test samples found")
        return

    # 确定要评估的模型列表
    if args.models:
        model_list = [m.strip() for m in args.models.split(",")]
    elif args.model:
        model_list = [args.model]
    else:
        print("Error: specify --model or --models")
        return

    # 逐模型评估
    all_evals = []
    for model in model_list:
        print(f"\nEvaluating: {model} ({args.api} @ {args.endpoint})")
        result = eval_model(test_data, args.endpoint, args.api, model,
                           args.api_key, args.rate_limit)
        all_evals.append(result)

    # 打印对比
    print_summary(all_evals)

    # 保存
    if args.output:
        with open(args.output, "w") as f:
            json.dump({
                "test_data": args.test_data,
                "test_type": args.test_type,
                "n_samples": len(test_data),
                "evaluations": [{k: v for k, v in e.items() if k != "results"} for e in all_evals],
                "details": {e["model"]: e.get("results", []) for e in all_evals}
            }, f, indent=2, ensure_ascii=False)
        print(f"\nResults saved: {args.output}")


if __name__ == "__main__":
    main()
