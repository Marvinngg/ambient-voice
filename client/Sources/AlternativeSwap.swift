import Foundation

/// L1 确定性替换
/// 基于 SA 的候选词 (alternatives) 和历史纠错记录，对低置信度词做替换
enum AlternativeSwap {
    /// 置信度低于此阈值的词才考虑替换
    static let confidenceThreshold: Float = 0.8

    static func apply(
        text: String,
        words: [WordInfo],
        corrections: [CorrectionEntry]
    ) -> String {
        var result = text

        // 从历史纠错中构建替换字典
        var replacements: [String: String] = [:]
        for correction in corrections {
            for diff in correction.diffs {
                replacements[diff.original] = diff.corrected
            }
        }

        // 对低置信度词，优先从历史纠错中查找替换
        for word in words where word.confidence < confidenceThreshold {
            // 先查历史纠错
            if let replacement = replacements[word.text] {
                result = result.replacingOccurrences(of: word.text, with: replacement)
                continue
            }
            // 再查 SA alternatives（如果第一个候选词存在于历史纠错的正确词中）
            if let alt = word.alternatives.first,
               corrections.contains(where: { $0.diffs.contains(where: { $0.corrected == alt }) }) {
                result = result.replacingOccurrences(of: word.text, with: alt)
            }
        }

        return result
    }
}
