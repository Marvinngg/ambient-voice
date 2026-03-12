import Foundation

/// 语义级 diff
struct SemanticDiff: Codable {
    let original: String
    let corrected: String
}

/// 纠错记录
struct CorrectionEntry: Codable {
    let timestamp: Date
    let rawText: String
    let insertedText: String
    let userFinalText: String
    let diffs: [SemanticDiff]
    let quality: Double
    let source: String  // "human"
    let appBundleID: String?
}

/// 纠错数据存储
/// 写入 ~/.we/corrections.jsonl 和 ~/.we/semantic-diffs.jsonl
@MainActor
final class CorrectionStore {
    static let shared = CorrectionStore()

    private let correctionsWriter = JSONLWriter(filename: "corrections.jsonl")
    private let diffsWriter = JSONLWriter(filename: "semantic-diffs.jsonl")
    private var recentEntries: [CorrectionEntry] = []

    func save(_ entry: CorrectionEntry) {
        correctionsWriter.append(entry)
        recentEntries.append(entry)
        // 保留最近 200 条用于 L1 AlternativeSwap
        if recentEntries.count > 200 {
            recentEntries.removeFirst(recentEntries.count - 200)
        }

        // 同时写入 semantic diffs
        for diff in entry.diffs {
            diffsWriter.append(diff)
        }

        Logger.log("CorrectionStore", "Saved correction (diffs: \(entry.diffs.count), quality: \(String(format: "%.2f", entry.quality)))")
    }

    func recentCorrections() -> [CorrectionEntry] {
        recentEntries
    }
}
