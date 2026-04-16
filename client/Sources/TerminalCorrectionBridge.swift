import Foundation

enum TerminalCorrectionBridge {
    private static let pendingFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".we/pending-correction.json")
    private static let shellCorrectionsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".we/shell-corrections.jsonl")

    /// Import corrections captured by the shell hook (we-shell-hook.zsh)
    static func importShellCorrections() {
        guard FileManager.default.fileExists(atPath: shellCorrectionsFile.path),
              let data = try? Data(contentsOf: shellCorrectionsFile),
              let content = String(data: data, encoding: .utf8),
              !content.isEmpty else { return }

        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let original = json["original"] as? String,
                  let corrected = json["corrected"] as? String,
                  original != corrected else { continue }

            let entry = CorrectionEntry(
                id: UUID().uuidString,
                timestamp: Date(),
                rawText: original,
                insertedText: original,
                userFinalText: corrected,
                quality: 0.8,
                appBundleID: "terminal",
                appName: "Shell",
                metadata: ["source": "shell-hook"]
            )
            CorrectionStore.shared.save(entry)
        }

        // Clear the file after importing
        try? "".write(to: shellCorrectionsFile, atomically: true, encoding: .utf8)
    }

    /// Write pending correction info for the shell hook to pick up
    static func writePending(insertedText: String, rawText: String, app: AppIdentity) {
        let pending: [String: String] = [
            "insertedText": insertedText,
            "rawText": rawText,
            "bundleID": app.bundleID,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: pending) {
            try? data.write(to: pendingFile)
        }
    }
}
