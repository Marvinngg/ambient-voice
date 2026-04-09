import Speech

/// SpeechAnalyzer 共享工具
/// VoiceSession、MeetingSession、RemoteInbox 共用的 locale 查找和模型管理
enum SpeechUtils {

    /// 查找最佳中文 locale
    static func findChineseLocale() async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let prefixes = ["zh-Hans", "zh-CN", "zh-Hant", "zh"]
        for prefix in prefixes {
            if let match = supported.first(where: { $0.identifier(.bcp47).hasPrefix(prefix) }) {
                return match
            }
        }
        return nil
    }

    /// 确保语音模型已安装
    static func ensureModelInstalled(transcriber: SpeechTranscriber, locale: Locale) async throws {
        let localeID = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: { $0.identifier(.bcp47) == localeID }) {
            return
        }
        Logger.log("Speech", "Downloading model for \(localeID)...")
        if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await downloader.downloadAndInstall()
            Logger.log("Speech", "Model downloaded")
        }
    }
}
