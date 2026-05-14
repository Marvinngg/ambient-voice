@preconcurrency import AVFoundation
import CoreMedia
import FluidAudio
import Speech

// MARK: - 会议录音会话

/// 长时间会议录音，支持连续转写 + 批量说话人分离
/// 音频采集复用 VoiceSession 的 AVCaptureSession 方案（兼容蓝牙设备）
/// 转写用 SpeechAnalyzer 实时流式处理，分离在录音结束后批量执行
@MainActor
final class MeetingSession {

    // MARK: - 公开状态

    private(set) var isRunning = false
    private(set) var transcriptSegments: [MeetingSegment] = []
    private(set) var duration: TimeInterval = 0

    // MARK: - 回调

    /// 实时转写更新（text, isFinal）
    var onTranscriptUpdate: ((String, Bool) -> Void)?

    /// 周期性时长更新（每秒触发）
    var onDurationUpdate: ((TimeInterval) -> Void)?

    // MARK: - 音频采集

    private var captureSession: AVCaptureSession?
    private var captureDelegate: MeetingCaptureDelegate?
    private var systemAudioCapturer: SystemAudioCapturer?
    private var audioMixer: AudioMixer?

    // MARK: - SpeechAnalyzer 转写

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?

    // MARK: - 分离缓冲区（16kHz Float32 mono）

    private var diarizationBuffer: [Float] = []
    private let diarizationSampleRate: Int = 16000

    // MARK: - 时长计时器

    private var durationTimer: Task<Void, Never>?
    private var startDate: Date?

    // MARK: - 音频文件

    private var audioFileURL: URL?

    // MARK: - 中断恢复

    private var interruptionObservers: [NSObjectProtocol] = []

    // MARK: - 分段 / L2 流水线

    private var segmentBuffer: SegmentBuffer?
    private var polishedSegments: [MeetingSegment] = []
    private var currentVolatileText: String = ""

    // 流式落盘（每个 segment L2 完成后立刻写一行）
    private let meetingHistory = MeetingHistory()
    private var meetingId: String = ""

    // L2 统计（stop 时打 summary）
    private var l2Changed = 0
    private var l2Identity = 0
    private var l2Failed = 0
    private var l2Skipped = 0
    private var l2TotalElapsedMs = 0
    private var l2CallCount = 0

    init() {}

    // MARK: - 文件输入模式（评估用）

    /// 从 WAV 文件运行完整会议链路（转写 + 分离 + 对齐）
    /// 替代 AVCaptureSession，其余链路完全一致
    func runFromFile(_ fileURL: URL, locale: String = "zh-CN") async -> MeetingResult {
        // 重置状态
        transcriptSegments = []
        polishedSegments = []
        currentVolatileText = ""
        diarizationBuffer = []
        duration = 0
        resetL2Stats()
        setupSegmentBuffer()
        audioFileURL = fileURL
        meetingId = "bench-" + fileURL.deletingPathExtension().lastPathComponent

        let localeObj = Locale(identifier: locale)

        do {
            // 1. 配置 SpeechTranscriber（和 start() 完全一致）
            let bestLocale = await findChineseLocale() ?? localeObj
            Logger.log("Meeting", "[Bench] Using locale: \(bestLocale.identifier(.bcp47))")

            let transcriber = SpeechTranscriber(
                locale: bestLocale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]
            )
            self.transcriber = transcriber
            try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

            // 2. 创建 SpeechAnalyzer（processLifetime 让模型在进程内常驻）
            let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
            self.analyzer = analyzer

            // 2.5 上下文注入（字典 + 可选 OCR），和 Remote/Voice 路径统一
            await injectContextualStrings(analyzer: analyzer)

            // 3. 启动结果处理（和 start() 完全一致的 resultTask）
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)

                        if result.isFinal {
                            let timeRange = self.extractTimeRange(from: result.text)
                            let entry = SegmentBuffer.Entry(
                                text: text,
                                startTime: timeRange.start,
                                endTime: timeRange.start + timeRange.duration
                            )
                            self.currentVolatileText = ""

                            Logger.log("Meeting", "[Bench] Final: \"\(text.prefix(40))\" [\(String(format: "%.1f", timeRange.start))-\(String(format: "%.1f", timeRange.start + timeRange.duration))s]")
                            self.onTranscriptUpdate?(text, true)
                            await self.segmentBuffer?.feed(entry)
                        } else {
                            self.currentVolatileText = text
                            self.onTranscriptUpdate?(text, false)
                        }
                    }
                } catch {
                    Logger.log("Meeting", "[Bench] Result stream error: \(error)")
                }
            }

            // 4. 从文件读取音频填充 diarizationBuffer（16kHz Float32 mono）
            Logger.log("Meeting", "[Bench] Loading audio: \(fileURL.lastPathComponent)")
            let audioFile = try AVAudioFile(forReading: fileURL)
            let fileFormat = audioFile.processingFormat
            let frameCount = AVAudioFrameCount(audioFile.length)
            duration = Double(frameCount) / fileFormat.sampleRate
            Logger.log("Meeting", "[Bench] Audio: \(String(format: "%.1f", duration))s, \(Int(fileFormat.sampleRate))Hz, \(fileFormat.channelCount)ch")

            // 转换为 16kHz Float32 mono 给 diarization
            let diaFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(diarizationSampleRate),
                channels: 1,
                interleaved: false
            )!

            let fullBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: frameCount)!
            try audioFile.read(into: fullBuffer)

            if fileFormat.sampleRate != diaFormat.sampleRate
                || fileFormat.commonFormat != diaFormat.commonFormat
                || fileFormat.channelCount != diaFormat.channelCount {
                let converter = AVAudioConverter(from: fileFormat, to: diaFormat)!
                let ratio = diaFormat.sampleRate / fileFormat.sampleRate
                let outCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1
                let outBuffer = AVAudioPCMBuffer(pcmFormat: diaFormat, frameCapacity: outCapacity)!

                var error: NSError?
                let consumed = Box(false)
                converter.convert(to: outBuffer, error: &error) { _, outStatus in
                    if consumed.value {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed.value = true
                    outStatus.pointee = .haveData
                    return fullBuffer
                }

                if let floatData = outBuffer.floatChannelData {
                    diarizationBuffer = Array(UnsafeBufferPointer(start: floatData[0], count: Int(outBuffer.frameLength)))
                }
            } else {
                if let floatData = fullBuffer.floatChannelData {
                    diarizationBuffer = Array(UnsafeBufferPointer(start: floatData[0], count: Int(fullBuffer.frameLength)))
                }
            }
            Logger.log("Meeting", "[Bench] Diarization buffer: \(diarizationBuffer.count) samples")

            // 5. 用 SpeechAnalyzer 文件输入 API（Apple 原生，替代 AVCaptureSession）
            Logger.log("Meeting", "[Bench] Starting SpeechAnalyzer from file...")
            let inputFile = try AVAudioFile(forReading: fileURL)
            let startTime = CFAbsoluteTimeGetCurrent()
            try await analyzer.start(inputAudioFile: inputFile, finishAfterFile: true)

            // start 立即返回，结果通过 transcriber.results 异步到达
            // 等待 resultTask 跑完（for-await 循环在 analyzer finalize 后终止）
            await resultTask?.value
            let transcribeTime = CFAbsoluteTimeGetCurrent() - startTime
            Logger.log("Meeting", "[Bench] Transcription done in \(String(format: "%.1f", transcribeTime))s (RTFx: \(String(format: "%.1f", duration / transcribeTime)))")

            resultTask = nil
            self.analyzer = nil
            self.transcriber = nil

            // 冲尾：最后一批 buffer → L2
            await segmentBuffer?.flushFinal()
            logL2Summary()

            Logger.log("Meeting", "[Bench] L2 pipeline: \(polishedSegments.count) segments produced")

            // 6. 执行说话人分离（和 stop() 完全一致）
            let diarizedSegments = await performDiarization()

            // 7. 构建结果
            let result = MeetingResult(
                segments: diarizedSegments,
                duration: duration,
                audioPath: fileURL.path
            )

            // 清理
            diarizationBuffer = []
            polishedSegments = []
            segmentBuffer = nil

            Logger.log("Meeting", "[Bench] Complete: \(diarizedSegments.count) segments with speaker labels")
            return result

        } catch {
            Logger.log("Meeting", "[Bench] Error: \(error)")
            return MeetingResult(segments: [], duration: 0, audioPath: fileURL.path)
        }
    }

    // MARK: - 麦克风启动（正常使用）

    func start() async throws {
        guard !isRunning else { return }

        guard VoiceSession.isAuthorized else {
            throw VoiceError.notAuthorized
        }

        // 重置状态
        transcriptSegments = []
        polishedSegments = []
        currentVolatileText = ""
        diarizationBuffer = []
        duration = 0
        resetL2Stats()
        setupSegmentBuffer()

        // 1. 查找最佳中文 locale
        let bestLocale = await findChineseLocale()
        guard let bestLocale else {
            throw VoiceError.recognizerUnavailable
        }
        Logger.log("Meeting", "Using locale: \(bestLocale.identifier(.bcp47))")

        // 2. 配置 SpeechTranscriber（含 volatile + audioTimeRange，与 VoiceSession 一致）
        let transcriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        self.transcriber = transcriber

        // 3. 确保语音模型已安装
        try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

        // 4. 创建 SpeechAnalyzer（processLifetime 让模型在长会议期间不被卸载）
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        self.analyzer = analyzer

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        Logger.log("Meeting", "Analyzer format: \(analyzerFormat as Any)")

        // 4.5 预热模型（会议首段转写延迟从 ~800ms 降到 <100ms）
        let prepareT0 = CFAbsoluteTimeGetCurrent()
        try? await analyzer.prepareToAnalyze(in: analyzerFormat)
        Logger.log("Meeting", "prepareToAnalyze took \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - prepareT0))s")

        // 4.6 上下文注入（字典 + 可选 OCR），和 Remote/Voice 路径统一
        await injectContextualStrings(analyzer: analyzer)

        // 5. 创建 AsyncStream 输入通道
        let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputBuilder = inputBuilder

        // 6. 启动分析器
        try await analyzer.start(inputSequence: inputSequence)

        // 7. 启动结果处理任务
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)

                    if result.isFinal {
                        // 提取 audioTimeRange
                        let timeRange = self.extractTimeRange(from: result.text)
                        let entry = SegmentBuffer.Entry(
                            text: text,
                            startTime: timeRange.start,
                            endTime: timeRange.start + timeRange.duration
                        )
                        self.currentVolatileText = ""

                        Logger.log("Meeting", "Final: \"\(text)\" [\(String(format: "%.1f", timeRange.start))-\(String(format: "%.1f", timeRange.start + timeRange.duration))s]")
                        self.onTranscriptUpdate?(text, true)
                        await self.segmentBuffer?.feed(entry)
                    } else {
                        self.currentVolatileText = text
                        self.onTranscriptUpdate?(text, false)
                    }
                }
            } catch {
                Logger.log("Meeting", "Result stream error: \(error)")
            }
        }

        // 8. 准备音频文件路径
        let fileName = "meeting-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = WEDataDir.url.appendingPathComponent("audio/\(fileName).wav")
        audioFileURL = url
        meetingId = fileName  // 流式 jsonl 用作会议唯一标识

        // 9. 启动音频采集（根据 config 选 mic / system / both）
        let audioSource = (RuntimeConfig.shared.meetingConfig["audio_source"] as? String) ?? "mic"
        Logger.log("Meeting", "Audio source: \(audioSource)")

        // diarization 目标格式（mixer / capturer 统一使用）
        let diarizationFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(diarizationSampleRate),
            channels: 1,
            interleaved: false
        )!

        // diarization 回调（共用）
        let onDiaSamples: @Sendable ([Float]) -> Void = { [weak self] samples in
            DispatchQueue.main.async {
                self?.diarizationBuffer.append(contentsOf: samples)
            }
        }

        switch audioSource {
        case "system":
            let cap = SystemAudioCapturer(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: url,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples
            )
            try await cap.start()
            self.systemAudioCapturer = cap

        case "both":
            // B4: mic + system 并行采集 → AudioMixer 样本级混音 → SA
            let mixer = AudioMixer(
                analyzerFormat: analyzerFormat,
                diarizationFormat: diarizationFormat,
                inputBuilder: inputBuilder,
                onDiarizationSamples: onDiaSamples
            )
            mixer.start()
            self.audioMixer = mixer

            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw VoiceError.noAudioDevice
            }
            Logger.log("Meeting", "[both] Mic device: \(audioDevice.localizedName)")

            let micFileURL = url.deletingPathExtension().appendingPathExtension("mic.wav")
            let session = AVCaptureSession()
            let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
            session.addInput(deviceInput)

            let audioOutput = AVCaptureAudioDataOutput()
            let captureQueue = DispatchQueue(label: "com.antigravity.we.meeting-capture")

            let delegate = MeetingCaptureDelegate(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: micFileURL,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples,
                mixer: mixer
            )
            audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
            session.addOutput(audioOutput)

            self.captureDelegate = delegate
            self.captureSession = session
            session.startRunning()
            observeInterruptions(on: session)

            let sysFileURL = url.deletingPathExtension().appendingPathExtension("system.wav")
            let sysCap = SystemAudioCapturer(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: sysFileURL,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples,
                mixer: mixer
            )
            try await sysCap.start()
            self.systemAudioCapturer = sysCap

        default:  // "mic"
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw VoiceError.noAudioDevice
            }
            Logger.log("Meeting", "Audio device: \(audioDevice.localizedName)")

            let session = AVCaptureSession()
            let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
            session.addInput(deviceInput)

            let audioOutput = AVCaptureAudioDataOutput()
            let captureQueue = DispatchQueue(label: "com.antigravity.we.meeting-capture")

            let delegate = MeetingCaptureDelegate(
                inputBuilder: inputBuilder,
                analyzerFormat: analyzerFormat,
                audioFileURL: url,
                diarizationSampleRate: diarizationSampleRate,
                onDiarizationSamples: onDiaSamples
            )
            audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
            session.addOutput(audioOutput)

            self.captureDelegate = delegate
            self.captureSession = session
            session.startRunning()
            observeInterruptions(on: session)
        }

        isRunning = true
        startDate = Date()

        // 10. 启动时长计时器（每秒更新）
        durationTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let start = self.startDate else { return }
                self.duration = Date().timeIntervalSince(start)
                self.onDurationUpdate?(self.duration)
            }
        }

        Logger.log("Meeting", "Session started")
    }

    // MARK: - 停止 + 分离

    /// 停止录音，执行批量说话人分离，返回带 speakerId 的完整结果
    func stop() async -> MeetingResult {
        guard isRunning else {
            return MeetingResult(segments: [], duration: 0, audioPath: nil)
        }

        isRunning = false

        // 停止计时器
        durationTimer?.cancel()
        durationTimer = nil
        let finalDuration = duration

        // 停止音频采集（三种模式都清理）
        removeInterruptionObservers()
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate?.close()
        captureDelegate = nil
        if let cap = systemAudioCapturer {
            await cap.stop()
            systemAudioCapturer = nil
        }
        if let mixer = audioMixer {
            await mixer.stop()
            audioMixer = nil
        }

        // 告诉 SpeechAnalyzer 音频结束
        inputBuilder?.finish()
        Logger.log("Meeting", "Input stream finished, waiting for analyzer...")

        do {
            // 60s 熔断：长会议的尾部 audio finalize 可能比实时录音慢得多
            try await withThrowingTimeout(seconds: 60) {
                try await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
            Logger.log("Meeting", "Analyzer finalized")
        } catch {
            Logger.log("Meeting", "Finalize timeout/error: \(error)")
        }

        // 给 resultTask 短暂时间处理最终结果
        try? await Task.sleep(for: .milliseconds(500))
        resultTask?.cancel()
        resultTask = nil

        // 清理 SA 资源
        analyzer = nil
        transcriber = nil

        // 冲尾：最后一批 buffer → L2
        await segmentBuffer?.flushFinal()
        logL2Summary()

        Logger.log("Meeting", "Transcription complete: \(polishedSegments.count) L2 segments, \(diarizationBuffer.count) audio samples")

        // 执行说话人分离
        let diarizedSegments = await performDiarization()

        // 构建结果
        let result = MeetingResult(
            segments: diarizedSegments,
            duration: finalDuration,
            audioPath: audioFileURL?.path
        )

        // 清理缓冲区
        diarizationBuffer = []
        polishedSegments = []
        segmentBuffer = nil

        Logger.log("Meeting", "Session stopped, duration=\(String(format: "%.1f", finalDuration))s, segments=\(diarizedSegments.count)")
        return result
    }

    // MARK: - 说话人分离

    /// 批量执行 FluidAudio 分离，将结果与 L2 纠错后的批次段对齐
    /// 注意：方案 D（flush 批次 = 一个 MeetingSegment），diarization 按批次时间范围找说话人
    private func performDiarization() async -> [MeetingSegment] {
        let buffer = diarizationBuffer
        let segments = polishedSegments

        // 如果没有 L2 段，直接返回空
        guard !segments.isEmpty else {
            Logger.log("Meeting", "No polished segments to diarize")
            return []
        }

        // 音频太短，跳过分离
        let audioDuration = Double(buffer.count) / Double(diarizationSampleRate)
        guard audioDuration >= 2.0 else {
            Logger.log("Meeting", "Audio too short for diarization (\(String(format: "%.1f", audioDuration))s), skipping")
            return segments
        }

        Logger.log("Meeting", "Starting diarization: \(String(format: "%.1f", audioDuration))s audio")

        do {
            // 下载/加载模型
            Logger.log("Meeting", "Loading diarization models...")
            let models = try await DiarizerModels.downloadIfNeeded(
                progressHandler: { progress in
                    Logger.log("Meeting", "Model download progress: \(String(format: "%.0f%%", progress.fractionCompleted * 100))")
                }
            )

            let diarizer = DiarizerManager(config: DiarizerConfig())
            diarizer.initialize(models: models)

            Logger.log("Meeting", "Running diarization...")
            let result = try diarizer.performCompleteDiarization(buffer, sampleRate: diarizationSampleRate)

            Logger.log("Meeting", "Diarization complete: \(result.segments.count) speaker segments")
            for seg in result.segments {
                Logger.log("Meeting", "  Speaker \(seg.speakerId): \(String(format: "%.1f", seg.startTimeSeconds))-\(String(format: "%.1f", seg.endTimeSeconds))s")
            }

            // 对齐：为每个 L2 批次段分配说话人
            return alignTranscriptionWithDiarization(
                segments: segments,
                diarization: result.segments
            )

        } catch {
            Logger.log("Meeting", "Diarization failed: \(error), returning segments without speaker labels")
            // 分离失败，保留 L2 段，speakerId 为 nil
            return segments
        }
    }

    /// 对齐 L2 批次段与分离段：基于时间重叠度
    /// 对每个批次段，找到重叠时间最长的分离段，取其 speakerId
    private func alignTranscriptionWithDiarization(
        segments: [MeetingSegment],
        diarization: [TimedSpeakerSegment]
    ) -> [MeetingSegment] {
        return segments.map { tSeg in
            let tStart = tSeg.startTime
            let tEnd = tSeg.endTime

            // 找重叠最大的分离段
            var bestSpeaker: String? = nil
            var maxOverlap: TimeInterval = 0

            for dSeg in diarization {
                let dStart = TimeInterval(dSeg.startTimeSeconds)
                let dEnd = TimeInterval(dSeg.endTimeSeconds)

                let overlapStart = max(tStart, dStart)
                let overlapEnd = min(tEnd, dEnd)
                let overlap = max(0, overlapEnd - overlapStart)

                if overlap > maxOverlap {
                    maxOverlap = overlap
                    bestSpeaker = dSeg.speakerId
                }
            }

            return MeetingSegment(
                text: tSeg.text,
                rawText: tSeg.rawText,
                startTime: tSeg.startTime,
                endTime: tSeg.endTime,
                speakerId: bestSpeaker,
                l2Kind: tSeg.l2Kind,
                isFinal: tSeg.isFinal
            )
        }
    }

    // MARK: - B3.1 中断恢复

    /// 订阅 AVCaptureSession 的中断/恢复通知。蓝牙切换、音频路由变化会触发。
    /// 恢复策略：interruptionEnded 时检查 session 是否仍在运行，未运行则 startRunning。
    /// 注意：若音频设备切换导致 format 变化（蓝牙 Int16 → 内置 Float32），
    /// 现有 AVAudioConverter 可能失败，该场景留待后续观察真实日志再决定是否重建采集链。
    private func observeInterruptions(on session: AVCaptureSession) {
        let center = NotificationCenter.default
        let obs1 = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { _ in
            // macOS 无 InterruptionReasonKey，只记录事件
            Logger.log("Meeting", "Capture interrupted (audio route changed / device removed)")
        }
        let obs2 = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            // queue: .main 保证 callback 在 main queue 上执行，与 @MainActor 隔离一致
            MainActor.assumeIsolated {
                guard let self, let s = self.captureSession else { return }
                Logger.log("Meeting", "Capture interruption ended, isRunning=\(s.isRunning)")
                if !s.isRunning {
                    s.startRunning()
                    Logger.log("Meeting", "Capture restarted: isRunning=\(s.isRunning)")
                }
            }
        }
        let obs3 = center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { note in
            let err = note.userInfo?[AVCaptureSessionErrorKey]
            Logger.log("Meeting", "Capture runtime error: \(String(describing: err))")
        }
        interruptionObservers = [obs1, obs2, obs3]
    }

    private func removeInterruptionObservers() {
        for obs in interruptionObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        interruptionObservers.removeAll()
    }

    // MARK: - B1 辅助：分段 + L2

    /// 从 config 读阈值，创建 SegmentBuffer 并挂 flush 回调
    private func setupSegmentBuffer() {
        let cfg = RuntimeConfig.shared.meetingConfig
        let pauseSec = (cfg["l2_flush_on_pause_sec"] as? Double) ?? 1.5
        let maxChars = (cfg["l2_flush_on_chars"] as? Int) ?? 200
        let minChars = (cfg["l2_min_chars"] as? Int) ?? 30

        let buf = SegmentBuffer(
            pauseThresholdSec: pauseSec,
            maxChars: maxChars,
            minChars: minChars
        )
        buf.onFlush = { [weak self] batch in
            guard let self else { return }
            let seg = await self.polishBatch(batch)
            self.polishedSegments.append(seg)
        }
        self.segmentBuffer = buf
    }

    /// ContextEnhancer 调用 + analyzer.setContext（和 Remote/Voice 路径一致）
    private func injectContextualStrings(analyzer: SpeechAnalyzer) async {
        let polish = RuntimeConfig.shared.polishConfig
        let dictEnabled = polish["context_dictionary_enabled"] as? Bool ?? false
        let dictPath = polish["context_dictionary_path"] as? String
        let ocrEnabled = polish["context_ocr_enabled"] as? Bool ?? false
        let words = await ContextEnhancer.enhance(
            for: AppIdentity.current(),
            dictionaryEnabled: dictEnabled,
            dictionaryPath: dictPath,
            ocrEnabled: ocrEnabled
        )
        if !words.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = words
            try? await analyzer.setContext(ctx)
            let preview = words.prefix(5).joined(separator: ", ")
            let suffix = words.count > 5 ? "..." : ""
            Logger.log("Meeting", "SA context injected \(words.count) terms: [\(preview)\(suffix)]")
        }
    }

    /// 对一个 flush 批次做 L2 纠错，返回最终 MeetingSegment
    /// L2 失败时 text = rawText（fallback）；每次调用结果立刻 append 到 meeting-history.jsonl
    private func polishBatch(_ batch: SegmentBuffer.FlushBatch) async -> MeetingSegment {
        let segNum = segmentBuffer?.flushCount ?? 0
        let polishCfg = RuntimeConfig.shared.polishConfig
        let polishEnabled = (polishCfg["enabled"] as? Bool) == true

        let rawText = batch.rawText
        let rawPreview = rawText.prefix(60)

        let finalText: String
        let polishedText: String?
        let l2Kind: L2Kind
        let elapsedMs: Int

        if !polishEnabled {
            l2Skipped += 1
            finalText = rawText
            polishedText = nil
            l2Kind = .skipped
            elapsedMs = 0
            Logger.log("Meeting", "L2 seg=[\(segNum)] kind=skipped reason=polish.enabled=false chars=\(rawText.count)")
        } else {
            let t0 = CFAbsoluteTimeGetCurrent()
            let polished = await PolishClient.shared.polish(text: rawText, words: [], app: nil)
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            l2CallCount += 1
            l2TotalElapsedMs += elapsedMs

            if let p = polished {
                polishedText = p
                if p == rawText {
                    l2Identity += 1
                    l2Kind = .identity
                    finalText = p
                    Logger.log("Meeting", "L2 seg=[\(segNum)] kind=identity elapsedMs=\(elapsedMs) chars=\(rawText.count) text=\"\(rawPreview)\"")
                } else {
                    l2Changed += 1
                    l2Kind = .changed
                    finalText = p
                    let polPreview = p.prefix(60)
                    Logger.log("Meeting", "L2 seg=[\(segNum)] kind=changed elapsedMs=\(elapsedMs) chars=\(rawText.count) raw=\"\(rawPreview)\" → polished=\"\(polPreview)\"")
                }
            } else {
                polishedText = nil
                l2Failed += 1
                l2Kind = .failed
                finalText = rawText
                Logger.log("Meeting", "L2 seg=[\(segNum)] kind=failed FAILED elapsedMs=\(elapsedMs) chars=\(rawText.count) using_raw=\"\(rawPreview)\"")
            }
        }

        // 流式落盘到 meeting-history.jsonl（每个 segment 一行，会议进行中即可见）
        let record = MeetingSegmentRecord(
            timestamp: Date(),
            meetingId: meetingId,
            audioPath: audioFileURL?.path ?? "",
            segIndex: segNum,
            startTime: batch.startTime,
            endTime: batch.endTime,
            triggerReason: batch.triggerReason,
            rawText: rawText,
            polishedText: polishedText,
            finalText: finalText,
            l2Kind: l2Kind.rawValue,
            l2ElapsedMs: elapsedMs
        )
        meetingHistory.append(record)

        return MeetingSegment(
            text: finalText,
            rawText: rawText,
            startTime: batch.startTime,
            endTime: batch.endTime,
            speakerId: nil,
            l2Kind: l2Kind,
            isFinal: true
        )
    }

    private func resetL2Stats() {
        l2Changed = 0
        l2Identity = 0
        l2Failed = 0
        l2Skipped = 0
        l2TotalElapsedMs = 0
        l2CallCount = 0
    }

    /// 会议结束时打一行统计汇总（验收用）
    /// 如果 failed>0 或 fallback_used>0，就是 L2 链路不健康的直接证据
    private func logL2Summary() {
        let total = l2Changed + l2Identity + l2Failed + l2Skipped
        let avgMs = l2CallCount > 0 ? l2TotalElapsedMs / l2CallCount : 0
        let fallback = l2Failed + l2Skipped
        Logger.log("Meeting", "L2 summary: total=\(total) changed=\(l2Changed) identity=\(l2Identity) failed=\(l2Failed) skipped=\(l2Skipped) avgMs=\(avgMs) fallback_used=\(fallback)")
    }

    // MARK: - 从 AttributedString 提取 audioTimeRange

    private func extractTimeRange(from attrText: AttributedString) -> (start: TimeInterval, duration: TimeInterval) {
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        // 遍历 runs 找到整个段的时间范围
        var earliest: TimeInterval = .infinity
        var latest: TimeInterval = 0

        for (timeRange, _) in attrText.runs[TimeKey.self] {
            guard let range = timeRange else { continue }
            let start = range.start.seconds
            let end = start + range.duration.seconds
            if start < earliest { earliest = start }
            if end > latest { latest = end }
        }

        if earliest == .infinity {
            return (start: 0, duration: 0)
        }
        return (start: earliest, duration: latest - earliest)
    }

    // MARK: - Locale 查找（与 VoiceSession 相同）

    private func findChineseLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let prefixes = ["zh-Hans", "zh-CN", "zh-Hant", "zh"]
        for prefix in prefixes {
            if let match = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                return match
            }
        }
        Logger.log("Meeting", "No Chinese locale found")
        return nil
    }

    // MARK: - 模型管理（与 VoiceSession 相同）

    private func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }

        if installedIDs.contains(localeID) {
            Logger.log("Meeting", "Speech model for \(localeID) already installed")
            return
        }

        Logger.log("Meeting", "Downloading speech model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Meeting", "Speech model downloaded")
        }
    }
}

// MARK: - 会议音频采集代理

/// 从 AVCaptureSession 接收音频，分叉到：
/// 1. SpeechAnalyzer（实时转写）
/// 2. diarization buffer（16kHz Float32 mono 累积）
/// 3. WAV 文件（持久化）
final class MeetingCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    private let diarizationSampleRate: Int
    private let onDiarizationSamples: ([Float]) -> Void
    private let mixer: AudioMixer?

    // 格式转换器
    private var analyzerConverter: AVAudioConverter?
    private var diarizationConverter: AVAudioConverter?

    // 分离目标格式：16kHz Float32 mono
    private lazy var diarizationFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(diarizationSampleRate),
            channels: 1,
            interleaved: false
        )
    }()

    // WAV 写入
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?

    private var bufferCount = 0

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat?,
        audioFileURL: URL,
        diarizationSampleRate: Int,
        onDiarizationSamples: @escaping ([Float]) -> Void,
        mixer: AudioMixer? = nil
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        self.diarizationSampleRate = diarizationSampleRate
        self.onDiarizationSamples = onDiarizationSamples
        self.mixer = mixer
        super.init()
    }

    func close() {
        finalizeWAV()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1

        // CMSampleBuffer → AVAudioPCMBuffer（复用 VoiceSession 的扩展方法）
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Meeting", "Audio #\(bufferCount): CMSampleBuffer conversion failed") }
            return
        }

        if bufferCount <= 3 {
            Logger.log("Meeting", "Audio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // --- 分支1: 送 SpeechAnalyzer（可能需要格式转换）---
        let analyzerBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat {

            if analyzerConverter == nil {
                analyzerConverter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Meeting", "Analyzer converter: \(pcmBuffer.format) → \(targetFormat)")
            }
            guard let converter = analyzerConverter,
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 3 { Logger.log("Meeting", "Audio #\(bufferCount): analyzer conversion failed") }
                return
            }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = pcmBuffer
        }

        // 送 SpeechAnalyzer（B4 混音模式下由 mixer 统一 yield，本 delegate 不直接送）
        if mixer == nil {
            let input = AnalyzerInput(buffer: analyzerBuffer)
            inputBuilder.yield(input)
        }

        // 写 WAV 文件（原始 mic 流，混音模式下也保留便于事后分析）
        writeToWAV(buffer: analyzerBuffer)

        // --- 分支2: 16kHz Float32 mono 样本 → mixer 或 diarization ---
        if let diaFmt = diarizationFormat {
            let diaBuffer: AVAudioPCMBuffer
            if pcmBuffer.format.sampleRate != diaFmt.sampleRate
                || pcmBuffer.format.commonFormat != diaFmt.commonFormat
                || pcmBuffer.format.channelCount != diaFmt.channelCount {

                if diarizationConverter == nil {
                    diarizationConverter = AVAudioConverter(from: pcmBuffer.format, to: diaFmt)
                    Logger.log("Meeting", "Diarization converter: \(pcmBuffer.format) → \(diaFmt)")
                }
                guard let converter = diarizationConverter,
                      let converted = convert(buffer: pcmBuffer, using: converter, to: diaFmt) else {
                    return
                }
                diaBuffer = converted
            } else {
                diaBuffer = pcmBuffer
            }

            if let floatData = diaBuffer.floatChannelData {
                let frameCount = Int(diaBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                if let mixer {
                    mixer.feedMic(samples)
                } else {
                    onDiarizationSamples(samples)
                }
            }
        }
    }

    // MARK: - WAV 手动写入

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            fileHandle?.write(Data(count: 44)) // WAV header 占位
            wavDataSize = 0
        }

        let abl = buffer.audioBufferList.pointee
        guard let mData = abl.mBuffers.mData else { return }
        let byteCount = Int(abl.mBuffers.mDataByteSize)
        let data = Data(bytes: mData, count: byteCount)
        fileHandle?.write(data)
        wavDataSize += UInt32(byteCount)
    }

    private func finalizeWAV() {
        guard let fh = fileHandle, let fmt = wavFormat else {
            fileHandle = nil
            return
        }

        let asbd = fmt.streamDescription.pointee
        let numChannels = UInt16(asbd.mChannelsPerFrame)
        let sampleRate = UInt32(asbd.mSampleRate)
        let bitsPerSample = UInt16(asbd.mBitsPerChannel)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)

        var header = Data(capacity: 44)
        header.append(contentsOf: "RIFF".utf8)
        header.appendMeetingLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendMeetingLE(UInt32(16))
        header.appendMeetingLE(UInt16(1)) // PCM
        header.appendMeetingLE(numChannels)
        header.appendMeetingLE(sampleRate)
        header.appendMeetingLE(byteRate)
        header.appendMeetingLE(blockAlign)
        header.appendMeetingLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendMeetingLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Meeting", "WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - 格式转换（与 VoiceSession 相同的 block-based API）

    private func convert(buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        let consumed = Box(false)
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return buffer
        }

        return (error == nil && output.frameLength > 0) ? output : nil
    }
}

// MARK: - Data little-endian helpers（避免与 VoiceSession 的 private extension 冲突）

private extension Data {
    mutating func appendMeetingLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendMeetingLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
