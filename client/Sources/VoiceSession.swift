import AVFoundation
import CoreMedia
import Speech

// MARK: - 转写数据类型

/// 转写结果的词级信息
struct WordInfo: Codable {
    let text: String
    let confidence: Float
    let alternatives: [String]
    let startTime: TimeInterval
    let duration: TimeInterval
}

/// 一次语音会话的完整转写结果
struct TranscriptionResult: Codable {
    let fullText: String
    let words: [WordInfo]
    /// 每个 segment 的整句级候选列表（二维数组）
    /// segmentAlternatives[i][0] == 该 segment 的 best text
    /// segmentAlternatives[i][1..] == 替代解释（按可能性降序）
    let segmentAlternatives: [[String]]
    let audioPath: String?
    let timestamp: Date
}

// MARK: - VoiceSession

/// 语音会话：使用 Apple SpeechAnalyzer (WWDC 2025) 做端侧实时转写
/// 音频采集用 AVCaptureSession（兼容蓝牙等各类音频设备）
/// AVAudioEngine 的 installTap 在蓝牙设备上不触发回调
@MainActor
final class VoiceSession {
    enum SessionError: Error {
        case recognizerUnavailable
        case audioEngineFailure(NSError)
    }

    private var captureSession: AVCaptureSession?
    private var captureDelegate: AudioCaptureDelegate?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?

    private var analyzerFormat: AVAudioFormat?
    private var audioFileURL: URL?

    private(set) var isRunning = false

    // 转写结果累积
    private var finalizedText = ""
    private var volatileText = ""
    private var allWords: [WordInfo] = []
    /// 整句级 alternatives 累积（每个 final segment 的所有候选）
    private var allAlternatives: [[String]] = []

    /// 识别完成时的回调
    var onResult: ((TranscriptionResult) -> Void)?

    /// 实时部分结果回调（可选，用于 UI 显示）
    var onPartialResult: ((String) -> Void)?

    init() {}

    nonisolated static func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            Logger.log("Voice", "Microphone auth: \(granted)")
        }
    }

    nonisolated static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 开始录音 + 实时转写
    func start() async throws {
        guard Self.isAuthorized else {
            throw VoiceError.notAuthorized
        }

        finalizedText = ""
        volatileText = ""
        allWords = []

        // 1. 查找最佳中文 locale
        let bestLocale = await findChineseLocale()
        guard let bestLocale else {
            throw VoiceError.recognizerUnavailable
        }
        Logger.log("Voice", "Using locale: \(bestLocale.identifier(.bcp47))")

        // 2. 配置 SpeechTranscriber（含 volatile + alternatives）
        let transcriber = SpeechTranscriber(
            locale: bestLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .alternativeTranscriptions],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence]
        )
        self.transcriber = transcriber

        // 3. 确保语音模型已安装
        try await ensureModelInstalled(transcriber: transcriber, locale: bestLocale)

        // 4. 创建 SpeechAnalyzer
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        // 获取最佳音频格式
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        self.analyzerFormat = analyzerFormat
        Logger.log("Voice", "Analyzer format: \(analyzerFormat as Any)")

        // 5. 创建 AsyncStream 用于音频输入
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
                        self.finalizedText += text
                        self.volatileText = ""

                        let words = self.extractWords(from: result.text)
                        self.allWords.append(contentsOf: words)

                        // 收集整句级 alternatives
                        let alts = result.alternatives.map { String($0.characters) }
                        self.allAlternatives.append(alts)

                        let altCount = alts.count
                        Logger.log("Voice", "Final segment: \(text) (\(words.count) words, \(altCount) alternatives)")
                        if altCount > 1 {
                            for (i, alt) in alts.enumerated() where alt != text {
                                Logger.log("Voice", "  alt[\(i)]: \(alt)")
                            }
                        }
                    } else {
                        self.volatileText = text
                        self.onPartialResult?(self.finalizedText + text)
                    }
                }
            } catch {
                Logger.log("Voice", "Result stream error: \(error)")
            }
        }

        // 8. 准备音频文件
        let fileName = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = WEDataDir.url.appendingPathComponent("audio/\(fileName).wav")
        audioFileURL = url

        // 9. 启动 AVCaptureSession（替代 AVAudioEngine，兼容蓝牙设备）
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            throw VoiceError.noAudioDevice
        }
        Logger.log("Voice", "Audio device: \(audioDevice.localizedName)")

        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: audioDevice)
        session.addInput(deviceInput)

        let audioOutput = AVCaptureAudioDataOutput()
        let captureQueue = DispatchQueue(label: "com.antigravity.we.audio-capture")

        // 创建 delegate，捕获所有需要的局部变量（避免访问 @MainActor 的 self）
        let delegate = AudioCaptureDelegate(
            inputBuilder: inputBuilder,
            analyzerFormat: analyzerFormat,
            audioFileURL: url
        )
        audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        session.addOutput(audioOutput)

        self.captureDelegate = delegate
        self.captureSession = session

        session.startRunning()
        self.isRunning = true

        Logger.log("Voice", "Session started (AVCaptureSession + SpeechAnalyzer)")
    }

    /// G3 → G2：运行时注入屏幕上下文到 SA（提升专有名词/术语识别率）
    func updateContext(contextualWords: [String]) async {
        guard let analyzer, !contextualWords.isEmpty else { return }
        let context = AnalysisContext()
        context.contextualStrings[.general] = contextualWords
        do {
            try await analyzer.setContext(context)
            let preview = contextualWords.prefix(5).joined(separator: ", ")
            let suffix = contextualWords.count > 5 ? "..." : ""
            Logger.log("Voice", "SA context injected \(contextualWords.count) contextualStrings: [\(preview)\(suffix)]")
        } catch {
            Logger.log("Voice", "SA context update failed: \(error)")
        }
    }

    /// 停止录音并等待最终结果
    func stop() async -> TranscriptionResult {
        guard isRunning else {
            return TranscriptionResult(fullText: "", words: [], segmentAlternatives: [], audioPath: nil, timestamp: Date())
        }

        // 停止音频采集
        captureSession?.stopRunning()
        captureSession = nil
        captureDelegate?.close()
        captureDelegate = nil

        // 告诉分析器音频结束
        inputBuilder?.finish()
        Logger.log("Voice", "Input stream finished, waiting for analyzer...")

        // 等待分析器完成（带超时）
        do {
            try await withThrowingTimeout(seconds: 5) {
                try await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            }
            Logger.log("Voice", "Analyzer finalized")
        } catch {
            Logger.log("Voice", "Finalize timeout/error: \(error)")
        }

        // 给 resultTask 短暂时间处理最终结果，然后强制取消
        Logger.log("Voice", "Waiting briefly for results...")
        try? await Task.sleep(for: .milliseconds(500))
        resultTask?.cancel()
        resultTask = nil
        Logger.log("Voice", "Result task cancelled")

        let fullText = finalizedText + volatileText
        isRunning = false

        // 清理
        analyzer = nil
        transcriber = nil

        Logger.log("Voice", "Session stopped, text: \(fullText)")

        return TranscriptionResult(
            fullText: fullText,
            words: allWords,
            segmentAlternatives: allAlternatives,
            audioPath: audioFileURL?.path,
            timestamp: Date()
        )
    }

    // MARK: - Locale 查找

    private func findChineseLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let ids = supported.map { $0.identifier(.bcp47) }
        Logger.log("Voice", "Supported locales: \(ids)")

        let prefixes = ["zh-Hans", "zh-CN", "zh-Hant", "zh"]
        for prefix in prefixes {
            if let match = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                return match
            }
        }

        Logger.log("Voice", "No Chinese locale found")
        return nil
    }

    // MARK: - 词级信息提取

    private func extractWords(from attrText: AttributedString) -> [WordInfo] {
        var words: [WordInfo] = []
        typealias ConfKey = AttributeScopes.SpeechAttributes.ConfidenceAttribute
        typealias TimeKey = AttributeScopes.SpeechAttributes.TimeRangeAttribute

        for (confidence, timeRange, range) in attrText.runs[ConfKey.self, TimeKey.self] {
            let wordText = String(attrText[range].characters)
            guard !wordText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            let startTime = timeRange?.start.seconds ?? 0
            let duration = timeRange?.duration.seconds ?? 0

            words.append(WordInfo(
                text: wordText,
                confidence: Float(confidence ?? 1.0),
                alternatives: [],
                startTime: startTime,
                duration: duration
            ))
        }
        return words
    }

    // MARK: - 模型管理

    private func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)

        let installed = await SpeechTranscriber.installedLocales
        let installedIDs = installed.map { $0.identifier(.bcp47) }
        Logger.log("Voice", "Installed locales: \(installedIDs)")

        if installedIDs.contains(localeID) {
            Logger.log("Voice", "Model for \(localeID) already installed")
            return
        }

        Logger.log("Voice", "Downloading speech model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Voice", "Model downloaded")
        }
    }
}

// MARK: - 音频采集代理（nonisolated，在后台队列运行）

/// 从 AVCaptureSession 接收 CMSampleBuffer，转换为 AVAudioPCMBuffer 后
/// 喂给 SpeechAnalyzer 的 inputBuilder，同时写入 WAV 音频文件
///
/// 音频文件使用手动 WAV 写入，彻底避免 AVAudioFile 内部 AudioConverter 的 abort 崩溃
final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    private var converter: AVAudioConverter?
    private var fileHandle: FileHandle?
    private var wavDataSize: UInt32 = 0
    private var wavFormat: AVAudioFormat?
    private var bufferCount = 0

    init(inputBuilder: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat?, audioFileURL: URL) {
        self.inputBuilder = inputBuilder
        self.analyzerFormat = analyzerFormat
        // 改用 .wav 扩展名
        self.audioFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("wav")
        super.init()
    }

    func close() {
        finalizeWAV()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        bufferCount += 1

        // CMSampleBuffer → AVAudioPCMBuffer
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Voice", "Audio #\(bufferCount): failed to convert CMSampleBuffer") }
            return
        }

        if bufferCount <= 5 {
            Logger.log("Voice", "Audio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // 格式转换（如果采集格式 ≠ analyzer 格式）
        let outputBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat {

            // 延迟创建 converter（需要知道输入格式）
            if converter == nil {
                converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Voice", "Created converter: \(pcmBuffer.format) → \(targetFormat)")
            }

            guard let converter,
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 5 { Logger.log("Voice", "Audio #\(bufferCount): conversion failed") }
                return
            }
            outputBuffer = converted
        } else {
            outputBuffer = pcmBuffer
        }

        // 写入 WAV 文件（用 outputBuffer，格式始终一致：Int16 16kHz mono）
        writeToWAV(buffer: outputBuffer)

        // 发送给 SpeechAnalyzer
        let input = AnalyzerInput(buffer: outputBuffer)
        inputBuilder.yield(input)
    }

    // MARK: - WAV 手动写入（绕过 AVAudioFile）

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        // 首次写入：创建文件 + 占位 WAV header
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            // 写入 44 字节占位 header
            fileHandle?.write(Data(count: 44))
            wavDataSize = 0
        }

        // 提取 PCM 数据
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
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        header.appendLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        header.appendLE(UInt32(16))            // chunk size
        header.appendLE(UInt16(1))             // PCM format
        header.appendLE(numChannels)
        header.appendLE(sampleRate)
        header.appendLE(byteRate)
        header.appendLE(blockAlign)
        header.appendLE(bitsPerSample)
        // data chunk
        header.append(contentsOf: "data".utf8)
        header.appendLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Voice", "WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - 格式转换

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

// MARK: - Data little-endian helpers

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )

        return pcmBuffer
    }
}

// MARK: - Errors & Helpers

enum VoiceError: Error {
    case recognizerUnavailable
    case notAuthorized
    case noAudioDevice
    case timeout
}

/// 带超时的 async 执行（throwing 版本）
func withThrowingTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw VoiceError.timeout
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// 带超时的 async 执行（non-throwing 版本）
func withTimeout(seconds: TimeInterval, operation: @Sendable @escaping () async -> Void) async {
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
        }
        await group.next()
        group.cancelAll()
    }
}
