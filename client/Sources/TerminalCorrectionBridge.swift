import Foundation

/// 终端纠错桥接
///
/// 解决终端 App 纠错捕获的根本问题：
/// Enter 后命令已提交给 shell，AX buffer 可能已经有输出，无法可靠读取用户输入。
///
/// 工作流：
/// 1. CorrectionCapture 检测到终端 App 且 prompt 识别失败
/// 2. 写 pending 文件到 ~/.we/pending-terminal.json
/// 3. zsh preexec hook 读 pending → 对比实际执行的命令 → 写 corrections
/// 4. 下次 VoicePipeline 运行时导入 corrections
enum TerminalCorrectionBridge {

    private static let pendingURL = WEDataDir.url.appendingPathComponent("pending-terminal.json")
    private static let correctionsURL = WEDataDir.url.appendingPathComponent("terminal-corrections.jsonl")

    /// 写 pending 记录（由 CorrectionCapture 调用）
    static func writePending(insertedText: String, rawText: String, app: AppIdentity?) {
        let record: [String: Any] = [
            "inserted_text": insertedText,
            "raw_text": rawText,
            "app_bundle_id": app?.bundleID ?? "",
            "app_name": app?.appName ?? "",
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]) else {
            Logger.log("Bridge", "Failed to serialize pending record")
            return
        }

        do {
            try data.write(to: pendingURL, options: .atomic)
            Logger.log("Bridge", "Pending terminal capture written: \"\(insertedText)\"")
        } catch {
            Logger.log("Bridge", "Failed to write pending: \(error)")
        }
    }

    /// 清除 pending 文件
    static func clearPending() {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    /// 导入 shell hook 写的 corrections（由 VoicePipeline 调用）
    static func importShellCorrections() {
        guard FileManager.default.fileExists(atPath: correctionsURL.path) else { return }

        guard let data = try? Data(contentsOf: correctionsURL),
              let content = String(data: data, encoding: .utf8) else { return }

        var imported = 0
        for line in content.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let insertedText = json["inserted_text"] as? String,
                  let userCommand = json["user_command"] as? String,
                  insertedText != userCommand else { continue }

            let entry = CorrectionStore.CorrectionEntry(
                id: UUID().uuidString,
                timestamp: Date(),
                rawText: json["raw_text"] as? String ?? insertedText,
                insertedText: insertedText,
                correctedText: userCommand,
                appBundleID: json["app_bundle_id"] as? String ?? "",
                quality: json["quality"] as? Double ?? 0.8
            )
            CorrectionStore.shared.save(entry)
            imported += 1
        }

        if imported > 0 {
            Logger.log("Bridge", "Imported \(imported) terminal corrections")
            // 清空已导入的 corrections
            try? FileManager.default.removeItem(at: correctionsURL)
        }
    }
}
