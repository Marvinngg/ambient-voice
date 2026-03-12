# WE 项目进展报告

## 一句话

**macOS 端侧语音输入工具，按住说话 → 智能润色 → 注入任意应用，数据自动回流蒸馏持续优化模型。**

---

## 已完成

### 1. macOS 客户端（24 个 Swift 文件，完整可用）

**核心链路已跑通：**
```
按住 Right Option → 录音 → Apple SA 转写 → L1 确定性替换 → L2 模型润色 → 注入焦点应用
```

| 模块 | 状态 | 说明 |
|---|---|---|
| 热键触发 (GlobalHotKey) | ✅ | CGEventTap 监听 Right Option，兼容 macOS 26 |
| 录音 (VoiceSession) | ✅ | AVCaptureSession + 手写 WAV（修复了 AVAudioFile 崩溃） |
| 语音转写 (TranscriptionAccumulator) | ✅ | Apple SpeechAnalyzer，词级 confidence + alternatives |
| L1 替换 (AlternativeSwap) | ✅ | 基于 SA alternatives 的确定性替换 |
| L2 润色 (PolishClient) | ✅ | Ollama 本地 Qwen3.5:4B，专用 ASR 纠错 prompt |
| 文本注入 (TextInjector) | ✅ | 剪贴板 Cmd+V 方式注入，支持所有应用 |
| 录音 UI (RecordingIndicator) | ✅ | 类原生听写浮窗，红色脉冲圆点 + 毛玻璃面板 |
| 菜单栏 (StatusBarController) | ✅ | 录音时红色 WE● 指示 |
| 权限管理 (PermissionManager) | ✅ | 麦克风 + 辅助功能权限检查 |
| 配置系统 (RuntimeConfig) | ✅ | ~/.we/config.json 热更新 |

### 2. 纠错采集（CorrectionCapture）

| 功能 | 状态 | 说明 |
|---|---|---|
| 文本编辑器（Notes 等） | ✅ | AX API 直接读取输入框文本，对比注入内容 |
| Terminal 适配 | ✅ | AX 返回整个缓冲区，LCS 行搜索匹配 + prompt 前缀剥离 |
| Enter 键触发 | ✅ | CGEventTap 监听 keyDown(36/76)，30 秒超时兜底 |
| 数据落盘 | ✅ | corrections.jsonl，三层数据：SA原文 / L2输出 / 用户最终修改 |

### 3. 蒸馏数据管线（双路线并行，全自动）

目标：用强模型生成训练数据，蒸馏到端侧小模型（Qwen3-0.6B），持续提升 L2 润色质量。

**路线 A — 语音重转写（服务器 4090）**
```
原始音频 (.wav) → Whisper-large-v3 重新转写 → 产出新的转写文本
配对：<SA原文, Whisper转写>
```
- 不涉及文本润色，纯粹用更强的语音模型重新听一遍音频
- Whisper 直接听原始语音，不会被 SA 的文字错误误导
- 在 4090 GPU 上跑，cron 每 10 分钟增量处理新数据

**路线 B — 文本纠正（本地 Mac）**
```
SA原文 + L2小模型润色结果 → Gemini 2.5 Flash 判断纠正 → 产出纠正文本
配对：<SA原文, Gemini纠正>
```
- 纯文本层面：把 SA 转写和小模型当前的润色输出都给 Gemini，让它判断哪些改对了、哪些改错了
- 通过本地 Antigravity Tools 代理 (localhost:8045) 调用，不需要音频
- launchd 监听数据变化自动触发，增量处理

**人工纠错（可选第三路）**
```
L2润色注入后 → 用户手动修改 → Enter 键触发采集
配对：<SA原文, 用户最终文本>
```
- 质量最高，作为训练高优样本 + 评测基准
- 支持文本编辑器和 Terminal

**自动化全流程：**
```
用户说话 → voice-history.jsonl + audio/*.wav 落盘
  → launchd 自动触发
    → ① 路线B: Gemini 文本纠正（本地，不需要音频）
    → ② rsync 全部数据（文本+音频+蒸馏结果）到 4090 服务器
  → 服务器 cron
    → ③ 路线A: Whisper 语音重转写（服务器 GPU，需要音频）
```

| 环节 | 状态 | 运行位置 |
|---|---|---|
| 数据落盘 + 音频保存 | ✅ | 本地 Mac |
| 自动同步（launchd + rsync） | ✅ | 本地 → 服务器 |
| 路线 B: Gemini 文本纠正 | ✅ | 本地 Mac（增量） |
| 路线 A: Whisper 语音重转写 | ✅ | 4090 服务器（增量） |
| 人工纠错采集 | ✅ | 本地 Mac |

### 4. 关键 Bug 修复

| Bug | 修复 |
|---|---|
| 第二次录音崩溃（AVAudioFile C 级 abort） | 手写 WAV FileHandle，绕过 AVAudioFile |
| 服务器 HTTP 被 ATS 拦截 | Info.plist 添加 NSAllowsArbitraryLoads |
| L2 模型不听 system prompt | 从 0.8B 升级到 4B，重写纠错专用 prompt |
| Terminal 纠错 similarity=0.00 | LCS 相似度 + 行搜索 + prompt 前缀剥离 |

---

## 未完成

### 1. 训练与部署（脚本已写，待数据量足够后执行）

| 环节 | 状态 | 说明 |
|---|---|---|
| QLoRA 微调 (train_qlora.py) | 📝 脚本就绪 | Qwen3-0.6B, rank=16 |
| 模型评估 (eval_model.py) | 📝 脚本就绪 | fix_rate / break_rate / CER，分来源统计 |
| 数据合并 (merge_pairs.py) | 📝 脚本就绪 | Whisper + Gemini + 人工纠错合并，冲突仲裁 |
| 模型部署 (deploy_model.sh) | 📝 脚本就绪 | merge LoRA → GGUF → ollama create |
| 全链路 Pipeline (run_pipeline.sh) | 📝 脚本就绪 | 一键：蒸馏→合并→训练→评估→部署 |
| 服务器 GPU 依赖 | ❌ 未安装 | torch / transformers / peft / trl / bitsandbytes |

### 2. 客户端能力补全

| 功能 | 状态 | 说明 |
|---|---|---|
| 本地模型推理 (llama.cpp) | ❌ | 当前通过 Ollama HTTP，计划集成 llama.cpp C 库直推 |
| 模型自动更新 | ❌ | 训练出新 adapter 后客户端自动拉取 |
| 首次设置引导 | ❌ | 下载模型、申请权限的引导窗口 |
| 纠错功能开关 UI | ❌ | config 里有字段，菜单栏 UI 还没做 |

---

## 架构总览

```
┌──────────────────── macOS 客户端 (Swift) ────────────────────┐
│                                                               │
│  用户体验层：                                                  │
│    Right Option → 录音 → SA转写 → L1替换 → L2润色 → 注入      │
│                                                               │
│  数据采集层：                                                  │
│    voice-history.jsonl (SA原文+L2输出)                         │
│    audio/*.wav         (原始录音)                              │
│    corrections.jsonl   (用户手动纠正)                          │
│                                                               │
│  路线B (本地, 文本纠正):                                       │
│    SA原文 + L2润色 → Gemini 2.5 Flash → distill-gemini.jsonl  │
│    (通过 Antigravity Tools 本地代理, 不需要音频)               │
│                                                               │
└───────────────────────┬──────────────────────────────────────┘
                        │ launchd + rsync (自动同步)
                        ▼
┌──────────────────── 4090 服务器 (GPU) ───────────────────────┐
│                                                               │
│  路线A (服务器, 语音重转写):                                    │
│    audio/*.wav → Whisper-large-v3 → distill-whisper.jsonl     │
│    (纯语音重听, 不依赖文本, 需要 GPU)                          │
│                                                               │
│  训练 (待执行):                                                │
│    路线A + 路线B + 人工纠错                                     │
│      → 合并去重 → QLoRA 微调 Qwen3-0.6B → GGUF → 部署        │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```
