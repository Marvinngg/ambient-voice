import AppKit
import CoreGraphics

/// 热键配置
///
/// 两种模式：
/// 1. modifier-only（如 Right Option 单独按下）：keyCode 是 modifier 键码（61=右 option 等），modifiers 为空
/// 2. 组合键（如 Cmd+Shift+R）：keyCode 是字母/数字键码，modifiers 是 modifier 标志位集合
///
/// 存储格式（JSON in ~/.we/config.json）：
/// ```json
/// "hotkey": {
///   "keyCode": 61,
///   "modifierFlags": 0,         // NSEvent.ModifierFlags.rawValue
///   "isModifierOnly": true,
///   "displayName": "Right Option"
/// }
/// ```
struct HotKeyConfig: Codable, Equatable, Sendable {
    let keyCode: UInt16
    /// NSEvent.ModifierFlags.rawValue（不要直接存 CGEventFlags，二者位不同）
    let modifierFlags: UInt
    let isModifierOnly: Bool
    let displayName: String

    static let `default` = HotKeyConfig(
        keyCode: 61,           // Right Option
        modifierFlags: 0,
        isModifierOnly: true,
        displayName: "Right Option"
    )

    /// 从 RuntimeConfig 读取，失败返回默认
    static func load(from dict: [String: Any]) -> HotKeyConfig {
        guard let keyCode = dict["keyCode"] as? Int else {
            return .default
        }
        let modifierFlags = (dict["modifierFlags"] as? Int).map { UInt($0) } ?? 0
        let isModifierOnly = dict["isModifierOnly"] as? Bool ?? false
        let displayName = dict["displayName"] as? String ?? "Unknown"
        return HotKeyConfig(
            keyCode: UInt16(keyCode),
            modifierFlags: modifierFlags,
            isModifierOnly: isModifierOnly,
            displayName: displayName
        )
    }

    /// 序列化回 [String: Any] 写入 config.json
    func toDictionary() -> [String: Any] {
        return [
            "keyCode": Int(keyCode),
            "modifierFlags": Int(modifierFlags),
            "isModifierOnly": isModifierOnly,
            "displayName": displayName
        ]
    }

    /// CGEventFlags 表示（用于 GlobalHotKey 匹配）
    /// 注意：NSEvent.ModifierFlags 和 CGEventFlags 的 modifier 位是同一套（macOS 内部一致）
    var cgEventFlags: CGEventFlags {
        return CGEventFlags(rawValue: UInt64(modifierFlags))
    }

    /// 仅取 modifier 标志位（command/shift/option/control/capsLock）
    var deviceIndependentModifiers: NSEvent.ModifierFlags {
        return NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }
}

// MARK: - Display name 渲染

/// 把 keyCode + modifiers 渲染成人类可读字符串（"⌘⇧R" / "Right Option" 等）
enum HotKeyFormatter {

    /// 从 NSEvent 录制结果构造 displayName
    static func displayName(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isModifierOnly: Bool) -> String {
        let modifierFlags = modifiers.intersection(.deviceIndependentFlagsMask)

        if isModifierOnly {
            return modifierOnlyName(keyCode: keyCode)
        }

        var parts: [String] = []
        if modifierFlags.contains(.control) { parts.append("⌃") }
        if modifierFlags.contains(.option)  { parts.append("⌥") }
        if modifierFlags.contains(.shift)   { parts.append("⇧") }
        if modifierFlags.contains(.command) { parts.append("⌘") }
        if let key = keyName(keyCode: keyCode) {
            parts.append(key)
        } else {
            parts.append("Key \(keyCode)")
        }
        return parts.joined()
    }

    /// modifier-only 时，把 keyCode 翻译成具体 modifier 名
    private static func modifierOnlyName(keyCode: UInt16) -> String {
        switch keyCode {
        case 54: return "Right Command"   // ⌘ 右
        case 55: return "Left Command"    // ⌘ 左
        case 56: return "Left Shift"
        case 57: return "Caps Lock"
        case 58: return "Left Option"
        case 59: return "Left Control"
        case 60: return "Right Shift"
        case 61: return "Right Option"
        case 62: return "Right Control"
        case 63: return "Function (fn)"
        default: return "Modifier \(keyCode)"
        }
    }

    /// 字母/数字/常用键的可读名（来自 macOS 标准物理键码）
    private static func keyName(keyCode: UInt16) -> String? {
        // 来源：HIToolbox/Events.h kVK_* 常量
        switch keyCode {
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Escape"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 27: return "-"
        case 24: return "="
        case 33: return "["
        case 30: return "]"
        case 41: return ";"
        case 39: return "'"
        case 43: return ","
        case 47: return "."
        case 44: return "/"
        case 50: return "`"
        case 42: return "\\"
        default: return nil
        }
    }
}
