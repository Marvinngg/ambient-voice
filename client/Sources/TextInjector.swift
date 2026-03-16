import AppKit

/// 文本注入器
///
/// 三级 fallback 策略：
/// 1. AX 插入 (kAXSelectedTextAttribute) — 不动剪贴板，最干净
/// 2. AX 菜单 (Edit > Paste) — 绕过 Secure Keyboard Entry（Ghostty/iTerm2）
/// 3. CGEvent Cmd+V — 最后兜底
///
/// 终端 App 跳过第一级（AX 写入会写到整个 buffer）
enum TextInjector {

    /// 终端类 App，AX 写入不可靠，直接走 clipboard
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
    ]

    static func isTerminalApp(_ bundleID: String) -> Bool {
        terminalBundleIDs.contains(bundleID)
    }

    @MainActor
    static func inject(text: String, to app: AppIdentity?) {
        guard !text.isEmpty else { return }

        // 非终端 App：优先尝试 AX 直接插入
        if let app, !terminalBundleIDs.contains(app.bundleID),
           tryAXInsertion(text, pid: app.processID) {
            Logger.log("Injector", "AX insert to \(app.bundleID)")
            return
        }

        // Clipboard 注入（带 AX 菜单 fallback）
        clipboardInject(text: text, app: app)
    }

    // MARK: - AX 直接插入

    /// 通过 AX API 设置 kAXSelectedTextAttribute（在光标处插入）
    private static func tryAXInsertion(_ text: String, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement
        ) == .success else { return false }

        let element = focusedElement as! AXUIElement

        // 优先：kAXSelectedTextAttribute — 在光标处插入，不覆盖已有内容
        if AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        ) == .success {
            return true
        }

        // 兜底：只在文本框为空时设置 kAXValueAttribute
        var currentValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue) == .success,
           let currentText = currentValue as? String, !currentText.isEmpty {
            return false  // 有内容，不覆盖
        }

        return AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFTypeRef
        ) == .success
    }

    // MARK: - Clipboard 注入

    private static func clipboardInject(text: String, app: AppIdentity?) {
        let pb = NSPasteboard.general
        let savedString = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)
        let changeCountAfterPaste = pb.changeCount

        // 优先：AX 菜单粘贴（绕过 Secure Keyboard Entry）
        var pasted = false
        if let pid = app?.processID {
            pasted = triggerPasteViaMenu(pid: pid)
        }

        // 兜底：CGEvent Cmd+V
        if !pasted {
            simulateCmdV()
        }

        Logger.log("Injector", "Pasted to \(app?.bundleID ?? "unknown") via \(pasted ? "AX menu" : "CGEvent")")

        // 延迟恢复剪贴板
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if pb.changeCount == changeCountAfterPaste, let saved = savedString {
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    /// 通过 AX 点击 Edit > Paste 菜单项
    /// 绕过 Secure Keyboard Entry（Ghostty/iTerm2 开启时 CGEvent 被拦截）
    private static func triggerPasteViaMenu(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        var menuBarRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement, kAXMenuBarAttribute as CFString, &menuBarRef
        ) == .success else { return false }

        var menuBarItems: AnyObject?
        guard AXUIElementCopyAttributeValue(
            menuBarRef as! AXUIElement, kAXChildrenAttribute as CFString, &menuBarItems
        ) == .success, let topMenus = menuBarItems as? [AXUIElement] else { return false }

        // 查找 Edit / 编辑 菜单
        for topMenu in topMenus {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(topMenu, kAXTitleAttribute as CFString, &title)
            guard let menuTitle = title as? String,
                  menuTitle == "Edit" || menuTitle == "编辑" else { continue }

            var submenuRef: AnyObject?
            guard AXUIElementCopyAttributeValue(
                topMenu, kAXChildrenAttribute as CFString, &submenuRef
            ) == .success,
                  let submenus = submenuRef as? [AXUIElement],
                  let editMenu = submenus.first else { continue }

            var menuItems: AnyObject?
            guard AXUIElementCopyAttributeValue(
                editMenu, kAXChildrenAttribute as CFString, &menuItems
            ) == .success, let items = menuItems as? [AXUIElement] else { continue }

            for item in items {
                var itemTitle: AnyObject?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle)
                if let t = itemTitle as? String, t == "Paste" || t == "粘贴" || t == "貼上" {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    /// CGEvent Cmd+V 模拟
    private static func simulateCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
