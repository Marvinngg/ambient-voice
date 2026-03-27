import Foundation

/// 语义级 diff
struct SemanticDiff: Codable {
    let original: String
    let corrected: String
}

/// 纠错记录
struct CorrectionEntry: Codable, Identifiable {
    let id: String
    let timestamp: Date
    let rawText: String
    let insertedText: String
    let userFinalText: String
    let diffs: [SemanticDiff]
    let quality: Double
    let source: String  // "human"
    let appBundleID: String
    let appName: String
    let metadata: [String: String]

    /// Convenience init with defaults for backward compatibility
    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        rawText: String,
        insertedText: String,
        userFinalText: String,
        diffs: [SemanticDiff] = [],
        quality: Double,
        source: String = "human",
        appBundleID: String = "",
        appName: String = "",
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.insertedText = insertedText
        self.userFinalText = userFinalText
        self.diffs = diffs
        self.quality = quality
        self.source = source
        self.appBundleID = appBundleID
        self.appName = appName
        self.metadata = metadata
    }
}

/// 纠错数据存储
/// 写入 ~/.we/corrections.jsonl 和 ~/.we/semantic-diffs.jsonl
final class CorrectionStore: @unchecked Sendable {
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

    func loadHistory() -> [CorrectionEntry] {
        // Return in-memory recent entries (JSONL file is append-only, full reload not yet implemented)
        recentEntries
    }
}
