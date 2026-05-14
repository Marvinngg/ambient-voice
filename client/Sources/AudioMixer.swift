@preconcurrency import AVFoundation
import Speech

/// B4: 样本级混音器
///
/// 同时录 mic + system 的会议模式使用。两路 16kHz Float32 mono 样本到达后，
/// 定时窗口（100ms）drain + 逐样本相加 + yield 到 SpeechAnalyzer。
///
/// 时间对齐策略：定时 drain（非严格对齐）。两路异步到达，drain 时间窗口内各取可用样本，
/// 短的补 0。~100ms 级时间误差对 SA 转写可接受，也避免了 host-time 严格对齐的复杂度。
///
/// 混音规则：`mixed = (mic + system) * 0.5`，50-50 叠加防过载。
///
/// 线程模型：
/// - feed 从 capturer 后台队列同步调用（nonisolated + NSLock 保护）
/// - drainAndMix 在 MainActor 定时触发，内部通过 nonisolated drainBuffers() 拿样本快照（sync + lock），
///   然后在 MainActor 上做 mix + yield
@MainActor
final class AudioMixer {

    private let analyzerFormat: AVAudioFormat?
    private let diarizationFormat: AVAudioFormat
    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let onDiarizationSamples: @Sendable ([Float]) -> Void

    /// 共享样本缓冲（nonisolated + NSLock）
    private nonisolated(unsafe) var micBuffer: [Float] = []
    private nonisolated(unsafe) var sysBuffer: [Float] = []
    private nonisolated(unsafe) var _micSamplesFed: Int = 0
    private nonisolated(unsafe) var _sysSamplesFed: Int = 0
    private let bufferLock = NSLock()

    /// MainActor 独享
    private var drainTask: Task<Void, Never>?
    private var mixOutputCount: Int = 0
    private let windowMs: Int = 100

    init(
        analyzerFormat: AVAudioFormat?,
        diarizationFormat: AVAudioFormat,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        onDiarizationSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        self.analyzerFormat = analyzerFormat
        self.diarizationFormat = diarizationFormat
        self.inputBuilder = inputBuilder
        self.onDiarizationSamples = onDiarizationSamples
    }

    func start() {
        let interval = windowMs
        drainTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(interval))
                guard let self else { return }
                await self.drainAndMix()
            }
        }
        Logger.log("Meeting", "AudioMixer started, window=\(windowMs)ms")
    }

    func stop() async {
        drainTask?.cancel()
        drainTask = nil
        // 最后 drain 一次残留样本
        await drainAndMix()
        let (micFed, sysFed) = readCounts()
        Logger.log("Meeting", "AudioMixer stopped. micFed=\(micFed) sysFed=\(sysFed) mixed=\(mixOutputCount)")
    }

    // MARK: - 样本投递（nonisolated，后台队列调用）

    nonisolated func feedMic(_ samples: [Float]) {
        bufferLock.lock()
        micBuffer.append(contentsOf: samples)
        _micSamplesFed += samples.count
        bufferLock.unlock()
    }

    nonisolated func feedSystem(_ samples: [Float]) {
        bufferLock.lock()
        sysBuffer.append(contentsOf: samples)
        _sysSamplesFed += samples.count
        bufferLock.unlock()
    }

    // MARK: - Drain + Mix

    /// 取出并清空两路缓冲（sync，lock-protected，async 安全）
    private nonisolated func drainBuffers() -> (mic: [Float], sys: [Float]) {
        bufferLock.lock()
        let m = micBuffer
        let s = sysBuffer
        micBuffer.removeAll(keepingCapacity: true)
        sysBuffer.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        return (m, s)
    }

    /// 读计数（sync，lock-protected）
    private nonisolated func readCounts() -> (mic: Int, sys: Int) {
        bufferLock.lock()
        let r = (_micSamplesFed, _sysSamplesFed)
        bufferLock.unlock()
        return r
    }

    private func drainAndMix() async {
        let (mic, sys) = drainBuffers()

        if mic.isEmpty && sys.isEmpty {
            return
        }

        // 对齐到更长的一路，短的补 0
        let len = max(mic.count, sys.count)
        var mixed = [Float](repeating: 0, count: len)
        for i in 0..<len {
            let m = i < mic.count ? mic[i] : 0
            let s = i < sys.count ? sys[i] : 0
            mixed[i] = (m + s) * 0.5
        }

        mixOutputCount += 1

        // 送 SA（转成 analyzerFormat PCM buffer）
        if let analyzerFormat,
           let pcmBuffer = makeAnalyzerBuffer(from: mixed, targetFormat: analyzerFormat) {
            inputBuilder.yield(AnalyzerInput(buffer: pcmBuffer))
        }

        // 送 diarization
        onDiarizationSamples(mixed)
    }

    /// 16kHz Float32 mono 样本 → analyzerFormat AVAudioPCMBuffer
    private func makeAnalyzerBuffer(from samples: [Float], targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let srcFormat = diarizationFormat
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        srcBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = srcBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                dst[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }

        // 如果目标格式就是 Float32 mono 16kHz，直接返回
        if srcFormat.sampleRate == targetFormat.sampleRate
            && srcFormat.commonFormat == targetFormat.commonFormat
            && srcFormat.channelCount == targetFormat.channelCount {
            return srcBuffer
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat),
              let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(samples.count * 2)) else {
            return nil
        }

        var error: NSError?
        let consumed = Box(false)
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if consumed.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed.value = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        return (error == nil && outBuf.frameLength > 0) ? outBuf : nil
    }
}
