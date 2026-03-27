import Foundation

struct WEConfig {
    struct MeetingConfig {
        let enabled: Bool
        let silenceThresholdMs: Int
        let chunkDurationSec: Int
        let panelOpacity: Double
        let saveAudio: Bool

        static let `default` = MeetingConfig(
            enabled: true,
            silenceThresholdMs: 1500,
            chunkDurationSec: 300,
            panelOpacity: 0.85,
            saveAudio: true
        )
    }

    let replacements: [String: String]?
    let meeting: MeetingConfig?

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".we/config.json")

    static func load() -> WEConfig {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return WEConfig(replacements: nil, meeting: .default)
        }

        let replacements = json["replacements"] as? [String: String]

        var meetingConfig: MeetingConfig = .default
        if let m = json["meeting"] as? [String: Any] {
            meetingConfig = MeetingConfig(
                enabled: m["enabled"] as? Bool ?? true,
                silenceThresholdMs: m["silence_threshold_ms"] as? Int ?? 1500,
                chunkDurationSec: m["chunk_duration_sec"] as? Int ?? 300,
                panelOpacity: m["panel_opacity"] as? Double ?? 0.85,
                saveAudio: m["save_audio"] as? Bool ?? true
            )
        }

        return WEConfig(replacements: replacements, meeting: meetingConfig)
    }
}
