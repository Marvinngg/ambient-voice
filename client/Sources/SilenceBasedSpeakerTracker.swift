import Foundation

class SilenceBasedSpeakerTracker {
    private let silenceThresholdMs: Int
    private(set) var currentSpeakerIndex: Int = 0
    private var consecutiveSilenceMs: Int = 0

    init(silenceThresholdMs: Int) {
        self.silenceThresholdMs = silenceThresholdMs
    }

    /// Process silence duration, returns new speaker index if speaker changed
    func processSilence(durationMs: Int) -> Int {
        if durationMs >= silenceThresholdMs {
            if consecutiveSilenceMs < silenceThresholdMs && durationMs >= silenceThresholdMs {
                // Long silence detected — likely speaker change
                currentSpeakerIndex += 1
            }
        }
        consecutiveSilenceMs = durationMs
        return currentSpeakerIndex
    }

    func reset() {
        currentSpeakerIndex = 0
        consecutiveSilenceMs = 0
    }
}
