import AppKit
import SwiftUI

/// 热键设置窗口
///
/// 用 NSWindow + NSHostingView 嵌入 SwiftUI。和 TranscriptPanel 同样的混合栈。
@MainActor
final class HotKeySettingsWindow {
    static let shared = HotKeySettingsWindow()

    private var window: NSWindow?

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let initialConfig = HotKeyConfig.load(from: RuntimeConfig.shared.hotKeyConfig)
        let viewModel = HotKeySettingsViewModel(current: initialConfig)
        viewModel.onSave = { [weak self] newConfig in
            // 保存到 config + 重新加载 GlobalHotKey
            RuntimeConfig.shared.updateHotKeyConfig(newConfig.toDictionary())
            GlobalHotKey.shared.reload(config: newConfig)
            Logger.log("HotKey", "User saved hotkey: \(newConfig.displayName)")
            self?.close()
        }
        viewModel.onCancel = { [weak self] in
            self?.close()
        }

        let host = NSHostingView(rootView: HotKeySettingsContentView(viewModel: viewModel))
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 240)

        let win = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "WE 设置热键"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }

    func close() {
        window?.close()
        window = nil
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class HotKeySettingsViewModel {
    var current: HotKeyConfig
    var captured: HotKeyConfig?
    var conflictWarning: String?

    var onSave: ((HotKeyConfig) -> Void)?
    var onCancel: (() -> Void)?

    init(current: HotKeyConfig) {
        self.current = current
    }

    var saveDisabled: Bool {
        captured == nil || captured == current
    }

    func updateCaptured(_ config: HotKeyConfig) {
        captured = config
        if HotKeyConflictChecker.isConflicting(config) {
            conflictWarning = "该快捷键可能与系统快捷键冲突。"
        } else {
            conflictWarning = nil
        }
    }

    func save() {
        guard let c = captured else { return }
        onSave?(c)
    }

    func cancel() {
        onCancel?()
    }
}

// MARK: - SwiftUI 视图

struct HotKeySettingsContentView: View {
    @Bindable var viewModel: HotKeySettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("录音 / 停止 快捷键")
                .font(.headline)

            HotKeyRecorderView(
                current: viewModel.captured ?? viewModel.current,
                onCapture: { config in
                    viewModel.updateCaptured(config)
                }
            )

            if let w = viewModel.conflictWarning {
                HStack(alignment: .top, spacing: 6) {
                    Text("⚠️")
                    Text(w)
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }

            Text("点击按钮，按下你想要的快捷键。可以是单 modifier（如 Right Option）或组合键（如 ⌘+⇧+R）。Esc 取消。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("取消") { viewModel.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { viewModel.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.saveDisabled)
            }
        }
        .padding(20)
    }
}

// MARK: - HotKeyRecorder（录制控件）

struct HotKeyRecorderView: View {
    let current: HotKeyConfig
    let onCapture: (HotKeyConfig) -> Void

    @State private var isRecording: Bool = false
    @State private var pressedFlags: NSEvent.ModifierFlags = []
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(buttonLabel)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isRecording
                              ? Color.red.opacity(0.18)
                              : Color.gray.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isRecording ? Color.red.opacity(0.6) : Color.gray.opacity(0.3),
                                lineWidth: isRecording ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopMonitor() }
    }

    private var buttonLabel: String {
        isRecording ? "请按下快捷键…  (Esc 取消)" : current.displayName
    }

    private func toggleRecording() {
        if isRecording { stopMonitor() }
        else { startMonitor() }
    }

    private func startMonitor() {
        isRecording = true
        pressedFlags = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
            return nil  // 阻止事件传给应用
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        isRecording = false
        pressedFlags = []
    }

    private func handleEvent(_ event: NSEvent) {
        // Esc 退出录制（不捕获）
        if event.type == .keyDown && event.keyCode == 53 {
            stopMonitor()
            return
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.type == .keyDown {
            // 组合键（或纯字母键，但纯字母不推荐——仍接受，由用户决定）
            let cfg = HotKeyConfig(
                keyCode: event.keyCode,
                modifierFlags: mods.rawValue,
                isModifierOnly: false,
                displayName: HotKeyFormatter.displayName(
                    keyCode: event.keyCode,
                    modifiers: mods,
                    isModifierOnly: false
                )
            )
            onCapture(cfg)
            stopMonitor()
        } else if event.type == .flagsChanged {
            // 检测 modifier-only：先按下若干 modifier，全部松开则视为 modifier-only
            let newMods = mods
            if newMods.isEmpty && !pressedFlags.isEmpty {
                // 全部松开。捕获最近一次 flagsChanged 的 keyCode 作为 modifier 键
                let cfg = HotKeyConfig(
                    keyCode: event.keyCode,
                    modifierFlags: 0,
                    isModifierOnly: true,
                    displayName: HotKeyFormatter.displayName(
                        keyCode: event.keyCode,
                        modifiers: [],
                        isModifierOnly: true
                    )
                )
                onCapture(cfg)
                stopMonitor()
            } else {
                pressedFlags = newMods
            }
        }
    }
}
