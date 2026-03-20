# WE 评测结果报告

评测日期：2026-03-18
设备：Mac Mini M4 (10 核 CPU, 16GB RAM), macOS 26

## 测试变量

| 变量 | 值 |
|------|---|
| 转写引擎 | Apple SpeechAnalyzer (macOS 26), inputAudioFile API |
| L1 AlternativeSwap | 未启用（会议模式不走 L1） |
| L2 Polish (ollama) | 未启用（会议模式不走 L2） |
| 说话人分离 | FluidAudio performCompleteDiarization, offline, 默认 DiarizerConfig |
| 对齐逻辑 | WE alignTranscriptionWithDiarization（时间重叠匹配）|
| 导出 | WE MeetingExporter (Markdown) |
| CER 评估工具 | jiwer 4.0.0（标准工具） |
| DER 评估工具 | spyder 0.4.1 / fluidaudiocli 内置评估（标准工具） |

## 测试一：WE 端到端会议模式 — 远场

- **链路**：MeetingSession.runFromFile() 完整链路
- **数据集**：AliMeeting Eval 远场 ch0（8 通道阵列取单通道，无 beamforming）
- **场次**：8 场中文会议，2-4 人，26-37 分钟/场，重叠率 >30%

| ID | CER% | 分段数 | 说话人(检/实) | RTFx | 耗时 |
|---|---|---|---|---|---|
| R8009_M8018 | 24.2 | 109 | 2/2 | 76.6 | 21.6s |
| R8009_M8020 | 24.7 | 129 | 1/2 | 85.1 | 22.4s |
| R8009_M8019 | 30.9 | 141 | 2/2 | 88.6 | 22.3s |
| R8003_M8001 | 33.7 | 143 | 3/4 | 81.6 | 25.3s |
| R8008_M8013 | 37.0 | 181 | 2/3 | 74.0 | 30.3s |
| R8007_M8011 | 38.5 | 127 | 2/4 | 77.1 | 24.1s |
| R8001_M8004 | 51.7 | 122 | 4/4 | 73.7 | 21.4s |
| R8007_M8010 | 62.1 | 152 | 6/4 | 81.0 | 22.9s |
| **整体** | **40.0** | | | | |

## 测试二：WE 端到端会议模式 — 近场

- **链路**：MeetingSession.runFromFile() 完整链路
- **数据集**：AliMeeting Eval 近场（每人头戴麦，单说话人）
- **场次**：25 个说话人文件，按会议分组

| 会议 | 平均 CER% | 说话人数 |
|---|---|---|
| R8008_M8013 | 17.8 | 3 |
| R8001_M8004 | 22.8 | 4 |
| R8009_M8019 | 23.7 | 2 |
| R8009_M8018 | 24.0 | 2 |
| R8007_M8010 | 25.9 | 4 |
| R8007_M8011 | 27.4 | 4 |
| R8009_M8020 | 39.3 | 2 |
| R8003_M8001 | 110.1 | 4（2 个说话人幻听严重，异常值）|
| **整体** | **34.0** | |
| **去异常值** | **~25%** | |

## 测试三：FluidAudio 组件级分离 — AMI

- **链路**：fluidaudiocli diarization-benchmark（非 WE 链路，组件基线）
- **数据集**：AMI test set，16 场英文，3-4 人，14-50 分钟/场
- **DER 评估**：fluidaudiocli 内置（collar=0.25s, ignoreOverlap=True）

| 指标 | 值 |
|---|---|
| 平均 DER | 23.2% |
| 平均 RTFx | 130.9x |
| DER 范围 | 7.7% - 72.6% |

最佳 3 场：IS1009c(7.7%), IS1009b(7.7%), TS3003b(9.9%)
最差 2 场：ES2004d(69.4%), EN2002a(72.6%)——speaker error 占主导（62%, 59%）

## 测试四：FluidAudio 组件级分离 — AliMeeting

- **链路**：fluidaudiocli process --mode offline → spyder DER（非 WE 链路，组件基线）
- **数据集**：AliMeeting Eval 远场 ch0，8 场中文

| 指标 | 值 |
|---|---|
| 整体 DER | 48.5% |
| Miss | 21.6% |
| False Alarm | 2.7% |
| Confusion | 24.1% |
| RTFx | ~131x |

## 测试五：内存占用

30-40 分钟会议，diarization offline 进程级峰值：
- RSS: ~500MB
- Peak memory footprint: 730-930MB
- 8GB 设备无压力

## 对比总结

| 条件 | 整体 CER | 说明 |
|---|---|---|
| WE 远场 | 40.0% | 8ch 阵列 ch0，无 beamforming，高重叠 |
| WE 近场 | 34.0%（去异常 ~25%）| 头戴麦，单说话人 |
| 近场 vs 远场 | -6pp（去异常 -15pp）| 近场显著优于远场 |

## 未测试项

- [ ] L1 AlternativeSwap 对 CER 的影响（日常转录模式）
- [ ] L2 Polish (ollama) 对 CER 的影响（日常转录模式）
- [ ] 日常转录模式完整链路（短语音场景）
- [ ] 英文转写 CER/WER
- [ ] 5+ 说话人场景
- [ ] 近场混合音频的 DER
- [ ] 端到端 cpWER（meeteval）

## 结果文件

```
results/
├── ami_diarization/          # 测试三：AMI 16 场 JSON + summary
├── alimeeting_diarization/   # 测试四：AliMeeting 8 场 JSON + RTTM + DER
├── we_meeting_e2e/           # 测试一：WE 远场端到端 8 场 JSON + CER + 对比
├── we_nearfield_transcription/ # 测试二：WE 近场 25 个 JSON + CER
└── EVAL_RESULTS.md           # 本文件
```
