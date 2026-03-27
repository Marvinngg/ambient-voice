import Foundation

/// 每次语音会话的历史记录
/// 写入 ~/.we-lite/voice-history.jsonl
struct VoiceHistoryEntry: Codable {
    let timestamp: Date
    let rawSA: String
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
        finalText: String,
        app: AppIdentity?
    ) {
        let entry = VoiceHistoryEntry(
            timestamp: transcription.timestamp,
            rawSA: transcription.fullText,
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
