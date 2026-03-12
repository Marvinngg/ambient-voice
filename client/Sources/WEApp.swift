import AppKit
import SwiftUI

@main
struct WEApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // 菜单栏应用，不显示 Dock 图标
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private let moduleManager = ModuleManager()
    private let config = RuntimeConfig.shared
    private let recordingIndicator = RecordingIndicator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初始化数据目录
        WEDataDir.ensureExists()

        // 检查权限
        let axOK = PermissionManager.checkAccessibility()
        let screenOK = PermissionManager.checkScreenCapture()
        Logger.log("WE", "Accessibility: \(axOK), Screen capture: \(screenOK)")

        // 初始化菜单栏
        statusBar = StatusBarController(moduleManager: moduleManager)

        // 注册语音模块
        let voiceModule = VoiceModule()
        voiceModule.onStateChange = { [weak self] state in
            guard let self else { return }
            let recording = state == .recording
            self.statusBar?.setRecording(recording)
            if recording {
                self.recordingIndicator.show()
            } else {
                self.recordingIndicator.hide()
            }
        }
        moduleManager.register(voiceModule)

        // 注册全局热键
        GlobalHotKey.shared.onPress = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyDown()
        }
        GlobalHotKey.shared.onRelease = { [weak self] in
            self?.moduleManager.activeModule?.onHotKeyUp()
        }
        GlobalHotKey.shared.start()

        // 启动模型服务器健康检测
        ModelServer.shared.startHealthCheck()

        // G1 ambient 模式（config 控制开关）
        if config.ambientEnabled {
            let ambient = AmbientController.shared
            ambient.onSpeechStart = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .idle else { return }
                vm.onHotKeyDown()  // 复用热键流程：开始录音
            }
            ambient.onSpeechEnd = { [weak self] in
                guard let vm = self?.moduleManager.activeModule as? VoiceModule,
                      vm.state == .recording else { return }
                vm.onHotKeyDown()  // 复用热键流程：停止并处理
            }
            ambient.start()
            Logger.log("WE", "Ambient mode: ON")
        }

        Logger.log("WE", "App launched, modules: \(moduleManager.moduleNames)")
        Logger.log("WE", "Correction capture: \(config.correctionEnabled ? "ON" : "OFF")")
        Logger.log("WE", "Server endpoint: \(config.serverConfig["endpoint"] as? String ?? "not set")")
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotKey.shared.stop()
        AmbientController.shared.stop()
        ModelServer.shared.stopHealthCheck()
        Logger.log("WE", "App terminated")
    }
}
