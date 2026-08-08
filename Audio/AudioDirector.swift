@preconcurrency import AVFoundation
import Foundation

/// An opaque identifier shared by authored content, the manifest, and delivery files.
struct AudioCue: Hashable, RawRepresentable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

enum AudioChannel: String, CaseIterable, Sendable {
    case narration
    case dialogue
    case soundEffects = "sfx"
    case music

    static func inferred(from cue: AudioCue) -> AudioChannel? {
        switch cue.rawValue.split(separator: ".").first {
        case "nar": .narration
        case "sys": .dialogue
        case "sfx": .soundEffects
        case "music": .music
        default: nil
        }
    }

    var deliverySubdirectory: String { rawValue }

    var isSpeech: Bool {
        self == .narration || self == .dialogue
    }
}

enum AudioPlaybackContext: Sendable, Equatable {
    case sharedSpace
    case immersive
}

enum AEDAudioSafetyState: String, CaseIterable, Sendable, Equatable {
    case normal
    case analysing
    case charging
    case clearConfirmation
    case simulatedShock

    var requiresMusicHardStop: Bool { self != .normal }

    static func forPracticeState(_ state: AEDPracticeState?) -> AEDAudioSafetyState {
        switch state {
        case .analysing: .analysing
        case .charging: .charging
        case .clearConfirmation: .clearConfirmation
        case .simulatedShock: .simulatedShock
        default: .normal
        }
    }
}

enum AudioPlaybackBlockReason: Sendable, Equatable {
    case unknownChannel
    case missingAsset
    case inactiveImmersiveScene
    case musicSafetyHardStop
    case playerCreationFailed
}

enum AudioPlaybackResult: Sendable, Equatable {
    case started
    case blocked(AudioPlaybackBlockReason)
}

struct AudioPlaybackRequest: Sendable, Equatable {
    let cue: AudioCue
    let channel: AudioChannel?
    let context: AudioPlaybackContext
    let autoplay: Bool
    let narrationSpeed: Double?

    init(
        cue: AudioCue,
        channel: AudioChannel? = nil,
        context: AudioPlaybackContext = .sharedSpace,
        autoplay: Bool = false,
        narrationSpeed: Double? = nil
    ) {
        self.cue = cue
        self.channel = channel
        self.context = context
        self.autoplay = autoplay
        self.narrationSpeed = narrationSpeed
    }
}

/// A persistent visual counterpart is published for every meaningful delivery SFX.
struct AudioVisualState: Sendable, Equatable {
    let cue: AudioCue
    let stateLabel: String
    let captionText: String
    let direction: String?

    static func forCue(_ cue: AudioCue) -> AudioVisualState? {
        let values: [String: (String, String, String?)] = [
            "sfx.aed_analysis": ("AED analysis active", "[AED analysing]", "from the AED trainer"),
            "sfx.aed_case_open": ("AED case open", "[AED case opens]", "from the AED trainer"),
            "sfx.aed_charging": ("AED charging active", "[AED charging]", "from the AED trainer"),
            "sfx.aed_power_on": ("AED trainer switched on", "[AED power-on self-test tone]", "from the AED trainer"),
            "sfx.aed_shock_delivered": ("Simulated shock delivered", "[Simulated shock tone — no electricity]", "from the AED trainer"),
            "sfx.answer_correct": ("Answer recorded as correct", "[Correct-answer tone]", nil),
            "sfx.answer_incorrect": ("Answer needs review", "[Review-answer tone]", nil),
            "sfx.badge_unlocked": ("Internal badge earned", "[Internal badge earned]", nil),
            "sfx.clear_cue": ("Clear check required", "[Clear prompt — stand clear]", "from the AED trainer"),
            "sfx.connector_insert": ("AED connector inserted", "[AED connector clicks into place]", "from the AED trainer"),
            "sfx.debrief_transition": ("Debrief ready", "[Debrief transition]", nil),
            "sfx.electrode_packet_open": ("Electrode packet open", "[Electrode packet opens]", "near the AED trainer"),
            "sfx.focus_confirm": ("Focus confirmed", "[Focus confirmed]", nil),
            "sfx.metronome": ("Compression rhythm beat", "[Compression rhythm beat]", nil),
            "sfx.module_complete": ("Module complete", "[Module-complete tone]", nil),
            "sfx.pad_backing_peel": ("Pad backing removed", "[AED pad backing peels]", "near the AED trainer"),
            "sfx.paramedic_arrival": ("Paramedics arriving", "[Paramedics arriving from the doorway]", "from the doorway"),
            "sfx.pinch_confirm": ("Selection confirmed", "[Selection confirmed]", nil),
            "sfx.safety_warning": ("Safety correction active", "[Safety warning]", nil)
        ]
        guard let value = values[cue.rawValue] else { return nil }
        return AudioVisualState(
            cue: cue,
            stateLabel: value.0,
            captionText: value.1,
            direction: value.2
        )
    }
}

struct AudioPlaybackSnapshot: Sendable, Equatable {
    let activeCue: AudioCue?
    let channel: AudioChannel?
    let isPlaying: Bool
    let isPaused: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let lastResult: AudioPlaybackResult?
    let visualState: AudioVisualState?
    let musicIsDucked: Bool
    let musicIsSafetyStopped: Bool

    static let idle = AudioPlaybackSnapshot(
        activeCue: nil,
        channel: nil,
        isPlaying: false,
        isPaused: false,
        currentTime: 0,
        duration: 0,
        lastResult: nil,
        visualState: nil,
        musicIsDucked: false,
        musicIsSafetyStopped: false
    )
}

/// Pure policy used by the production director and unit tests.
struct AudioMixPolicy: Sendable, Equatable {
    static let speechDuckingDecibels = -11.0
    static let speechDuckingLinearGain = pow(10.0, speechDuckingDecibels / 20.0)

    private(set) var activeSpeechChannels: Set<AudioChannel> = []
    private(set) var aedSafetyState: AEDAudioSafetyState = .normal
    private(set) var safetyCriticalCorrectionActive = false

    var musicIsDucked: Bool { !activeSpeechChannels.isEmpty }
    var musicRequiresHardStop: Bool {
        aedSafetyState.requiresMusicHardStop || safetyCriticalCorrectionActive
    }

    mutating func speechStarted(on channel: AudioChannel) {
        guard channel.isSpeech else { return }
        activeSpeechChannels.insert(channel)
    }

    mutating func speechEnded(on channel: AudioChannel) {
        activeSpeechChannels.remove(channel)
    }

    mutating func setAEDSafetyState(_ state: AEDAudioSafetyState) {
        aedSafetyState = state
    }

    mutating func setSafetyCriticalCorrectionActive(_ active: Bool) {
        safetyCriticalCorrectionActive = active
    }

    func effectiveMusicVolume(preference: Double) -> Float {
        guard !musicRequiresHardStop else { return 0 }
        let gain = musicIsDucked ? Self.speechDuckingLinearGain : 1
        return Float(min(1, max(0, preference * gain)))
    }
}

protocol AudioAssetResolving: Sendable {
    func url(for cue: AudioCue, channel: AudioChannel) -> URL?
}

/// Supports both preserved resource folders and Xcode's flattened resource-copy layout.
struct BundleAudioAssetResolver: AudioAssetResolving, @unchecked Sendable {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func url(for cue: AudioCue, channel: AudioChannel) -> URL? {
        let subdirectories = [
            "Audio/Delivery/\(channel.deliverySubdirectory)",
            "Delivery/\(channel.deliverySubdirectory)",
            channel.deliverySubdirectory
        ]
        for subdirectory in subdirectories {
            if let url = bundle.url(
                forResource: cue.rawValue,
                withExtension: "m4a",
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return bundle.url(forResource: cue.rawValue, withExtension: "m4a")
    }
}

/// Coordinates non-positional app audio without exposing AVFoundation to feature code.
protocol AudioDirector: Sendable {
    func prepare() async throws
    func play(_ cue: AudioCue) async
    func play(_ request: AudioPlaybackRequest) async -> AudioPlaybackResult
    func pause(_ channel: AudioChannel) async
    func resume(_ channel: AudioChannel) async
    func replay(_ channel: AudioChannel) async
    func stop(_ channel: AudioChannel) async
    func stopAll() async
    func refreshPreferences() async
    func setImmersiveScene(active: Bool, isOpen: Bool) async
    func setAEDSafetyState(_ state: AEDAudioSafetyState) async
    func setSafetyCriticalCorrectionActive(_ active: Bool) async
    func presentVisualCue(_ cue: AudioCue) async
    func playbackSnapshot() async -> AudioPlaybackSnapshot
}

extension AudioDirector {
    func play(_ request: AudioPlaybackRequest) async -> AudioPlaybackResult {
        await play(request.cue)
        return .started
    }

    func pause(_ channel: AudioChannel) async {}
    func resume(_ channel: AudioChannel) async {}
    func replay(_ channel: AudioChannel) async {}
    func stop(_ channel: AudioChannel) async {}
    func refreshPreferences() async {}
    func setImmersiveScene(active: Bool, isOpen: Bool) async {}
    func setAEDSafetyState(_ state: AEDAudioSafetyState) async {}
    func setSafetyCriticalCorrectionActive(_ active: Bool) async {}
    func presentVisualCue(_ cue: AudioCue) async {}
    func playbackSnapshot() async -> AudioPlaybackSnapshot { .idle }
}

/// Production AVAudioPlayer implementation. Relative app gain leaves system volume intact.
actor SystemAudioDirector: AudioDirector {
    private let resolver: any AudioAssetResolving
    private let preferences: AudioPreferencesStore
    private var players: [AudioChannel: AVAudioPlayer] = [:]
    private var cues: [AudioChannel: AudioCue] = [:]
    private var completionTasks: [AudioChannel: Task<Void, Never>] = [:]
    private var mixPolicy = AudioMixPolicy()
    private var immersiveSceneActive = false
    private var immersionIsOpen = false
    private var lastResult: AudioPlaybackResult?
    private var latestChannel: AudioChannel?
    private var visualState: AudioVisualState?

    init(
        resolver: any AudioAssetResolving = BundleAudioAssetResolver(),
        preferences: AudioPreferencesStore = AudioPreferencesStore()
    ) {
        self.resolver = resolver
        self.preferences = preferences
    }

    func prepare() async throws {
        await refreshPreferences()
    }

    func play(_ cue: AudioCue) async {
        _ = await play(AudioPlaybackRequest(cue: cue))
    }

    func play(_ request: AudioPlaybackRequest) async -> AudioPlaybackResult {
        guard let channel = request.channel ?? AudioChannel.inferred(from: request.cue) else {
            return recordBlocked(.unknownChannel)
        }
        if request.context == .immersive,
           request.autoplay,
           (!immersiveSceneActive || !immersionIsOpen) {
            return recordBlocked(.inactiveImmersiveScene)
        }
        if channel == .music, mixPolicy.musicRequiresHardStop {
            return recordBlocked(.musicSafetyHardStop)
        }
        guard let url = resolver.url(for: request.cue, channel: channel) else {
            return recordBlocked(.missingAsset)
        }

        stopChannel(channel, clearVisualState: false)
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.numberOfLoops = shouldLoop(request.cue, channel: channel) ? -1 : 0
            let preference = preferences.snapshot()
            if channel == .narration {
                let requested = request.narrationSpeed ?? preference.narrationSpeed
                player.rate = Float(AudioPreferencesSnapshot.allowedNarrationSpeeds.min {
                    abs($0 - requested) < abs($1 - requested)
                } ?? 1.0)
            } else {
                player.rate = 1
            }
            players[channel] = player
            cues[channel] = request.cue
            latestChannel = channel
            if let nextVisualState = AudioVisualState.forCue(request.cue) {
                visualState = nextVisualState
            }
            if channel.isSpeech {
                mixPolicy.speechStarted(on: channel)
            }
            applyVolumes(preference)
            player.prepareToPlay()
            guard player.play() else {
                stopChannel(channel, clearVisualState: false)
                return recordBlocked(.playerCreationFailed)
            }
            lastResult = .started
            scheduleCompletion(
                for: channel,
                cue: request.cue,
                duration: wallClockDuration(
                    mediaDuration: player.duration,
                    rate: player.rate
                )
            )
            return .started
        } catch {
            stopChannel(channel, clearVisualState: false)
            return recordBlocked(.playerCreationFailed)
        }
    }

    func pause(_ channel: AudioChannel) async {
        guard let player = players[channel], player.isPlaying else { return }
        player.pause()
        completionTasks[channel]?.cancel()
        completionTasks[channel] = nil
    }

    func resume(_ channel: AudioChannel) async {
        guard let player = players[channel], !player.isPlaying else { return }
        player.play()
        if let cue = cues[channel] {
            scheduleCompletion(
                for: channel,
                cue: cue,
                duration: wallClockDuration(
                    mediaDuration: max(0, player.duration - player.currentTime),
                    rate: player.rate
                )
            )
        }
    }

    func replay(_ channel: AudioChannel) async {
        guard let player = players[channel] else { return }
        player.currentTime = 0
        player.play()
        if let cue = cues[channel] {
            scheduleCompletion(
                for: channel,
                cue: cue,
                duration: wallClockDuration(
                    mediaDuration: player.duration,
                    rate: player.rate
                )
            )
        }
    }

    func stop(_ channel: AudioChannel) async {
        stopChannel(channel)
    }

    func stopAll() async {
        for channel in AudioChannel.allCases {
            stopChannel(channel)
        }
        latestChannel = nil
        visualState = nil
        mixPolicy = AudioMixPolicy()
    }

    func refreshPreferences() async {
        applyVolumes(preferences.snapshot())
    }

    func setImmersiveScene(active: Bool, isOpen: Bool) async {
        immersiveSceneActive = active
        immersionIsOpen = isOpen
        if !active || !isOpen {
            await stopAll()
        }
    }

    func setAEDSafetyState(_ state: AEDAudioSafetyState) async {
        mixPolicy.setAEDSafetyState(state)
        if state.requiresMusicHardStop {
            stopChannel(.music, clearVisualState: false)
        }
        applyVolumes(preferences.snapshot())
    }

    func setSafetyCriticalCorrectionActive(_ active: Bool) async {
        mixPolicy.setSafetyCriticalCorrectionActive(active)
        if active {
            stopChannel(.music, clearVisualState: false)
        }
        applyVolumes(preferences.snapshot())
    }

    func presentVisualCue(_ cue: AudioCue) async {
        visualState = AudioVisualState.forCue(cue)
    }

    func playbackSnapshot() async -> AudioPlaybackSnapshot {
        guard let channel = snapshotChannel(),
              let player = players[channel],
              let cue = cues[channel]
        else {
            return AudioPlaybackSnapshot(
                activeCue: nil,
                channel: nil,
                isPlaying: false,
                isPaused: false,
                currentTime: 0,
                duration: 0,
                lastResult: lastResult,
                visualState: visualState,
                musicIsDucked: mixPolicy.musicIsDucked,
                musicIsSafetyStopped: mixPolicy.musicRequiresHardStop
            )
        }
        return AudioPlaybackSnapshot(
            activeCue: cue,
            channel: channel,
            isPlaying: player.isPlaying,
            isPaused: !player.isPlaying && player.currentTime > 0 && player.currentTime < player.duration,
            currentTime: player.currentTime,
            duration: player.duration,
            lastResult: lastResult,
            visualState: visualState,
            musicIsDucked: mixPolicy.musicIsDucked,
            musicIsSafetyStopped: mixPolicy.musicRequiresHardStop
        )
    }

    private func snapshotChannel() -> AudioChannel? {
        // Captions follow active speech even when a simultaneous SFX or music cue was
        // started later. Dialogue takes precedence for immediate safety guidance.
        for speechChannel in [AudioChannel.dialogue, .narration]
        where players[speechChannel] != nil {
            return speechChannel
        }
        if let latestChannel, players[latestChannel] != nil {
            return latestChannel
        }
        return AudioChannel.allCases.first { players[$0] != nil }
    }

    private func scheduleCompletion(
        for channel: AudioChannel,
        cue: AudioCue,
        duration: TimeInterval
    ) {
        completionTasks[channel]?.cancel()
        guard players[channel]?.numberOfLoops != -1, duration.isFinite, duration > 0 else {
            return
        }
        completionTasks[channel] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await self?.complete(channel: channel, cue: cue)
        }
    }

    private func complete(channel: AudioChannel, cue: AudioCue) {
        guard cues[channel] == cue else { return }
        stopChannel(channel, clearVisualState: false)
    }

    private func stopChannel(_ channel: AudioChannel, clearVisualState: Bool = true) {
        completionTasks[channel]?.cancel()
        completionTasks[channel] = nil
        players[channel]?.stop()
        players[channel] = nil
        cues[channel] = nil
        if channel.isSpeech {
            mixPolicy.speechEnded(on: channel)
            applyVolumes(preferences.snapshot())
        }
        if latestChannel == channel {
            latestChannel = nil
        }
        if clearVisualState {
            visualState = nil
        }
    }

    private func applyVolumes(_ preference: AudioPreferencesSnapshot) {
        players[.narration]?.volume = Float(preference.narrationVolume)
        players[.dialogue]?.volume = Float(preference.dialogueVolume)
        players[.soundEffects]?.volume = Float(preference.soundEffectsVolume)
        players[.music]?.volume = mixPolicy.effectiveMusicVolume(
            preference: preference.musicVolume
        )
    }

    private func shouldLoop(_ cue: AudioCue, channel: AudioChannel) -> Bool {
        channel == .music && cue.rawValue != "music.completion_sting"
    }

    private func wallClockDuration(mediaDuration: TimeInterval, rate: Float) -> TimeInterval {
        mediaDuration / Double(max(0.1, rate))
    }

    private func recordBlocked(_ reason: AudioPlaybackBlockReason) -> AudioPlaybackResult {
        let result = AudioPlaybackResult.blocked(reason)
        lastResult = result
        return result
    }
}

/// Silent implementation for previews and tests that do not exercise audio.
actor NoOpAudioDirector: AudioDirector {
    func prepare() async throws {}
    func play(_ cue: AudioCue) async {}
    func stopAll() async {}
}
