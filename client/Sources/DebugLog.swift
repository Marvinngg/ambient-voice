import Foundation

enum DebugLog {
    enum Category: String {
        case pipeline = "Pipeline"
        case meeting = "Meeting"
        case correction = "Correction"
    }
    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".we/debug.log")

    static func log(_ category: Category, _ message: String, level: Level = .info) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) [\(level.rawValue)] [WE:\(category.rawValue)] \(message)\n"
        // Also print to Logger for backward compat
        Logger.log(category.rawValue, message)
        // Append to debug.log
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}
