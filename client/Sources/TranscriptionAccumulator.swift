import Foundation
import Speech

/// 转写结果的词级信息
struct WordInfo: Codable {
    let text: String
    let confidence: Float
    let alternatives: [String]
    let startTime: TimeInterval
    let duration: TimeInterval
}

/// 一次语音会话的完整转写结果
struct TranscriptionResult: Codable {
    let fullText: String
    let words: [WordInfo]
    let audioPath: String?
    let timestamp: Date
}

/// 聚合 SFSpeechRecognitionResult 的词级信息
/// 每次 update 接收部分结果，finalize 返回最终结果
@MainActor
final class TranscriptionAccumulator {
    private var latestResult: SFSpeechRecognitionResult?

    func reset() {
        latestResult = nil
    }

    func update(_ result: SFSpeechRecognitionResult) {
        latestResult = result
    }

    func finalize(audioPath: String?) -> TranscriptionResult {
        guard let result = latestResult else {
            return TranscriptionResult(fullText: "", words: [], audioPath: audioPath, timestamp: Date())
        }

        let bestTranscription = result.bestTranscription
        let words = bestTranscription.segments.map { segment in
            // 收集 alternatives（SA 的候选词，用于 L1 AlternativeSwap）
            let alts = segment.alternativeSubstrings

            return WordInfo(
                text: segment.substring,
                confidence: segment.confidence,
                alternatives: alts,
                startTime: segment.timestamp,
                duration: segment.duration
            )
        }

        return TranscriptionResult(
            fullText: bestTranscription.formattedString,
            words: words,
            audioPath: audioPath,
            timestamp: Date()
        )
    }
}
