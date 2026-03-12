import Foundation

/// 简单日志，写入 ~/.we/debug.log + 控制台
enum Logger {
    private static let logURL = WEDataDir.url.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "we.logger", qos: .utility)
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
}
