import XCTest
@testable import LifesaverVision

/// Coverage for the simulated AED trainer's real-world voice-prompt sequence: startup
/// guidance after the power press, analysis and shock-path prompts, no-shock path,
/// CPR coaching, and the interruption rules.
@MainActor
final class AEDVoicePromptTests: XCTestCase {

    func testPowerPressPlaysStartupGuidanceSequenceWithSelfTestTone() async throws {
        let model = makeModel()
        model.pressPowerButton()

        try await waitUntil { model.voicePromptHistory.count >= 7 }
        XCTAssertEqual(
            Array(model.voicePromptHistory.prefix(7)),
            [
                .alertTone(AEDVoicePromptScript.powerOnAlertCue),
                .voice(.callForHelp),
                .voice(.removeClothing),
                .voice(.lookAtPictures),
                .voice(.peelPad),
                .voice(.applyPads),
                .voice(.plugConnector)
            ]
        )
        model.stop()
    }

    func testPadsCorrectThenAnalysisPromptsHandsOff() async throws {
        let model = makeModel()
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        XCTAssertEqual(model.state, .padsCorrect)
        try await waitUntil { model.voicePromptHistory.contains(.voice(.doNotTouch)) }

        confirmAllBystanders(in: model)
        model.activateClearZone()
        XCTAssertEqual(model.state, .analysing)
        try await waitUntil { model.voicePromptHistory.contains(.voice(.analysing)) }
        model.stop()
    }

    func testShockPathAnnouncesChargeClearShockAndCPRCoaching() async throws {
        let model = try await modelAtArmedClearConfirmation()

        model.pressSimulatedShockControl()
        XCTAssertEqual(model.state, .simulatedShock)
        try await waitUntil {
            model.voicePromptHistory.contains(.voice(.pushHardAndFast))
        }
        let history = model.voicePromptHistory
        XCTAssertTrue(history.contains(.voice(.shockAdvised)))
        XCTAssertTrue(history.contains(.voice(.charging)))
        XCTAssertTrue(history.contains(.voice(.pressShockButton)))
        XCTAssertTrue(
            history.contains(.alertTone(AEDVoicePromptScript.shockDeliveredAlertCue))
        )
        assertOrdered(
            history,
            [.voice(.shockDelivered), .voice(.beginCPR), .voice(.pushHardAndFast)]
        )

        model.resumeCompressions()
        XCTAssertEqual(model.state, .resumeCompressions)
        try await waitUntil { model.voicePromptHistory.contains(.voice(.keepRhythm)) }
        model.stop()
    }

    func testNoShockPathCoachesImmediateCPR() async throws {
        let model = makeModel()
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.noShock)
        XCTAssertEqual(model.state, .noShockAdvised)

        try await waitUntil {
            model.voicePromptHistory.contains(.voice(.pushHardAndFast))
        }
        assertOrdered(
            model.voicePromptHistory,
            [.voice(.noShockAdvised), .voice(.beginCPR), .voice(.pushHardAndFast)]
        )
        model.stop()
    }

    func testRetryPadPlacementRepromptsPadsWithoutReplayingStartup() {
        XCTAssertEqual(
            AEDVoicePromptScript.steps(for: .awaitingPads, acceptedEvent: .retryPadPlacement),
            [.voice(.applyPads)]
        )
        XCTAssertEqual(
            AEDVoicePromptScript.steps(for: .awaitingPads, acceptedEvent: .pressPowerControl).count,
            7
        )
        // Preparation acceptances stay silent so startup guidance is never cut off.
        XCTAssertTrue(
            AEDVoicePromptScript.steps(
                for: .awaitingPads,
                acceptedEvent: .performPreparation(.dryChest)
            ).isEmpty
        )
    }

    func testEveryPromptHasTranscriptAndDialogueCue() {
        for prompt in AEDVoicePrompt.allCases {
            XCTAssertFalse(prompt.transcript.isEmpty)
            XCTAssertTrue(
                prompt.rawValue.hasPrefix("sys.aed."),
                "AED prompts route through the dialogue channel: \(prompt.rawValue)"
            )
            XCTAssertEqual(AudioChannel.inferred(from: prompt.cue), .dialogue)
        }
    }

    func testSafetyTransitionInterruptsPendingStartupPrompts() async throws {
        // Hold each step long enough that startup guidance is still mid-queue when
        // the pads land; the analysis transition must replace the pending prompts.
        let model = makeModel(stepSeconds: 0.2)
        model.pressPowerButton()
        try await waitUntil { !model.voicePromptHistory.isEmpty }

        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        XCTAssertEqual(model.state, .analysing)

        try await waitUntil(timeoutSeconds: 3) {
            model.voicePromptHistory.contains(.voice(.analysing))
        }
        let startupTail = model.voicePromptHistory.filter { $0 == .voice(.plugConnector) }
        XCTAssertTrue(
            startupTail.isEmpty,
            "Interrupted startup guidance must not keep playing after analysis begins"
        )
        model.stop()
    }

    // MARK: - Helpers

    private func waitUntil(
        timeoutSeconds: Double = 1.0,
        _ condition: () -> Bool
    ) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                return XCTFail("Timed out waiting for condition")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeModel(stepSeconds: TimeInterval = 0) -> AEDPracticeSessionModel {
        let model = AEDPracticeSessionModel(
            resumeCoachingDelay: .seconds(60),
            promptStepDuration: { _ in stepSeconds }
        )
        model.prepare()
        XCTAssertEqual(model.loadState, .ready)
        return model
    }

    /// Advances stage by stage, letting each transition's prompt play before the next
    /// input — the same pacing a real learner produces. Back-to-back transitions
    /// deliberately interrupt pending prompts, so a fully synchronous drive would
    /// discard the intermediate announcements.
    private func modelAtArmedClearConfirmation() async throws -> AEDPracticeSessionModel {
        let model = makeModel()
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.shock)
        XCTAssertEqual(model.state, .shockAdvised)
        try await waitUntil { model.voicePromptHistory.contains(.voice(.shockAdvised)) }
        model.beginCharging()
        XCTAssertEqual(model.state, .charging)
        try await waitUntil { model.voicePromptHistory.contains(.voice(.charging)) }
        model.finishCharging()
        XCTAssertEqual(model.state, .clearConfirmation)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        try await waitUntil {
            model.voicePromptHistory.contains(.voice(.pressShockButton))
        }
        return model
    }

    private func completePreparation(in model: AEDPracticeSessionModel) {
        for condition in AEDChestCondition.allCases {
            model.completePreparation(condition)
        }
    }

    private func placeCorrectPads(in model: AEDPracticeSessionModel) {
        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
        model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: true)
    }

    private func confirmAllBystanders(in model: AEDPracticeSessionModel) {
        model.confirmBystanderClear("bystander_01")
        model.confirmBystanderClear("bystander_02")
    }

    private func assertOrdered(
        _ history: [AEDPromptStep],
        _ expected: [AEDPromptStep],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var searchIndex = history.startIndex
        for step in expected {
            guard let found = history[searchIndex...].firstIndex(of: step) else {
                XCTFail(
                    "Missing or out-of-order prompt \(step) in \(history)",
                    file: file,
                    line: line
                )
                return
            }
            searchIndex = history.index(after: found)
        }
    }
}
