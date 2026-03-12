import Foundation

/// 每次语音会话的历史记录
/// 写入 ~/.we/voice-history.jsonl
/// 蒸馏流水线从此文件读取训练数据
struct VoiceHistoryEntry: Codable {
    let timestamp: Date
    let rawSA: String
    let l1Text: String
    let polishedText: String?
    let finalText: String
    let words: [WordInfo]
    let audioPath: String?
    let appBundleID: String?
    let appName: String?
}

@MainActor
final class VoiceHistory {
    private let writer = JSONLWriter(filename: "voice-history.jsonl")

    func save(
        transcription: TranscriptionResult,
        l1Text: String,
        polishedText: String?,
        finalText: String,
        app: AppIdentity?
    ) {
        let entry = VoiceHistoryEntry(
            timestamp: transcription.timestamp,
            rawSA: transcription.fullText,
            l1Text: l1Text,
            polishedText: polishedText,
            finalText: finalText,
            words: transcription.words,
            audioPath: transcription.audioPath,
            appBundleID: app?.bundleID,
            appName: app?.appName
        )
        writer.append(entry)
        Logger.log("History", "Saved voice history entry")
    }
}
