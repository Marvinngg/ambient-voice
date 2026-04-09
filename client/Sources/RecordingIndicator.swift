import AppKit

/// 录音指示器：模仿 macOS 原生听写的浮动面板
/// 深色毛玻璃背景 + 麦克风图标 + 脉冲动画 + 实时识别文字
@MainActor
final class RecordingIndicator {
    enum State {
        case listening
        case processing
    }

    private var window: NSWindow?
    private var pulseTimer: Timer?
    private var glowState = true
    private var indicatorView: RecordingPanelView?
    private var baseOriginY: CGFloat = 0

    func show() {
        guard window == nil else { return }

        let barSize = RecordingPanelView.barSize
        let screen = NSScreen.main ?? NSScreen.screens.first!
        baseOriginY = screen.visibleFrame.minY + 80
        let origin = NSPoint(
            x: screen.frame.midX - barSize.width / 2,
            y: baseOriginY
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: barSize),
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

        let view = RecordingPanelView(frame: NSRect(origin: .zero, size: barSize))
        panel.contentView = view
        self.indicatorView = view

        panel.orderFrontRegardless()
        self.window = panel

        setState(.listening)
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

    func updateText(_ text: String) {
        guard let view = indicatorView, let panel = window else { return }
        let newSize = view.updateTranscription(text)
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let newOrigin = NSPoint(
            x: screen.frame.midX - newSize.width / 2,
            y: baseOriginY
        )
        panel.setFrame(NSRect(origin: newOrigin, size: newSize), display: true)
    }

    func setState(_ state: State) {
        guard let view = indicatorView else { return }
        switch state {
        case .listening:
            view.setState(text: "正在聆听…", color: .systemRed, showsLoading: false)
            startPulse()
        case .processing:
            pulseTimer?.invalidate()
            pulseTimer = nil
            view.setState(text: "正在处理…", color: .systemOrange, showsLoading: true)
            view.setPulse(false)
        }
    }

    private func startPulse() {
        pulseTimer?.invalidate()
        glowState = true
        indicatorView?.setPulse(true)
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
    static let barSize = NSSize(width: 160, height: 48)
    private static let textMaxWidth: CGFloat = 400
    private static let textPadding: CGFloat = 12

    private let blurView: NSVisualEffectView
    private let dotLayer = CAShapeLayer()
    private let micView: NSImageView
    private let loadingIndicator: NSProgressIndicator
    private let statusLabel: NSTextField
    private let transcriptionLabel: NSTextField
    private var pulsing = true

    override init(frame: NSRect) {
        blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        micView = NSImageView(frame: NSRect(x: 34, y: (Self.barSize.height - 22) / 2, width: 22, height: 22))
        loadingIndicator = NSProgressIndicator(frame: NSRect(x: 35, y: (Self.barSize.height - 16) / 2, width: 16, height: 16))
        statusLabel = NSTextField(labelWithString: "正在聆听…")
        transcriptionLabel = NSTextField(wrappingLabelWithString: "")

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
        dotLayer.path = CGPath(ellipseIn: CGRect(origin: .zero, size: CGSize(width: dotSize, height: dotSize)), transform: nil)
        dotLayer.fillColor = NSColor.systemRed.cgColor
        dotLayer.frame = CGRect(x: 16, y: (Self.barSize.height - dotSize) / 2, width: dotSize, height: dotSize)
        layer?.addSublayer(dotLayer)

        // 麦克风图标
        if let micImage = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            micView.image = micImage.withSymbolConfiguration(config)
            micView.contentTintColor = .white
        }
        addSubview(micView)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.isIndeterminate = true
        loadingIndicator.appearance = NSAppearance(named: .darkAqua)
        loadingIndicator.stopAnimation(nil)
        addSubview(loadingIndicator)

        // 状态文字
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.frame = NSRect(x: 60, y: (Self.barSize.height - 18) / 2, width: 90, height: 18)
        addSubview(statusLabel)

        // 实时识别文字（初始隐藏，有内容时显示在栏上方）
        transcriptionLabel.font = .systemFont(ofSize: 13)
        transcriptionLabel.textColor = .white.withAlphaComponent(0.9)
        transcriptionLabel.backgroundColor = .clear
        transcriptionLabel.isEditable = false
        transcriptionLabel.isBordered = false
        transcriptionLabel.isHidden = true
        transcriptionLabel.maximumNumberOfLines = 0
        transcriptionLabel.cell?.lineBreakMode = .byCharWrapping
        transcriptionLabel.preferredMaxLayoutWidth = Self.textMaxWidth - Self.textPadding * 2
        addSubview(transcriptionLabel)
    }

    required init?(coder: NSCoder) { nil }

    func setPulse(_ on: Bool) {
        pulsing = on
        dotLayer.opacity = on ? 1.0 : 0.3
    }

    func setState(text: String, color: NSColor, showsLoading: Bool) {
        statusLabel.stringValue = text
        dotLayer.fillColor = color.cgColor
        micView.isHidden = showsLoading
        loadingIndicator.isHidden = !showsLoading
        if showsLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
        }
    }

    /// 更新识别文字，返回面板所需的新尺寸
    func updateTranscription(_ text: String) -> NSSize {
        let hasText = !text.isEmpty
        transcriptionLabel.isHidden = !hasText
        transcriptionLabel.stringValue = text

        guard hasText else {
            frame.size = Self.barSize
            blurView.frame = bounds
            return Self.barSize
        }

        let textWidth = Self.textMaxWidth - Self.textPadding * 2
        let textHeight = textHeightFor(text, width: textWidth)
        let totalHeight = Self.barSize.height + textHeight + Self.textPadding * 2
        let size = NSSize(width: Self.textMaxWidth, height: totalHeight)

        frame.size = size
        blurView.frame = bounds
        transcriptionLabel.frame = NSRect(
            x: Self.textPadding,
            y: Self.barSize.height + Self.textPadding,
            width: textWidth,
            height: textHeight
        )
        return size
    }

    private func textHeightFor(_ text: String, width: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: transcriptionLabel.font!]
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(rect.height)
    }
}
