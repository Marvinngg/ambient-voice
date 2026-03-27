#!/usr/bin/env python3
"""
路线 B: Gemini 文本纠正蒸馏（通过 OpenAI 兼容代理）
把 SA 转写 + 小模型润色输出给 Gemini，让它判断纠正，生成训练数据。

默认使用本地 Antigravity Tools 代理 (localhost:8045)，
也可指定任意 OpenAI 兼容端点。
"""

import json
import argparse
import time
import urllib.request
import urllib.error
from difflib import SequenceMatcher


def edit_distance_ratio(a: str, b: str) -> float:
    return 1.0 - SequenceMatcher(None, a, b).ratio()


# 已知映射表，用于自动信任判断
KNOWN_MAPPINGS = {
    "crown": "cron", "Crown": "cron",
    "cloud": "Claude", "Cloud": "Claude",
    "cold": "Code", "Cold": "Code",
    "户口": "hook",
    "forback": "fallback", "for back": "fallback",
    "有福": "有孚",
    "奥特": "auto",
    "A俊才": "Agent", "A俊辰": "Agent",
    "普瑞卷": "bridge",
    "MacBook": "MoltBook",
    "Photo Wink": "browserwing", "Brother Wing": "browserwing",
    "T恤": "Team",
    "S H五": "SH5", "SH五": "SH5",
    "龙虾": "Ghostty",
}


def classify_pair(raw: str, corrected: str) -> str:
    """分类一个纠正对：auto_pass / needs_review / auto_reject"""
    if raw == corrected:
        return "auto_pass"  # 没改动

    ratio = edit_distance_ratio(raw, corrected)
    if ratio > 0.5:
        return "auto_reject"  # 改动太大

    # 检查改动是否全部命中已知映射
    diff_text = corrected
    for wrong, right in KNOWN_MAPPINGS.items():
        diff_text = diff_text.replace(right, wrong)

    # 替换回去后如果跟原文一样，说明所有改动都命中了已知映射
    if edit_distance_ratio(raw, diff_text) < 0.02:
        return "auto_pass"

    return "needs_review"


SYSTEM_PROMPT = """你是 macOS 语音输入的 ASR 纠错专家。用户通过 Apple SpeechAnalyzer 语音输入，你负责修正识别错误。

## 已知专有词汇（用户高频使用）
Claude, Claude Code, CLAUDE.md, cron, fallback, SSH, Ghostty,
GGUF, LoRA, Qwen, llama.cpp, Agent, MoltBook, skill, hook,
auto, bridge, eval, 有孚, browserwing, Tailscale, ollama,
Whisper, adapter, QLoRA, distill, pipeline

## 常见误识别→正确映射
crown/Crown → cron | cloud/Cloud → Claude | cold/Cold → Code
户口 → hook | forback/for back → fallback | 有福 → 有孚
奥特 → auto | A俊才/A俊辰 → Agent | 普瑞卷 → bridge
MacBook → MoltBook | Photo Wink/Brother Wing → browserwing
T恤 → Team（在技术语境下）| S H五/SH五 → SH5（服务器名）
龙虾 → Ghostty（终端应用名）

## 规则
- 根据上下文修正语音识别错误（同音字、错别字、专有名词误识别）
- 利用上面的映射表，但也要结合语境判断（如"crown"在王冠语境下不应改为cron）
- 不确定的保持原样，宁可漏改不要错改
- 不改句式、不改语气、不扩写、不缩写
- 可以补充明显缺失的标点
- 不要删除口水词、不要删除重复、不要缩短句子、不要重组句式
- 只输出修正后的完整文本，不要解释、不要省略任何部分"""


def build_prompt(raw_sa: str, polished: str, app_name: str = "") -> str:
    parts = []
    if app_name:
        parts.append(f"应用场景：{app_name}")
    parts.append(f"语音识别原文：{raw_sa}")
    if polished and polished != raw_sa:
        parts.append(f"小模型润色参考：{polished}")
    parts.append("\n修正后的文本：")
    return "\n".join(parts)


def call_openai_compatible(base_url: str, api_key: str, model: str,
                           system: str, user: str, timeout: int = 30) -> str:
    """调用 OpenAI 兼容 API，纯 stdlib 实现，不需要额外依赖"""
    url = f"{base_url}/v1/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0,
        "max_tokens": 1024,
    }).encode()

    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    })
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    return data["choices"][0]["message"]["content"].strip()


def load_offset(path: str) -> int:
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (FileNotFoundError, ValueError):
        return 0


def save_offset(path: str, offset: int):
    with open(path, "w") as f:
        f.write(str(offset))


def main():
    parser = argparse.ArgumentParser(description="Generate distillation data via Gemini (OpenAI-compatible proxy)")
    parser.add_argument("--input", required=True, help="voice-history.jsonl path")
    parser.add_argument("--output", required=True, help="Output training pairs JSONL")
    parser.add_argument("--base-url", default="http://127.0.0.1:8045",
                        help="OpenAI-compatible API base URL (default: Antigravity Tools)")
    parser.add_argument("--api-key", default="",
                        help="API key (required)")
    parser.add_argument("--model", default="gemini-2.5-flash", help="Model name")
    parser.add_argument("--max-edit-ratio", type=float, default=0.5,
                        help="Max edit distance ratio to accept")
    parser.add_argument("--rate-limit", type=float, default=0.5,
                        help="Seconds between API calls")
    parser.add_argument("--max-retries", type=int, default=3, help="Max retries per sample")
    parser.add_argument("--incremental", action="store_true",
                        help="Incremental mode: only process new entries since last run")
    parser.add_argument("--review", action="store_true",
                        help="Review mode: split output into auto_pass / needs_review / auto_reject")
    args = parser.parse_args()

    pairs = []
    skipped = 0
    errors = 0

    with open(args.input) as f:
        entries = [json.loads(line.strip()) for line in f]

    # 增量模式：跳过已处理的条目
    offset = 0
    offset_file = args.output + ".offset"
    if args.incremental:
        offset = load_offset(offset_file)
        if offset >= len(entries):
            print(f"No new entries (total={len(entries)}, processed={offset})")
            return
        entries = entries[offset:]
        print(f"Incremental: processing {len(entries)} new entries (offset={offset})")

    print(f"Processing {len(entries)} entries with {args.model} via {args.base_url}")

    for i, entry in enumerate(entries):
        raw_sa = entry.get("rawSA") or entry.get("rawText", "")
        raw_sa = raw_sa.strip()
        polished = entry.get("polishedText") or entry.get("l1Text") or entry.get("finalText", "")
        polished = polished.strip()

        if not raw_sa:
            skipped += 1
            continue

        if not polished:
            polished = raw_sa

        app_name = entry.get("appName", "")
        prompt = build_prompt(raw_sa, polished, app_name)

        # 带重试的 API 调用
        corrected = None
        for retry in range(args.max_retries):
            try:
                corrected = call_openai_compatible(
                    args.base_url, args.api_key, args.model,
                    SYSTEM_PROMPT, prompt
                )
                break
            except Exception as e:
                if retry < args.max_retries - 1:
                    wait = (retry + 1) * 2
                    print(f"  Retry {retry+1}/{args.max_retries} after {wait}s: {e}")
                    time.sleep(wait)
                else:
                    print(f"  Failed after {args.max_retries} retries: {e}")
                    errors += 1

        if not corrected:
            skipped += 1
            continue

        # 质量过滤
        ratio = edit_distance_ratio(raw_sa, corrected)
        if ratio > args.max_edit_ratio:
            print(f"  [{i}] FILTERED ratio={ratio:.3f}: {raw_sa[:30]} → {corrected[:30]}")
            skipped += 1
            continue

        words = entry.get("words", [])
        avg_conf = sum(w.get("confidence", 0) for w in words) / max(len(words), 1)

        pairs.append({
            "input": raw_sa,
            "output": corrected,
            "source": "gemini",
            "polished_0.6b": polished,
            "edit_ratio": round(ratio, 4),
            "avg_confidence": round(avg_conf, 4),
            "timestamp": entry.get("timestamp", "")
        })

        print(f"  [{i}] PASS ratio={ratio:.3f}: {raw_sa[:30]} → {corrected[:30]}")

        if (i + 1) % 50 == 0:
            print(f"  Progress: {i+1}/{len(entries)}, pairs: {len(pairs)}")

        time.sleep(args.rate_limit)

    if args.review:
        # 分三类输出
        base = args.output.replace(".jsonl", "")
        buckets = {"auto_pass": [], "needs_review": [], "auto_reject": []}
        for pair in pairs:
            cat = classify_pair(pair["input"], pair["output"])
            pair["_review"] = cat
            buckets[cat].append(pair)

        for cat, items in buckets.items():
            path = f"{base}_{cat}.jsonl"
            with open(path, "w") as f:
                for p in items:
                    f.write(json.dumps(p, ensure_ascii=False) + "\n")

        print(f"\n=== Review Mode ===")
        print(f"auto_pass:    {len(buckets['auto_pass']):>4} 条 → {base}_auto_pass.jsonl（直接用）")
        print(f"needs_review: {len(buckets['needs_review']):>4} 条 → {base}_needs_review.jsonl（你过一遍）")
        print(f"auto_reject:  {len(buckets['auto_reject']):>4} 条 → {base}_auto_reject.jsonl（丢弃）")
    else:
        # 原有逻辑
        mode = "a" if args.incremental else "w"
        with open(args.output, mode) as f:
            for pair in pairs:
                f.write(json.dumps(pair, ensure_ascii=False) + "\n")

    # 更新 offset
    if args.incremental:
        save_offset(offset_file, offset + len(entries))

    total = len(pairs)
    print(f"\nDone: {total} pairs, {skipped} skipped, {errors} errors")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
