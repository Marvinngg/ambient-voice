import Foundation
import AVFoundation
import Speech

/// Persistent recording engine for meeting mode.
/// Uses AVCaptureSession (not AVAudioEngine — which has bluetooth silent-fail issues)
/// and SFSpeechRecognizer with rolling restarts to work around the ~60s recognition limit.
/// Tracks speakers via silence-based detection and saves audio to disk.
final class MeetingSession: @unchecked Sendable {
    enum State {
        case idle, recording, paused
    }

    private(set) var state: State = .idle
    private let config: WEConfig.MeetingConfig
    private var meeting: Meeting

    // Audio capture via AVCaptureSession (handles Bluetooth correctly)
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let captureQueue = DispatchQueue(label: "we.meeting.capture", qos: .userInitiated)

    // Speech recognition
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Audio file writing
    private var audioFile: AVAudioFile?
    private var audioFormat: AVAudioFormat?
    private var chunkStartTime: Date?
    private var chunkIndex = 0

    // Speaker tracking
    private var speakerTracker: SilenceBasedSpeakerTracker
    private var lastSpeechTime: Date?
    private var silenceTimer: Timer?

    // Recognition restart
    private var recognitionStartTime: Date?
    private static let maxRecognitionDuration: TimeInterval = 55  // Restart before 60s limit

    // Callbacks
    var onSegment: ((MeetingSegment) -> Void)?
    var onStateChange: ((State) -> Void)?

    init(config: WEConfig.MeetingConfig) {
        self.config = config
        self.meeting = Meeting()
        self.speakerTracker = SilenceBasedSpeakerTracker(silenceThresholdMs: config.silenceThresholdMs)
    }

    var currentMeeting: Meeting { meeting }

    // MARK: - Public API

    func start() async throws {
        guard state == .idle else { return }

        let locale = Locale(identifier: "zh-Hans")
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw VoiceSession.SessionError.recognizerUnavailable
        }
        self.recognizer = rec

        // Create meeting directory
        let meetingDir = meetingDirectory()
        try FileManager.default.createDirectory(at: meetingDir, withIntermediateDirectories: true)

        // Set up AVCaptureSession
        let session = AVCaptureSession()
        session.beginConfiguration()

        guard let audioDevice = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: audioDevice) else {
            throw VoiceSession.SessionError.audioEngineFailure(
                NSError(domain: "MeetingSession", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "No audio capture device"])
            )
        }

        if session.canAddInput(audioInput) {
            session.addInput(audioInput)
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(
            AudioBufferDelegate(session: self),
            queue: captureQueue
        )
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        self.audioOutput = output

        session.commitConfiguration()
        self.captureSession = session

        // Start recognition
        try startRecognition()

        // Start capture
        session.startRunning()

        state = .recording
        onStateChange?(.recording)
        lastSpeechTime = Date()
        recognitionStartTime = Date()

        // Start silence monitoring timer
        startSilenceTimer()

        DebugLog.log(.meeting, "Meeting \(meeting.id) started (AVCaptureSession)")
    }

    func stop() -> Meeting {
        guard state == .recording else { return meeting }

        silenceTimer?.invalidate()
        silenceTimer = nil

        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        audioFile = nil
        recognizer = nil

        meeting.endDate = Date()
        state = .idle
        onStateChange?(.idle)

        DebugLog.log(.meeting, "Meeting \(meeting.id) ended, \(meeting.segments.count) segments, \(meeting.formattedDuration)")
        return meeting
    }

    // MARK: - Audio Buffer Processing

    fileprivate func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Feed to speech recognizer
        recognitionRequest?.appendAudioSampleBuffer(sampleBuffer)

        // RMS silence detection
        checkRMSSilence(sampleBuffer)

        // Write to audio file
        if config.saveAudio {
            writeAudioChunk(sampleBuffer)
        }
    }

    private func writeAudioChunk(_ sampleBuffer: CMSampleBuffer) {
        // Lazy init audio format and file from first buffer
        if audioFormat == nil {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)
            self.audioFormat = format
            do {
                try startNewAudioChunk(format: format)
            } catch {
                DebugLog.log(.meeting, "Failed to start audio chunk: \(error)", level: .warning)
            }
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer and write
        guard let pcmBuffer = pcmBuffer(from: sampleBuffer) else { return }
        try? audioFile?.write(from: pcmBuffer)

        // Rotate chunk if needed
        if let start = chunkStartTime,
           -start.timeIntervalSinceNow >= Double(config.chunkDurationSec),
           let format = self.audioFormat {
            do {
                try startNewAudioChunk(format: format)
            } catch {
                DebugLog.log(.meeting, "Failed to rotate audio chunk: \(error)", level: .warning)
            }
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, let channelData = buffer.floatChannelData else { return nil }
        memcpy(channelData[0], data, length)

        return buffer
    }

    // MARK: - Recognition Management

    private func startRecognition() throws {
        guard let recognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        self.recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if !text.isEmpty {
                    self.lastSpeechTime = Date()
                    let segment = MeetingSegment(
                        timestamp: self.meeting.duration,
                        text: text,
                        speakerIndex: self.speakerTracker.currentSpeakerIndex,
                        isFinal: result.isFinal
                    )
                    if result.isFinal {
                        self.meeting.segments.append(segment)
                    }
                    DispatchQueue.main.async {
                        self.onSegment?(segment)
                    }
                }
            }

            if error != nil || (result?.isFinal ?? false) {
                if self.state == .recording {
                    self.restartRecognition()
                }
            }
        }

        recognitionStartTime = Date()
    }

    private func restartRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        guard captureSession != nil, state == .recording else { return }

        do {
            try startRecognition()
            DebugLog.log(.meeting, "Recognition restarted (rolling)")
        } catch {
            DebugLog.log(.meeting, "Failed to restart recognition: \(error)", level: .error)
        }
    }

    // MARK: - Audio Chunks

    private func meetingDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/meetings/\(meeting.id)")
    }

    private func startNewAudioChunk(format: AVAudioFormat) throws {
        let dir = meetingDirectory()
        let filename = String(format: "chunk-%03d.caf", chunkIndex)
        let url = dir.appendingPathComponent(filename)

        audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        meeting.audioChunkPaths.append(url.path)
        chunkStartTime = Date()
        chunkIndex += 1

        DebugLog.log(.meeting, "Started audio chunk \(chunkIndex)")
    }

    // MARK: - Silence Detection

    private func checkRMSSilence(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer else { return }
        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        let floatPointer = UnsafeRawPointer(data).bindMemory(to: Float.self, capacity: floatCount)
        var sumOfSquares: Float = 0
        for i in 0..<floatCount {
            let sample = floatPointer[i]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(floatCount))

        if rms >= 0.01 {
            lastSpeechTime = Date()
        }
    }

    private func startSilenceTimer() {
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let lastSpeech = self.lastSpeechTime else { return }
            let silenceMs = Int(-lastSpeech.timeIntervalSinceNow * 1000)
            _ = self.speakerTracker.processSilence(durationMs: silenceMs)

            // Check if recognition needs rolling restart
            if let startTime = self.recognitionStartTime,
               -startTime.timeIntervalSinceNow >= Self.maxRecognitionDuration {
                self.restartRecognition()
            }
        }
    }
}

// MARK: - AVCaptureAudioDataOutput delegate bridge

private class AudioBufferDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var session: MeetingSession?

    init(session: MeetingSession) {
        self.session = session
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        session?.handleAudioBuffer(sampleBuffer)
    }
}
