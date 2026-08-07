import XCTest
@testable import LifesaverVision

@MainActor
final class DRSABCPracticeSessionModelTests: XCTestCase {
    func testSourceBackedCallSheetDelegationAndDispatcherContentLoads() {
        let model = preparedModel()

        XCTAssertEqual(
            DRSABCPracticeSessionModel.simulationBadge,
            "SIMULATION — no real call is made"
        )
        XCTAssertTrue(model.simulatedCallTitle.contains("SIMULATION"))
        XCTAssertTrue(model.simulatedCallBody.contains("never dials"))
        XCTAssertTrue(model.simulatedCallBody.contains("hang up only when told"))
        XCTAssertFalse(model.callSourceReferences.isEmpty)
        XCTAssertTrue(model.aedDelegationGuidance.contains("60-second walk"))
        XCTAssertTrue(model.aedDelegationGuidance.contains("lone rescuer"))
        XCTAssertTrue(model.aedDelegationGuidance.contains("dispatcher"))
        XCTAssertFalse(model.aedDelegationSourceReferences.isEmpty)
        XCTAssertFalse(model.dispatcherSourceReferences.isEmpty)

        model.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false)
        XCTAssertTrue(model.guidanceBody.contains("Tap the shoulders firmly"))
    }

    func testPausePreventsGuidedActionsFromMutatingReducer() {
        let model = preparedModel()
        model.setPaused(true)

        model.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false)

        XCTAssertEqual(model.state, .step(.danger))
        XCTAssertEqual(model.eventLogCount, 0)

        model.setPaused(false)
        model.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false)
        XCTAssertEqual(model.state, .step(.response))
        XCTAssertEqual(model.eventLogCount, 1)
    }

    func testUnsafeEntryShowsSourceReferencedCorrectionAndGuidedRetry() {
        let model = preparedModel()

        model.inspectDanger(sceneUnsafe: true, enteredUnsafeScene: true)

        XCTAssertEqual(model.activeCorrection?.code, .unsafeSceneEntry)
        XCTAssertEqual(model.activeCorrection?.sourceFactIDs, ["fact.drsabc.danger"])
        XCTAssertFalse(model.activeCorrectionSourceCitations.isEmpty)
        XCTAssertTrue(
            model.activeCorrectionSourceCitations.allSatisfy {
                !$0.document.isEmpty && !$0.edition.isEmpty &&
                    !$0.section.isEmpty && $0.page > 0
            }
        )
        XCTAssertEqual(model.criticalFailures, [.unsafeSceneEntry])

        model.confirmSceneMitigated()
        XCTAssertEqual(model.state, .step(.danger))
        model.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false)
        XCTAssertEqual(model.state, .step(.response))
    }

    func testNearFarAndLoneStayAEDBranchesAllContinueWithoutUnsafeDeparture() {
        let near = modelAtAEDDelegation()
        near.delegateAED(
            bystanderAvailable: true,
            aedNear: true,
            learnerLeavesCasualty: false
        )
        XCTAssertEqual(near.state, .step(.breathingCheck))
        XCTAssertTrue(near.criticalFailures.isEmpty)

        let far = modelAtAEDDelegation()
        far.delegateAED(
            bystanderAvailable: true,
            aedNear: false,
            learnerLeavesCasualty: false
        )
        XCTAssertEqual(far.state, .step(.breathingCheck))
        XCTAssertTrue(far.criticalFailures.isEmpty)

        let alone = modelAtAEDDelegation()
        alone.delegateAED(
            bystanderAvailable: false,
            aedNear: false,
            learnerLeavesCasualty: false
        )
        XCTAssertEqual(alone.state, .step(.breathingCheck))
        XCTAssertTrue(alone.criticalFailures.isEmpty)
    }

    func testGaspingAndNormalBreathingBranchesReachTheirDistinctTerminalSteps() {
        let gasping = modelAtBreathingCheck()
        XCTAssertTrue(gasping.guidanceBody.contains("or you are unsure"))
        gasping.assessBreathing(
            durationSeconds: 8,
            casualtyGasping: true,
            breathingNormal: false,
            treatedGaspingAsNormal: false
        )
        XCTAssertEqual(gasping.state, .step(.compressions))
        gasping.completeTerminalStep()
        XCTAssertEqual(gasping.state, .step(.complete))

        let normal = modelAtBreathingCheck()
        normal.assessBreathing(
            durationSeconds: 8,
            casualtyGasping: false,
            breathingNormal: true,
            treatedGaspingAsNormal: false
        )
        XCTAssertEqual(normal.state, .step(.monitoringNormalBreathing))
        XCTAssertTrue(normal.guidanceBody.contains("do not compress"))
        normal.completeTerminalStep()
        XCTAssertEqual(normal.state, .step(.complete))
    }

    func testEveryUnsafeDecisionCorrectionExposesDocumentLevelCitations() {
        let missedHelp = preparedModel()
        missedHelp.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false)
        missedHelp.checkResponse(isUnresponsive: true)
        missedHelp.shoutForHelp(helpActivated: false)

        let loneDeparture = modelAtAEDDelegation()
        loneDeparture.delegateAED(
            bystanderAvailable: false,
            aedNear: false,
            learnerLeavesCasualty: true
        )

        let gaspingMistake = modelAtBreathingCheck()
        gaspingMistake.assessBreathing(
            durationSeconds: 8,
            casualtyGasping: true,
            breathingNormal: true,
            treatedGaspingAsNormal: true
        )

        let prolongedCheck = modelAtBreathingCheck()
        prolongedCheck.assessBreathing(
            durationSeconds: 10.01,
            casualtyGasping: false,
            breathingNormal: false,
            treatedGaspingAsNormal: false
        )

        let fixtures: [(String, DRSABCPracticeSessionModel)] = [
            ("help not activated", missedHelp),
            ("lone rescuer departed", loneDeparture),
            ("gasping mistaken", gaspingMistake),
            ("breathing check too long", prolongedCheck)
        ]
        for (name, model) in fixtures {
            XCTAssertNotNil(model.activeCorrection, name)
            XCTAssertFalse(model.activeCorrectionSourceCitations.isEmpty, name)
            XCTAssertTrue(
                model.activeCorrectionSourceCitations.allSatisfy {
                    !$0.document.isEmpty && !$0.edition.isEmpty &&
                        !$0.section.isEmpty && $0.page > 0
                },
                name
            )
        }
    }

    private func preparedModel() -> DRSABCPracticeSessionModel {
        let model = DRSABCPracticeSessionModel()
        model.prepare()
        XCTAssertEqual(model.loadState, .ready)
        return model
    }

    private func modelAtAEDDelegation() -> DRSABCPracticeSessionModel {
        let model = preparedModel()
        model.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false)
        model.checkResponse(isUnresponsive: true)
        model.shoutForHelp(helpActivated: true)
        model.rehearseSimulatedCall()
        XCTAssertEqual(model.state, .step(.aedDelegation))
        return model
    }

    private func modelAtBreathingCheck() -> DRSABCPracticeSessionModel {
        let model = modelAtAEDDelegation()
        model.delegateAED(
            bystanderAvailable: true,
            aedNear: true,
            learnerLeavesCasualty: false
        )
        XCTAssertEqual(model.state, .step(.breathingCheck))
        return model
    }
}
