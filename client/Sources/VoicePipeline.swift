import Foundation

/// 语音后处理流水线
/// L1: AlternativeSwap 确定性替换
/// L2: PolishClient 语义润色
/// 注入 -> 纠错监测 -> 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?,
        correctionEnabled: Bool
    ) async {
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        // L1: 确定性替换（基于 SA alternatives + 历史纠错）
        let l1Text = AlternativeSwap.apply(
            text: rawText,
            words: transcription.words,
            corrections: CorrectionStore.shared.recentCorrections()
        )
        if l1Text != rawText {
            Logger.log("Pipeline", "L1 swap: \(l1Text)")
        }

        // L2: 模型润色
        let polished = await PolishClient.shared.polish(
            text: l1Text,
            words: transcription.words,
            app: targetApp
        )
        let finalText = polished ?? l1Text
        if let polished, polished != l1Text {
            Logger.log("Pipeline", "L2 polish: \(polished)")
        }

        // 注入到焦点应用
        TextInjector.inject(text: finalText, to: targetApp)

        // 纠错监测（如果开启）
        if correctionEnabled {
            CorrectionCapture.shared.startWindow(
                insertedText: finalText,
                rawText: rawText,
                app: targetApp
            )
        }

        // 历史落盘（始终写入，蒸馏流水线需要）
        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: polished,
            finalText: finalText,
            app: targetApp
        )
    }
}
