import AppKit
import AVFoundation

/// 权限检查与引导
/// - Accessibility：用于 TextInjector (AX API) 和 CorrectionCapture
/// - Microphone：用于语音录制
/// - Screen Capture：用于 G3 屏幕上下文感知
enum PermissionManager {
    static func checkAccessibility() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            Logger.log("Permission", "Accessibility not granted, prompting...")
            let prompt = "AXTrustedCheckOptionPrompt" as CFString
            let options = [prompt: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }
        return trusted
    }

    static func checkMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            Logger.log("Permission", "Microphone denied, open System Settings")
            return false
        }
    }

    /// 请求屏幕录制权限（G3 需要）
    /// CGRequestScreenCaptureAccess() 会把 app 加入系统设置的屏幕录制列表
    /// 用户需要手动开启后重启 app 才生效
    static func checkScreenCapture() -> Bool {
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            Logger.log("Permission", "Screen capture not granted, requesting...")
            CGRequestScreenCaptureAccess()
        } else {
            Logger.log("Permission", "Screen capture: OK")
        }
        return granted
    }
}
