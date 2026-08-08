import Foundation
import RealityKit

enum SpatialAudioRoute: Sendable, Equatable {
    case aedUnit
    case companionGuide
    case roomAmbience
    case paramedicDoor
}

enum SpatialAudioRoutingError: Error, Sendable, Equatable {
    case missingRouteEntity(SpatialAudioRoute)
    case unknownChannel(String)
    case missingAsset(String)
    case inactiveScene
}

/// RealityKit audio remains main-actor isolated because entities and controllers are not Sendable.
@MainActor
final class SpatialAudioManager {
    private let resolver: any AudioAssetResolving
    private let preferences: AudioPreferencesStore
    private let captions: BundleCaptionResolver
    private var routeEntities: [SpatialAudioRoute: Entity] = [:]
    private var controllers: [SpatialAudioRoute: AudioPlaybackController] = [:]
    private var ambienceDuckingTask: Task<Void, Never>?
    private(set) var sceneIsActive = false

    init(
        resolver: any AudioAssetResolving = BundleAudioAssetResolver(),
        preferences: AudioPreferencesStore = AudioPreferencesStore(),
        captions: BundleCaptionResolver = BundleCaptionResolver()
    ) {
        self.resolver = resolver
        self.preferences = preferences
        self.captions = captions
    }

    /// Configures semantic emitters once the independently loaded room is active.
    func configure(in root: Entity, sceneIsActive: Bool) {
        stopAll()
        routeEntities.removeAll(keepingCapacity: true)
        self.sceneIsActive = sceneIsActive

        if let aed = firstEntity(named: "aed_unit", in: root) {
            aed.components.set(
                SpatialAudioComponent(
                    gain: 0,
                    directLevel: 0,
                    reverbLevel: -9,
                    directivity: .beam(focus: 0.45)
                )
            )
            routeEntities[.aedUnit] = aed
        }

        if let guide = firstEntity(named: "companion_orb_bot", in: root) {
            guide.components.set(
                SpatialAudioComponent(
                    gain: -5,
                    directLevel: 0,
                    reverbLevel: -12,
                    directivity: .beam(focus: 0.2)
                )
            )
            routeEntities[.companionGuide] = guide
        }

        root.components.set(AmbientAudioComponent(gain: -18))
        routeEntities[.roomAmbience] = root

        let doorAnchor = Entity()
        doorAnchor.name = "paramedic_arrival_audio_anchor"
        doorAnchor.position = [1.8, 1.2, -2.4]
        doorAnchor.components.set(
            SpatialAudioComponent(
                gain: 0,
                directLevel: 0,
                reverbLevel: -7,
                directivity: .beam(focus: 0.35)
            )
        )
        root.addChild(doorAnchor)
        routeEntities[.paramedicDoor] = doorAnchor
    }

    func setSceneActive(_ active: Bool) {
        sceneIsActive = active
        if !active { stopAll() }
    }

    @discardableResult
    func play(
        _ cue: AudioCue,
        route: SpatialAudioRoute,
        shouldLoop: Bool = false
    ) async throws -> AudioPlaybackController {
        guard sceneIsActive else { throw SpatialAudioRoutingError.inactiveScene }
        guard let entity = routeEntities[route] else {
            throw SpatialAudioRoutingError.missingRouteEntity(route)
        }
        guard let channel = AudioChannel.inferred(from: cue) else {
            throw SpatialAudioRoutingError.unknownChannel(cue.rawValue)
        }
        guard let url = resolver.url(for: cue, channel: channel) else {
            throw SpatialAudioRoutingError.missingAsset(cue.rawValue)
        }

        controllers[route]?.stop()
        let configuration = AudioFileResource.Configuration(
            loadingStrategy: .preload,
            shouldLoop: shouldLoop
        )
        let resource = try await AudioFileResource(
            contentsOf: url,
            withName: cue.rawValue,
            configuration: configuration
        )
        let controller = entity.prepareAudio(resource)
        let currentPreferences = preferences.snapshot()
        controller.gain = Self.decibels(
            for: Self.volume(for: channel, preferences: currentPreferences)
        )
        if channel == .narration {
            controller.speed = currentPreferences.narrationSpeed
        }
        controller.play()
        controllers[route] = controller
        if channel.isSpeech,
           let duration = captions.track(for: cue.rawValue)?.cues.last?.endTime {
            duckRoomAmbience(for: duration)
        }
        return controller
    }

    func stop(_ route: SpatialAudioRoute) {
        controllers[route]?.stop()
        controllers[route] = nil
    }

    func stopAll() {
        ambienceDuckingTask?.cancel()
        ambienceDuckingTask = nil
        for controller in controllers.values {
            controller.stop()
        }
        controllers.removeAll(keepingCapacity: false)
    }

    private func firstEntity(named name: String, in root: Entity) -> Entity? {
        if root.name == name { return root }
        for child in root.children {
            if let match = firstEntity(named: name, in: child) {
                return match
            }
        }
        return nil
    }

    private static func volume(
        for channel: AudioChannel,
        preferences: AudioPreferencesSnapshot
    ) -> Double {
        switch channel {
        case .narration: preferences.narrationVolume
        case .dialogue: preferences.dialogueVolume
        case .soundEffects: preferences.soundEffectsVolume
        case .music: preferences.musicVolume
        }
    }

    private static func decibels(for linearVolume: Double) -> Double {
        guard linearVolume > 0 else { return -96 }
        return max(-96, 20 * log10(min(1, linearVolume)))
    }

    private func duckRoomAmbience(for duration: TimeInterval) {
        ambienceDuckingTask?.cancel()
        guard let ambience = controllers[.roomAmbience] else { return }
        let musicDecibels = Self.decibels(
            for: preferences.snapshot().musicVolume
        )
        ambience.gain = musicDecibels + AudioMixPolicy.speechDuckingDecibels
        ambienceDuckingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, duration)))
            guard !Task.isCancelled, let self else { return }
            self.controllers[.roomAmbience]?.gain = Self.decibels(
                for: self.preferences.snapshot().musicVolume
            )
            self.ambienceDuckingTask = nil
        }
    }
}
