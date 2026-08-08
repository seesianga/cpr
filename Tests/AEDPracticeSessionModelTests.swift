import XCTest
@testable import LifesaverVision

@MainActor
final class AEDPracticeSessionModelTests: XCTestCase {
    func testAcceptedAEDInteractionsPublishSpatialCueSequence() throws {
        let model = preparedModel()

        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.aed_case_open")

        completePreparation(in: model)
        XCTAssertEqual(
            model.spatialCueRequest?.cue.rawValue,
            "sfx.electrode_packet_open"
        )

        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.pad_backing_peel")

        model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: true)
        XCTAssertEqual(model.state, .padsCorrect)
        XCTAssertEqual(model.spatialCueRequest?.cue.rawValue, "sfx.connector_insert")
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

    func testPauseCancelsAndResumeRestartsAEDResumeCoachingTimer() async throws {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: .milliseconds(30))
        model.prepare()
        completePreparation(in: model)
        placeCorrectPads(in: model)
        confirmAllBystanders(in: model)
        model.activateClearZone()
        model.receiveAnalysisOutcome(.noShock)

        model.setPaused(true)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(model.criticalFailures.isEmpty)

        model.setPaused(false)
        try await Task.sleep(for: .milliseconds(70))
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
        return model
    }

    private func modelAtPadsCorrect(
        resumeCoachingDelay: Duration = .seconds(60)
    ) -> AEDPracticeSessionModel {
        let model = AEDPracticeSessionModel(resumeCoachingDelay: resumeCoachingDelay)
        model.prepare()
        XCTAssertEqual(model.loadState, .ready)
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
