import Foundation

/// L1: Apple 官方排序
///
/// SpeechAnalyzer 返回的 alternatives 按可能性降序排列，
/// result.text == alternatives[0] 是 Apple 语言模型选出的最优解。
/// 信任 Apple 排序，不做自定义重排。
/// alternatives 仅记录日志供数据分析。
enum AlternativeSwap {

    /// 记录 alternatives 日志（不修改文本）
    static func log(segmentAlternatives: [[String]]) {
        for alts in segmentAlternatives where alts.count > 1 {
            let best = alts.first ?? ""
            let others = alts.dropFirst().filter { $0 != best }
            if !others.isEmpty {
                Logger.log("L1", "Alternatives: \"\(best.prefix(20))\" → \(others.map { "\"\($0)\"" }.joined(separator: ", "))")
            }
        }
    }
}
