#!/usr/bin/env python3
"""
评估微调后的模型效果
指标：fix_rate（改对）、break_rate（改错）、identity_rate（没动）、CER
按数据来源分别统计
"""

import json
import argparse
from difflib import SequenceMatcher
from collections import defaultdict


def cer(reference: str, hypothesis: str) -> float:
    """字错率（Character Error Rate）"""
    if not reference:
        return 0.0 if not hypothesis else 1.0
    d = [[0] * (len(hypothesis) + 1) for _ in range(len(reference) + 1)]
    for i in range(len(reference) + 1):
        d[i][0] = i
    for j in range(len(hypothesis) + 1):
        d[0][j] = j
    for i in range(1, len(reference) + 1):
        for j in range(1, len(hypothesis) + 1):
            cost = 0 if reference[i - 1] == hypothesis[j - 1] else 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
    return d[len(reference)][len(hypothesis)] / len(reference)


def edit_distance_ratio(a: str, b: str) -> float:
    return 1.0 - SequenceMatcher(None, a, b).ratio()


def main():
    parser = argparse.ArgumentParser(description="Evaluate fine-tuned model")
    parser.add_argument("--data", required=True, help="training_data.jsonl (has input/output ground truth)")
    parser.add_argument("--model-path", required=True, help="Path to merged model or adapter")
    parser.add_argument("--base-model", default="Qwen/Qwen3-0.6B")
    parser.add_argument("--max-samples", type=int, default=200)
    parser.add_argument("--output", default=None, help="Save detailed results to JSONL")
    args = parser.parse_args()

    try:
        import torch
        from transformers import AutoTokenizer, AutoModelForCausalLM, pipeline
        from peft import PeftModel
    except ImportError as e:
        print(f"Missing: {e}")
        return

    SYSTEM_PROMPT = "语音转写后处理。修正错别字和同音误识别，补充标点，删除口水词和重复，轻度润色为自然书面语。保持原意、语气和长度，不添加不解释不扩写。只输出结果。"

    # 加载模型
    print(f"Loading model from {args.model_path}...")
    tokenizer = AutoTokenizer.from_pretrained(args.base_model, trust_remote_code=True)

    # 尝试作为 adapter 加载，失败则作为完整模型
    try:
        base = AutoModelForCausalLM.from_pretrained(
            args.base_model, torch_dtype=torch.bfloat16, device_map="auto", trust_remote_code=True
        )
        model = PeftModel.from_pretrained(base, args.model_path)
        model = model.merge_and_unload()
        print("Loaded as LoRA adapter")
    except Exception:
        model = AutoModelForCausalLM.from_pretrained(
            args.model_path, torch_dtype=torch.bfloat16, device_map="auto", trust_remote_code=True
        )
        print("Loaded as full model")

    pipe = pipeline("text-generation", model=model, tokenizer=tokenizer, device_map="auto")

    # 加载测试数据
    samples = []
    with open(args.data) as f:
        for line in f:
            entry = json.loads(line.strip())
            if entry.get("input") and entry.get("output"):
                samples.append(entry)

    samples = samples[:args.max_samples]
    print(f"Evaluating on {len(samples)} samples")

    # 评估
    results = []
    stats = defaultdict(lambda: {"fix": 0, "break": 0, "identity": 0, "total": 0, "cer_sum": 0.0})

    for i, sample in enumerate(samples):
        inp = sample["input"]
        expected = sample["output"]
        source = sample.get("source", "unknown")

        messages = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": inp},
        ]
        out = pipe(messages, max_new_tokens=256, temperature=0.0, do_sample=False)
        predicted = out[0]["generated_text"][-1]["content"].strip()

        # 分类
        pred_cer = cer(expected, predicted)
        orig_cer = cer(expected, inp)

        if predicted == inp:
            category = "identity"
        elif pred_cer < orig_cer:
            category = "fix"
        elif pred_cer > orig_cer:
            category = "break"
        else:
            category = "identity"

        stats[source][category] += 1
        stats[source]["total"] += 1
        stats[source]["cer_sum"] += pred_cer
        stats["ALL"][category] += 1
        stats["ALL"]["total"] += 1
        stats["ALL"]["cer_sum"] += pred_cer

        results.append({
            "input": inp, "expected": expected, "predicted": predicted,
            "category": category, "source": source,
            "pred_cer": round(pred_cer, 4), "orig_cer": round(orig_cer, 4),
        })

        if (i + 1) % 20 == 0:
            print(f"  Progress: {i + 1}/{len(samples)}")

    # 打印结果
    print("\n" + "=" * 60)
    print(f"{'Source':<12} {'Total':>6} {'Fix%':>8} {'Break%':>8} {'Id%':>8} {'Avg CER':>8}")
    print("-" * 60)
    for source in sorted(stats.keys()):
        s = stats[source]
        n = s["total"]
        if n == 0:
            continue
        print(f"{source:<12} {n:>6} "
              f"{s['fix']/n*100:>7.1f}% "
              f"{s['break']/n*100:>7.1f}% "
              f"{s['identity']/n*100:>7.1f}% "
              f"{s['cer_sum']/n:>7.4f}")
    print("=" * 60)

    # 保存详细结果
    if args.output:
        with open(args.output, "w") as f:
            for r in results:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")
        print(f"Details saved: {args.output}")


if __name__ == "__main__":
    main()
