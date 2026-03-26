import AppKit

@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let moduleManager: ModuleManager
    private let config = RuntimeConfig.shared

    private var isRecording = false

    // 会议模式
    private var meetingSession: MeetingSession?
    private let transcriptPanel = TranscriptPanelController()
    private var isMeetingActive: Bool { meetingSession?.isRunning ?? false }

    init(moduleManager: ModuleManager) {
        self.moduleManager = moduleManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        ModelServer.shared.onStatusChange = { [weak self] _ in
            self?.updateIcon()
            self?.setupMenu()
        }

        updateIcon()
        setupMenu()
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        if isRecording {
            button.title = "WE●"
            button.contentTintColor = .systemRed
            return
        }

        button.contentTintColor = nil
        switch ModelServer.shared.status {
        case .connected:
            button.title = "WE"
        case .disconnected:
            button.title = "WE·"
        case .unknown:
            button.title = "WE?"
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "WE 语音输入", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        // 服务器状态
        let serverItem = NSMenuItem(title: serverMenuTitle, action: nil, keyEquivalent: "")
        menu.addItem(serverItem)

        let modelItem = NSMenuItem(title: modelMenuTitle, action: nil, keyEquivalent: "")
        menu.addItem(modelItem)

        let reconnectItem = NSMenuItem(
            title: "检查服务器连接",
            action: #selector(checkServer),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(NSMenuItem.separator())

        // 会议模式
        if isMeetingActive {
            let stopMeeting = NSMenuItem(
                title: "结束会议",
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            stopMeeting.target = self
            menu.addItem(stopMeeting)
        } else {
            let startMeeting = NSMenuItem(
                title: "开始会议录音",
                action: #selector(toggleMeeting),
                keyEquivalent: "m"
            )
            startMeeting.target = self
            menu.addItem(startMeeting)
        }

        menu.addItem(NSMenuItem.separator())

        // 配置与数据
        let configItem = NSMenuItem(
            title: "编辑配置文件...",
            action: #selector(openConfig),
            keyEquivalent: ","
        )
        configItem.target = self
        menu.addItem(configItem)

        let dataItem = NSMenuItem(
            title: "打开数据目录...",
            action: #selector(openDataDir),
            keyEquivalent: ""
        )
        dataItem.target = self
        menu.addItem(dataItem)

        let logItem = NSMenuItem(
            title: "查看日志...",
            action: #selector(openLog),
            keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private var serverMenuTitle: String {
        let status = ModelServer.shared.status
        let endpoint = RuntimeConfig.shared.serverConfig["endpoint"] as? String ?? "未配置"
        switch status {
        case .connected:
            return "服务器：已连接 (\(endpoint))"
        case .disconnected:
            return "服务器：未连接 (\(endpoint))"
        case .unknown:
            return "服务器：检测中..."
        }
    }

    private var modelMenuTitle: String {
        let model = RuntimeConfig.shared.serverConfig["model"] as? String ?? "未配置"
        return "模型：\(model)"
    }


    @objc private func checkServer() {
        Task {
            await ModelServer.shared.checkHealth()
            setupMenu()
            updateIcon()
        }
    }

    @objc private func toggleMeeting() {
        if isMeetingActive {
            stopMeeting()
        } else {
            startMeeting()
        }
    }

    private func startMeeting() {
        let session = MeetingSession()
        self.meetingSession = session

        // 实时转写回调 → 更新面板
        var wordCount = 0
        session.onTranscriptUpdate = { [weak self] text, isFinal in
            guard let self else { return }
            if isFinal {
                wordCount += text.count
                let segment = MeetingSegment(
                    text: text,
                    startTime: self.meetingSession?.duration ?? 0,
                    endTime: self.meetingSession?.duration ?? 0,
                    speakerId: nil,
                    isFinal: true
                )
                self.transcriptPanel.appendSegment(segment)
                self.transcriptPanel.updateStatus(
                    duration: self.meetingSession?.duration ?? 0,
                    wordCount: wordCount
                )
            }
        }

        session.onDurationUpdate = { [weak self] duration in
            guard let self else { return }
            self.transcriptPanel.updateStatus(
                duration: duration,
                wordCount: wordCount
            )
        }

        // 显示转录面板
        transcriptPanel.clear()
        transcriptPanel.setRecording(true)
        transcriptPanel.show()

        Task {
            do {
                try await session.start()
                Logger.log("StatusBar", "Meeting started")
                self.setupMenu()
                self.updateMeetingIcon()
            } catch {
                Logger.log("StatusBar", "Meeting start failed: \(error)")
                self.meetingSession = nil
                self.transcriptPanel.hide()
            }
        }
    }

    private func stopMeeting() {
        guard let session = meetingSession else { return }
        transcriptPanel.setRecording(false)

        Task {
            let result = await session.stop()
            self.meetingSession = nil

            // 更新面板显示最终结果（带说话人标签）
            if !result.segments.isEmpty {
                self.transcriptPanel.updateTranscript(segments: result.segments)
            }

            // 导出 Markdown
            if let url = MeetingExporter.exportMarkdown(
                segments: result.segments,
                duration: result.duration
            ) {
                Logger.log("StatusBar", "Meeting exported: \(url.lastPathComponent)")
            }

            self.setupMenu()
            self.updateMeetingIcon()
            Logger.log("StatusBar", "Meeting stopped, \(result.segments.count) segments, \(String(format: "%.0f", result.duration))s")
        }
    }

    private func updateMeetingIcon() {
        guard let button = statusItem.button else { return }
        if isMeetingActive {
            button.title = "WE◉"
            button.contentTintColor = .systemOrange
        } else if !isRecording {
            updateIcon()
        }
    }

    @objc private func openConfig() {
        let configURL = WEDataDir.url.appendingPathComponent("config.json")
        // 确保配置文件存在
        if !FileManager.default.fileExists(atPath: configURL.path) {
            _ = RuntimeConfig.shared  // 触发默认配置创建
        }
        NSWorkspace.shared.open(configURL)
    }

    @objc private func openDataDir() {
        NSWorkspace.shared.open(WEDataDir.url)
    }

    @objc private func openLog() {
        let logURL = WEDataDir.url.appendingPathComponent("debug.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
