import Foundation
import XCTest
@testable import LifesaverVision

final class AudioIntegrationTests: XCTestCase {
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
            "sfx.aed_analysis",
            "sfx.aed_charging",
            "sfx.clear_cue",
            "sfx.paramedic_arrival",
            "sfx.safety_warning"
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
}

private struct MissingAudioResolver: AudioAssetResolving {
    func url(for cue: AudioCue, channel: AudioChannel) -> URL? { nil }
}
