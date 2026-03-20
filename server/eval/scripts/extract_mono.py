#!/usr/bin/env python3
"""
多通道 WAV → 单通道 WAV 提取

AliMeeting 远场音频是 8 通道环形麦克风阵列。
FluidAudio 和 SpeechAnalyzer 接收单通道。

默认取 channel 0（第一个麦克风），也可指定通道号。

用法:
    python3 extract_mono.py input_8ch.wav output_mono.wav
    python3 extract_mono.py input_8ch.wav output_mono.wav --channel 3
    python3 extract_mono.py --dir audio_dir/ --output-dir mono_dir/
"""

import os
import sys
import wave
import struct
import argparse


def extract_channel(input_path: str, output_path: str, channel: int = 0):
    """从多通道 WAV 提取单通道"""
    with wave.open(input_path, "rb") as wf:
        n_channels = wf.getnchannels()
        sample_width = wf.getsampwidth()
        frame_rate = wf.getframerate()
        n_frames = wf.getnframes()

        if channel >= n_channels:
            print(f"  ERROR: channel {channel} requested but file has {n_channels} channels")
            return False

        # 读取全部帧
        raw = wf.readframes(n_frames)

    # 提取指定通道
    frame_size = sample_width * n_channels
    mono_samples = bytearray()

    for i in range(n_frames):
        offset = i * frame_size + channel * sample_width
        mono_samples.extend(raw[offset:offset + sample_width])

    # 写单通道 WAV
    with wave.open(output_path, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(sample_width)
        wf.setframerate(frame_rate)
        wf.writeframes(bytes(mono_samples))

    duration = n_frames / frame_rate
    size_mb = os.path.getsize(output_path) / 1024 / 1024
    print(f"  {os.path.basename(input_path)}: {n_channels}ch → ch{channel}, "
          f"{duration:.1f}s, {size_mb:.1f}MB")
    return True


def main():
    parser = argparse.ArgumentParser(description="Multi-channel WAV → mono extractor")
    parser.add_argument("input", nargs="?", help="Input WAV file")
    parser.add_argument("output", nargs="?", help="Output mono WAV file")
    parser.add_argument("--channel", type=int, default=0, help="Channel to extract (default: 0)")
    parser.add_argument("--dir", help="Directory of WAV files")
    parser.add_argument("--output-dir", help="Output directory")
    args = parser.parse_args()

    if args.dir:
        output_dir = args.output_dir or args.dir.rstrip("/") + "_mono"
        os.makedirs(output_dir, exist_ok=True)

        files = sorted(f for f in os.listdir(args.dir) if f.endswith(".wav"))
        print(f"Extracting channel {args.channel} from {len(files)} files → {output_dir}/")

        for f in files:
            extract_channel(
                os.path.join(args.dir, f),
                os.path.join(output_dir, f),
                channel=args.channel
            )

        print(f"Done: {len(files)} files")

    elif args.input:
        output = args.output or args.input.replace(".wav", f"_ch{args.channel}.wav")
        extract_channel(args.input, output, channel=args.channel)

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
