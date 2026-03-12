import Foundation

/// 简单日志，写入 ~/.we/debug.log + 控制台
/// 超过 maxSize 时自动截断保留最近一半
enum Logger {
    private static let logURL = WEDataDir.url.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "we.logger", qos: .utility)
    private static let maxSize: UInt64 = 5 * 1024 * 1024  // 5 MB
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] WE:\(tag) \(message)"

        // 控制台
        print(line)

        // 文件
        queue.async {
            trimIfNeeded()
            let data = (line + "\n").data(using: .utf8) ?? Data()
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

    /// 日志超过 maxSize 时保留后半部分
    private static func trimIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxSize else { return }

        guard let data = try? Data(contentsOf: logURL) else { return }

        // 保留后半部分，从换行符处切割
        let keepFrom = data.count / 2
        if let newlineIndex = data[keepFrom...].firstIndex(of: UInt8(ascii: "\n")) {
            let trimmed = data[(newlineIndex + 1)...]
            try? trimmed.write(to: logURL)
        }
    }
}
