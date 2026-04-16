import Foundation

class Meeting {
    let id: String
    var startDate: Date
    var endDate: Date
    var segments: [MeetingSegment] = []
    var audioChunkPaths: [String] = []

    init() {
        self.id = UUID().uuidString
        self.startDate = Date()
        self.endDate = Date()
    }

    var duration: TimeInterval {
        // 录制期间用当前时间，结束后用 endDate
        let end = (endDate.timeIntervalSince(startDate) < 1) ? Date() : endDate
        return end.timeIntervalSince(startDate)
    }

    var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
