import Foundation

/// 语音模块
/// 交互：按住右 Command 说话 → 松开自动停止并注入文字 (push-to-talk)
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
    private var pinnedApp: AppIdentity?
    private var screenContext: ScreenContextProvider.ScreenContext?

    func onHotKeyDown() {
        if state == .idle {
            startRecording()
        }
    }

    func onHotKeyUp() {
        if state == .recording {
            stopAndProcess()
        }
    }

    private func startRecording() {
        guard VoiceSession.isAuthorized else {
            Logger.log("Voice", "Not authorized, requesting permissions")
            VoiceSession.requestPermissions()
            return
        }

        // 立即设为 recording，防止快速重复按键创建多个 session
        state = .recording

        // 锁定当前焦点应用
        pinnedApp = AppIdentity.current()
        Logger.log("Voice", "Pinned app: \(pinnedApp?.bundleID ?? "unknown")")

        let voiceSession = VoiceSession()
        self.session = voiceSession
        self.screenContext = nil

        Task {
            do {
                try await voiceSession.start()
                Logger.log("Voice", "Recording... press hotkey again to stop")

                // G3: 截屏 OCR 获取上下文（异步，不阻塞录音）
                Task {
                    if let ctx = await ScreenContextProvider.shared.capture(for: self.pinnedApp) {
                        self.screenContext = ctx
                        await voiceSession.updateContext(contextualWords: ctx.contextualWords)
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

        state = .processing
        Logger.log("Voice", "Stopping...")

        Task {
            let result = await session.stop()
            self.session = nil

            guard !result.fullText.isEmpty else {
                Logger.log("Voice", "Empty transcription, skipping")
                state = .idle
                return
            }

            Logger.log("Voice", "Transcribed: \(result.fullText)")

            if let app = pinnedApp ?? AppIdentity.current() {
                await VoicePipeline.process(
                    result: result,
                    appIdentity: app,
                    screenContext: screenContext,
                    audioFilePath: result.audioPath
                )
            }
            state = .idle
            Logger.log("Voice", "Pipeline done -> idle")
        }
    }
}
