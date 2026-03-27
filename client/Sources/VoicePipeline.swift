import Foundation

/// 语音后处理流水线（Lite 版）
/// rawSA → 注入焦点应用 → 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?
    ) async {
        let text = transcription.fullText
        Logger.log("Pipeline", "Text: \(text)")

        // 注入到焦点应用
        TextInjector.inject(text: text, to: targetApp)

        // 历史落盘
        history.save(
            transcription: transcription,
            finalText: text,
            app: targetApp
        )
    }
}
