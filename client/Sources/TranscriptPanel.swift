import AppKit
import SwiftUI

// MARK: - ViewModel

/// 转录面板的数据源，驱动 SwiftUI 视图刷新
@Observable
@MainActor
final class TranscriptViewModel {
    var segments: [MeetingSegment] = []
    var volatileText: String = ""
    var duration: TimeInterval = 0
    var wordCount: Int = 0
    var isRecording: Bool = false

    /// 格式化时间为 MM:SS
    func formatTimestamp(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - SwiftUI 视图

/// 转录面板内容视图
struct TranscriptContentView: View {
    let viewModel: TranscriptViewModel

    var body: some View {
        VStack(spacing: 0) {
            // 转录内容区
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(viewModel.segments) { segment in
                            segmentRow(segment)
                                .id(segment.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.segments.count) {
                    // 自动滚动到底部
                    if let last = viewModel.segments.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // 底部状态栏
            statusBar
        }
        .frame(minWidth: 300, minHeight: 200)
    }

    // MARK: - 单行转录

    @ViewBuilder
    private func segmentRow(_ segment: MeetingSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // 时间戳
            Text("[\(viewModel.formatTimestamp(segment.startTime))]")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // 说话人标签
            if let speaker = segment.speakerLabel {
                Text(speaker + ":")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
            }

            // 文本内容
            Text(segment.text)
                .font(.system(.body, design: .default))
                .foregroundStyle(segment.isFinal ? .primary : .secondary)
                .opacity(segment.isFinal ? 1.0 : 0.6)
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        HStack {
            // 录音状态
            if viewModel.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                Text("录音中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Circle()
                    .fill(.gray)
                    .frame(width: 8, height: 8)
                Text("已停止")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 时长
            Text(viewModel.formatTimestamp(viewModel.duration))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // 字数
            Text("· \(viewModel.wordCount) 字")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 面板控制器

/// 会议转录浮动面板，不抢焦点，始终置顶
@MainActor
final class TranscriptPanelController {
    private var panel: NSPanel?
    private let viewModel = TranscriptViewModel()

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.title = "WE 会议转录"
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95)
        panel.minSize = NSSize(width: 280, height: 200)

        // 居中显示
        if let screen = NSScreen.main {
            let x = screen.frame.maxX - 420
            let y = screen.frame.midY - 250
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        let hostingView = NSHostingView(rootView: TranscriptContentView(viewModel: viewModel))
        panel.contentView = hostingView
        panel.orderFrontRegardless()
        self.panel = panel

        Logger.log("Transcript", "Panel shown")
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        Logger.log("Transcript", "Panel hidden")
    }

    /// 更新转录内容
    func updateTranscript(segments: [MeetingSegment]) {
        viewModel.segments = segments
    }

    /// 追加单条转录片段
    func appendSegment(_ segment: MeetingSegment) {
        viewModel.segments.append(segment)
    }

    /// 更新底部状态栏
    func updateStatus(duration: TimeInterval, wordCount: Int) {
        viewModel.duration = duration
        viewModel.wordCount = wordCount
    }

    /// 设置录音状态
    func setRecording(_ recording: Bool) {
        viewModel.isRecording = recording
    }

    /// 清空所有转录
    func clear() {
        viewModel.segments.removeAll()
        viewModel.duration = 0
        viewModel.wordCount = 0
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }
}
