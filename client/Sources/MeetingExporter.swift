import Foundation

/// 会议转录导出器
/// 支持导出为 Markdown 格式，保存到 ~/.we/meetings/
@MainActor
final class MeetingExporter {

    /// 导出会议转录为 Markdown 文件
    /// - Returns: 导出文件的 URL
    static func exportMarkdown(
        segments: [MeetingSegment],
        duration: TimeInterval,
        date: Date = Date()
    ) -> URL? {
        let dir = WEDataDir.url.appendingPathComponent("meetings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        let fileName = "\(formatter.string(from: date)).md"
        let fileURL = dir.appendingPathComponent(fileName)

        var md = "# 会议记录\n\n"
        md += "- 日期：\(formatDate(date))\n"
        md += "- 时长：\(formatDuration(duration))\n"
        md += "- 总字数：\(segments.reduce(0) { $0 + $1.text.count })\n\n"
        md += "---\n\n"

        var currentSpeaker = ""
        for segment in segments where !segment.text.isEmpty {
            let time = formatTimestamp(segment.startTime)
            let speaker = segment.speakerLabel ?? "未知"

            if speaker != currentSpeaker {
                currentSpeaker = speaker
                md += "\n### \(speaker)\n\n"
            }

            md += "`\(time)` \(segment.text)\n\n"
        }

        do {
            try md.write(to: fileURL, atomically: true, encoding: .utf8)
            Logger.log("Meeting", "Exported to \(fileURL.lastPathComponent)")
            return fileURL
        } catch {
            Logger.log("Meeting", "Export failed: \(error)")
            return nil
        }
    }

    // MARK: - 格式化

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%d小时%d分%d秒", h, m, s)
        }
        return String(format: "%d分%d秒", m, s)
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 HH:mm"
        return f.string(from: date)
    }
}
