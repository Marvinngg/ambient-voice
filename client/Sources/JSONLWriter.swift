import Foundation

/// 通用 JSONL 写入器，线程安全，支持文件滚动
final class JSONLWriter: Sendable {
    private let fileURL: URL
    private let queue: DispatchQueue
    private let encoder: JSONEncoder

    init(filename: String) {
        self.fileURL = WEDataDir.url.appendingPathComponent(filename)
        self.queue = DispatchQueue(label: "we.jsonl.\(filename)", qos: .utility)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    func append<T: Encodable & Sendable>(_ value: T) {
        queue.async { [fileURL, encoder] in
            guard var data = try? encoder.encode(value) else { return }
            data.append(0x0A)  // newline

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
