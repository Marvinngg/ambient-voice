import Foundation

class ShellContext {
    let dataDir: URL

    init() {
        self.dataDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we")
    }
}
