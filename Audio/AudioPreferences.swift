import Foundation

/// Stable keys shared by Settings and the production audio engine.
enum AudioPreferenceKeys {
    static let narrationVolume = "settings.audio.narrationVolume"
    static let dialogueVolume = "settings.audio.dialogueVolume"
    static let soundEffectsVolume = "settings.audio.soundEffectsVolume"
    static let musicVolume = "settings.audio.musicVolume"
    static let narrationSpeed = "settings.audio.narrationSpeed"
    static let captionsEnabled = "settings.accessibility.captionsEnabled"
    static let reduceMotion = "settings.accessibility.reduceMotion"
    static let highContrast = "settings.accessibility.highContrast"
}

/// A value snapshot keeps UserDefaults outside the playback implementation's hot path.
struct AudioPreferencesSnapshot: Sendable, Equatable {
    static let allowedNarrationSpeeds = [0.8, 1.0, 1.2]

    var narrationVolume: Double
    var dialogueVolume: Double
    var soundEffectsVolume: Double
    var musicVolume: Double
    var narrationSpeed: Double
    var captionsEnabled: Bool

    static let defaults = AudioPreferencesSnapshot(
        narrationVolume: 0.8,
        dialogueVolume: 0.8,
        soundEffectsVolume: 0.7,
        musicVolume: 0.5,
        narrationSpeed: 1.0,
        captionsEnabled: true
    )

    func normalised() -> Self {
        var copy = self
        copy.narrationVolume = Self.clampVolume(narrationVolume)
        copy.dialogueVolume = Self.clampVolume(dialogueVolume)
        copy.soundEffectsVolume = Self.clampVolume(soundEffectsVolume)
        copy.musicVolume = Self.clampVolume(musicVolume)
        copy.narrationSpeed = Self.allowedNarrationSpeeds.min {
            abs($0 - narrationSpeed) < abs($1 - narrationSpeed)
        } ?? 1.0
        return copy
    }

    private static func clampVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}

/// Injectable preferences persistence used by production and isolated unit tests.
struct AudioPreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot() -> AudioPreferencesSnapshot {
        let fallback = AudioPreferencesSnapshot.defaults
        return AudioPreferencesSnapshot(
            narrationVolume: number(for: AudioPreferenceKeys.narrationVolume)
                ?? fallback.narrationVolume,
            dialogueVolume: number(for: AudioPreferenceKeys.dialogueVolume)
                ?? fallback.dialogueVolume,
            soundEffectsVolume: number(for: AudioPreferenceKeys.soundEffectsVolume)
                ?? fallback.soundEffectsVolume,
            musicVolume: number(for: AudioPreferenceKeys.musicVolume)
                ?? fallback.musicVolume,
            narrationSpeed: number(for: AudioPreferenceKeys.narrationSpeed)
                ?? fallback.narrationSpeed,
            captionsEnabled: bool(for: AudioPreferenceKeys.captionsEnabled)
                ?? fallback.captionsEnabled
        ).normalised()
    }

    func save(_ snapshot: AudioPreferencesSnapshot) {
        let value = snapshot.normalised()
        defaults.set(value.narrationVolume, forKey: AudioPreferenceKeys.narrationVolume)
        defaults.set(value.dialogueVolume, forKey: AudioPreferenceKeys.dialogueVolume)
        defaults.set(value.soundEffectsVolume, forKey: AudioPreferenceKeys.soundEffectsVolume)
        defaults.set(value.musicVolume, forKey: AudioPreferenceKeys.musicVolume)
        defaults.set(value.narrationSpeed, forKey: AudioPreferenceKeys.narrationSpeed)
        defaults.set(value.captionsEnabled, forKey: AudioPreferenceKeys.captionsEnabled)
    }

    private func number(for key: String) -> Double? {
        (defaults.object(forKey: key) as? NSNumber)?.doubleValue
    }

    private func bool(for key: String) -> Bool? {
        (defaults.object(forKey: key) as? NSNumber)?.boolValue
    }
}
