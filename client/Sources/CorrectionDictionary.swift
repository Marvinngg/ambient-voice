import Foundation

/// 加载 ~/.we/correction-dictionary.json
/// 文件格式：{"正确词": {"errors": [...], "frequency": N, "source": "..."}, ...}
/// 注入 SA 的 contextualStrings，用正确词作为 hint
@MainActor
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private(set) var terms: [String] = []
    private(set) var loadedPath: String?

    private init() {}

    /// 加载字典，返回是否成功
    @discardableResult
    func load(from path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.log("Dict", "Load failed: \(expanded)")
            terms = []
            loadedPath = nil
            return false
        }

        let keys = Array(json.keys)
        terms = keys
        loadedPath = expanded
        Logger.log("Dict", "Loaded \(keys.count) terms from \(expanded)")
        return true
    }
}
