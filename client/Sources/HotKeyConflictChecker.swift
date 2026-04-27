import AppKit
import Carbon

/// 系统级 symbolic hot key 冲突检测
///
/// 用 Carbon `CopySymbolicHotKeys()` 查询当前 macOS 启用的所有系统快捷键
/// （Spotlight、Mission Control、应用切换等）。MASShortcut / Karabiner-Elements
/// 等库的标准做法——动态查询系统当前状态，不硬编码。
///
/// 注意：modifier-only 热键（如 Right Option）不在 symbolic hot keys 范围，
/// 不参与检测。
enum HotKeyConflictChecker {

    /// 检测给定 HotKeyConfig 是否与当前启用的系统快捷键冲突
    static func isConflicting(_ config: HotKeyConfig) -> Bool {
        if config.isModifierOnly { return false }

        var unmanaged: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&unmanaged)
        guard status == noErr,
              let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else {
            return false
        }

        let userMods = config.deviceIndependentModifiers
        let userKeyCode = Int(config.keyCode)

        // 字段名来自 plist 约定，Carbon 公开常量在新 SDK 不再暴露
        for entry in array {
            guard let enabled = entry["enabled"] as? Bool, enabled,
                  let value = entry["value"] as? [String: Any],
                  let sysKeyCode = value["v_kCode"] as? Int,
                  let carbonMods = value["v_modifiers"] as? Int else {
                continue
            }

            let sysMods = nsModifierFlags(fromCarbon: carbonMods)
            if sysKeyCode == userKeyCode && sysMods == userMods {
                return true
            }
        }
        return false
    }

    /// Carbon modifier 位 → NSEvent.ModifierFlags（device-independent 部分）
    /// Carbon: cmdKey=1<<8, shiftKey=1<<9, alphaLock=1<<10, optionKey=1<<11, controlKey=1<<12
    private static func nsModifierFlags(fromCarbon carbon: Int) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if (carbon & cmdKey) != 0     { flags.insert(.command) }
        if (carbon & shiftKey) != 0   { flags.insert(.shift) }
        if (carbon & optionKey) != 0  { flags.insert(.option) }
        if (carbon & controlKey) != 0 { flags.insert(.control) }
        if (carbon & alphaLock) != 0  { flags.insert(.capsLock) }
        return flags.intersection(.deviceIndependentFlagsMask)
    }
}
