# WE 问题深度分析

## 架构前提

WE 有两个独立的语音处理模式，共享底层采集方案（AVCaptureSession）和转写引擎（SpeechAnalyzer + SpeechTranscriber），但上层流程完全不同：

**日常转写模式**（VoiceModule → VoiceSession → VoicePipeline）
- 触发：热键 / Ambient VAD
- 时长：几秒到几十秒
- 链路：SA 转写 → L1（alternatives 日志）→ L2（PolishClient 纠错）→ TextInjector 注入 → VoiceHistory 落盘
- 有 contextualStrings（通过 ScreenContextProvider OCR）
- 有 L2 纠错（通过 ModelServer → ollama）

**会议模式**（MeetingSession，从 StatusBarController 菜单触发）
- 触发：菜单栏点击
- 时长：几十分钟到几小时
- 链路：SA 转写 → TranscriptPanel 实时显示 → stop 后 FluidAudio 批量分离 → 对齐 → MeetingExporter 导出 MD
- **没有** contextualStrings
- **没有** L2 纠错
- **没有** TextInjector 注入
- **没有**写 voice-history

---

## 问题 1：日常转写模式 — 尾部内容丢失

### 现象
用户反馈：说了约 1 分钟的话，最后约 20 秒的转录内容丢失。

### 代码追踪

VoiceSession.stop()（第 204-252 行）的执行顺序：

```
① captureSession?.stopRunning()      // 同步，立即停止硬件采集
② captureSession = nil
③ captureDelegate?.close()            // 关闭 WAV 文件
④ captureDelegate = nil               // delegate 被释放
⑤ inputBuilder?.finish()              // 告诉 SA 输入流结束
⑥ finalizeAndFinishThroughEndOfInput()  // 等 SA 处理完，超时 5 秒
⑦ sleep(500ms)
⑧ resultTask?.cancel()                // 强制取消结果接收循环
⑨ fullText = finalizedText + volatileText
```

### 根因分析（三层）

**第一层：音频 buffer 丢弃**

步骤 ① `stopRunning()` 是同步的，调用后硬件立即停止采集。但 `captureOutput` 回调跑在后台 DispatchQueue `com.antigravity.we.audio-capture` 上。停止采集时，队列里可能有已采集但还没被回调处理的 CMSampleBuffer。

步骤 ④ 立即把 `captureDelegate` 置 nil。但 delegate 是 `AVCaptureAudioDataOutput` 的 delegate，由后台队列持有。置 nil 后，后续回调中 delegate 的 `inputBuilder.yield()` 可能还在执行（竞态条件），也可能已经不再被调用。

关键问题：`stopRunning()` 到 `inputBuilder.finish()` 之间没有任何等待机制确保后台队列排空。如果队列里还有 buffer，这些 buffer 对应的音频永远不会送到 SA。

**第二层：SA finalize 超时**

步骤 ⑥ 给 `finalizeAndFinishThroughEndOfInput()` 5 秒超时。这个方法的语义是"等 SA 处理完所有已收到的音频，产出所有 final result"。对于几秒的短句这够了，但如果用户说了较长的内容（几十秒），SA 内部可能有较大的未处理 buffer，5 秒不一定够。

超时后代码继续执行，不会 crash，但 SA 可能还没产出最后几个 final segment。

**第三层：resultTask 被强制取消**

步骤 ⑧ 在 sleep(500ms) 后强制 `resultTask?.cancel()`。`resultTask` 是 `for try await result in transcriber.results` 循环。cancel 后，即使 SA 后续产出了 final result，也没有消费者接收了。

步骤 ⑨ 用 `finalizedText + volatileText` 做最终文本。`volatileText` 保存的是最后一次 volatile 更新的内容。但 SA 在 finalize 阶段会把 volatile 转成 final——如果这个转换发生在 resultTask cancel 之后，final 丢了，而 volatileText 可能是更早版本的 volatile（不是最新的）。

### 结论

丢失不是单点问题，是三个缺陷叠加：
1. 采集停止和输入流关闭之间没有等待后台队列排空
2. finalize 超时太短（5 秒）
3. resultTask 被过早强制取消，丢弃了 finalize 阶段产出的 final result

---

## 问题 2：会议模式 — 黑话/术语识别差

### 现象
会议中的行业术语、产品名（Claude Code、Tailscale、contextualStrings 等）被 SA 错误识别。

### 根因

**MeetingSession 完全没有使用 contextualStrings。** 代码中搜索 `contextualStrings`、`AnalysisContext`、`setContext`——MeetingSession.swift 里没有任何相关调用。

对比 VoiceSession：VoiceSession.updateContext()（第 189-201 行）通过 ScreenContextProvider OCR 获取屏幕上下文词汇，注入到 `analyzer.setContext(context)`。MeetingSession 没有这个逻辑。

**MeetingSession 没有接 L2 纠错管线。** 会议模式的数据流是：

```
SA final segment → finalizedSegments 数组 → stop() 后批量分离 → MeetingExporter 导出 MD
```

VoicePipeline（包含 PolishClient L2 纠错）完全没有参与。MeetingSession 产出的文本是 SA 原始输出，直接写进 MD 文件。

### 加 L2 纠错到会议模式的完整路径分析

**方案 A：实时纠错（每个 final segment 都调 L2）**

在 MeetingSession 的 resultTask 循环里（第 272-299 行），每当收到一个 `result.isFinal` 时，在追加到 `finalizedSegments` 之前，先调 `PolishClient.polish()` 纠正文本。

问题：
- PolishClient 调用 ModelServer，ModelServer 通过网络请求 ollama。每次请求延迟约 100-500ms
- 会议模式 1 小时可能有 400+ 个 final segment，累计额外延迟 40-200 秒
- resultTask 跑在 Task 里，是串行消费 `transcriber.results`。如果消费速度跟不上 SA 产出速度（因为 L2 调用阻塞），results AsyncSequence 可能 backpressure
- 但这对实时显示不影响——可以先显示 SA 原文，L2 结果回来后再更新

实现复杂度：中等。需要在 MeetingSession 里引入 PolishClient，管理一个异步纠错队列。

**方案 B：事后批量纠错（stop 后一次性处理所有 segment）**

在 `stop()` 里，分离完成后、导出 MD 之前，遍历所有 segment 调 L2 纠错。

问题：
- 400 个 segment 串行纠错需要 40-200 秒。用户点"结束会议"后要等很久才能拿到结果
- 可以并行，但 ollama 是单线程推理，并行不会加速
- 优点：逻辑简单，不影响实时转写

**方案 C：contextualStrings 注入（SA 层面，零延迟）**

在 MeetingSession.start() 里，从 correction-dictionary.json 加载所有正确词（55 个），通过 `analyzer.setContext()` 注入 contextualStrings。SA 在识别时就倾向于输出正确拼写。

问题：
- contextualStrings 的 API 是 `AnalysisContext`，已确认存在。VoiceSession 里已经用过，验证过可行
- 但 contextualStrings 只是"提示"，不保证 SA 一定选择正确词
- 55 个词可能不超过 Apple 限制（限制具体数值未在官方文档确认，但 VoiceSession 里代码注释写的是 100）
- 零延迟，不影响任何现有流程

**我的判断：C 先做（成本最低、风险最小），A 或 B 后做。**

C 只需要在 MeetingSession.start() 里加几行代码，从词典文件加载词汇注入 SA。不改数据流，不引入网络依赖。效果可能不完美（SA 不一定全听），但至少给了 SA 纠正的机会。

A 或 B 需要在会议模式里引入 ModelServer 依赖，需要处理网络不可用、延迟、队列管理等问题，改动大。且前提是微调模型的纠错效果已经稳定——目前模型还在调参阶段，不适合立即集成。

---

## 问题 3：连续多人对话识别差

### 现象
多人交替发言时，SA 的转写质量下降。

### 根因

SpeechTranscriber 是为**单人连续语音**设计的。Apple 官方文档描述它适用于"clear speech"的场景。当多人交替发言时：

1. **语言模型上下文断裂**：SA 的语言模型基于前文预测下一个词。说话人切换时，语境突变，语言模型预测失准
2. **声学模型不适应**：不同说话人的音色、语速、口音不同。SA 不做说话人感知，它把所有声音当同一个人处理
3. **FluidAudio 分离是事后做的**，不参与实时转写。SA 收到的音频流里混着多个人的声音

### 可能的改善方向

**DictationTranscriber 是否更好？**

DictationTranscriber 在 Apple 文档里确认存在（developer.apple.com/documentation/speech/dictationtranscriber），是 SpeechModule 子类。但它的定位是"系统听写功能的替代方案"，主要优势是输出带标点和句子结构，**不是为多人场景优化的**。

关于 DictationTranscriber 是否支持 contextualStrings、是否在多人场景下更好——**官方文档没有确认**。我之前说"DictationTranscriber 更适合会议场景"是推测，不是事实。

**Apple 有没有原生多说话人支持？**

没有。Apple Speech 框架没有说话人分离 API，没有说话人识别 API。SpeechAnalyzer 的设计是"一路音频 → 一路文字"，不区分说话人。FluidAudio 是第三方方案。

**实际可行的改善：**

这个问题在 SA 层面无法根本解决。可行的方向：
- L2 纠错可以部分补偿（修正因语境断裂导致的错字）
- contextualStrings 注入团队常用术语可以减少术语错误
- 但多人交叉发言导致的识别质量下降是 SA 的固有限制

---

## 问题 4：语速快时识别差

### 根因

同问题 3，是 SA 中文模型的固有特性。SA 的声学模型对语速有一定的容忍范围，超出范围后识别率下降。

### 可行的改善

- L2 纠错可以部分补偿
- 但语速快导致的**漏字**（SA 直接跳过了部分音频内容）是无法通过后处理恢复的

---

## 问题 5：音频来源多样性

### 用户提的场景

1. **本地麦克风录物理环境**（当前方案）
2. **大屏/他人电脑播放的会议声音**——通过麦克风二次采集，有距离衰减和环境噪音
3. **Mac 本地的线上会议**（Zoom/Teams/飞书在 Mac 上运行）——需要捕获系统音频
4. **通过耳机传入的远程会议音频**

### 当前代码

VoiceSession 和 MeetingSession 都用 `AVCaptureDevice.default(for: .audio)` 获取默认音频输入设备。这取的是系统偏好设置里选择的输入设备，通常是麦克风或蓝牙耳机的麦克风。

无法采集系统音频（其他 app 播放的声音）。

### Apple 提供的解决方案

**ScreenCaptureKit（已确认）：**
- `SCStreamConfiguration.capturesAudio`：捕获系统音频
- `SCStreamConfiguration.captureMicrophone`：同时捕获麦克风（macOS 15+ 确认存在）
- 可以同时开启两者
- 通过 `SCContentFilter` 可以过滤特定窗口/应用的音频

这意味着：
- 场景 3（Mac 本地线上会议）：用 ScreenCaptureKit 采集 Zoom/Teams 的系统音频，直接送 SA
- 场景 4（耳机传入的远程音频）：如果远程音频通过系统播放，同样可以用 ScreenCaptureKit 采集
- 场景 2（大屏物理声音）：仍然只能通过麦克风二次采集，ScreenCaptureKit 帮不了（声音不在这台 Mac 上播放）

**Core Audio AudioHardwareCreateProcessTap（已确认，macOS 14.4+）：**
- 可以 tap 特定进程的音频输出
- 比 ScreenCaptureKit 更底层，控制粒度更细
- 但 API 更复杂

**改造涉及的范围：**

当前的 AVCaptureSession 采集方案需要和 ScreenCaptureKit 方案共存：
- 物理麦克风场景：继续用 AVCaptureSession（已验证稳定，兼容蓝牙）
- 系统音频场景：新增 ScreenCaptureKit 采集路径
- 两条路径都要输出 AVAudioPCMBuffer 送给 SA 的 inputBuilder

这不是简单改一行代码的事。需要：
1. 新增一个音频源抽象层（AudioSource protocol）
2. 实现两个 source：MicrophoneSource（现有 AVCaptureSession）和 SystemAudioSource（ScreenCaptureKit）
3. 配置选择哪个 source（config.json 或 UI 切换）
4. 确保 ScreenCaptureKit 的音频格式和 SA 的 bestAvailableAudioFormat 兼容

---

## 问题 6：蓝牙耳机切换导致录音中断

### 现象
录音过程中蓝牙耳机断开/切换，录音静默停止，后续内容全部丢失。

### 根因

代码里没有任何设备变更监听。搜索 `wasInterrupted`、`routeChange`、`deviceDisconnect`——VoiceSession 和 MeetingSession 都没有。

AVCaptureSession 在输入设备断开后行为：
- `AVCaptureSession.wasInterruptedNotification`（已确认存在）会被发送
- 但没有注册监听，所以 app 不知道
- session 停止产出 CMSampleBuffer，但不会 crash
- `inputBuilder` 停止收到数据，SA 也停止产出结果
- 录音就这样静默死了

### 修复方向

1. 监听 `AVCaptureSession.wasInterruptedNotification`
2. 收到通知后：
   a. 记录断点位置（已转写的内容不丢）
   b. 尝试获取新的默认音频设备 `AVCaptureDevice.default(for: .audio)`
   c. 如果有新设备，重建 AVCaptureDeviceInput，替换 session 的 input
   d. 如果没有设备，显示 UI 提示用户
3. 不需要重建 SA session——`inputBuilder` 还在，只是暂时没有数据输入。恢复设备后继续 yield 即可

关键风险：设备切换期间的音频间隙（几秒）会丢失。这个无法避免，但至少后续内容不会全丢。

---

## Apple 框架调研总结（已验证 vs 未验证）

| 信息 | 状态 | 来源 |
|------|------|------|
| DictationTranscriber 存在 | ✓ 已确认 | developer.apple.com/documentation/speech/dictationtranscriber |
| DictationTranscriber 支持 contextualStrings | **未确认** | 官方文档未明确说明 |
| DictationTranscriber 适合多人场景 | **未确认，我之前是推测** | 无依据 |
| AnalysisContext.contextualStrings API | ✓ 已确认 | developer.apple.com/documentation/speech/analysiscontext |
| contextualStrings 上限 100 词 | **未确认** | 代码注释写了 100，但官方文档未找到此限制 |
| SCStreamConfiguration.captureMicrophone | ✓ 已确认 | developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturemicrophone |
| SCStreamConfiguration.capturesAudio | ✓ 已确认 | developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio |
| 系统音频 + 麦克风同时采集 | 可配置，但有可靠性问题报告 | 开发者社区反馈 |
| AVCaptureSession.wasInterruptedNotification | ✓ 已确认 | developer.apple.com/documentation/avfoundation/avcapturesession/wasinterruptednotification |
| AudioHardwareCreateProcessTap（macOS 14.4+） | ✓ 已确认 | developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap |
| Apple 原生说话人分离 API | **不存在** | 搜索确认无此 API |
