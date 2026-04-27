import Foundation

/// 语音模块
/// 交互：按右 Command 开始录音+转写 → 再按右 Command 停止 → 自动注入
@MainActor
final class VoiceModule: WEModule {
    let name = "Voice"
    var isActive = false

    enum State {
        case idle
        case recording
        case processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }

    /// 状态变化回调（UI 指示器用）
    var onStateChange: ((State) -> Void)?

    private var session: VoiceSession?
    private let pipeline = VoicePipeline()
    private var pinnedApp: AppIdentity?
    private var recordingStartT: CFAbsoluteTime = 0

    func onHotKeyDown() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            Logger.log("Voice", "Ignored hotkey, processing")
        }
    }

    func onHotKeyUp() {
        // 松开不做操作
    }

    private func startRecording() {
        guard VoiceSession.isAuthorized else {
            Logger.log("Voice", "Not authorized, requesting permissions")
            VoiceSession.requestPermissions()
            return
        }

        // 立即设为 recording，防止快速重复按键创建多个 session
        state = .recording
        recordingStartT = CFAbsoluteTimeGetCurrent()

        // 锁定当前焦点应用
        pinnedApp = AppIdentity.current()
        Logger.log("Voice", "Pinned app: \(pinnedApp?.bundleID ?? "unknown")")

        let voiceSession = VoiceSession()
        self.session = voiceSession

        Task {
            do {
                try await voiceSession.start()
                Logger.log("Voice", "Recording... press hotkey again to stop")

                // G3: 上下文注入（OCR + 可选纠错字典），异步不阻塞录音
                Task {
                    let polish = RuntimeConfig.shared.polishConfig
                    let dictEnabled = polish["context_dictionary_enabled"] as? Bool ?? false
                    let dictPath = polish["context_dictionary_path"] as? String
                    let ocrEnabled = polish["context_ocr_enabled"] as? Bool ?? false
                    let words = await ContextEnhancer.enhance(
                        for: self.pinnedApp,
                        dictionaryEnabled: dictEnabled,
                        dictionaryPath: dictPath,
                        ocrEnabled: ocrEnabled
                    )
                    if !words.isEmpty {
                        await voiceSession.updateContext(contextualWords: words)
                    }
                }
            } catch {
                Logger.log("Voice", "Failed to start: \(error)")
                session = nil
                state = .idle
            }
        }
    }

    private func stopAndProcess() {
        guard let session else {
            state = .idle
            return
        }

        let tStop0 = CFAbsoluteTimeGetCurrent()
        let recordingMs = Int((tStop0 - recordingStartT) * 1000)
        state = .processing
        Logger.log("Voice", "Stopping... (recorded \(recordingMs)ms)")

        Task {
            let result = await session.stop()
            let stopMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            self.session = nil

            guard !result.fullText.isEmpty else {
                Logger.log("Voice", "Empty transcription, skipping")
                state = .idle
                return
            }

            Logger.log("Voice", "Transcribed: \(result.fullText)")

            let tPipe = CFAbsoluteTimeGetCurrent()
            await pipeline.process(
                transcription: result,
                targetApp: pinnedApp
            )
            let pipelineMs = Int((CFAbsoluteTimeGetCurrent() - tPipe) * 1000)
            let voiceTotalMs = Int((CFAbsoluteTimeGetCurrent() - tStop0) * 1000)
            Logger.log("Voice", "Timing: recording=\(recordingMs)ms stop_finalize=\(stopMs)ms pipeline=\(pipelineMs)ms voice_total=\(voiceTotalMs)ms")
            state = .idle
        }
    }
}
