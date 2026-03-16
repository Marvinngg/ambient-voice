import Foundation

/// Per-app 纠错捕获策略
///
/// 不同 App 的提交行为差异很大：
/// - IM 类（微信/Telegram/Slack）：Enter 发送
/// - 终端（Terminal/Ghostty）：Enter 执行命令，需要 edit-detection 模式
/// - 编辑器（VS Code/Xcode）：Cmd+Enter 运行
/// - 笔记类（Notes/TextEdit）：无提交信号，靠 focusChange 或超时
struct CaptureProfile: Sendable {

    enum SubmitSignal: String, Sendable {
        case enter          // Enter 键
        case cmdEnter       // Cmd+Enter
        case focusChange    // 用户切走应用
        case none           // 无提交信号，仅靠超时
    }

    let bundleID: String
    let submitSignal: SubmitSignal
    let captureTimeout: TimeInterval
    let enabled: Bool

    /// 未知 App 的默认 profile
    static let `default` = CaptureProfile(
        bundleID: "*",
        submitSignal: .enter,
        captureTimeout: 30,
        enabled: true
    )

    /// 内置 App 适配表（基于实际使用经验）
    static let builtIn: [CaptureProfile] = [
        // 终端类：Enter 执行命令，用 edit-detection + shell hook
        CaptureProfile(bundleID: "com.apple.Terminal", submitSignal: .enter, captureTimeout: 30, enabled: true),
        CaptureProfile(bundleID: "com.googlecode.iterm2", submitSignal: .enter, captureTimeout: 30, enabled: true),
        CaptureProfile(bundleID: "com.mitchellh.ghostty", submitSignal: .enter, captureTimeout: 30, enabled: true),

        // IM 类：Enter 发送，超时短一些
        CaptureProfile(bundleID: "com.tencent.xinWeChat", submitSignal: .enter, captureTimeout: 15, enabled: true),
        CaptureProfile(bundleID: "com.tinyspeck.slackmacgap", submitSignal: .enter, captureTimeout: 15, enabled: true),
        CaptureProfile(bundleID: "com.apple.MobileSMS", submitSignal: .enter, captureTimeout: 15, enabled: true),
        CaptureProfile(bundleID: "ru.keepcoder.Telegram", submitSignal: .enter, captureTimeout: 15, enabled: true),

        // 笔记/编辑器类：无明确提交信号，切换应用时捕获
        CaptureProfile(bundleID: "com.apple.Notes", submitSignal: .focusChange, captureTimeout: 60, enabled: true),
        CaptureProfile(bundleID: "com.apple.TextEdit", submitSignal: .focusChange, captureTimeout: 60, enabled: true),

        // IDE 类：Cmd+Enter
        CaptureProfile(bundleID: "com.microsoft.VSCode", submitSignal: .cmdEnter, captureTimeout: 30, enabled: true),
        CaptureProfile(bundleID: "com.apple.dt.Xcode", submitSignal: .cmdEnter, captureTimeout: 30, enabled: true),

        // 浏览器
        CaptureProfile(bundleID: "com.apple.Safari", submitSignal: .enter, captureTimeout: 30, enabled: true),
        CaptureProfile(bundleID: "com.google.Chrome", submitSignal: .enter, captureTimeout: 30, enabled: true),
    ]

    /// 按 bundleID 查找 profile
    static func profile(for bundleID: String) -> CaptureProfile {
        builtIn.first { $0.bundleID == bundleID } ?? .default
    }
}
