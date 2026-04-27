import Foundation

/// L2 纠错的处理类型（对照 Pipeline 的 kind 字段）
enum L2Kind: String, Sendable {
    case changed   // L2 改动了文本
    case identity  // L2 输出 == 输入
    case failed    // L2 调用失败或返回 nil
    case skipped   // polish.enabled=false 时跳过
}

/// 会议转录片段
/// 一个 MeetingSegment 对应 SegmentBuffer 的一次 flush
/// - text: 展示给用户的最终文本（L2 成功时 = L2 输出；失败/跳过时 = rawText）
/// - rawText: 本批次 SA final 段原文拼接（调试 + 蒸馏留存）
/// - l2Kind: L2 的处理结果，用于验收和日志回溯
struct MeetingSegment: Sendable, Identifiable {
    let id = UUID()
    let text: String
    let rawText: String
    let startTime: TimeInterval   // 相对于会议开始的秒数
    let endTime: TimeInterval
    let speakerId: String?        // FluidAudio 分配的说话人 ID
    let l2Kind: L2Kind
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
