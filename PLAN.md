# WE 项目方案

## 一、目标

从零复现 WE macOS 客户端核心能力，同时将数据飞轮从"用户纠错驱动"升级为"强模型蒸馏驱动"。

交付物：一个可构建运行的 macOS 菜单栏应用，实现按住说话、语音转文字、智能润色、文本注入的完整链路。

---

## 二、核心链路

```
按住 Right Command
  -> AudioEngine 录音
  -> Apple SpeechAnalyzer 转写（词级 confidence + alternatives）
  -> L1: AlternativeSwap 确定性替换（高置信度词替换）
  -> L2: PolishClient 语义润色（路由到后端/本地模型）
  -> TextInjector 注入焦点应用
  -> CorrectionCapture 监测用户修正（辅助信号）
  -> 数据落盘 ~/.we/
```

---

## 三、架构设计

### 3.1 分层

```
Shell 层（壳）
  WEApp -> StatusBar Menu -> GlobalHotKey -> ModuleManager
  RuntimeConfig / PermissionManager / UpdaterService

Module 层（模块，当前只有 Voice）
  VoiceModule -> VoiceSession -> TranscriptionAccumulator

Pipeline 层（后处理）
  VoicePipeline -> AlternativeSwap -> PolishClient -> TextInjector

Data 层（数据闭环）
  CorrectionCapture -> CorrectionStore -> VoiceHistory
  JSONLWriter（通用落盘）

Model 层（本地推理）
  ModelManager -> LocalModelClient (llama.cpp)
```

### 3.2 关键设计决策

| 决策 | 选择 | 原因 |
|------|------|------|
| ASR | Apple SpeechAnalyzer | 免费、端侧、词级信息丰富 |
| 润色模型 | Qwen3-0.6B + LoRA | 小、快、可私有微调 |
| 本地推理 | llama.cpp (GGUF) | 成熟、C 库可静态链接到 Swift |
| 文本注入 | AX API 优先，clipboard 兜底 | AX 无侵入，兜底保证可用 |
| 配置 | ~/.we/config.json + runtime-config.json | 配置驱动，不改代码 |
| 构建 | Makefile + SPM | make build 先编 llama.cpp，再 swift build |

---

## 四、数据飞轮方案（核心升级点）

### 4.1 原方案的问题

原方案依赖用户手动纠错 -> corrections.jsonl -> 回流训练。
现实：用户不会勤快地改每一个错字，数据量不够驱动飞轮。

### 4.2 新方案：双路线并行蒸馏

前期测试阶段，两条路线同时跑，后台并行产出训练数据，后期根据数据质量决定取舍。

```
              用户日常使用
                   |
          SA 转写原文 + 原始音频
                   |
              落盘到 ~/.we/
                   |
        -------- 后端离线（并行） --------
           |                        |
      路线 A: 强语音模型           路线 B: Gemini 文本纠正
           |                        |
   原始音频 -> 强 ASR 转写    SA原文 -> 0.6B 润色输出
   (Whisper-large 等)          -> Gemini 2.5 Flash 纠正
           |                        |
   生成 <SA原文, 强ASR输出>   生成 <SA原文, Gemini纠正>
           |                        |
        -------- 合并训练数据 --------
                   |
          QLoRA 蒸馏到 0.6B（学生）
                   |
          导出 adapter GGUF -> manifest 发布
                   |
          客户端下载新 adapter -> 本地润色升级
```

### 4.3 两条路线详解

#### 路线 A：强语音模型蒸馏

| 项目 | 说明 |
|------|------|
| 输入 | 原始音频文件（~/.we/audio/*.caf） |
| 教师 | 更强的语音模型（Whisper-large / 在线语音 API） |
| 做法 | 把音频直接丢给强语音模型转写，输出作为"正确答案" |
| 产出 | `<SA转写, 强ASR转写>` 配对 |
| 优势 | 教师直接听到语音，纠正质量最高，不会被 SA 错误文本误导 |
| 要求 | 客户端需保存原始音频 |

#### 路线 B：Gemini 2.5 Flash 文本纠正

| 项目 | 说明 |
|------|------|
| 输入 | SA 转写原文 + 0.6B 小模型当前润色输出 |
| 教师 | Gemini 2.5 Flash（有大量额度） |
| 做法 | 把小模型的输出给 Gemini，让它判断哪里对哪里错，做纠正 |
| 产出 | `<SA转写, Gemini纠正>` 配对 |
| 优势 | 不需要音频，成本低（额度充足），速度快，可大批量跑 |
| 要求 | 提示词要设计好，让 Gemini 理解"ASR 纠错"的任务边界 |

### 4.4 并行策略

- **两条路线同时跑**，后台各自独立产出训练数据
- 训练数据打标来源（`source: "whisper"` / `source: "gemini"`），方便后续分析
- 可以分别训练 adapter 对比效果，也可以混合训练
- **后期看数据**：哪条路线 fix_rate 更高、break_rate 更低，就加权哪条
- 不排除最终两条都保留（各有擅长的场景）

### 4.5 用户纠错的定位（可开关）

**用户侧**：纠错功能通过 `~/.we/config.json` 的 `correction.enabled` 控制，默认关闭。
用户可在菜单栏设置中打开/关闭。

**数据逻辑**：
- 关闭时：客户端不监测用户修正，不写 corrections.jsonl。voice-history 正常落盘（供蒸馏路线 A/B 使用）。
- 打开时：CorrectionCapture 激活，用户修正写入 corrections.jsonl，标记 `source: "human"`。

**纠错数据在蒸馏流水线中的角色**：
1. **高优训练数据**：人工纠错样本权重高于自动蒸馏样本（训练时 `sample_weight` 区分）
2. **评测基准**：人工纠错样本同时进入评测集，用来衡量两条蒸馏路线的效果
3. **冲突仲裁**：当路线 A/B 对同一条样本给出不同纠正时，如果该样本有人工纠错，以人工为准

---

## 五、实现计划

### Phase 0: 项目骨架（优先）

```
we/
  Package.swift          # SPM 配置
  Makefile               # 构建入口（llama.cpp + swift build）
  Sources/
    WEApp.swift          # @main, 启动入口
    WEModule.swift       # 模块协议
    ModuleManager.swift  # 模块管理
    StatusBarController.swift  # 菜单栏
    GlobalHotKey.swift   # Right Command 热键
    RuntimeConfig.swift  # 配置热更新
    PermissionManager.swift  # 权限检查
  Resources/
    Assets.xcassets/
```

交付标准：make build 通过，菜单栏图标出现，热键可响应。

### Phase 1: 语音转写

```
  Sources/
    VoiceModule.swift
    VoiceSession.swift
    TranscriptionAccumulator.swift
```

交付标准：按住说话，松开后 debug.log 输出 SA 转写文本。

### Phase 2: 后处理 + 注入

```
  Sources/
    VoicePipeline.swift
    AlternativeSwap.swift
    PolishClient.swift
    TextInjector.swift
```

交付标准：转写文本经 L1/L2 处理后注入到焦点应用。

### Phase 3: 数据落盘 + 纠错采集

```
  Sources/
    CorrectionCapture.swift
    CorrectionStore.swift
    CaptureProfile.swift
    VoiceHistory.swift
    JSONLWriter.swift
```

交付标准：voice-history.jsonl 和 corrections.jsonl 正常写入。

### Phase 4: 本地模型 + 模型管理

```
  Sources/
    ModelManager.swift
    LocalModelClient.swift
    SetupWindowController.swift
  llama.cpp/              # 子模块或预编译
```

交付标准：首次启动引导下载模型，本地推理可用。

### Phase 5: 蒸馏流水线（后端）

```
  sa-adapter/
    gen_distill_data.py    # 强模型批量纠正 SA 转写
    train_qlora_0.6b.py    # QLoRA 训练
    eval_0.6b.py           # 评估
    merge_and_convert.sh   # LoRA -> GGUF
    deploy.sh              # 发布到 manifest
```

交付标准：一轮完整的 收集 -> 蒸馏 -> 训练 -> 评估 -> 部署 跑通。

---

## 六、蒸馏流水线细节设计

### 6.1 数据收集（客户端侧）

客户端每次语音会话自动落盘：
```json
{
  "ts": "2026-03-06T10:00:00Z",
  "raw_sa": "今天我们去讨论一下这个方案的可行性",
  "polished_0.6b": "今天我们去讨论一下这个方案的可行性",
  "words": [{"text":"今天","confidence":0.95}, {"text":"我们","confidence":0.92}, ...],
  "app": "com.apple.Notes",
  "audio_path": "~/.we/audio/20260306-100000.caf"
}
```

关键：**必须同时保存原始音频和 0.6B 润色输出**，两条路线分别需要。

### 6.2 路线 A：强语音模型蒸馏（gen_distill_whisper.py）

```python
# 伪代码
import whisper  # 或调用在线强 ASR API

model = whisper.load_model("large-v3")

for sample in voice_history:
    audio = load_audio(sample['audio_path'])
    teacher_text = model.transcribe(audio, language="zh")["text"]

    # 质量过滤
    if edit_distance_ratio(sample['raw_sa'], teacher_text) < 0.4:
        training_pairs.append({
            "input": sample['raw_sa'],
            "output": teacher_text,
            "source": "whisper",
            "confidence": avg_word_confidence(sample['words'])
        })
```

### 6.3 路线 B：Gemini 2.5 Flash 文本纠正（gen_distill_gemini.py）

```python
# 伪代码
import google.generativeai as genai

model = genai.GenerativeModel("gemini-2.5-flash")

for sample in voice_history:
    prompt = f"""你是 ASR 纠错专家。
以下是语音识别的原文和一个小模型的润色结果。
请判断哪些地方是对的、哪些地方有错（错字、漏字、多字、语序不通），
输出你纠正后的最终文本。
只改确定有错的地方，不确定就保持原样。不要改变原意和风格。

语音识别原文：{sample['raw_sa']}
小模型润色结果：{sample['polished_0.6b']}
你的纠正："""

    corrected = model.generate_content(prompt).text

    # 质量过滤
    if edit_distance_ratio(sample['raw_sa'], corrected) < 0.3:
        training_pairs.append({
            "input": sample['raw_sa'],
            "output": corrected,
            "source": "gemini",
            "confidence": avg_word_confidence(sample['words'])
        })
```

### 6.4 数据合并与训练

```python
# 两条路线的数据都打了 source 标签，合并后训练
all_pairs = whisper_pairs + gemini_pairs

# 也可以分开训练两个 adapter 做 A/B 对比
# adapter_a = train(whisper_pairs)   # 强 ASR 蒸馏版
# adapter_b = train(gemini_pairs)    # Gemini 纠正版
# adapter_c = train(all_pairs)       # 混合版
```

沿用已有的 train_qlora_0.6b.py 框架：
- 基座：Qwen3-0.6B
- 方法：QLoRA (rank=16, alpha=32)
- 数据：路线A + 路线B + 历史人工纠错（如有）
- 评估：fix_rate / break_rate / CER 变化
- **分来源统计**：分别看 whisper 样本和 gemini 样本对最终效果的贡献

### 6.5 部署

```bash
# merge LoRA -> full model -> GGUF
python merge_lora.py --base qwen3-0.6b --adapter checkpoint-xxx
./llama-quantize merged.bin sa-adapter-vN.gguf Q4_K_M

# 发布
ln -sf sa-adapter-vN.gguf /path/to/we-model-serve/sa-adapter.gguf
# 更新 manifest.json（sha256 + size + version）
```

### 6.6 并行调度（run_distill.sh）

```bash
#!/bin/bash
# 两条路线并行跑，互不依赖
python gen_distill_whisper.py --input voice-history.jsonl --output pairs_whisper.jsonl &
python gen_distill_gemini.py  --input voice-history.jsonl --output pairs_gemini.jsonl &
wait

# 合并
python merge_pairs.py --inputs pairs_whisper.jsonl pairs_gemini.jsonl --output training_data.jsonl

# 训练
python train_qlora_0.6b.py --data training_data.jsonl

# 评估
python eval_0.6b.py --checkpoint latest --by-source
```

---

## 七、关键风险与对策

| 风险 | 对策 |
|------|------|
| 教师模型纠正引入新错误 | edit_distance 阈值过滤；identity 优先（不确定就不改） |
| 蒸馏后小模型学不到 | 先小样本验证；关注 break_rate 不能比 baseline 高 |
| 两条路线产出矛盾（同一条样本 A/B 给出不同纠正） | 打 source 标签，训练时可按权重调；评估时分来源统计 |
| 音频存储占空间 | 设滚动保留策略（如保留最近 7 天），过期自动清理 |
| Gemini API 额度/稳定性 | 批量调用加 retry + rate limit；额度耗尽时路线 B 自动暂停 |
| Whisper-large 推理慢 | 在 4090 上跑，或用 faster-whisper；非实时任务可接受 |
| 苹果 API 变更 | SpeechAnalyzer 是公开 API，做好版本兼容 |

---

## 八、下一步

1. **立即**：搭建 Phase 0 项目骨架，make build 跑通
2. **然后**：逐 Phase 推进客户端能力（确保音频 + 0.6B 输出都落盘）
3. **并行**：在后端同时搭建两条蒸馏路线
   - 路线 A：4090 上部署 Whisper-large，跑音频重转写
   - 路线 B：调 Gemini 2.5 Flash API，跑文本纠正
4. **对比**：分别训练 adapter，用用户真实纠错数据做评测基准，看哪条路线效果更好
5. **收敛**：根据数据决定保留/加权/合并
