import Foundation

/// 会议模式 segment 级流式落盘
///
/// 每次 SegmentBuffer flush + L2 调用完成（changed/identity/failed/skipped 都写），
/// 立刻 append 一行到 `~/.we/meeting-history.jsonl`。
///
/// 数据用途：
/// - 蒸馏 / 评估 / A-B 对比（rawText vs polishedText）
/// - L2 行为监控（kind 分布、avgMs）
/// - 会议中途崩溃数据保全（流式写入，不依赖会议正常结束）
///
/// `speakerId` 留空：会议进行中 diarization 还没跑（FluidAudio 在 stop 时一次性处理）。
/// 蒸馏需要 speaker label 时，按 `audioPath + startTime/endTime` 自行回填。
struct MeetingSegmentRecord: Codable, Sendable {
    let timestamp: Date
    let meetingId: String
    let audioPath: String
    let segIndex: Int
    let startTime: TimeInterval     // 相对会议起点的秒
    let endTime: TimeInterval
    let triggerReason: String       // "pause" / "maxChars" / "final"
    let rawText: String             // SA 原始拼接（L2 输入）
    let polishedText: String?       // L2 输出，nil 表示失败
    let finalText: String           // 最终采用的文本（polished ?? rawText）
    let l2Kind: String              // "changed" / "identity" / "failed" / "skipped"
    let l2ElapsedMs: Int
}

@MainActor
final class MeetingHistory {
    private let writer = JSONLWriter(filename: "meeting-history.jsonl")

    func append(_ record: MeetingSegmentRecord) {
        writer.append(record)
        Logger.log("MeetingHistory", "appended seg=\(record.segIndex) kind=\(record.l2Kind) chars=\(record.rawText.count)")
    }
}
