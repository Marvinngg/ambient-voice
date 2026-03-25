import Foundation

/// 语音后处理流水线
/// L1: 信任 Apple 官方排序（alternatives 记日志）
/// L2: PolishClient 语义润色（可关闭）
/// 注入 → 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?
    ) async {
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        // L1: 信任 Apple 官方排序，不修改文本
        AlternativeSwap.log(segmentAlternatives: transcription.segmentAlternatives)
        let l1Text = rawText

        // L2: 模型润色（polish.enabled = false 时跳过）
        let finalText: String
        let polished: String?
        if RuntimeConfig.shared.polishConfig["enabled"] as? Bool == true {
            polished = await PolishClient.shared.polish(
                text: l1Text,
                words: transcription.words,
                app: targetApp
            )
            finalText = polished ?? l1Text
            if let polished, polished != l1Text {
                Logger.log("Pipeline", "L2 polish: \(polished)")
            }
        } else {
            polished = nil
            finalText = l1Text
        }

        // 注入到焦点应用
        TextInjector.inject(text: finalText, to: targetApp)

        // 历史落盘（始终写入，蒸馏需要）
        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: polished,
            finalText: finalText,
            app: targetApp
        )
    }
}
