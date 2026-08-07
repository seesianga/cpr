import Foundation

/// An opaque identifier for an audio asset or cue.
struct AudioCue: Hashable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Coordinates app audio without coupling feature code to an audio engine.
protocol AudioDirector: Sendable {
    func prepare() async throws
    func play(_ cue: AudioCue) async
    func stopAll() async
}

/// Silent audio implementation for previews, tests, and the phase-two scaffold.
actor NoOpAudioDirector: AudioDirector {
    func prepare() async throws {}

    func play(_ cue: AudioCue) async {}

    func stopAll() async {}
}
