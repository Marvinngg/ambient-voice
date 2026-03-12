#!/usr/bin/env python3
"""
路线 A: 强语音模型蒸馏
把原始音频丢给 Whisper-large，输出作为教师标注，与 SA 转写配对生成训练数据。
"""

import json
import argparse
import os
from pathlib import Path
from difflib import SequenceMatcher


def edit_distance_ratio(a: str, b: str) -> float:
    """编辑距离占比，越小越相似"""
    return 1.0 - SequenceMatcher(None, a, b).ratio()


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
    parser = argparse.ArgumentParser(description="Generate distillation data via Whisper")
    parser.add_argument("--input", required=True, help="voice-history.jsonl path")
    parser.add_argument("--output", required=True, help="Output training pairs JSONL")
    parser.add_argument("--model-size", default="large-v3", help="Whisper model size")
    parser.add_argument("--max-edit-ratio", type=float, default=0.4,
                        help="Max edit distance ratio to accept a pair")
    parser.add_argument("--audio-dir", default=None,
                        help="Override audio directory (default: use paths from input)")
    parser.add_argument("--incremental", action="store_true",
                        help="Incremental mode: only process new entries since last run")
    args = parser.parse_args()

    # 延迟导入，允许在没有 whisper 时查看帮助
    try:
        import whisper
    except ImportError:
        print("Error: pip install openai-whisper  (or use faster-whisper)")
        return

    # 增量模式
    offset = 0
    offset_file = args.output + ".offset"
    all_entries = []
    with open(args.input) as f:
        all_entries = [json.loads(line.strip()) for line in f]

    if args.incremental:
        offset = load_offset(offset_file)
        if offset >= len(all_entries):
            print(f"No new entries (total={len(all_entries)}, processed={offset})")
            return
        all_entries = all_entries[offset:]
        print(f"Incremental: processing {len(all_entries)} new entries (offset={offset})")

    print(f"Loading Whisper model: {args.model_size}")
    model = whisper.load_model(args.model_size)

    pairs = []
    skipped = 0
    total_entries = len(all_entries)

    for entry in all_entries:
        audio_path = entry.get("audioPath")
        if not audio_path:
            skipped += 1
            continue

        # 支持 ~ 展开和路径覆盖
        if args.audio_dir:
            audio_path = os.path.join(args.audio_dir, os.path.basename(audio_path))
        else:
            audio_path = os.path.expanduser(audio_path)

        if not os.path.exists(audio_path):
            skipped += 1
            continue

        raw_sa = entry.get("rawSA", "")
        if not raw_sa.strip():
            skipped += 1
            continue

        # Whisper 转写
        result = model.transcribe(audio_path, language="zh")
        teacher_text = result["text"].strip()

        if not teacher_text:
            skipped += 1
            continue

        # 质量过滤
        ratio = edit_distance_ratio(raw_sa, teacher_text)
        if ratio > args.max_edit_ratio:
            skipped += 1
            continue

        # 计算平均词置信度
        words = entry.get("words", [])
        avg_conf = sum(w.get("confidence", 0) for w in words) / max(len(words), 1)

        pairs.append({
            "input": raw_sa,
            "output": teacher_text,
            "source": "whisper",
            "edit_ratio": round(ratio, 4),
            "avg_confidence": round(avg_conf, 4),
            "audio_path": audio_path,
            "timestamp": entry.get("timestamp", "")
        })

    # 增量模式追加，否则覆盖
    mode = "a" if args.incremental else "w"
    with open(args.output, mode) as f:
        for pair in pairs:
            f.write(json.dumps(pair, ensure_ascii=False) + "\n")

    if args.incremental:
        save_offset(offset_file, offset + total_entries)

    print(f"Done: {len(pairs)} pairs generated, {skipped} skipped")
    print(f"Output: {args.output}")


if __name__ == "__main__":
    main()
