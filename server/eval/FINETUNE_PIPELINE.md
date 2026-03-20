# 端侧模型微调全链路架构

## 目标

用户每天使用 WE → 自动积累数据 → 蒸馏生成训练集 → 微调端侧模型 → 评估 → 部署替换 → 用户体验提升 → 继续积累

## 全链路总览

```
┌─────────────────────────────────────────────────────────────┐
│                    Mac（客户端）                              │
│                                                             │
│  用户使用 WE                                                 │
│    │                                                        │
│    ├──→ voice-history.jsonl    (每次转写自动写入)              │
│    ├──→ corrections.jsonl      (用户纠正自动采集)              │
│    ├──→ audio/*.wav            (原始录音)                     │
│    │                                                        │
│    ▼                                                        │
│  ① 蒸馏路线 B（本地）                                         │
│    config.distill → Gemini 2.5 Flash                        │
│    voice-history + polished → distill-gemini.jsonl           │
│    │                                                        │
│    ▼                                                        │
│  ② 自动同步（config.sync）                                    │
│    rsync → GPU 服务器                                        │
│    推送：voice-history + corrections + audio + distill-gemini │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    GPU 服务器（4090）                         │
│                                                             │
│  ③ 蒸馏路线 A（服务器）                                       │
│    audio/*.wav → Whisper large → distill-whisper.jsonl       │
│                                                             │
│  ④ 数据合并                                                  │
│    merge_pairs.py                                           │
│    distill-gemini + distill-whisper + corrections            │
│    → merged-pairs.jsonl（最终训练集）                          │
│    优先级：人工纠错(x2) > 多路一致(x1.5) > 单路(x1)            │
│                                                             │
│  ⑤ 微调                                                     │
│    train_qlora.py                                           │
│    base: Qwen3-0.6B                                         │
│    data: merged-pairs.jsonl                                  │
│    output: LoRA adapter                                      │
│                                                             │
│  ⑥ 评估                                                     │
│    eval_model.py                                            │
│    测试集 → base model → CER_base                            │
│    测试集 → fine-tuned → CER_ft                              │
│    测试集 → AI Judge  → 质量分                                │
│    对比：CER 下降？语义保留？退化了没有？                        │
│                                                             │
│  ⑦ 部署                                                     │
│    deploy_model.sh                                          │
│    merge LoRA → GGUF 量化 → ollama create                    │
│    │                                                        │
└────┼────────────────────────────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────────────────────────────┐
│                    Mac（客户端）                              │
│                                                             │
│  ⑧ 模型替换                                                  │
│    config.json: model → we-polish-v2                         │
│    热更新，无需重启                                            │
│    下一轮使用数据继续积累 → 回到 ①                              │
└─────────────────────────────────────────────────────────────┘
```

## 各环节详细设计

### ① 蒸馏路线 B（本地 Mac，Gemini）

- 触发：sync 脚本自动执行，或 `make sync` 手动
- 输入：voice-history.jsonl（rawSA + polishedText）
- 处理：gen_distill_gemini.py，增量模式
- 输出：distill-gemini.jsonl
- 配置：config.json → distill.base_url / api_key / model
- 质量过滤：edit_ratio > 0.3 的丢弃

### ② 数据同步

- 触发：launchd 监听 voice-history.jsonl 变化，或手动 `make sync`
- 工具：rsync over SSH
- 推送内容：
  - voice-history.jsonl（蒸馏输入源）
  - corrections.jsonl（人工标注，最高优先级）
  - audio/（路线 A 输入）
  - distill-gemini.jsonl（路线 B 产出）
- 配置：config.json → sync.server / remote_dir

### ③ 蒸馏路线 A（GPU 服务器，Whisper）

- 触发：cron 每 10 分钟检查新数据
- 输入：audio/*.wav + voice-history.jsonl（取 rawSA）
- 处理：gen_distill_whisper.py，增量模式
- 输出：distill-whisper.jsonl
- 模型：whisper-large-v3
- 质量过滤：edit_ratio > 0.4 的丢弃

### ④ 数据合并

- 工具：merge_pairs.py
- 输入：distill-gemini.jsonl + distill-whisper.jsonl + corrections.jsonl
- 输出：merged-pairs.jsonl
- 合并策略：
  - 按 input 文本去重
  - 人工纠错权重 x2
  - 多路一致权重 x1.5
  - 冲突标记但保留

### ⑤ 微调

- 工具：train_qlora.py
- 基础模型：Qwen/Qwen3-0.6B
- 方法：QLoRA (4-bit quantized LoRA)
- 数据格式：{"input": "SA原文", "output": "纠正后文本"}
- 输出：LoRA adapter checkpoint
- 关键参数：
  - epochs: 根据数据量调整
  - sample_weight: 用 merged-pairs 中的权重字段
  - eval_split: 10% 留作验证

### ⑥ 评估

#### 测试集构成

| 测试集 | 来源 | 用途 |
|--------|------|------|
| corrections 测试集 | corrections.jsonl 随机 20% 留出 | 真实用户纠正，最高价值 |
| voice-history 测试集 | voice-history.jsonl 有音频的条目 | 可重跑音频对比不同模型 |
| AliMeeting 近场切段 | 公开数据集 | 标准化对比 |
| AISHELL-1 test | 公开数据集 | 学术基线 |

#### 评估指标

| 指标 | 工具 | 层级 | 说明 |
|------|------|------|------|
| CER_raw | jiwer | SpeechAnalyzer 原始 | 基线，不可优化 |
| CER_L2_base | jiwer | base model 润色后 | 微调前 |
| CER_L2_ft | jiwer | fine-tuned 润色后 | 微调后 |
| ∆CER | 计算 | CER_L2_base - CER_L2_ft | 微调增益（正=提升） |
| 退化率 | 计算 | 被改错的样本占比 | 负面影响 |
| AI_fidelity | Gemini Judge | 语义保真度 0-1 | 意思有没有变 |
| AI_fluency | Gemini Judge | 流畅度 0-1 | 是否自然书面语 |
| AI_cleanup | Gemini Judge | 口语清理 0-1 | 口水词/重复处理 |
| latency | 计时 | L2 调用耗时 | 用户体感 |

#### AI Judge 标准化 prompt

```
你是 ASR 后处理评估专家。

原始转写：{rawSA}
模型输出：{polished}
参考答案：{reference}

评分标准：
- fidelity (0-1): 模型输出和参考答案语义是否一致。1=完全一致，0=意思完全不同
- fluency (0-1): 模型输出是否是自然流畅的书面语。1=完美书面语，0=不可读
- cleanup (0-1): 口水词(嗯啊那个)、重复、语气词是否被合理清理。1=完美清理，0=未处理

只输出 JSON：{"fidelity": 0.9, "fluency": 0.8, "cleanup": 0.7}
```

#### 评估流程

```
测试集（固定不变）
  │
  ├──→ rawSA（不经过模型）→ CER_raw
  │
  ├──→ base model (qwen3:0.6b) 润色 → CER_L2_base + AI Judge
  │
  ├──→ fine-tuned v1 润色 → CER_L2_ft_v1 + AI Judge
  │
  ├──→ fine-tuned v2 润色 → CER_L2_ft_v2 + AI Judge
  │
  └──→ 对比表：
       | 模型 | CER | ∆CER | 退化率 | fidelity | fluency | cleanup | latency |
```

### ⑦ 部署

- 工具：deploy_model.sh
- 流程：merge LoRA → GGUF 量化(Q4_K_M) → ollama create
- 输出：ollama 模型（如 we-polish-v2）
- 验证：部署后跑一遍 eval 确认线上和离线指标一致

### ⑧ 模型替换

- 修改 config.json: `server.model → "we-polish-v2"`
- WE 热更新，无需重启应用
- 新版模型开始服务，新的使用数据继续积累

## 迭代节奏

```
第 1 周：积累数据（100+ 条）
         ↓
第 2 周：首次蒸馏 + 微调 v1
         eval: base vs v1
         ↓
持续使用：数据继续增长
         ↓
第 N 周：数据量翻倍 → 微调 v2
         eval: base vs v1 vs v2
         ↓
...
```

每次迭代的评估结果存档：`server/eval/results/finetune_v1/`, `finetune_v2/` ...

## 文件结构

```
server/
├── gen_distill_gemini.py        # ① 路线 B 蒸馏
├── gen_distill_whisper.py       # ③ 路线 A 蒸馏
├── merge_pairs.py               # ④ 数据合并
├── train_qlora.py               # ⑤ 微调
├── eval_model.py                # ⑥ 评估（待完善）
├── scripts/
│   ├── run_pipeline.sh          # 一键：蒸馏 → 合并 → 微调 → 评估
│   ├── deploy_model.sh          # ⑦ 部署
│   └── run_distill.sh           # 并行蒸馏调度
└── eval/
    ├── EVAL_FRAMEWORK.md        # 会议模式评估架构
    ├── FINETUNE_PIPELINE.md     # 本文件：微调全链路架构
    ├── scripts/                 # 数据预处理辅助脚本
    ├── benchmarks/              # 评估运行脚本
    ├── transcription-bench/     # SpeechAnalyzer 文件输入工具
    ├── datasets/                # 公开数据集
    └── results/                 # 评估结果存档
```
