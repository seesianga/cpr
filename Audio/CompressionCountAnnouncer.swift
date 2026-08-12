import AVFoundation
import Foundation

/// Speaks the running compression tally so a learner keeping their eyes on their hands
/// still hears the count, the way an instructor counts strokes aloud.
///
/// The count is an operational tally of detected contact cycles. It says nothing about
/// compression depth, force, or recoil, none of which are physically assessed.
@MainActor
protocol CompressionCountAnnouncing: AnyObject {
    func announce(count: Int)
    func reset()
}

/// `AVSpeechSynthesizer`-backed announcer.
///
/// At practice tempo (110/min ≈ 545 ms per stroke) an utterance often cannot finish
/// before the next compression lands, so a count arriving while speech is in flight is
/// DROPPED rather than queued. Queueing would drift further behind on every stroke until
/// the spoken number no longer matched the hands, which is worse than skipping one.
@MainActor
final class SpeechCompressionCountAnnouncer: CompressionCountAnnouncing {
    private let synthesizer = AVSpeechSynthesizer()
    private let utteranceRate: Float
    private let isEnabled: Bool

    /// - Parameter utteranceRate: Faster than the system default so short numbers fit
    ///   inside a compression interval.
    init(isEnabled: Bool = true, utteranceRate: Float = 0.6) {
        self.isEnabled = isEnabled
        self.utteranceRate = utteranceRate
    }

    func announce(count: Int) {
        guard isEnabled, count > 0, !synthesizer.isSpeaking else { return }
        let utterance = AVSpeechUtterance(string: String(count))
        utterance.rate = utteranceRate
        utterance.postUtteranceDelay = 0
        utterance.preUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    func reset() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Silent announcer that records what it was asked to say, for tests and previews.
@MainActor
final class RecordingCompressionCountAnnouncer: CompressionCountAnnouncing {
    private(set) var announcedCounts: [Int] = []

    func announce(count: Int) {
        announcedCounts.append(count)
    }

    func reset() {
        announcedCounts.removeAll()
    }
}
