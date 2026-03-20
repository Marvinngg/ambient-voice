#!/usr/bin/env python3
"""
TextGrid → 参考文本提取（层 A 转写评估用）

从 TextGrid 提取所有说话人的转写文本，按时间排序拼接。
输出 JSONL 格式供 WER/CER 计算。

用法:
    python3 textgrid_to_ref.py input.TextGrid
    python3 textgrid_to_ref.py --dir textgrid_dir/ --output-dir ref_dir/
"""

import json
import os
import argparse

# 复用 textgrid_to_rttm 的解析逻辑
from textgrid_to_rttm import parse_textgrid


def extract_reference(textgrid_path: str) -> dict:
    """从 TextGrid 提取参考信息"""
    file_id = os.path.splitext(os.path.basename(textgrid_path))[0]
    segments = parse_textgrid(textgrid_path)

    if not segments:
        return {"id": file_id, "reference": "", "segments": []}

    # 全文拼接（按时间排序）
    full_text = "".join(seg["text"] for seg in segments)

    # 带说话人的分段
    ref_segments = [
        {
            "speaker": seg["speaker"],
            "start": round(seg["start"], 3),
            "end": round(seg["end"], 3),
            "text": seg["text"]
        }
        for seg in segments
    ]

    speakers = sorted(set(s["speaker"] for s in segments))
    duration = max(s["end"] for s in segments)

    return {
        "id": file_id,
        "reference": full_text,
        "duration_s": round(duration, 2),
        "speakers": speakers,
        "n_speakers": len(speakers),
        "n_segments": len(segments),
        "segments": ref_segments
    }


def main():
    parser = argparse.ArgumentParser(description="TextGrid → reference text extractor")
    parser.add_argument("input", nargs="?", help="Single TextGrid file")
    parser.add_argument("--dir", help="Directory of TextGrid files")
    parser.add_argument("--output-dir", help="Output directory")
    parser.add_argument("--audio-dir", help="Directory of mono WAV files (for manifest audio paths)")
    args = parser.parse_args()

    if args.dir:
        output_dir = args.output_dir or args.dir.rstrip("/") + "_ref"
        os.makedirs(output_dir, exist_ok=True)

        files = sorted(f for f in os.listdir(args.dir) if f.endswith(".TextGrid"))
        print(f"Extracting reference from {len(files)} TextGrid files → {output_dir}/")

        # 同时生成 manifest.jsonl（供 transcription-bench --batch 使用）
        manifest_lines = []

        # 查找对应的 mono 音频目录（约定：同级 mono/ 目录）
        audio_dir = args.audio_dir
        if not audio_dir:
            parent = os.path.dirname(args.dir.rstrip("/"))
            candidate = os.path.join(parent, "mono")
            if os.path.isdir(candidate):
                audio_dir = candidate

        for f in files:
            ref = extract_reference(os.path.join(args.dir, f))

            # 查找对应音频
            audio_path = ""
            if audio_dir:
                # AliMeeting 命名: TextGrid=R8001_M8004.TextGrid, WAV=R8001_M8004_MS801.wav
                matches = [w for w in os.listdir(audio_dir) if w.startswith(ref["id"]) and w.endswith(".wav")]
                if matches:
                    audio_path = os.path.abspath(os.path.join(audio_dir, matches[0]))

            ref["audio"] = audio_path

            # 写单个 JSON
            out_path = os.path.join(output_dir, ref["id"] + ".json")
            with open(out_path, "w", encoding="utf-8") as fh:
                json.dump(ref, fh, ensure_ascii=False, indent=2)

            print(f"  {ref['id']}: {ref['n_segments']} segments, "
                  f"{ref['n_speakers']} speakers, {ref['duration_s']}s, "
                  f"{len(ref['reference'])} chars"
                  f"{' audio=' + os.path.basename(audio_path) if audio_path else ' NO AUDIO'}")

            manifest_lines.append(ref)

        # 写 manifest（含 audio 路径，供 transcription-bench --batch 使用）
        manifest_path = os.path.join(output_dir, "manifest.jsonl")
        with open(manifest_path, "w", encoding="utf-8") as f:
            for ref in manifest_lines:
                f.write(json.dumps({
                    "id": ref["id"],
                    "audio": ref.get("audio", ""),
                    "reference": ref["reference"],
                    "duration_s": ref["duration_s"],
                    "n_speakers": ref["n_speakers"],
                    "locale": "zh-CN"
                }, ensure_ascii=False) + "\n")

        print(f"Manifest: {manifest_path} ({len(manifest_lines)} entries)")

    elif args.input:
        ref = extract_reference(args.input)
        print(json.dumps(ref, ensure_ascii=False, indent=2))

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
