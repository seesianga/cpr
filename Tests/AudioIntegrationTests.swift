import Foundation
import XCTest
@testable import LifesaverVision

final class AudioIntegrationTests: XCTestCase {
    func testEveryManifestDeliveryAssetResolvesFromApplicationBundle() throws {
        let manifest = try loadApplicationManifest()
        XCTAssertEqual(manifest.assets.count, 107)
        let resolver = BundleAudioAssetResolver(bundle: .main)

        for asset in manifest.assets {
            let cue = AudioCue(rawValue: asset.assetID)
            let channel = try XCTUnwrap(
                AudioChannel.inferred(from: cue),
                "Unknown channel for \(asset.assetID)"
            )
            let url = try XCTUnwrap(
                resolver.url(for: cue, channel: channel),
                "Missing bundled Delivery asset \(asset.assetID)"
            )
            XCTAssertEqual(url.pathExtension, "m4a")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testEveryNarrationAndSafetyVoiceHasBundledCaptionTrack() throws {
        let manifest = try loadApplicationManifest()
        let speech = manifest.assets.filter {
            $0.assetID.hasPrefix("nar.") || $0.assetID.hasPrefix("sys.")
        }
        XCTAssertEqual(speech.count, 86)
        let resolver = BundleCaptionResolver(bundle: .main)

        for asset in speech {
            XCTAssertNotNil(asset.captionFile, "Manifest caption path missing for \(asset.assetID)")
            let track = try XCTUnwrap(
                resolver.track(for: asset.assetID),
                "Missing or invalid bundled VTT for \(asset.assetID)"
            )
            XCTAssertFalse(track.cues.isEmpty, "Empty VTT for \(asset.assetID)")
            XCTAssertFalse(track.transcript.isEmpty, "Empty transcript for \(asset.assetID)")
        }
    }

    func testPreferencesPersistAllChannelsRateAndDefaultCaptions() throws {
        let suite = "AudioIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AudioPreferencesStore(defaults: defaults)

        XCTAssertEqual(store.snapshot(), .defaults)
        store.save(
            AudioPreferencesSnapshot(
                narrationVolume: 0.1,
                dialogueVolume: 0.2,
                soundEffectsVolume: 0.3,
                musicVolume: 0.4,
                narrationSpeed: 1.2,
                captionsEnabled: false
            )
        )

        XCTAssertEqual(
            AudioPreferencesStore(defaults: defaults).snapshot(),
            AudioPreferencesSnapshot(
                narrationVolume: 0.1,
                dialogueVolume: 0.2,
                soundEffectsVolume: 0.3,
                musicVolume: 0.4,
                narrationSpeed: 1.2,
                captionsEnabled: false
            )
        )
    }

    func testPreferencesClampVolumesAndConstrainNarrationRate() {
        let value = AudioPreferencesSnapshot(
            narrationVolume: -1,
            dialogueVolume: 2,
            soundEffectsVolume: .infinity,
            musicVolume: 0.4,
            narrationSpeed: 1.13,
            captionsEnabled: true
        ).normalised()

        XCTAssertEqual(value.narrationVolume, 0)
        XCTAssertEqual(value.dialogueVolume, 1)
        XCTAssertEqual(value.soundEffectsVolume, 0)
        XCTAssertEqual(value.musicVolume, 0.4)
        XCTAssertEqual(value.narrationSpeed, 1.2)
    }

    func testSpeechDucksMusicByElevenDecibelsUntilAllSpeechEnds() {
        var policy = AudioMixPolicy()
        policy.speechStarted(on: .narration)
        policy.speechStarted(on: .dialogue)
        XCTAssertTrue(policy.musicIsDucked)
        XCTAssertEqual(
            Double(policy.effectiveMusicVolume(preference: 1)),
            AudioMixPolicy.speechDuckingLinearGain,
            accuracy: 0.000_001
        )
        XCTAssertEqual(AudioMixPolicy.speechDuckingDecibels, -11)

        policy.speechEnded(on: .narration)
        XCTAssertTrue(policy.musicIsDucked)
        policy.speechEnded(on: .dialogue)
        XCTAssertFalse(policy.musicIsDucked)
        XCTAssertEqual(policy.effectiveMusicVolume(preference: 0.5), 0.5)
    }

    func testSpatialSpeechDuckDurationTracksNarrationSpeed() {
        XCTAssertEqual(
            SpatialAudioManager.wallClockDuration(
                mediaDuration: 12,
                playbackSpeed: 0.8
            ),
            15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            SpatialAudioManager.wallClockDuration(
                mediaDuration: 12,
                playbackSpeed: 1.2
            ),
            10,
            accuracy: 0.000_001
        )
    }

    func testEveryAEDCriticalStateAndSafetyCorrectionHardStopsMusic() {
        for state in AEDAudioSafetyState.allCases where state != .normal {
            var policy = AudioMixPolicy()
            policy.setAEDSafetyState(state)
            XCTAssertTrue(policy.musicRequiresHardStop, "Expected hard stop for \(state)")
            XCTAssertEqual(policy.effectiveMusicVolume(preference: 1), 0)
        }

        var policy = AudioMixPolicy()
        policy.setSafetyCriticalCorrectionActive(true)
        XCTAssertTrue(policy.musicRequiresHardStop)
        policy.setSafetyCriticalCorrectionActive(false)
        XCTAssertFalse(policy.musicRequiresHardStop)

        XCTAssertEqual(AEDAudioSafetyState.forPracticeState(.analysing), .analysing)
        XCTAssertEqual(AEDAudioSafetyState.forPracticeState(.charging), .charging)
        XCTAssertEqual(
            AEDAudioSafetyState.forPracticeState(.clearConfirmation),
            .clearConfirmation
        )
        XCTAssertEqual(
            AEDAudioSafetyState.forPracticeState(.simulatedShock),
            .simulatedShock
        )
        XCTAssertEqual(AEDAudioSafetyState.forPracticeState(.complete), .normal)
    }

    func testInactiveImmersiveAutoplayAndMissingAssetsFailGracefully() async {
        let director = SystemAudioDirector(resolver: MissingAudioResolver())
        let cue = AudioCue(rawValue: "nar.M1-B1")

        let inactive = await director.play(
            AudioPlaybackRequest(
                cue: cue,
                context: .immersive,
                autoplay: true
            )
        )
        XCTAssertEqual(inactive, .blocked(.inactiveImmersiveScene))

        await director.setImmersiveScene(active: true, isOpen: true)
        let missing = await director.play(
            AudioPlaybackRequest(
                cue: cue,
                context: .immersive,
                autoplay: true
            )
        )
        XCTAssertEqual(missing, .blocked(.missingAsset))
    }

    func testMusicStartIsRejectedDuringSafetyHardStop() async {
        let director = SystemAudioDirector(resolver: MissingAudioResolver())
        await director.setAEDSafetyState(.analysing)
        let result = await director.play(
            AudioPlaybackRequest(cue: AudioCue(rawValue: "music.scenario_bed"))
        )
        XCTAssertEqual(result, .blocked(.musicSafetyHardStop))
    }

    func testSafetyAndPlaybackRequirementsDispatchThroughAudioDirectorExistential() async {
        let director: any AudioDirector = SystemAudioDirector(
            resolver: MissingAudioResolver()
        )
        await director.setAEDSafetyState(.analysing)
        let result = await director.play(
            AudioPlaybackRequest(cue: AudioCue(rawValue: "music.scenario_bed"))
        )
        let snapshot = await director.playbackSnapshot()

        XCTAssertEqual(result, .blocked(.musicSafetyHardStop))
        XCTAssertTrue(snapshot.musicIsSafetyStopped)
    }

    func testImmersiveTeardownClearsSafetyHardStopForNextSession() async {
        let director = SystemAudioDirector(resolver: MissingAudioResolver())
        await director.setAEDSafetyState(.charging)
        await director.setSafetyCriticalCorrectionActive(true)
        let stopped = await director.playbackSnapshot()
        XCTAssertTrue(stopped.musicIsSafetyStopped)

        await director.stopAll()

        let reset = await director.playbackSnapshot()
        XCTAssertFalse(reset.musicIsSafetyStopped)
        XCTAssertFalse(reset.musicIsDucked)
        let result = await director.play(
            AudioPlaybackRequest(cue: AudioCue(rawValue: "music.scenario_bed"))
        )
        XCTAssertEqual(result, .blocked(.missingAsset))
    }

    func testVTTParserBuildsTimedCaptionsAndTranscript() throws {
        let source = """
        WEBVTT

        00:00:00.000 --> 00:00:01.500
        First caption.

        00:00:01.500 --> 00:00:03.000
        Second caption.
        """
        let track = try WebVTTParser().parse(source, assetID: "nar.test")

        XCTAssertEqual(track.cues.count, 2)
        XCTAssertEqual(track.text(at: 0.5), "First caption.")
        XCTAssertEqual(track.text(at: 2), "Second caption.")
        XCTAssertNil(track.text(at: 3))
        XCTAssertEqual(track.transcript, "First caption.\nSecond caption.")
    }

    func testMeaningfulSFXHaveVisualAndCaptionEquivalents() {
        let required = [
            "sfx.aed_analysis", "sfx.aed_case_open", "sfx.aed_charging",
            "sfx.answer_correct", "sfx.answer_incorrect", "sfx.badge_unlocked",
            "sfx.clear_cue", "sfx.connector_insert", "sfx.debrief_transition",
            "sfx.electrode_packet_open", "sfx.focus_confirm", "sfx.metronome",
            "sfx.module_complete", "sfx.pad_backing_peel", "sfx.paramedic_arrival",
            "sfx.pinch_confirm", "sfx.safety_warning"
        ]
        for id in required {
            let state = AudioVisualState.forCue(AudioCue(rawValue: id))
            XCTAssertNotNil(state)
            XCTAssertFalse(state?.stateLabel.isEmpty ?? true)
            XCTAssertFalse(state?.captionText.isEmpty ?? true)
        }
        XCTAssertNotNil(
            AudioVisualState.forCue(AudioCue(rawValue: "sfx.paramedic_arrival"))?.direction
        )
    }

    private func loadApplicationManifest() throws -> TestAudioManifest {
        let url = try XCTUnwrap(
            Bundle.main.url(
                forResource: "ELEVENLABS_AUDIO_MANIFEST",
                withExtension: "json"
            ),
            "Audio manifest is missing from the application bundle"
        )
        return try JSONDecoder().decode(
            TestAudioManifest.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct TestAudioManifest: Decodable {
    struct Asset: Decodable {
        let assetID: String
        let filename: String
        let captionFile: String?
    }

    let assets: [Asset]
}

private struct MissingAudioResolver: AudioAssetResolving {
    func url(for cue: AudioCue, channel: AudioChannel) -> URL? { nil }
}
