import AVFoundation
import CoreMedia
import ScreenCaptureKit

// MARK: - 系统音频采集

/// 通过 ScreenCaptureKit 采集系统音频输出（Zoom / 腾讯会议 / 飞书等会议软件远端的声音）
///
/// 输出与 AVCaptureSession 一致的 CMSampleBuffer，交由调用方消费。
/// 需要用户授予「屏幕录制」权限，首次使用时系统会弹出授权。
///
/// SCK 技术细节：
/// - 必须提供 display filter 和非零视频尺寸，因此配置 2×2 最小画面并丢弃视频输出
/// - excludesCurrentProcessAudio = true 避免 WE 自身产生的声音被循环录制
@MainActor
final class SystemAudioCapture: NSObject, SCStreamDelegate {
    private var stream: SCStream?
    private var audioOutput: SystemAudioOutput?
    private let captureQueue = DispatchQueue(label: "com.antigravity.we.system-audio-capture")

    /// 每个音频 sample buffer 到达时的回调（在 captureQueue 后台队列执行）
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            Logger.log("SystemAudio", "No display found")
            throw VoiceError.noAudioDevice
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let audioOutput = SystemAudioOutput { [weak self] buffer in
            self?.onSampleBuffer?(buffer)
        }
        try stream.addStreamOutput(audioOutput, type: .audio, sampleHandlerQueue: captureQueue)

        try await stream.startCapture()

        self.stream = stream
        self.audioOutput = audioOutput
        Logger.log("SystemAudio", "Started (\(Int(config.sampleRate))Hz, \(config.channelCount)ch)")
    }

    func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
            Logger.log("SystemAudio", "Stopped")
        } catch {
            Logger.log("SystemAudio", "Stop error: \(error)")
        }
        self.stream = nil
        self.audioOutput = nil
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.log("SystemAudio", "Stream stopped with error: \(error)")
    }
}

/// SCStreamOutput 包装，只处理音频 buffer
private final class SystemAudioOutput: NSObject, SCStreamOutput {
    private let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              sampleBuffer.isValid,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return
        }
        handler(sampleBuffer)
    }
}

// MARK: - 音频混合器

/// 麦克风 + 系统音频的简单混合器
///
/// 设计：麦克风作为主时钟，系统音频以 16kHz Float32 mono 的样本流形式累积在队列中。
/// 每次麦克风产生 N 帧时，从系统队列弹出等长的样本并与麦克风逐样本相加。
/// 若系统队列样本不足，缺口用 0 填充（即视为静音）。
///
/// 这个设计避开了 CMSampleBuffer PTS 对齐的复杂性，代价是系统和麦克风之间可能有
/// 最多 ~100ms 的相对延迟。对会议转写场景足够。
final class AudioMixer: @unchecked Sendable {
    private let lock = NSLock()
    private var systemSamples: [Float] = []

    /// 系统队列最多保留 10 秒的样本，避免麦克风长时间不活跃时无限增长
    private let maxBufferedSamples: Int = 16000 * 10

    /// 系统音频回调调用：追加样本到队列
    func pushSystemSamples(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        systemSamples.append(contentsOf: samples)
        if systemSamples.count > maxBufferedSamples {
            let overflow = systemSamples.count - maxBufferedSamples
            systemSamples.removeFirst(overflow)
        }
    }

    /// 麦克风驱动调用：取出 count 个系统样本；不足时用 0 填充
    func popSystemSamples(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if systemSamples.count >= count {
            let out = Array(systemSamples.prefix(count))
            systemSamples.removeFirst(count)
            return out
        }
        let available = systemSamples
        systemSamples = []
        return available + Array(repeating: 0, count: count - available.count)
    }

    func drain() {
        lock.lock()
        systemSamples = []
        lock.unlock()
    }
}

// MARK: - CMSampleBuffer → 16kHz Float32 mono 样本转换

/// 有状态的转换辅助：CMSampleBuffer → [Float]（16kHz Float32 mono）
/// 复用 AVAudioConverter 避免每次回调都重建。用于 .both 模式把系统音频样本压入混合器队列。
final class MonoFloat32Converter: @unchecked Sendable {
    private var converter: AVAudioConverter?
    private let targetFormat: AVAudioFormat

    init(targetSampleRate: Int = 16000) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        )!
    }

    func convert(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let pcm = sampleBuffer.toPCMBuffer() else { return nil }

        // 源格式已经与目标一致，直接返回样本
        if pcm.format.sampleRate == targetFormat.sampleRate
            && pcm.format.commonFormat == targetFormat.commonFormat
            && pcm.format.channelCount == targetFormat.channelCount {
            guard let data = pcm.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: data, count: Int(pcm.frameLength)))
        }

        if converter == nil {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
        }
        guard let converter else { return nil }

        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1
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
            return pcm
        }

        guard error == nil, output.frameLength > 0, let data = output.floatChannelData?[0] else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }
}
