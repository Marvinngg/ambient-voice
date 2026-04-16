import Cocoa
import CoreGraphics

/// 全局热键：Right Command toggle
/// 使用 CGEventTap 替代 NSEvent monitor，避免 macOS 26 下
/// AppKit GlobalObserverHandler 的 Swift actor runtime crash (Bus error)
final class GlobalHotKey: @unchecked Sendable {
    @MainActor static let shared = GlobalHotKey()

    nonisolated(unsafe) var onPress: (() -> Void)?
    nonisolated(unsafe) var onRelease: (() -> Void)?

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var isPressed = false

    @MainActor
    func start() {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: globalHotKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.log("HotKey", "Failed to create CGEventTap (check Accessibility permissions)")
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let axTrusted = AXIsProcessTrusted()
        Logger.log("HotKey", "Global hotkey started (CGEventTap, Right Command) AX=\(axTrusted)")
    }

    @MainActor
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    fileprivate func handleKeyDown(keyCode: Int64) {
        // 预留：未来可扩展按键处理
    }

    fileprivate func handleFlags(_ flags: CGEventFlags, keyCode: Int64) {
        // Debug: log all modifier key events to find the right keyCode
        if flags.contains(.maskCommand) || flags.contains(.maskAlternate) {
            Logger.log("HotKey", "Flags event: keyCode=\(keyCode), cmd=\(flags.contains(.maskCommand)), opt=\(flags.contains(.maskAlternate))")
        }
        let cmdDown = flags.contains(.maskCommand)
        let isRightCmd = keyCode == 54  // Right Command keyCode

        if cmdDown && isRightCmd && !isPressed {
            isPressed = true
            Logger.log("HotKey", "Right Command DOWN")
            // CGEventTap 回调虽在主线程但不在 GCD/Swift actor 上下文中，
            // 直接调用 @MainActor 代码会触发 runtime actor check crash。
            // DispatchQueue.main.async 让 Swift runtime 能识别 MainActor。
            if let onPress {
                DispatchQueue.main.async { onPress() }
            }
        } else if !cmdDown && isPressed {
            isPressed = false
            Logger.log("HotKey", "Right Command UP")
            if let onRelease {
                DispatchQueue.main.async { onRelease() }
            }
        }
    }
}

/// 纯 C 回调，不经过任何 Swift concurrency 路径
private func globalHotKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let hotkey = Unmanaged<GlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .flagsChanged {
        hotkey.handleFlags(event.flags, keyCode: keyCode)
    } else if type == .keyDown {
        hotkey.handleKeyDown(keyCode: keyCode)
    }

    // 超时或用户禁用后自动重新启用
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        Logger.log("HotKey", "Tap disabled (type=\(type.rawValue)), re-enabling...")
        if let tap = hotkey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
