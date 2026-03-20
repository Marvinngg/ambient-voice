#!/usr/bin/env python3
"""
TextGrid → RTTM 转换（AliMeeting 格式）

TextGrid 每个 tier 是一个说话人，每个 interval 是一段发言。
RTTM 格式: SPEAKER <file> 1 <start> <dur> <NA> <NA> <speaker> <NA> <NA>

用法:
    python3 textgrid_to_rttm.py input.TextGrid output.rttm
    python3 textgrid_to_rttm.py --dir textgrid_dir/ --output-dir rttm_dir/
"""

import re
import os
import sys
import argparse


def parse_textgrid(path: str) -> list[dict]:
    """解析 Praat TextGrid 文件，返回 [{speaker, start, end, text}, ...]"""
    with open(path, encoding="utf-8") as f:
        content = f.read()

    segments = []

    # 匹配每个 item（tier）
    tier_pattern = re.compile(
        r'item\s*\[(\d+)\]:\s*'
        r'class\s*=\s*"IntervalTier"\s*'
        r'name\s*=\s*"([^"]+)"\s*'
        r'xmin\s*=\s*([\d.]+)\s*'
        r'xmax\s*=\s*([\d.]+)\s*'
        r'intervals:\s*size\s*=\s*(\d+)\s*'
        r'((?:intervals\s*\[\d+\].*?(?=item\s*\[|$))+)',
        re.DOTALL
    )

    interval_pattern = re.compile(
        r'intervals\s*\[\d+\]:\s*'
        r'xmin\s*=\s*([\d.]+)\s*'
        r'xmax\s*=\s*([\d.]+)\s*'
        r'text\s*=\s*"([^"]*)"',
        re.DOTALL
    )

    for tier_match in tier_pattern.finditer(content):
        speaker = tier_match.group(2)
        tier_content = tier_match.group(6)

        for iv_match in interval_pattern.finditer(tier_content):
            xmin = float(iv_match.group(1))
            xmax = float(iv_match.group(2))
            text = iv_match.group(3).strip()

            # 跳过空 interval（静音段）
            if not text:
                continue

            segments.append({
                "speaker": speaker,
                "start": xmin,
                "end": xmax,
                "text": text
            })

    return sorted(segments, key=lambda x: x["start"])


def segments_to_rttm(segments: list[dict], file_id: str) -> str:
    """将 segments 转为 RTTM 格式字符串"""
    lines = []
    for seg in segments:
        duration = seg["end"] - seg["start"]
        if duration <= 0:
            continue
        lines.append(
            f"SPEAKER {file_id} 1 {seg['start']:.3f} {duration:.3f} "
            f"<NA> <NA> {seg['speaker']} <NA> <NA>"
        )
    return "\n".join(lines) + "\n" if lines else ""


def convert_file(textgrid_path: str, rttm_path: str):
    """转换单个文件"""
    file_id = os.path.splitext(os.path.basename(textgrid_path))[0]
    segments = parse_textgrid(textgrid_path)

    if not segments:
        print(f"  WARNING: no segments in {textgrid_path}")
        return 0

    rttm = segments_to_rttm(segments, file_id)
    with open(rttm_path, "w") as f:
        f.write(rttm)

    speakers = set(s["speaker"] for s in segments)
    total_dur = max(s["end"] for s in segments)
    print(f"  {file_id}: {len(segments)} segments, {len(speakers)} speakers, {total_dur:.1f}s")
    return len(segments)


def main():
    parser = argparse.ArgumentParser(description="TextGrid → RTTM converter")
    parser.add_argument("input", nargs="?", help="Single TextGrid file")
    parser.add_argument("output", nargs="?", help="Output RTTM file")
    parser.add_argument("--dir", help="Directory of TextGrid files")
    parser.add_argument("--output-dir", help="Output directory for RTTM files")
    args = parser.parse_args()

    if args.dir:
        output_dir = args.output_dir or args.dir.rstrip("/") + "_rttm"
        os.makedirs(output_dir, exist_ok=True)

        files = sorted(f for f in os.listdir(args.dir) if f.endswith(".TextGrid"))
        print(f"Converting {len(files)} TextGrid files → {output_dir}/")

        total = 0
        for f in files:
            rttm_name = os.path.splitext(f)[0] + ".rttm"
            total += convert_file(
                os.path.join(args.dir, f),
                os.path.join(output_dir, rttm_name)
            )
        print(f"Done: {total} segments total")

    elif args.input:
        output = args.output or os.path.splitext(args.input)[0] + ".rttm"
        convert_file(args.input, output)

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
