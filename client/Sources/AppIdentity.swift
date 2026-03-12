import AppKit

/// 焦点应用身份信息，用于文本注入和按 App 路由
struct AppIdentity {
    let bundleID: String
    let appName: String
    let processID: pid_t

    /// 获取当前焦点应用
    @MainActor
    static func current() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppIdentity(
            bundleID: app.bundleIdentifier ?? "unknown",
            appName: app.localizedName ?? "unknown",
            processID: app.processIdentifier
        )
    }
}
