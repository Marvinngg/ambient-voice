import Foundation

/// 会议模式分段缓冲
/// 累积 SA final segment，按下列任一触发器 flush：
///   1. 与前一段的 audioTimeRange gap >= pauseThresholdSec，且 buffer 字数 >= minChars
///   2. buffer 字数 >= maxChars（熔断，保证 L2 不超出模型训练窗口）
///   3. 手动 flush（会议结束）
///
/// flush 产出：一个 FlushBatch，包含本批次的 rawText（所有段原文拼起来）+ 时间范围 + 触发原因
/// 下游（MeetingSession）拿到 batch 后调 L2 润色，组装成 MeetingSegment
@MainActor
final class SegmentBuffer {
    struct Entry {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    struct FlushBatch {
        let entries: [Entry]
        let rawText: String           // 所有 entry.text 拼起来
        let startTime: TimeInterval
        let endTime: TimeInterval
        let triggerReason: String     // "pause" / "maxChars" / "final"
        let pauseGapSec: Double?      // 只有 trigger=pause 时有值
    }

    // 阈值（从 config 读）
    private let pauseThresholdSec: Double
    private let maxChars: Int
    private let minChars: Int

    private var buffer: [Entry] = []
    private var flushCounter = 0

    /// flush 回调（在 MainActor 上调用）
    var onFlush: ((FlushBatch) async -> Void)?

    init(pauseThresholdSec: Double, maxChars: Int, minChars: Int) {
        self.pauseThresholdSec = pauseThresholdSec
        self.maxChars = maxChars
        self.minChars = minChars
        Logger.log("SegBuf", "init pauseSec=\(pauseThresholdSec) maxChars=\(maxChars) minChars=\(minChars)")
    }

    /// 喂入一个 final segment。内部判断是否需要 flush。
    /// 触发优先级：先检查停顿（相对于已 buffer 的 segment），再 append，再检查熔断。
    func feed(_ entry: Entry) async {
        // 先判停顿（新段的 startTime 与 buffer 末段的 endTime 比较）
        if let last = buffer.last {
            let gap = entry.startTime - last.endTime
            let bufChars = currentCharCount()
            if gap >= pauseThresholdSec, bufChars >= minChars {
                await flushInternal(trigger: "pause", pauseGap: gap)
            }
        }

        buffer.append(entry)

        // 再判熔断
        if currentCharCount() >= maxChars {
            await flushInternal(trigger: "maxChars", pauseGap: nil)
        }
    }

    /// 会议结束时冲尾（即使短于 minChars 也 flush）
    func flushFinal() async {
        if !buffer.isEmpty {
            await flushInternal(trigger: "final", pauseGap: nil)
        }
    }

    private func currentCharCount() -> Int {
        buffer.reduce(0) { $0 + $1.text.count }
    }

    private func flushInternal(trigger: String, pauseGap: Double?) async {
        guard !buffer.isEmpty else { return }
        let entries = buffer
        buffer.removeAll(keepingCapacity: true)
        flushCounter += 1

        let rawText = entries.map(\.text).joined()
        let start = entries.first?.startTime ?? 0
        let end = entries.last?.endTime ?? start

        let gapStr = pauseGap.map { String(format: "%.2f", $0) } ?? "-"
        Logger.log("SegBuf", "flush seg=\(flushCounter) trigger=\(trigger) entries=\(entries.count) chars=\(rawText.count) gap=\(gapStr)s range=[\(String(format: "%.1f", start))-\(String(format: "%.1f", end))s]")

        let batch = FlushBatch(
            entries: entries,
            rawText: rawText,
            startTime: start,
            endTime: end,
            triggerReason: trigger,
            pauseGapSec: pauseGap
        )
        await onFlush?(batch)
    }

    /// 当前缓冲状态（调试用）
    var currentState: (entries: Int, chars: Int) {
        (buffer.count, currentCharCount())
    }

    /// 本次会议累计 flush 次数（= segment 数）
    var flushCount: Int { flushCounter }
}
