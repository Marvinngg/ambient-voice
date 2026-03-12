import Foundation

/// 会议转录片段
struct MeetingSegment: Sendable, Identifiable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval   // 相对于会议开始的秒数
    let endTime: TimeInterval
    let speakerId: String?        // FluidAudio 分配的说话人 ID
    let isFinal: Bool

    /// 显示用的说话人标签
    var speakerLabel: String? {
        guard let speakerId else { return nil }
        return "说话人 \(speakerId)"
    }
}

/// 会议结果
struct MeetingResult: Sendable {
    let segments: [MeetingSegment]
    let duration: TimeInterval
    let audioPath: String?
    let date: Date

    init(segments: [MeetingSegment], duration: TimeInterval, audioPath: String?, date: Date = Date()) {
        self.segments = segments
        self.duration = duration
        self.audioPath = audioPath
        self.date = date
    }
}
