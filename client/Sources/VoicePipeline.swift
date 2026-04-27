import Foundation

/// 语音后处理流水线
/// L2: PolishClient 语义润色（可关闭）
/// 注入 → 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?
    ) async {
        let tStart = CFAbsoluteTimeGetCurrent()
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        // L1: 信任 Apple 官方排序，不做任何修改
        let l1Text = rawText

        // L2: 模型润色（polish.enabled = false 时跳过）
        let finalText: String
        let polished: String?
        var l2ElapsedMs = 0
        if RuntimeConfig.shared.polishConfig["enabled"] as? Bool == true {
            let tL2 = CFAbsoluteTimeGetCurrent()
            polished = await PolishClient.shared.polish(
                text: l1Text,
                words: transcription.words,
                app: targetApp
            )
            l2ElapsedMs = Int((CFAbsoluteTimeGetCurrent() - tL2) * 1000)

            // 无条件记录 L2 真实行为：nil / identity / 真改
            let kind: String
            if polished == nil { kind = "nil" }
            else if polished == l1Text { kind = "identity" }
            else { kind = "changed" }
            Logger.log("Pipeline", "L2: elapsedMs=\(l2ElapsedMs) kind=\(kind) output=\(polished ?? "<nil>")")

            finalText = polished ?? l1Text
        } else {
            polished = nil
            finalText = l1Text
            Logger.log("Pipeline", "L2: skipped (polish.enabled=false)")
        }

        // 注入到焦点应用
        let tInject = CFAbsoluteTimeGetCurrent()
        TextInjector.inject(text: finalText, to: targetApp)
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - tInject) * 1000)

        // 历史落盘（始终写入，蒸馏需要）
        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: polished,
            finalText: finalText,
            app: targetApp
        )

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        Logger.log("Pipeline", "Timing: l2=\(l2ElapsedMs)ms inject=\(injectMs)ms pipeline_total=\(totalMs)ms")
    }
}
