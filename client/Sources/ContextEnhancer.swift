import Foundation

/// 组装 SpeechAnalyzer.contextualStrings 的统一入口
/// 来源：纠错字典（可关）+ 屏幕 OCR 关键词（可关）
/// Apple 建议 contextualStrings 总长 ≤100 项
@MainActor
enum ContextEnhancer {
    private static let maxContextualStrings = 100

    /// 组合字典术语和屏幕 OCR 关键词
    /// - 两个开关由 config.polish.context_{dictionary,ocr}_enabled 控制
    static func enhance(
        for app: AppIdentity?,
        dictionaryEnabled: Bool,
        dictionaryPath: String?,
        ocrEnabled: Bool
    ) async -> [String] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var result: [String] = []
        var seen = Set<String>()

        // 字典术语（高频术语，用户明确定义）
        var dictCount = 0
        if dictionaryEnabled, let path = dictionaryPath {
            CorrectionDictionary.shared.load(from: path)
            for term in CorrectionDictionary.shared.terms {
                if seen.insert(term).inserted {
                    result.append(term)
                    dictCount += 1
                }
            }
        }

        // OCR 关键词补齐剩余名额（可关）
        var ocrCount = 0
        if ocrEnabled {
            if let ctx = await ScreenContextProvider.shared.capture(for: app) {
                for word in ctx.contextualWords {
                    guard result.count < maxContextualStrings else { break }
                    if seen.insert(word).inserted {
                        result.append(word)
                        ocrCount += 1
                    }
                }
            }
        }

        if result.count > maxContextualStrings {
            result = Array(result.prefix(maxContextualStrings))
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let ocrState = ocrEnabled ? "\(ocrCount)" : "off"
        Logger.log("Ctx", "enhance: dict=\(dictCount) ocr=\(ocrState) total=\(result.count) elapsedMs=\(elapsedMs)")
        return result
    }
}
