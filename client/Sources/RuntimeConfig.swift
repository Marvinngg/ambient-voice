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
    var meetingConfig: [String: Any] {
        values["meeting"] as? [String: Any] ?? [:]
    }

    /// 全局热键配置
    var hotKeyConfig: [String: Any] {
        values["hotkey"] as? [String: Any] ?? [:]
    }

    /// 持久化新的 hotkey 配置（设置窗口保存时调用）
    func updateHotKeyConfig(_ dict: [String: Any]) {
        values["hotkey"] = dict
        save()
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
                    "system_prompt": "你是语音识别纠错助手。格式要求：修正语音识别错误，只输出修正后的最终文本，不要回答问题，不要改变原意，去掉语气词，修正标点符号。",
                    "context_dictionary_enabled": false,
                    "context_dictionary_path": "~/.we/correction-dictionary.json",
                    "context_ocr_enabled": false
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
                "downloads": [:],
                "remote": [
                    "enabled": true,
                    "port": 9800,
                    "auth_token": ""
                ],
                "meeting": [
                    "l2_flush_on_pause_sec": 1.5,
                    "l2_flush_on_chars": 200,
                    "l2_min_chars": 30,
                    "audio_source": "mic"
                ],
                "hotkey": [
                    "keyCode": 61,
                    "modifierFlags": 0,
                    "isModifierOnly": true,
                    "displayName": "Right Option"
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
