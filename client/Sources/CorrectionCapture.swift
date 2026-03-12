import AppKit

/// 纠错采集器
/// 注入文本后开启监测窗口，检测用户是否修改了注入内容
/// 监听 Enter 键触发对比，30 秒窗口超时也做一次对比
@MainActor
final class CorrectionCapture {
    static let shared = CorrectionCapture()

    private var insertedText: String?
    private var rawText: String?
    private var app: AppIdentity?
    private var windowTimer: DispatchWorkItem?
    private var isActive = false

    /// 监测窗口时长（秒）
    private let windowDuration: TimeInterval = 30

    func startWindow(insertedText: String, rawText: String, app: AppIdentity?) {
        self.insertedText = insertedText
        self.rawText = rawText
        self.app = app
        self.isActive = true

        // 注册 Enter 键监听
        GlobalHotKey.shared.onEnterKey = { [weak self] in
            self?.onUserSubmit()
        }

        windowTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onWindowTimeout()
        }
        windowTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + windowDuration, execute: work)

        Logger.log("Correction", "Capture window opened (\(windowDuration)s)")
    }

    /// Enter 键触发
    private func onUserSubmit() {
        guard isActive, let insertedText, let app else { return }

        let axText = readFocusedText(pid: app.processID)

        guard let axText, !axText.isEmpty else {
            Logger.log("Correction", "Could not read focused text")
            return
        }

        Logger.log("Correction", "AX text length=\(axText.count), insertedText length=\(insertedText.count)")

        // 从 AX 文本中提取用户修正
        let corrected = extractCorrectedText(axText: axText, insertedText: insertedText)

        guard let corrected, corrected != insertedText else {
            Logger.log("Correction", "No correction detected (corrected=\(corrected == nil ? "nil" : "same as inserted"))")
            return
        }

        saveCorrection(correctedText: corrected, insertedText: insertedText)
        endWindow()
    }

    /// 30 秒超时，再尝试一次读取对比
    private func onWindowTimeout() {
        guard isActive, let insertedText, let app else {
            endWindow()
            return
        }

        if let axText = readFocusedText(pid: app.processID), !axText.isEmpty {
            let corrected = extractCorrectedText(axText: axText, insertedText: insertedText)
            if let corrected, corrected != insertedText {
                saveCorrection(correctedText: corrected, insertedText: insertedText)
            }
        }

        endWindow()
    }

    /// 从 AX 读取的文本中提取用户修正
    /// 文本编辑器：AX 直接返回输入框内容，直接对比
    /// Terminal 等：AX 返回整个缓冲区，按行搜索最匹配的行
    private func extractCorrectedText(axText: String, insertedText: String) -> String? {
        let lengthRatio = Double(axText.count) / max(Double(insertedText.count), 1)

        // 短文本（文本编辑器）：直接用
        if lengthRatio < 3.0 {
            return axText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 长文本（Terminal 等）：按行搜索最匹配的
        // 取最后 100 行（最近的内容），避免搜索整个历史
        let allLines = axText.components(separatedBy: .newlines)
        let recentLines = allLines.suffix(100)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 2 }

        Logger.log("Correction", "Terminal mode: searching \(recentLines.count) lines (total \(allLines.count))")

        var bestLine: String?
        var bestSim: Double = 0

        for line in recentLines {
            // Terminal 行可能有 prompt 前缀（如 "user@host ~ %"），
            // 尝试 containsSubstring 匹配和 LCS 相似度
            let cleaned = stripPromptPrefix(line)
            let sim = lcsSimilarity(insertedText, cleaned)

            if sim > bestSim {
                bestSim = sim
                bestLine = cleaned
            }
        }

        guard bestSim > 0.3 else {
            Logger.log("Correction", "No matching line found (best sim=\(String(format: "%.2f", bestSim)))")
            return nil
        }

        Logger.log("Correction", "Matched line (sim=\(String(format: "%.2f", bestSim))): \(bestLine?.prefix(40) ?? "")")
        return bestLine
    }

    /// 去除常见 Terminal prompt 前缀
    private func stripPromptPrefix(_ line: String) -> String {
        // 匹配常见 prompt 格式：
        // "user@host ~ % cmd"  "$ cmd"  "> cmd"  "% cmd"
        let patterns: [String] = [
            #"^.*?[%$>]\s+"#,       // 通用: 任意前缀 + %/$/>  + 空格
            #"^\(.*?\)\s*"#,        // conda env: (env) cmd
        ]
        var result = line
        for pattern in patterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result = String(result[range.upperBound...])
                break
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func saveCorrection(correctedText: String, insertedText: String) {
        let similarity = stringSimilarity(insertedText, correctedText)
        let quality = similarity

        let diffs = computeDiffs(original: insertedText, corrected: correctedText)

        let entry = CorrectionEntry(
            timestamp: Date(),
            rawText: rawText ?? "",
            insertedText: insertedText,
            userFinalText: correctedText,
            diffs: diffs,
            quality: quality,
            source: "human",
            appBundleID: app?.bundleID
        )

        CorrectionStore.shared.save(entry)
        Logger.log("Correction", "Captured: \"\(insertedText)\" → \"\(correctedText)\"")
    }

    private func endWindow() {
        windowTimer?.cancel()
        windowTimer = nil
        insertedText = nil
        rawText = nil
        app = nil
        isActive = false
        GlobalHotKey.shared.onEnterKey = nil
    }

    // MARK: - AX 读取

    private func readFocusedText(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return nil }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return text
    }

    // MARK: - Diff & Similarity

    private func computeDiffs(original: String, corrected: String) -> [SemanticDiff] {
        guard original != corrected else { return [] }
        return [SemanticDiff(original: original, corrected: corrected)]
    }

    /// LCS（最长公共子序列）相似度，适应插入/删除/替换
    private func lcsSimilarity(_ a: String, _ b: String) -> Double {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        let maxLen = max(m, n)
        guard maxLen > 0 else { return 1.0 }

        // 空间优化的 LCS：只用两行
        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            prev = curr
            curr = [Int](repeating: 0, count: n + 1)
        }

        return Double(prev[n]) / Double(maxLen)
    }

    /// 简单逐位相似度（用于 saveCorrection 的 quality 评分）
    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        return lcsSimilarity(a, b)
    }
}
