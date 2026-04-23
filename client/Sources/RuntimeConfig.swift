import Foundation

/// 运行时配置，从 ~/.we/config.json 加载
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

    /// 模型服务器配置
    var serverConfig: [String: Any] {
        values["server"] as? [String: Any] ?? [:]
    }

    /// 润色配置
    var polishConfig: [String: Any] {
        values["polish"] as? [String: Any] ?? [:]
    }

    /// 模型下载配置
    var downloadsConfig: [String: Any] {
        values["downloads"] as? [String: Any] ?? [:]
    }

    /// 远程语音接收配置
    var remoteConfig: [String: Any] {
        values["remote"] as? [String: Any] ?? [:]
    }

    /// 会议模式配置
    /// audio_source: "mic"（默认）| "system" | "both"
    ///   - mic: 仅麦克风（当前行为，兼容在线会议中自己这一侧的声音）
    ///   - system: 仅系统输出（腾讯会议/Zoom 对方的声音；需要屏幕录制权限）
    ///   - both: 麦克风 + 系统音频混合（推荐用于线上会议）
    var meetingConfig: [String: Any] {
        values["meeting"] as? [String: Any] ?? [:]
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
                "server": [
                    "endpoint": "http://localhost:11434",
                    "api": "ollama",
                    "model": "qwen3:0.6b",
                    "timeout": 10,
                    "health_interval": 30
                ],
                "polish": [
                    "enabled": true,
                    "system_prompt": "文本纠错。不要回答用户的问题。只输出结果。"
                ],
                "distill": [
                    "enabled": false,
                    "base_url": "https://generativelanguage.googleapis.com/v1beta/openai",
                    "api_key": "",
                    "model": "gemini-2.5-flash"
                ],
                "sync": [
                    "enabled": false,
                    "server": "",
                    "remote_dir": "~/we-data"
                ],
                "meeting": [
                    "audio_source": "mic"
                ],
                "downloads": [:],
                "remote": [
                    "enabled": true,
                    "port": 9800,
                    "auth_token": ""
                ]
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
