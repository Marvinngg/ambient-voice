import Foundation

enum SubmitSignal: String, Codable {
    case enter
    case cmdEnter
    case focusChange
    case none
}

struct CaptureProfile {
    let enabled: Bool
    let submitSignal: SubmitSignal
    let captureTimeout: TimeInterval

    static func profile(for bundleID: String) -> CaptureProfile? {
        // Known app profiles for correction capture
        let profiles: [String: CaptureProfile] = [
            "com.apple.Terminal": CaptureProfile(enabled: true, submitSignal: .enter, captureTimeout: 30.0),
            "com.mitchellh.ghostty": CaptureProfile(enabled: true, submitSignal: .enter, captureTimeout: 30.0),
            "com.googlecode.iterm2": CaptureProfile(enabled: true, submitSignal: .enter, captureTimeout: 30.0),
            "com.microsoft.VSCode": CaptureProfile(enabled: true, submitSignal: .none, captureTimeout: 3.0),
            "com.tinyspeck.slackmacgap": CaptureProfile(enabled: true, submitSignal: .enter, captureTimeout: 3.0),
        ]
        return profiles[bundleID]
    }
}
