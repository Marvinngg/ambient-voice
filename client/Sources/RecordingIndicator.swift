import AppKit

/// 录音指示器：模仿 macOS 原生听写的浮动面板
/// 深色毛玻璃背景 + 麦克风图标 + 脉冲动画 + 文字提示
@MainActor
final class RecordingIndicator {
    private var window: NSWindow?
    private var pulseTimer: Timer?
    private var glowState = true
    private var indicatorView: RecordingPanelView?

    func show() {
        guard window == nil else { return }

        let panelSize = NSSize(width: 160, height: 48)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let origin = NSPoint(
            x: screen.frame.midX - panelSize.width / 2,
            y: screen.visibleFrame.minY + 80
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false

        let view = RecordingPanelView(frame: NSRect(origin: .zero, size: panelSize))
        panel.contentView = view
        self.indicatorView = view

        panel.orderFrontRegardless()
        self.window = panel

        startPulse()
        Logger.log("UI", "Recording indicator shown")
    }

    func hide() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        indicatorView = nil
        window?.orderOut(nil)
        window = nil
        Logger.log("UI", "Recording indicator hidden")
    }

    private func startPulse() {
        glowState = true
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.glowState.toggle()
                self.indicatorView?.setPulse(self.glowState)
            }
        }
    }
}

// MARK: - 面板视图

private class RecordingPanelView: NSView {
    private let blurView: NSVisualEffectView
    private let dotLayer = CAShapeLayer()
    private var pulsing = true

    override init(frame: NSRect) {
        blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true

        // 毛玻璃背景
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        addSubview(blurView)

        // 红色脉冲圆点
        let dotSize: CGFloat = 10
        let dotRect = CGRect(x: 16, y: (frame.height - dotSize) / 2, width: dotSize, height: dotSize)
        dotLayer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: CGSize(width: dotSize, height: dotSize)), transform: nil)
        dotLayer.fillColor = NSColor.systemRed.cgColor
        dotLayer.frame = dotRect
        layer?.addSublayer(dotLayer)

        // 麦克风图标
        let micView = NSImageView(frame: NSRect(x: 34, y: (frame.height - 22) / 2, width: 22, height: 22))
        if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            micView.image = micImage.withSymbolConfiguration(config)
            micView.contentTintColor = .white
        }
        addSubview(micView)

        // 文字
        let label = NSTextField(labelWithString: "正在聆听…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 60, y: (frame.height - 18) / 2, width: 90, height: 18)
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    func setPulse(_ on: Bool) {
        pulsing = on
        dotLayer.opacity = on ? 1.0 : 0.3
    }
}
