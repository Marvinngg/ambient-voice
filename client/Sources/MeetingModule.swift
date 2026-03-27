import Foundation

/// Meeting module: continuous recording with real-time transcription panel.
/// Activated by double-tap Right Cmd. Implements WEModule protocol.
@MainActor
final class MeetingModule: WEModule {
    let name = "Meeting"
    var isActive = false

    enum State {
        case idle, recording
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private let context: ShellContext
    private var session: MeetingSession?
    private let panel = TranscriptPanelController()
    private var timerUpdateTimer: Timer?
    private var lastMeeting: Meeting?

    init(context: ShellContext) {
        self.context = context
    }

    // MARK: - WEModule protocol

    func onHotKeyDown() {
        // Meeting mode uses double-tap, not hold — toggle on key down
        toggle()
    }

    func onHotKeyUp() {
        // No-op for meeting mode (toggle happens on key down)
    }

    // MARK: - WEModule lifecycle

    func activate() async throws {
        isActive = true
        DebugLog.log(.meeting, "MeetingModule activated")
    }

    func deactivate() async {
        if state == .recording {
            stopMeeting()
        }
        isActive = false
        DebugLog.log(.meeting, "MeetingModule deactivated")
    }

    // MARK: - Public API

    /// Toggle meeting mode on/off. Called from hotkey double-tap or menu.
    func toggle() {
        switch state {
        case .idle:
            startMeeting()
        case .recording:
            stopMeeting()
        }
    }

    /// Export the last completed meeting.
    func exportLastMeeting() -> String? {
        guard let meeting = lastMeeting else {
            DebugLog.log(.meeting, "No meeting to export")
            return nil
        }
        return MeetingExporter.export(meeting)
    }

    // MARK: - Meeting Lifecycle

    private func startMeeting() {
        let config = WEConfig.load()
        let meetingConfig = config.meeting ?? .default

        guard meetingConfig.enabled else {
            DebugLog.log(.meeting, "Meeting mode is disabled in config")
            return
        }

        let meetingSession = MeetingSession(config: meetingConfig)
        self.session = meetingSession

        // Set up callbacks
        meetingSession.onSegment = { [weak self] segment in
            self?.panel.appendSegment(segment)
        }

        // Show panel
        panel.show()

        // Start recording
        Task {
            do {
                try await meetingSession.start()
                self.state = .recording
                self.onStateChange?(.recording)
                self.startTimerUpdates()
                DebugLog.log(.meeting, "Meeting recording started")
            } catch {
                DebugLog.log(.meeting, "Failed to start meeting: \(error)", level: .error)
                panel.hide()
                self.session = nil
            }
        }
    }

    @discardableResult
    private func stopMeeting() -> Meeting? {
        guard let session else { return nil }

        timerUpdateTimer?.invalidate()
        timerUpdateTimer = nil

        let meeting = session.stop()
        self.session = nil
        self.lastMeeting = meeting

        panel.hide()

        state = .idle
        onStateChange?(.idle)

        // Auto-export
        MeetingExporter.export(meeting)

        DebugLog.log(.meeting, "Meeting stopped: \(meeting.segments.count) segments, duration \(meeting.formattedDuration)")
        return meeting
    }

    private func startTimerUpdates() {
        timerUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let session = self.session else { return }
                let meeting = session.currentMeeting
                self.panel.updateStatus(duration: meeting.duration, wordCount: meeting.segments.count)
            }
        }
    }
}
