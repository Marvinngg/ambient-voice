import Foundation

enum ClaudeHistoryReader {
    /// Read the last user message from Claude Code history after a given date
    static func lastUserMessage(after date: Date) -> String? {
        let historyDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")

        guard FileManager.default.fileExists(atPath: historyDir.path) else { return nil }

        // Find the most recent session file
        guard let enumerator = FileManager.default.enumerator(
            at: historyDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latestFile: URL?
        var latestDate: Date = .distantPast

        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl" else { continue }
            if let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate,
               modDate > latestDate, modDate > date {
                latestDate = modDate
                latestFile = url
            }
        }

        guard let file = latestFile,
              let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        // Parse last user message from JSONL
        let lines = content.components(separatedBy: .newlines).reversed()
        for line in lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = json["role"] as? String,
                  role == "human",
                  let message = json["content"] as? String else { continue }
            return message
        }
        return nil
    }
}
