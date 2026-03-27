import Foundation

/// ~/.we-lite/ 数据目录管理
enum WEDataDir {
    static let url: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".we-lite")
    }()

    static func ensureExists() {
        let fm = FileManager.default
        let dirs = [
            url,
            url.appendingPathComponent("audio"),
        ]
        for dir in dirs {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        Logger.log("DataDir", "Ensured ~/.we-lite/ structure exists")
    }
}
