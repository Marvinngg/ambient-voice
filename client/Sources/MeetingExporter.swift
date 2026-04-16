import Foundation

/// Exports meeting transcripts to Markdown format.
/// Format: **[MM:SS]** Speaker N: text
/// Files saved to ~/.we/meetings/{id}/transcript.md
enum MeetingExporter {

    /// Export a meeting to Markdown and save to disk.
    ///
    /// - Parameter meeting: The meeting to export.
    /// - Returns: The file path of the exported Markdown, or nil on failure.
    @discardableResult
    static func export(_ meeting: Meeting) -> String? {
        guard !meeting.segments.isEmpty else {
            DebugLog.log(.meeting, "No segments to export for meeting \(meeting.id)")
            return nil
        }

        let markdown = generateMarkdown(meeting)

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/meetings/\(meeting.id)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DebugLog.log(.meeting, "Failed to create meeting directory: \(error)", level: .error)
            return nil
        }

        let url = dir.appendingPathComponent("transcript.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            DebugLog.log(.meeting, "Exported meeting \(meeting.id) to \(url.path)")
            return url.path
        } catch {
            DebugLog.log(.meeting, "Failed to write transcript: \(error)", level: .error)
            return nil
        }
    }

    /// Generate Markdown content from a meeting.
    static func generateMarkdown(_ meeting: Meeting) -> String {
        var lines: [String] = []

        // Header
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = formatter.string(from: meeting.startDate)

        lines.append("# Meeting — \(dateStr)")
        lines.append("")
        lines.append("Duration: \(meeting.formattedDuration)")
        lines.append("Segments: \(meeting.segments.count)")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Segments
        for segment in meeting.segments where segment.isFinal {
            let timestamp = formatTimestamp(segment.timestamp)
            let speaker = "Speaker \(segment.speakerIndex + 1)"
            lines.append("**[\(timestamp)]** \(speaker): \(segment.text)")
            lines.append("")
        }

        // Footer
        if !meeting.audioChunkPaths.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("Audio chunks: \(meeting.audioChunkPaths.count)")
            for path in meeting.audioChunkPaths {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                lines.append("- `\(filename)`")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Export segments and duration directly to a Markdown file, returning the URL.
    static func exportMarkdown(segments: [MeetingSegment], duration: TimeInterval) -> URL? {
        guard !segments.isEmpty else { return nil }

        var lines: [String] = []
        let durationMin = Int(duration) / 60
        let durationSec = Int(duration) % 60

        lines.append("# Meeting Transcript")
        lines.append("")
        lines.append("Duration: \(String(format: "%02d:%02d", durationMin, durationSec))")
        lines.append("Segments: \(segments.count)")
        lines.append("")
        lines.append("---")
        lines.append("")

        for segment in segments where segment.isFinal {
            let timestamp = formatTimestamp(segment.timestamp)
            let speaker = "Speaker \(segment.speakerIndex + 1)"
            lines.append("**[\(timestamp)]** \(speaker): \(segment.text)")
            lines.append("")
        }

        let markdown = lines.joined(separator: "\n")
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/meetings/exports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(fileName).md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
