import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech

/// 系统音频采集器（B3.2）
///
/// 使用 ScreenCaptureKit 的 SCStream (capturesAudio=true) 捕获系统音频输出。
/// 典型场景：会议模式下录制 Zoom / 腾讯会议等应用里对方的声音。
///
/// 对外接口与 MeetingCaptureDelegate 对齐：
/// - 把 PCM 样本 yield 到 inputBuilder（SpeechAnalyzer 消费）
/// - 推送 16kHz Float32 mono 样本给 onDiarizationSamples（diarization 消费）
/// - 写入 WAV 文件（持久化音频）
///
/// 注意：
/// - ScreenCaptureKit 要求"屏幕录制"权限（TCC），复用项目已有的 checkScreenCapture 流程
/// - excludesCurrentProcessAudio=true 避免录到 WE 自己发出的声音
/// - 当前版本不与 mic 混音（B4 独立做）
final class SystemAudioCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    enum CaptureError: Error {
        case noDisplay
    }

    private let inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat?
    private let audioFileURL: URL
    private let diarizationSampleRate: Int
    private let onDiarizationSamples: @Sendable ([Float]) -> Void
    private let mixer: AudioMixer?

    // 格式转换
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

    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "com.antigravity.we.system-audio")
    private var bufferCount = 0

    init(
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation,
        analyzerFormat: AVAudioFormat?,
        audioFileURL: URL,
        diarizationSampleRate: Int,
        onDiarizationSamples: @escaping @Sendable ([Float]) -> Void,
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

    /// 启动 SCStream，开始接收系统音频
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // SCStream 要求有视频配置，给最小画面避免耗资源
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        // 也要 add .screen 输出，否则某些版本会报错；这里丢弃
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream

        Logger.log("Meeting", "SystemAudioCapturer started (ScreenCaptureKit, excludesCurrentProcess=true)")
    }

    /// 停止采集 + finalize WAV
    func stop() async {
        if let s = stream {
            try? await s.stopCapture()
        }
        stream = nil
        finalizeWAV()
        Logger.log("Meeting", "SystemAudioCapturer stopped, bufferCount=\(bufferCount)")
    }

    func close() {
        finalizeWAV()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 只处理音频，丢弃视频
        guard type == .audio else { return }
        bufferCount += 1

        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else {
            if bufferCount <= 3 { Logger.log("Meeting", "SysAudio #\(bufferCount): CMSampleBuffer conversion failed") }
            return
        }

        if bufferCount <= 3 {
            Logger.log("Meeting", "SysAudio #\(bufferCount): \(pcmBuffer.frameLength) frames, fmt=\(pcmBuffer.format)")
        }

        // --- 分支1: 送 SpeechAnalyzer ---
        let analyzerBuffer: AVAudioPCMBuffer
        if let targetFormat = analyzerFormat,
           pcmBuffer.format.sampleRate != targetFormat.sampleRate
            || pcmBuffer.format.commonFormat != targetFormat.commonFormat
            || pcmBuffer.format.channelCount != targetFormat.channelCount {
            if analyzerConverter == nil {
                analyzerConverter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
                Logger.log("Meeting", "SysAudio analyzer converter: \(pcmBuffer.format) → \(targetFormat)")
            }
            guard let converter = analyzerConverter,
                  let converted = convert(buffer: pcmBuffer, using: converter, to: targetFormat) else {
                if bufferCount <= 3 { Logger.log("Meeting", "SysAudio #\(bufferCount): analyzer conversion failed") }
                return
            }
            analyzerBuffer = converted
        } else {
            analyzerBuffer = pcmBuffer
        }

        // 送 SpeechAnalyzer（B4 混音模式下由 mixer 统一 yield）
        if mixer == nil {
            let input = AnalyzerInput(buffer: analyzerBuffer)
            inputBuilder.yield(input)
        }

        // 写 WAV（原始 system 流，混音模式下也保留）
        writeToWAV(buffer: analyzerBuffer)

        // --- 分支2: 16kHz Float32 mono 样本 → mixer 或 diarization ---
        if let diaFmt = diarizationFormat {
            let diaBuffer: AVAudioPCMBuffer
            if pcmBuffer.format.sampleRate != diaFmt.sampleRate
                || pcmBuffer.format.commonFormat != diaFmt.commonFormat
                || pcmBuffer.format.channelCount != diaFmt.channelCount {
                if diarizationConverter == nil {
                    diarizationConverter = AVAudioConverter(from: pcmBuffer.format, to: diaFmt)
                    Logger.log("Meeting", "SysAudio diarization converter: \(pcmBuffer.format) → \(diaFmt)")
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
                    mixer.feedSystem(samples)
                } else {
                    onDiarizationSamples(samples)
                }
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.log("Meeting", "SystemAudioCapturer didStopWithError: \(error)")
    }

    // MARK: - WAV 写入（与 MeetingCaptureDelegate 同构）

    private func writeToWAV(buffer: AVAudioPCMBuffer) {
        if fileHandle == nil {
            wavFormat = buffer.format
            let dir = audioFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: audioFileURL.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: audioFileURL)
            fileHandle?.write(Data(count: 44))
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
        header.appendSysLE(UInt32(36 + wavDataSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.appendSysLE(UInt32(16))
        header.appendSysLE(UInt16(1))
        header.appendSysLE(numChannels)
        header.appendSysLE(sampleRate)
        header.appendSysLE(byteRate)
        header.appendSysLE(blockAlign)
        header.appendSysLE(bitsPerSample)
        header.append(contentsOf: "data".utf8)
        header.appendSysLE(wavDataSize)

        fh.seek(toFileOffset: 0)
        fh.write(header)
        try? fh.close()
        fileHandle = nil

        Logger.log("Meeting", "SysAudio WAV saved: \(audioFileURL.lastPathComponent) (\(wavDataSize) bytes)")
    }

    // MARK: - 格式转换（与 MeetingCaptureDelegate 同构）

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

// MARK: - Data little-endian helpers（独立命名避免冲突）

private extension Data {
    mutating func appendSysLE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
    mutating func appendSysLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
