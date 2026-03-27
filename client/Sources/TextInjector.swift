import AppKit

/// 文本注入器
/// 使用 clipboard + Cmd+V 粘贴（最可靠的通用方式）
/// 粘贴后恢复原剪贴板内容
enum TextInjector {
    @MainActor
    static func inject(text: String, to app: AppIdentity?) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general

        // 保存当前剪贴板
        let savedString = pb.string(forType: .string)

        // 写入要注入的文字
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 记录粘贴后的 changeCount，用于恢复时判断剪贴板是否被其他操作修改
        let changeCountAfterPaste = pb.changeCount

        // 模拟 Cmd+V 粘贴
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        Logger.log("Injector", "Pasted to \(app?.bundleID ?? "unknown")")

        // 延迟恢复剪贴板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 只在剪贴板没被其他操作修改时恢复
            if pb.changeCount == changeCountAfterPaste, let saved = savedString {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    /// Convenience wrapper matching VoicePipeline's expected API
    @MainActor
    static func insert(_ text: String, into app: AppIdentity) {
        inject(text: text, to: app)
    }

    /// Check if the given bundle ID is a terminal application
    static func isTerminalApp(_ bundleID: String) -> Bool {
        let terminalBundleIDs = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.mitchellh.ghostty",
            "net.kovidgoyal.kitty",
            "co.zeit.hyper",
            "com.github.wez.wezterm",
            "dev.warp.Warp-Stable",
            "io.alacritty",
        ]
        return terminalBundleIDs.contains(bundleID)
    }
}
