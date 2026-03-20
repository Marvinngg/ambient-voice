# ambient-voice：基于 Apple 原生框架的语音输入系统

## 理念

语音效率高于打字，这已是共识。问题在实现路径。

市面上的语音输入方案——Whisper、讯飞、Google Speech——跑在苹果设备上，却没有用苹果的任何东西。Whisper 要几个 G 的内存加载模型，讯飞要把音频传到云端。这些方案放在 Windows 还是 macOS 上没有区别，完全没有利用苹果生态的能力。

macOS 26 把语音识别做进了系统框架（SpeechAnalyzer）。端侧运行，毫秒级延迟，不联网，不收费。同时 Apple 的 Vision 框架能做端侧 OCR，ScreenCaptureKit 能截取任意窗口，AX API 能读写任意应用的 UI 元素，CoreML 能跑端侧模型推理。

ambient-voice 的设计原则是：每一层都用 Apple 原生框架。

- 语音识别：SpeechAnalyzer
- 屏幕感知：ScreenCaptureKit + Vision OCR
- 文字注入：AX API + CGEvent
- 纠错检测：AX API
- 说话人分离：FluidAudio（CoreML）
- 热键监听：CGEventTap

原生意味着三件事：端侧处理，数据不出设备；零额外成本，不需要付费 API；随系统升级自动提升——macOS 27 的 SpeechAnalyzer 比 26 更准，你什么都不用做。

这就是"水涨船高"。

## 系统架构

### 输入链路

按住右 Option 键开始，松开结束。完整处理流程：

```
热键按下
  → AVCaptureSession 采集音频（兼容蓝牙设备）
  → 截取焦点窗口（ScreenCaptureKit）
  → Vision OCR 识别窗口文本 → 提取关键词
  → 关键词注入 SpeechAnalyzer 的 AnalysisContext
  → SpeechAnalyzer 实时转写
      输出：文本 + volatile/final 状态 + alternatives 候选词 + 词级 confidence
  → L1 AlternativeSwap：用 alternatives 列表做确定性候选词替换
  → L2 PolishClient：调用本地 LLM 润色（ollama，Qwen3 系列）
  → TextInjector：写入剪贴板 + 模拟 Cmd+V 注入当前焦点应用
松开结束
```

### 上下文偏置

这是整个架构的核心机制。

传统语音输入的纠错思路是：先转写，再用后处理修正错误。ambient-voice 的做法是在转写阶段就介入——开始说话时截取当前屏幕，OCR 提取可见文本中的关键词，注入 SpeechAnalyzer 的 AnalysisContext。

效果：你在回一封讨论 OKR 的邮件，说"把留存目标改一下"。识别引擎看到了屏幕上的"留存率"、"OKR"，在做同音词选择时直接命中，不会把"留存"识别成"留村"。

这不是纠错，是预防。

### 数据闭环

每次使用自动产生训练数据，通过蒸馏管线持续改进端侧模型。

```
每次转写自动落盘
  → voice-history.jsonl（转写全记录：SA 原文 / L1 输出 / L2 输出 / 词级 confidence）
  → audio/（原始录音 WAV）

注入后 30 秒观测窗口
  → AX API 读取焦点应用文本
  → 检测用户是否修改了注入内容
  → 如有修改 → corrections.jsonl（自动采集，无需用户主动操作）

后台蒸馏（双路线并行）
  → 路线 A：原始音频 → Whisper large 重新转写（GPU 服务器）
  → 路线 B：SA 原文 + 小模型输出 → Gemini 2.5 Flash 纠正（本地 API）

三路合并
  → 人工纠错（权重 x2）> 双路一致（x1.5）> 单路（x1）
  → QLoRA 微调 Qwen3 → GGUF 量化 → 部署回 ollama
  → L2 润色能力升级
```

飞轮的初始设计依赖用户主动纠错驱动迭代。开发过程中改掉了这个思路——用语音就是图省事，不能指望用户每次手动改。改为强模型自动蒸馏为主，用户纠错降为可选辅助信号（默认关闭，config 可开）。两条蒸馏路线并行跑，不预设取舍，按数据质量（fix_rate / break_rate）决定加权。

### 会议模式

除日常听写外，支持会议场景：

```
开始录音（⌘M）
  → AVCaptureSession 持续采集
  → 音频分叉：SpeechAnalyzer 实时转写 + 16kHz 缓冲区累积 + WAV 文件写入
  → 实时转录悬浮面板（NSPanel，浮动置顶，跨空间显示）

结束录音
  → FluidAudio 对累积音频做说话人分离（CoreML 端侧批处理）
  → 时间重叠对齐：转录片段 audioTimeRange 与分离片段匹配
  → 导出 Markdown（时间戳 + 说话人标签 + 文本）
```

## 开发方式：用 Skill 驱动 Claude Code

项目的主要开发由 Claude Code 完成。其中截屏上下文功能的开发方式值得单独说。

做法是写了一个 Claude Code Skill。Skill 不是代码，是一份结构化的领域知识文档——包含屏幕上下文感知的设计意图、Apple 原生 API 的签名（从 SDK 的 .swiftinterface 验证过的）、TCC 权限的获取方式和失败表现。

Claude Code 加载这个 Skill 后，具备了这个领域的认知上下文，然后实现具体功能。

思路是：**把"为什么做"和"用什么做"封装成 Skill，让 AI 专注于"怎么做"。** 领域知识越明确，AI 的实现质量越高。

开发过程中踩到的几个实战问题，都不在任何现有文档中（macOS 26 太新）：

- **蓝牙采集静默**：AVAudioEngine 的 installTap 在蓝牙设备上回调永远不触发。定位后切换到 AVCaptureSession 重写了整个采集链路。
- **Swift 6 并发崩溃**：NSEvent addGlobalMonitorForEvents 在 macOS 26 + Swift strict concurrency 下触发 Bus error（GlobalObserverHandler 的 actor 隔离问题）。切 CGEventTap + DispatchQueue.main.async 桥接回主线程。
- **权限每次编译重置**：ad-hoc 签名每次产生不同 cdhash，macOS 把它当新应用，TCC 权限全部丢失。切换到 Apple Development 证书签名，Team ID 固定，权限持久化。

这些问题的共同特点：不是写代码的问题，是对 macOS 系统机制的理解问题。Skill 提供了框架级认知，Claude Code 在此基础上做具体的工程判断和实现。

## 开源

MIT 开源。GitHub: [https://github.com/Marvinngg/ambient-voice](https://github.com/Marvinngg/ambient-voice)
