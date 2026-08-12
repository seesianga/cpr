import XCTest
@testable import LifesaverVision

@MainActor
final class AEDPracticeSessionModelTests: XCTestCase {
    func testPowerOnStageUsesM5B3AndBlocksPreparationUntilActivated() throws {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: .seconds(60))
        model.prepare()

        XCTAssertEqual(model.state, .powerOn)
        XCTAssertEqual(model.powerOnInstruction?.id, "M5-B3")
        XCTAssertTrue(model.powerOnInstruction?.body.contains("switch it on") == true)
        model.completePreparation(.hairPreventsPadContact)
        XCTAssertFalse(
            model.preparationItems.first(where: {
                $0.condition == .hairPreventsPadContact
            })?.isComplete ?? true
        )

        model.pressPowerButton()

        XCTAssertEqual(model.state, .awaitingPads)
        model.stop()
    }

    func testAcceptedAEDInteractionsPublishSpatialCueSequence() throws {
        let model = preparedModel()

        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.aed_case_open")

        completePreparation(in: model)
        XCTAssertEqual(
            model.spatialCueRequest?.cue.rawValue,
            "sfx.electrode_packet_open"
        )

        // A pad that lands in its anatomical region earns the confirmation tone at the
        // moment of placement, rather than the same "it stuck" sound a misplacement gets.
        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.answer_correct")

        model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: true)
        XCTAssertEqual(model.state, .padsCorrect)
        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.connector_insert")
    }

    /// The counterpart: a misplaced pad must not sound like a correct one, or the cue
    /// stops carrying information.
    func testMisplacedPadKeepsThePlainPlacementCue() throws {
        let model = preparedModel()
        completePreparation(in: model)

        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: false)

        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.pad_backing_peel")
    }

    func testPlacementRoomTaskDoesNotResetAcceptedPreparation() {
        let model = preparedModel()
        completePreparation(in: model)
        XCTAssertTrue(model.isPreparationComplete)

        model.prepareIfNeeded()

        XCTAssertTrue(model.isPreparationComplete)
        XCTAssertEqual(model.state, .awaitingPads)
        XCTAssertTrue(model.preparationItems.allSatisfy(\.isComplete))
    }

    func testAllFiveSourceBackedPreparationItemsMustCompleteBeforePads() throws {
        let model = preparedModel()

        XCTAssertEqual(Set(model.preparationItems.map(\.condition)), Set(AEDChestCondition.allCases))
        XCTAssertTrue(
            model.preparationItems.allSatisfy { !$0.instruction.sourceReferences.isEmpty }
        )
        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
        model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: true)
        XCTAssertEqual(model.state, .awaitingPads)

        completePreparation(in: model)

        XCTAssertTrue(model.isPreparationComplete)
        XCTAssertTrue(model.preparationItems.allSatisfy(\.isComplete))
        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
        model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: true)
        XCTAssertEqual(model.state, .padsCorrect)
    }

    func testPausedSessionCannotMutatePreparationPadOrClearSweepState() {
        let model = preparedModel()
        model.setPaused(true)

        model.completePreparation(.hairPreventsPadContact)
        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
        model.confirmBystanderClear("bystander_01")
        model.activateClearZone()

        XCTAssertFalse(model.isPreparationComplete)
        XCTAssertFalse(
            model.preparationItems.first(where: {
                $0.condition == .hairPreventsPadContact
            })?.isComplete ?? true
        )
        XCTAssertEqual(model.state, .awaitingPads)
        XCTAssertFalse(model.clearZoneActivated)
        XCTAssertFalse(model.bystanderClearStates["bystander_01"] ?? true)
    }

    func testIncorrectDraggedPadsRequireRetryBeforeCorrectPlacement() {
        let model = preparedModel()
        completePreparation(in: model)

        model.placeDraggedPad(
            padName: "aed_right_pad",
            destinationZoneName: "aed_left_pad_zone"
        )
        model.placeDraggedPad(
            padName: "aed_left_pad",
            destinationZoneName: "aed_right_pad_zone"
        )
        XCTAssertEqual(model.state, .padsIncorrect)

        model.retryPadPlacement()
        XCTAssertEqual(model.state, .awaitingPads)
        model.placeDraggedPad(
            padName: "aed_right_pad",
            destinationZoneName: "aed_right_pad_zone"
        )
        model.placeDraggedPad(
            padName: "aed_left_pad",
            destinationZoneName: "aed_left_pad_zone"
        )
        XCTAssertEqual(model.state, .padsCorrect)
    }

    func testRejectedClearActivationIsNotLeftVisuallyComplete() {
        let model = modelAtPadsCorrect()

        model.activateClearZone()

        XCTAssertEqual(model.state, .padsCorrect)
        XCTAssertFalse(model.clearZoneActivated)
        XCTAssertTrue(model.criticalFailures.contains(.contactDuringAnalysis))

        confirmAllBystanders(in: model)
        model.activateClearZone()
        XCTAssertEqual(model.state, .analysing)
        XCTAssertTrue(model.clearZoneActivated)
    }

    func testRejectedChargingCompletionPreservesSweepForAccessibleRecovery() {
        let model = modelAtPadsCorrect()
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.shock)
        model.beginCharging()
        XCTAssertEqual(model.state, .charging)

        model.markBystanderTouching("bystander_01")
        model.finishCharging()
        XCTAssertEqual(model.state, .charging)
        XCTAssertFalse(model.clearZoneActivated)
        XCTAssertFalse(model.bystanderClearStates["bystander_01"] ?? true)
        XCTAssertTrue(model.bystanderClearStates["bystander_02"] ?? false)

        model.confirmBystanderClear("bystander_01")
        model.finishCharging()
        XCTAssertEqual(model.state, .clearConfirmation)
        XCTAssertFalse(model.clearZoneActivated)
        XCTAssertTrue(model.bystanderClearStates.values.allSatisfy { !$0 })

        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.pressSimulatedShockControl()
        XCTAssertEqual(model.state, .simulatedShock)
        model.resumeCompressions()
        model.finish()
        XCTAssertEqual(model.state, .complete)
    }

    func testNoShockResumeCoachingTimerFlagsDelayAndStillAllowsRecovery() async throws {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: .milliseconds(20))
        model.prepare()
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.noShock)

        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(model.state, .noShockAdvised)
        XCTAssertEqual(model.criticalFailures, [.cprNotResumed])
        model.resumeCompressions()
        model.finish()
        XCTAssertEqual(model.state, .complete)
        model.stop()
    }

    func testShockResumeCoachingTimerFlagsDelayAndStillAllowsRecovery() async throws {
        let model = modelAtPadsCorrect(resumeCoachingDelay: .milliseconds(20))
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.shock)
        model.beginCharging()
        model.finishCharging()
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.pressSimulatedShockControl()
        XCTAssertEqual(model.state, .simulatedShock)

        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(model.criticalFailures, [.cprNotResumed])
        model.resumeCompressions()
        model.finish()
        XCTAssertEqual(model.state, .complete)
        model.stop()
    }

    func testBystanderTouchStateBlocksAnalysisOutcomeAndShockUntilFreshSweep() {
        let model = modelAtPadsCorrect()
        confirmAllBystanders(in: model)
        model.activateClearZone()
        XCTAssertEqual(model.state, .analysing)

        model.markBystanderTouching("bystander_01")
        model.receiveAnalysisOutcome(.shock)
        XCTAssertEqual(model.state, .analysing)
        XCTAssertTrue(model.criticalFailures.contains(.contactDuringAnalysis))

        model.confirmBystanderClear("bystander_01")
        model.receiveAnalysisOutcome(.shock)
        model.beginCharging()
        model.finishCharging()
        XCTAssertEqual(model.state, .clearConfirmation)
        confirmAllBystanders(in: model)
        model.activateClearZone()

        model.markBystanderTouching("bystander_01")
        model.pressSimulatedShockControl()
        XCTAssertEqual(model.state, .clearConfirmation)
        XCTAssertTrue(model.criticalFailures.contains(.contactDuringShock))

        model.confirmBystanderClear("bystander_01")
        model.activateClearZone()
        model.pressSimulatedShockControl()
        XCTAssertEqual(model.state, .simulatedShock)
        model.stop()
    }

    func testBystanderTouchInvalidatesMachineLatchAndSingleConfirmCannotShock() {
        let model = modelAtPadsCorrect()
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.shock)
        model.beginCharging()
        model.finishCharging()
        confirmAllBystanders(in: model)
        model.activateClearZone()
        XCTAssertTrue(model.clearZoneActivated)

        model.markBystanderTouching("bystander_01")
        model.confirmBystanderClear("bystander_01")
        model.pressSimulatedShockControl()

        XCTAssertEqual(model.state, .clearConfirmation)
        XCTAssertFalse(model.clearZoneActivated)
        XCTAssertTrue(model.criticalFailures.contains(.shockWithoutClearCheck))

        model.activateClearZone()
        model.pressSimulatedShockControl()
        XCTAssertEqual(model.state, .simulatedShock)
        model.stop()
    }

    func testResumePromptExposesTenSecondSourceBackedCountdownAndCaption() {
        XCTAssertEqual(AEDPracticeSessionModel.defaultResumeCoachingDelay, .seconds(10))
        XCTAssertEqual(
            Set(AEDPracticeSessionModel.resumeCoachingSourceFactIDs),
            Set([
                "fact.compression.restRule",
                "fact.compression.minimiseInterruptions",
                "fact.aed.resumeAfterShock",
                "fact.aed.noShockAdvised"
            ])
        )
        let model = AEDPracticeSessionModel()
        model.prepare()
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.noShock)

        XCTAssertEqual(model.resumeCaptionCue, "Resume compressions now")
        XCTAssertEqual(model.resumeCoachingSecondsRemaining, 10)
        model.stop()
    }

    func testPausePreservesRemainingAEDResumeCoachingTime() async throws {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: .milliseconds(300))
        model.prepare()
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.noShock)

        try await Task.sleep(for: .milliseconds(210))
        model.setPaused(true)
        let pausedRemaining = model.resumeCoachingSecondsRemaining
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(model.criticalFailures.isEmpty)
        XCTAssertEqual(model.resumeCoachingSecondsRemaining, pausedRemaining)

        model.setPaused(false)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(model.criticalFailures, [.cprNotResumed])
        model.resumeCompressions()
        model.finish()
        XCTAssertEqual(model.state, .complete)
        model.stop()
    }

    func testPadDropClassifierUsesBoundsOverlapNotBroadCentreRadius() {
        let zones = [
            AEDPadDropZone(
                name: "aed_right_pad_zone",
                center: [-0.20, 0.20, -0.10],
                extents: [0.12, 0.03, 0.15]
            ),
            AEDPadDropZone(
                name: "aed_left_pad_zone",
                center: [0.22, 0.20, 0.14],
                extents: [0.14, 0.03, 0.16]
            )
        ]

        XCTAssertEqual(
            AEDPadDropZoneClassifier.nearestOverlappingZone(
                padCenter: [-0.20, 0.20, -0.10],
                padExtents: [0.10, 0.02, 0.13],
                zones: zones
            ),
            "aed_right_pad_zone"
        )
        XCTAssertNil(
            AEDPadDropZoneClassifier.nearestOverlappingZone(
                padCenter: [0, 0.60, 0],
                padExtents: [0.10, 0.02, 0.13],
                zones: zones
            )
        )
    }

    private func preparedModel() -> AEDPracticeSessionModel {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: .seconds(60))
        model.prepare()
        XCTAssertEqual(model.loadState, .ready)
        XCTAssertEqual(model.state, .powerOn)
        model.pressPowerButton()
        XCTAssertEqual(model.state, .awaitingPads)
        return model
    }

    private func modelAtPadsCorrect(
        resumeCoachingDelay: Duration = .seconds(60)
    ) -> AEDPracticeSessionModel {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: resumeCoachingDelay)
        model.prepare()
        XCTAssertEqual(model.loadState, .ready)
        model.pressPowerButton()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        XCTAssertEqual(model.state, .padsCorrect)
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
}
