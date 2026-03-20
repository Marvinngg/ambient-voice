# 会议模式评估架构

## 评估目标

评估 ambient-voice 会议模式的端到端质量：**用户开完会，拿到的"谁说了什么"到底准不准。**

## 评估分层

```
输入音频
  │
  ├──→ [A] 转写质量评估（SpeechAnalyzer 单独评）
  │         输入：音频 + ground truth 文本
  │         输出：WER / CER
  │
  ├──→ [B] 说话人分离评估（FluidAudio 单独评）
  │         输入：音频 + ground truth RTTM
  │         输出：DER / JER / 检测说话人数
  │
  └──→ [C] 端到端评估（完整会议模式链路）
            输入：音频 + ground truth（文本 + 说话人 + 时间戳）
            输出：cpWER（拼接最小排列词错误率）
```

A 和 B 独立评，定位问题在哪层。C 是最终用户体感。

## 评估维度

| 维度 | 变量 | 优先级 | 说明 |
|------|------|--------|------|
| 说话人数 | 2 / 4 / 6-8 / 10+ | P0 | 聚类瓶颈，人多时退化 |
| 重叠率 | <10% / 10-30% / >30% | P0 | DER 最大变量，ignoreOverlap 掩盖真实能力 |
| 时长 | 5min / 15min / 30min / 60min | P1 | volatile 漂移 + 内存膨胀 |
| 语言 | 中文 / 英文 / 中英混 | P1 | 实际使用场景 |
| 性能 | RTFx / 内存峰值 / 首次加载 | P1 | 8GB 设备可行性 |
| 音频条件 | 近场/远场、安静/嘈杂 | P2 | VAD 和 embedding 质量 |
| 说话风格 | 轮流发言 / 自由讨论 / 演讲+QA | P2 | 不同交互模式 |

## 指标定义

| 指标 | 评什么 | 公式/说明 | 层 |
|------|--------|----------|---|
| WER | 转写词错误率 | (S+D+I) / N | A |
| CER | 转写字错误率 | 同上，字级别（中文主指标）| A |
| DER | 说话人标错率 | (miss + false_alarm + speaker_error) / total, collar=0.25s, ignoreOverlap=True | B |
| DER-overlap | 含重叠的 DER | 同上，ignoreOverlap=False | B |
| JER | Jaccard 说话人错误 | 1 - IoU per speaker, 对说话人数敏感 | B |
| Speaker Count Error | 说话人数偏差 | detected - ground_truth（正=过分割，负=欠分割）| B |
| cpWER | 端到端质量 | 最优排列下的拼接词错误率 | C |
| RTFx | 处理速度 | audio_duration / processing_time | 性能 |
| Peak Memory | 内存峰值 | MB | 性能 |

## 数据集需求矩阵

| 维度 | 需要的数据集特征 | 需要的标注 |
|------|-----------------|-----------|
| 说话人数 | 覆盖 2-10+ 人 | RTTM（说话人 + 时间段）|
| 重叠率 | 有高重叠场景 | RTTM 含重叠段标注 |
| 时长 | 单场 >30min | 完整长音频 |
| 语言 | 中文 + 英文 | 对应语言的转录文本 |
| 音频条件 | 近场 + 远场 | 多麦克风配置 |

## 单次测试输出格式

```jsonc
{
  "test_id": "ami-ES2004a-offline",
  "dataset": "AMI",
  "meeting": "ES2004a",
  "audio_duration_s": 1049.35,
  "language": "en",
  "speakers_gt": 4,
  "speakers_detected": 5,
  "overlap_ratio": null,        // 音频中重叠语音占比

  "device": "Mac Mini M4, 16GB",
  "mode": "offline",

  // 层 B: 分离
  "der": 14.53,
  "der_with_overlap": null,
  "jer": 37.2,
  "miss_rate": 7.59,
  "false_alarm_rate": 1.74,
  "speaker_error_rate": 5.20,

  // 层 A: 转写（待实现）
  "wer": null,
  "cer": null,

  // 层 C: 端到端（待实现）
  "cpwer": null,

  // 性能
  "processing_time_s": 7.85,
  "rtfx": 133.6,
  "peak_memory_mb": null,
  "timings": {
    "segmentation_s": 2.94,
    "embedding_s": 7.43,
    "clustering_s": 0.37,
    "model_load_s": 0.08,
    "audio_load_s": 0.02
  }
}
```

## 已有基线数据

### ES2004a（AMI，英文，4 人，17.5min）— 2026-03-17 实测

设备：Mac Mini M4，10 核 CPU，16GB RAM，macOS 26
工具：fluidaudiocli diarization-benchmark --mode offline --single-file ES2004a
音频时长来源：AMI UEM 文件 end_time=1049.354687s

```json
{
  "processing_time_s": 7.85,
  "rtfx": 133.6,
  "der": 14.53,
  "jer": 37.2,
  "speakers_gt": 4,
  "speakers_detected": 5,
  "miss_rate": 7.59,
  "false_alarm_rate": 1.74,
  "speaker_error_rate": 5.20,
  "timings": {
    "segmentation_s": 2.94,
    "embedding_s": 7.43,
    "clustering_s": 0.37
  }
}
```

### 官方参考（FluidAudio Benchmarks.md）

来源：https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md

设备：2024 MacBook Pro M4 Pro, 48GB RAM

Offline, VoxConverse 232 clips:
- StepRatio=0.2（默认）: DER 15.07%, RTFx 122x
- StepRatio=0.1（高精度）: DER 13.89%, RTFx 65x
- collar=0.25s, ignoreOverlap=True

对比 pyannote 原版:
- CPU: ~1.5-2x RTFx
- MPS: ~20-25x RTFx

## 数据集选型

验证日期：2026-03-18。逐个确认了下载可用性、标注格式、许可证。

### 选定数据集

| 数据集 | 语言 | 说话人 | 时长/场 | 重叠率 | 近/远场 | RTTM | 许可证 | 下载地址 |
|--------|------|--------|---------|--------|---------|------|--------|----------|
| **AMI** | 英 | 3-6 | 30-60min | ~10-20% | 近+远 | 社区转换 | CC BY 4.0 | https://groups.inf.ed.ac.uk/ami/download/ |
| **ICSI** | 英 | 3-10 | 17-103min | 高 | 近+远 | 社区转换 | CC BY 4.0 | https://groups.inf.ed.ac.uk/ami/icsi/download/ |
| **AliMeeting** | 中 | 2-4 | 15-30min | >30% | 近+远 | 有 | CC BY-SA 4.0 | https://www.openslr.org/119/ |
| **AISHELL-4** | 中 | 4-8 | ~34min | ~19% | 远场 | 需工具链 | CC BY-SA 4.0 | https://www.openslr.org/111/ |

### 维度覆盖

| 维度 | 覆盖情况 |
|------|----------|
| 说话人数 2-4 | AliMeeting |
| 说话人数 4-8 | AMI + AISHELL-4 |
| 说话人数 8-10 | ICSI（最高 10 人，部分会议） |
| 重叠 >30% | AliMeeting |
| 重叠 10-20% | AMI + AISHELL-4 |
| 时长 >30min | AMI + ICSI + AISHELL-4 |
| 中文 | AliMeeting + AISHELL-4 |
| 英文 | AMI + ICSI |
| 近场 | AMI + AliMeeting |
| 远场 | AMI + ICSI + AliMeeting + AISHELL-4 |

### 淘汰数据集及原因

| 数据集 | 淘汰原因 |
|--------|----------|
| DIHARD III | 需 LDC 付费，非免费 |
| VoxConverse | 重叠率仅 3.5%，片段 <20min |
| LibriCSS | 模拟数据（LibriSpeech 回放），片段仅 10min |
| MagicData-RAMC | CC BY-NC-ND（不可商用不可修改），仅 2 人对话 |

### 数据集详情

#### AMI Corpus

- 100 小时会议录音，场景会议通常 4 人
- 音频：WAV 16kHz 16-bit，headset-mix（单 WAV 混合）或单独头戴麦或麦克风阵列
- 原始标注为 NXT 格式，RTTM 通过 pyannote 社区工具转换：https://github.com/pyannote/AMI-diarization-setup
- FluidAudio CLI 内置 AMI 支持（`--dataset ami-sdm --auto-download`）

#### ICSI Meeting Corpus

- 75 场会议，约 72 小时，53 个独立说话人
- 每场 3-10 人（平均 6 人），时长 17-103 分钟（通常接近 1 小时）
- 重叠极为常见，3-4 人同时说话是常态
- 音频：WAV headset-mix 或 SPH 单通道，16kHz 16-bit
- 标注为 NXT 格式，需社区工具转 RTTM
- 录音年代较早（2000-2002），但数据质量可靠

#### AliMeeting (M2MeT)

- 120 小时中文会议，2-4 人/场，15-30 分钟/场
- **重叠率 >30%**——所有数据集中最高，最适合测重叠场景
- 远场：8 通道环形麦克风阵列；近场：每人头戴麦
- RTTM 标注 + 高质量转写，标注质量高
- 下载约 108GB（Train 远场 73GB + 近场 23GB + Eval + Test）
- 下载地址含阿里云 OSS 直链，国内速度快

#### AISHELL-4

- 211 场中文会议，120 小时，4-8 人/场，约 34 分钟/场
- 远场 8 通道环形麦克风阵列，无近场
- 重叠率：训练集 ~19%，评估集 ~9%
- 标注需通过工具链生成 RTTM
- 下载约 51GB，多镜像可选

### 评估执行计划

**Phase 1 — 层 B 分离评估（FluidAudio 单独评）**

优先使用 AMI（英文）和 AliMeeting（中文），因为：
- FluidAudio CLI 原生支持 AMI
- AliMeeting 自带 RTTM，无需转换
- 覆盖近场+远场+高重叠

测试矩阵：
- AMI: 从 test set 选 3-5 场不同说话人数的会议
- AliMeeting: eval set，关注重叠率对 DER 的影响
- AISHELL-4: eval set，关注 4-8 人聚类表现

**Phase 2 — 层 A 转写评估 + 层 C 端到端**

需要先确认 SpeechAnalyzer 对中英文的基线 WER/CER，再跑完整链路的 cpWER。
