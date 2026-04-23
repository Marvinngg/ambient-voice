import AVFoundation
import CoreMedia
import FluidAudio
import Speech

// MARK: - 音频采集模式

/// 会议模式下的音频来源选择
enum AudioSourceMode: String {
    /// 仅麦克风（默认，兼容旧行为）
    case mic
    /// 仅系统音频输出（Zoom/腾讯会议远端声音），需要屏幕录制权限
    case system
    /// 麦克风 + 系统音频混合（推荐用于线上会议）
    case both

    init(configValue: String?) {
        switch configValue?.lowercased() {
        case "system": self = .system
        case "both":   self = .both
        default:       self = .mic
        }
    }

    var needsMicrophone: Bool { self == .mic || self == .both }
    var needsSystemAudio: Bool { self == .system || self == .both }
}

// MARK: - 会议录音会话

/// 长时间会议录音，支持连续转写 + 批量说话人分离
/// 音频采集支持三种模式：仅麦克风 / 仅系统音频（ScreenCaptureKit）/ 两者混合
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
    private var systemAudioCapture: SystemAudioCapture?
    private var mixer: AudioMixer?
    private var audioMode: AudioSourceMode = .mic

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

    // MARK: - 内部转写累积

    /// 每个已完成的转写段（带时间戳），用于后续与分离结果对齐
    private struct FinalizedSegment {
        let text: String
        let startTime: TimeInterval // audioTimeRange.start.seconds
        let endTime: TimeInterval   // startTime + duration
    }

    private var finalizedSegments: [FinalizedSegment] = []
    private var currentVolatileText: String = ""

    init() {}

    // MARK: - 文件输入模式（评估用）

    /// 从 WAV 文件运行完整会议链路（转写 + 分离 + 对齐）
    /// 替代 AVCaptureSession，其余链路完全一致
    func runFromFile(_ fileURL: URL, locale: String = "zh-CN") async -> MeetingResult {
        // 重置状态
        transcriptSegments = []
        finalizedSegments = []
        currentVolatileText = ""
        diarizationBuffer = []
        duration = 0

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

            // 2. 创建 SpeechAnalyzer
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer

            // 3. 启动结果处理（和 start() 完全一致的 resultTask）
            resultTask = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        guard let self else { return }
                        let text = String(result.text.characters)

                        if result.isFinal {
                            let timeRange = self.extractTimeRange(from: result.text)
                            let segment = FinalizedSegment(
                                text: text,
                                startTime: timeRange.start,
                                endTime: timeRange.start + timeRange.duration
                            )
                            self.finalizedSegments.append(segment)
                            self.currentVolatileText = ""

                            Logger.log("Meeting", "[Bench] Final: \"\(text.prefix(40))\" [\(String(format: "%.1f", timeRange.start))-\(String(format: "%.1f", timeRange.start + timeRange.duration))s]")
                            self.onTranscriptUpdate?(text, true)
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
                var consumed = false
                converter.convert(to: outBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
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

            Logger.log("Meeting", "[Bench] Transcription: \(finalizedSegments.count) segments")

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
            finalizedSegments = []

            Logger.log("Meeting", "[Bench] Complete: \(diarizedSegments.count) segments with speaker labels")
            return result

        } catch {
            Logger.log("Meeting", "[Bench] Error: \(error)")
            return MeetingResult(segments: [], duration: 0, audioPath: fileURL.path)
        }
    }

    // MARK: - 启动（正常使用）

    func start() async throws {
        guard !isRunning else { return }

        // 读取音频来源模式（mic / system / both），默认 mic 兼容旧行为
        let mode = AudioSourceMode(
            configValue: RuntimeConfig.shared.meetingConfig["audio_source"] as? String
        )
        audioMode = mode
        Logger.log("Meeting", "Audio source mode: \(mode.rawValue)")

        if mode.needsMicrophone, !VoiceSession.isAuthorized {
            throw VoiceError.notAuthorized
        }

        // 重置状态
        transcriptSegments = []
        finalizedSegments = []
        currentVolatileText = ""
        diarizationBuffer = []
        duration = 0

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

        // 4. 创建 SpeechAnalyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        Logger.log("Meeting", "Analyzer format: \(analyzerFormat as Any)")

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
                        let segment = FinalizedSegment(
                            text: text,
                            startTime: timeRange.start,
                            endTime: timeRange.start + timeRange.duration
                        )
                        self.finalizedSegments.append(segment)
                        self.currentVolatileText = ""

                        Logger.log("Meeting", "Final: \"\(text)\" [\(String(format: "%.1f", timeRange.start))-\(String(format: "%.1f", timeRange.start + timeRange.duration))s]")
                        self.onTranscriptUpdate?(text, true)
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

        // 9. 配置音频采集（按模式分支）

        // 仅在 .both 模式下需要混合器：麦克风做主时钟，系统音频样本从队列中弹出求和
        let mixer: AudioMixer? = (mode == .both) ? AudioMixer() : nil
        self.mixer = mixer

        // 创建共享的 delegate（送 SpeechAnalyzer + 分离 + WAV 文件）
        let delegate = MeetingCaptureDelegate(
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioFileURL: url,
            diarizationSampleRate: diarizationSampleRate,
            mixer: mixer,
            onDiarizationSamples: { [weak self] samples in
                // 回调在后台队列，通过 DispatchQueue.main 桥接到 MainActor
                DispatchQueue.main.async {
                    self?.diarizationBuffer.append(contentsOf: samples)
                }
            }
        )
        self.captureDelegate = delegate

        // 9a. 麦克风采集（.mic / .both）
        if mode.needsMicrophone {
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                throw VoiceError.noAudioDevice
            }
            Logger.log("Meeting", "Audio device: \(audioDevice.localizedName)")

            let session = AVCaptureSession()
            let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
            session.addInput(deviceInput)

            let audioOutput = AVCaptureAudioDataOutput()
            let captureQueue = DispatchQueue(label: "com.antigravity.we.meeting-capture")
            audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
            session.addOutput(audioOutput)

            session.startRunning()
            self.captureSession = session
        }

        // 9b. 系统音频采集（.system / .both）
        if mode.needsSystemAudio {
            let systemCapture = SystemAudioCapture()
            self.systemAudioCapture = systemCapture

            if mode == .system {
                // 仅系统音频：直接喂给 delegate 走完整 SA + WAV + 分离流程
                systemCapture.onSampleBuffer = { [weak delegate] buffer in
                    delegate?.handleSystemSampleBuffer(buffer)
                }
            } else {
                // .both：系统音频转为 16kHz Float32 mono 后推入混合器队列
                let sysConverter = MonoFloat32Converter(targetSampleRate: diarizationSampleRate)
                systemCapture.onSampleBuffer = { [weak mixer] buffer in
                    guard let mixer, let samples = sysConverter.convert(buffer) else { return }
                    mixer.pushSystemSamples(samples)
                }
            }

            do {
                try await systemCapture.start()
            } catch {
                Logger.log("Meeting", "System audio capture failed: \(error)")
                // 系统音频不可用时的降级策略：.system 直接抛出；.both 降级为仅 mic
                if mode == .system {
                    throw error
                }
                self.systemAudioCapture = nil
                self.mixer = nil
            }
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

        // 停止音频采集
        captureSession?.stopRunning()
        captureSession = nil
        if let systemAudioCapture {
            await systemAudioCapture.stop()
        }
        systemAudioCapture = nil
        mixer?.drain()
        mixer = nil
        captureDelegate?.close()
        captureDelegate = nil

        // 告诉 SpeechAnalyzer 音频结束
        inputBuilder?.finish()
        Logger.log("Meeting", "Input stream finished, waiting for analyzer...")

        do {
            try await withThrowingTimeout(seconds: 10) {
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

        Logger.log("Meeting", "Transcription complete: \(finalizedSegments.count) segments, \(diarizationBuffer.count) audio samples")

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
        finalizedSegments = []

        Logger.log("Meeting", "Session stopped, duration=\(String(format: "%.1f", finalDuration))s, segments=\(diarizedSegments.count)")
        return result
    }

    // MARK: - 说话人分离

    /// 批量执行 FluidAudio 分离，将结果与转写段对齐
    private func performDiarization() async -> [MeetingSegment] {
        let buffer = diarizationBuffer
        let segments = finalizedSegments

        // 如果没有转写段，直接返回空
        guard !segments.isEmpty else {
            Logger.log("Meeting", "No transcription segments to diarize")
            return []
        }

        // 音频太短，跳过分离
        let audioDuration = Double(buffer.count) / Double(diarizationSampleRate)
        guard audioDuration >= 2.0 else {
            Logger.log("Meeting", "Audio too short for diarization (\(String(format: "%.1f", audioDuration))s), skipping")
            return segments.map { seg in
                MeetingSegment(
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    speakerId: nil,
                    isFinal: true
                )
            }
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

            // 对齐：为每个转写段分配说话人
            return alignTranscriptionWithDiarization(
                transcription: segments,
                diarization: result.segments
            )

        } catch {
            Logger.log("Meeting", "Diarization failed: \(error), returning segments without speaker labels")
            // 分离失败，仍然返回转写结果（无说话人标签）
            return segments.map { seg in
                MeetingSegment(
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    speakerId: nil,
                    isFinal: true
                )
            }
        }
    }

    /// 对齐转写段与分离段：基于时间重叠度
    /// 对每个转写段，找到重叠时间最长的分离段，取其 speakerId
    private func alignTranscriptionWithDiarization(
        transcription: [FinalizedSegment],
        diarization: [TimedSpeakerSegment]
    ) -> [MeetingSegment] {
        return transcription.map { tSeg in
            let tStart = tSeg.startTime
            let tEnd = tSeg.endTime

            // 找重叠最大的分离段
            var bestSpeaker: String? = nil
            var maxOverlap: TimeInterval = 0

            for dSeg in diarization {
                let dStart = TimeInterval(dSeg.startTimeSeconds)
                let dEnd = TimeInterval(dSeg.endTimeSeconds)

                // 计算重叠区间
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
                startTime: tStart,
                endTime: tEnd,
                speakerId: bestSpeaker,
                isFinal: true
            )
        }
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

/// 从音频源（AVCaptureSession 麦克风 / SCStream 系统音频）接收音频，分叉到：
/// 1. SpeechAnalyzer（实时转写）
/// 2. diarization buffer（16kHz Float32 mono 累积）
/// 3. WAV 文件（持久化）
///
/// 当 mixer != nil 时（.both 模式），每个输入 buffer 会与 mixer 中已入队的系统音频
/// 样本做逐样本相加，再走后续三条分支。麦克风作为主时钟驱动输出节奏。
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
    private var mixerInputConverter: AVAudioConverter?

    // 分离目标格式：16kHz Float32 mono（.both 模式下也用作混合的中间格式）
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
        mixer: AudioMixer? = nil,
        onDiarizationSamples: @escaping ([Float]) -> Void
    ) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        self.diarizationSampleRate = diarizationSampleRate
        self.mixer = mixer
        self.onDiarizationSamples = onDiarizationSamples
        super.init()
    }

    func close() {
        finalizeWAV()
    }

    // AVCaptureSession 麦克风路径
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handleSampleBuffer(sampleBuffer)
    }

    /// 由 SystemAudioCapture 直接调用（.system 模式下无 AVCaptureSession）
    func handleSystemSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        handleSampleBuffer(sampleBuffer)
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        bufferCount += 1

        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Meeting", "Audio #\(bufferCount): CMSampleBuffer conversion failed") }
            return
        }

        if bufferCount <= 3 {
            Logger.log("Meeting", "Audio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // .both 模式：先把当前 buffer（麦克风）与 mixer 中的系统音频样本相加
        let processedBuffer: AVAudioPCMBuffer
        if let mixer {
            guard let mixed = mixWithSystemAudio(micBuffer: pcmBuffer, mixer: mixer) else {
                return
            }
            processedBuffer = mixed
        } else {
            processedBuffer = pcmBuffer
        }

        // --- 分支1: 送 SpeechAnalyzer（可能需要格式转换）---
        let analyzerBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           processedBuffer.format.sampleRate != targetFormat.sampleRate
            || processedBuffer.format.commonFormat != targetFormat.commonFormat
            || processedBuffer.format.channelCount != targetFormat.channelCount {

            if analyzerConverter == nil {
                analyzerConverter = AVAudioConverter(from: processedBuffer.format, to: targetFormat)
                Logger.log("Meeting", "Analyzer converter: \(processedBuffer.format) → \(targetFormat)")
            }
            guard let converter = analyzerConverter,
                  let converted = convert(buffer: processedBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 3 { Logger.log("Meeting", "Audio #\(bufferCount): analyzer conversion failed") }
                return
            }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = processedBuffer
        }

        // 送 SpeechAnalyzer
        let input = AnalyzerInput(buffer: analyzerBuffer)
        inputBuilder.yield(input)

        // 写 WAV 文件
        writeToWAV(buffer: analyzerBuffer)

        // --- 分支2: 送分离缓冲区（16kHz Float32 mono）---
        if let diaFmt = diarizationFormat {
            let diaBuffer: AVAudioPCMBuffer
            if processedBuffer.format.sampleRate != diaFmt.sampleRate
                || processedBuffer.format.commonFormat != diaFmt.commonFormat
                || processedBuffer.format.channelCount != diaFmt.channelCount {

                if diarizationConverter == nil {
                    diarizationConverter = AVAudioConverter(from: processedBuffer.format, to: diaFmt)
                    Logger.log("Meeting", "Diarization converter: \(processedBuffer.format) → \(diaFmt)")
                }
                guard let converter = diarizationConverter,
                      let converted = convert(buffer: processedBuffer, using: converter, to: diaFmt) else {
                    return
                }
                diaBuffer = converted
            } else {
                diaBuffer = processedBuffer
            }

            // 提取 Float32 样本
            if let floatData = diaBuffer.floatChannelData {
                let frameCount = Int(diaBuffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
                onDiarizationSamples(samples)
            }
        }
    }

    /// 把麦克风 buffer 转到 16kHz Float32 mono，与 mixer 中等量系统样本逐样本相加
    /// 返回的 buffer 格式为 diarizationFormat（16kHz Float32 mono）
    private func mixWithSystemAudio(micBuffer: AVAudioPCMBuffer, mixer: AudioMixer) -> AVAudioPCMBuffer? {
        guard let diaFmt = diarizationFormat else { return micBuffer }

        // 1. 把麦克风 buffer 转为 16kHz Float32 mono
        let micMono: AVAudioPCMBuffer
        if micBuffer.format.sampleRate == diaFmt.sampleRate
            && micBuffer.format.commonFormat == diaFmt.commonFormat
            && micBuffer.format.channelCount == diaFmt.channelCount {
            micMono = micBuffer
        } else {
            if mixerInputConverter == nil {
                mixerInputConverter = AVAudioConverter(from: micBuffer.format, to: diaFmt)
                Logger.log("Meeting", "Mixer mic converter: \(micBuffer.format) → \(diaFmt)")
            }
            guard let converter = mixerInputConverter,
                  let converted = convert(buffer: micBuffer, using: converter, to: diaFmt) else {
                return nil
            }
            micMono = converted
        }

        let count = Int(micMono.frameLength)
        guard count > 0, let micData = micMono.floatChannelData?[0] else {
            return micMono
        }

        // 2. 从 mixer 取等量系统样本（不足补 0）
        let sysSamples = mixer.popSystemSamples(count: count)

        // 3. 求和并硬限幅到 [-1, 1]
        guard let mixed = AVAudioPCMBuffer(pcmFormat: diaFmt, frameCapacity: AVAudioFrameCount(count)),
              let mixedData = mixed.floatChannelData?[0] else {
            return micMono
        }
        mixed.frameLength = AVAudioFrameCount(count)

        sysSamples.withUnsafeBufferPointer { sysPtr in
            guard let sysBase = sysPtr.baseAddress else { return }
            for i in 0..<count {
                let sum = micData[i] + sysBase[i]
                mixedData[i] = max(-1.0, min(1.0, sum))
            }
        }

        return mixed
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
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
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
