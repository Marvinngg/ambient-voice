import Foundation

/// 运行时配置，从 ~/.we-lite/config.json 加载
/// 支持热更新（文件变更时自动重载）
@MainActor
final class RuntimeConfig {
    static let shared = RuntimeConfig()

    private let configURL: URL
    private var values: [String: Any] = [:]
    private var fileWatcher: DispatchSourceFileSystemObject?

    /// G1 ambient 模式开关，默认关闭
    var ambientEnabled: Bool {
        values["ambient_enabled"] as? Bool ?? false
    }

    private init() {
        self.configURL = WEDataDir.url.appendingPathComponent("config.json")
        load()
        watchFile()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            // 首次运行，创建默认配置
            let defaults: [String: Any] = [
                "ambient_enabled": false
            ]
            values = defaults
            save()
            return
        }

        do {
            let data = try Data(contentsOf: configURL)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                values = json
                Logger.log("Config", "Loaded config from \(configURL.path)")
            }
        } catch {
            Logger.log("Config", "Failed to load config: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configURL, options: .atomic)
        } catch {
            Logger.log("Config", "Failed to save config: \(error)")
        }
    }

    private func watchFile() {
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.load()
            Logger.log("Config", "Config reloaded (file changed)")
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }
}
