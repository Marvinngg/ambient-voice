import Foundation

/// 会议转录片段
struct MeetingSegment: Sendable, Identifiable {
    let id = UUID()
    let text: String
    let startTime: TimeInterval   // 相对于会议开始的秒数
    let endTime: TimeInterval
    let speakerId: String?        // FluidAudio 分配的说话人 ID
    let isFinal: Bool

    /// Alias: timestamp == startTime (used by MeetingSession and MeetingExporter)
    var timestamp: TimeInterval { startTime }

    /// Alias: speakerIndex derived from speakerId (used by MeetingSession and MeetingExporter)
    var speakerIndex: Int {
        guard let speakerId else { return 0 }
        return Int(speakerId) ?? 0
    }

    /// 显示用的说话人标签
    var speakerLabel: String? {
        guard let speakerId else { return nil }
        return "说话人 \(speakerId)"
    }

    /// Convenience init matching MeetingSession usage:
    /// MeetingSegment(timestamp:text:speakerIndex:isFinal:)
    init(timestamp: TimeInterval, text: String, speakerIndex: Int, isFinal: Bool) {
        self.text = text
        self.startTime = timestamp
        self.endTime = timestamp
        self.speakerId = String(speakerIndex)
        self.isFinal = isFinal
    }

    /// Full init with all fields
    init(text: String, startTime: TimeInterval, endTime: TimeInterval, speakerId: String?, isFinal: Bool) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerId = speakerId
        self.isFinal = isFinal
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
