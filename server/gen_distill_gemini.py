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


DEFAULT_DISTILL_PROMPT = "你是语音识别纠错专家。用户会提供一个私有词典和语音识别结果。将识别错误替换为词典中的正确词。只改确定有错的。只输出纠正后的文本。"


def build_prompt(raw_sa: str, polished: str, dictionary_terms: list[str] | None = None) -> str:
    parts = []
    if dictionary_terms:
        parts.append(f"用户常用词汇：{', '.join(dictionary_terms)}")
    parts.append(f"语音识别结果：{raw_sa}")
    if polished and polished != raw_sa:
        parts.append(f"小模型润色结果：{polished}")
    parts.append("将识别错误替换为词典中的正确词。只改确定有错的。只输出结果。")
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
        "max_tokens": 256,
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
    parser.add_argument("--max-edit-ratio", type=float, default=0.3,
                        help="Max edit distance ratio to accept")
    parser.add_argument("--rate-limit", type=float, default=0.5,
                        help="Seconds between API calls")
    parser.add_argument("--max-retries", type=int, default=3, help="Max retries per sample")
    parser.add_argument("--dictionary", default=None,
                        help="Path to dictionary.json (JSON with 'terms' array)")
    parser.add_argument("--system-prompt", default=DEFAULT_DISTILL_PROMPT,
                        help="System prompt for distillation model")
    parser.add_argument("--incremental", action="store_true",
                        help="Incremental mode: only process new entries since last run")
    args = parser.parse_args()

    SYSTEM_PROMPT = args.system_prompt

    # 加载词典
    dictionary_terms: list[str] | None = None
    if args.dictionary:
        try:
            with open(args.dictionary) as f:
                dictionary_terms = json.load(f).get("terms", [])
            print(f"Loaded dictionary: {len(dictionary_terms)} terms from {args.dictionary}")
        except (FileNotFoundError, json.JSONDecodeError) as e:
            print(f"Warning: failed to load dictionary {args.dictionary}: {e}")

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
        raw_sa = entry.get("rawSA", "").strip()
        polished = entry.get("polishedText") or entry.get("finalText", "")
        polished = polished.strip()

        if not raw_sa:
            skipped += 1
            continue

        if not polished:
            polished = raw_sa

        prompt = build_prompt(raw_sa, polished, dictionary_terms)

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

    # 增量模式追加，否则覆盖
    mode = "a" if args.incremental else "w"
    with open(args.output, mode) as f:
        for pair in pairs:
            f.write(json.dumps(pair, ensure_ascii=False) + "\n")

    # 更新 offset
    if args.incremental:
        save_offset(offset_file, offset + len(entries))

    print(f"\nDone: {len(pairs)} pairs, {skipped} skipped, {errors} errors")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
