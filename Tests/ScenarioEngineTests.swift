import XCTest
@testable import LifesaverVision

final class ScenarioEngineTests: XCTestCase {
    func testEveryScenarioSelectsOnlyItsApprovedPatternPoolAndKeepsClinicalRulesInvariant() throws {
        let document = try ScenarioDefinitionsCodec.load()
        XCTAssertEqual(document.scenarios.count, 4)

        for definition in document.scenarios {
            var signatures: Set<String> = []
            for patternID in definition.randomisation.shockPatternIDs {
                let engine = try ScenarioEngine(
                    document: document,
                    scenarioID: definition.id,
                    selector: DeterministicScenarioPatternSelector(patternID: patternID)
                )
                XCTAssertEqual(engine.selectedPattern.id, patternID)
                XCTAssertTrue(engine.approvedPatternIDs.contains(engine.selectedPattern.id))
                XCTAssertTrue(
                    engine.selectedPattern.analysisOutcomes.allSatisfy {
                        $0 == .shock || $0 == .noShock
                    }
                )
                signatures.insert(engine.clinicalRulesSignature)
            }
            XCTAssertEqual(signatures.count, 1)
            XCTAssertEqual(
                try ScenarioEngine(
                    document: document,
                    scenarioID: definition.id,
                    selector: DeterministicScenarioPatternSelector(
                        patternID: definition.randomisation.shockPatternIDs[0]
                    )
                ).scene,
                try XCTUnwrap(ScenarioEngine.sceneByScenarioID[definition.id])
            )
        }
    }

    func testRandomSelectorNeverEscapesApprovedPool() throws {
        let document = try ScenarioDefinitionsCodec.load()
        for definition in document.scenarios {
            for _ in 0..<100 {
                let engine = try ScenarioEngine(
                    document: document,
                    scenarioID: definition.id,
                    selector: RandomScenarioPatternSelector()
                )
                XCTAssertTrue(definition.randomisation.shockPatternIDs.contains(engine.selectedPattern.id))
            }
        }
    }

    func testPatternOutcomeOrderIsDeterministicAndExhaustive() throws {
        let document = try ScenarioDefinitionsCodec.load()
        let patternID = "N-S-N"
        var engine = try ScenarioEngine(
            document: document,
            scenarioID: "scenario-a-home",
            selector: DeterministicScenarioPatternSelector(patternID: patternID)
        )

        XCTAssertEqual(try engine.nextAnalysisOutcome(), .noShock)
        XCTAssertEqual(try engine.nextAnalysisOutcome(), .shock)
        XCTAssertEqual(try engine.nextAnalysisOutcome(), .noShock)
        XCTAssertThrowsError(try engine.nextAnalysisOutcome()) { error in
            XCTAssertEqual(error as? ScenarioEngineError, .noRemainingAnalysisOutcome)
        }
    }

    func testBranchTraversalCannotSkipTheCurrentAuthoredNode() throws {
        let document = try ScenarioDefinitionsCodec.load()
        var engine = try makeEngine(document: document, scenarioID: "scenario-a-home")
        let sceneSafetyNode = "scenario-a-home-branch-scene-safety"
        let responderNode = "scenario-a-home-branch-responder-availability"

        XCTAssertEqual(engine.currentBranchNodeID, sceneSafetyNode)
        let eventCount = engine.eventLog.count
        XCTAssertThrowsError(try engine.selectBranch(condition: "bystanderAvailable")) {
            XCTAssertEqual(
                $0 as? ScenarioEngineError,
                .unknownBranchCondition("bystanderAvailable")
            )
        }
        XCTAssertEqual(engine.currentBranchNodeID, sceneSafetyNode)
        XCTAssertEqual(engine.eventLog.count, eventCount)

        XCTAssertThrowsError(
            try engine.selectBranch(
                nodeID: responderNode,
                conditionID: "scenario-a-home-branch-responder-availability-condition-bystander"
            )
        ) {
            XCTAssertEqual(
                $0 as? ScenarioEngineError,
                .branchOutOfSequence(
                    expectedNodeID: sceneSafetyNode,
                    actualNodeID: responderNode
                )
            )
        }
        XCTAssertEqual(engine.currentBranchNodeID, sceneSafetyNode)

        try engine.selectBranch(condition: "sceneSafe")
        XCTAssertEqual(engine.currentBranchNodeID, responderNode)
        try engine.selectBranch(condition: "bystanderAvailable")
        try engine.selectBranch(condition: "aedNear")
        try engine.selectBranch(condition: "normalBreathingObserved")
        XCTAssertNil(engine.currentBranchNodeID)
        XCTAssertThrowsError(try engine.selectBranch(condition: "shockOutcome")) {
            XCTAssertEqual($0 as? ScenarioEngineError, .branchSequenceComplete)
        }
    }

    func testAEDOutcomeBranchesSelfLoopOnlyAtTheReachedAnalysisNode() throws {
        let document = try ScenarioDefinitionsCodec.load()
        var engine = try makeEngine(document: document, scenarioID: "scenario-a-home")
        try engine.selectBranch(condition: "sceneSafe")
        try engine.selectBranch(condition: "rescuerAlone")
        try engine.selectBranch(condition: "aedFar")
        try engine.selectBranch(condition: "breathingAbsentAbnormalOrUncertain")

        let analysisNode = "scenario-a-home-branch-aed-analysis"
        XCTAssertEqual(engine.currentBranchNodeID, analysisNode)
        try engine.selectBranch(condition: "shockOutcome")
        XCTAssertEqual(engine.currentBranchNodeID, analysisNode)
        try engine.selectBranch(condition: "noShockOutcome")
        XCTAssertEqual(engine.currentBranchNodeID, analysisNode)
    }

    func testEveryAuthoredCriticalCodeMapsToAnExistingSystemCueFamily() throws {
        let document = try ScenarioDefinitionsCodec.load()
        let expectedSuffixByCode = [
            "project_authored.adult_pad_placement_incorrect": "aed-safety",
            "project_authored.compression_on_xiphoid": "sequence",
            "project_authored.compressions_during_normal_breathing": "normal-breathing",
            "project_authored.cpr_not_resumed_after_aed_outcome": "resume",
            "project_authored.cpr_stopped_without_supported_condition": "sequence",
            "project_authored.emergency_help_not_activated": "sequence",
            "project_authored.gasping_treated_as_normal": "normal-breathing",
            "project_authored.lone_rescuer_left_for_aed": "sequence",
            "project_authored.responsiveness_not_checked": "sequence",
            "project_authored.shock_without_clear_check": "aed-safety",
            "project_authored.unsafe_scene_not_mitigated": "sequence",
            "unsafe.contact_during_aed_analysis": "aed-safety"
        ]

        for definition in document.scenarios {
            for error in definition.criticalErrors {
                let suffix = try XCTUnwrap(expectedSuffixByCode[error.code])
                XCTAssertEqual(
                    ScenarioEngine.systemCueID(
                        scenarioID: definition.id,
                        code: error.code
                    ),
                    "sys.\(definition.id)-feedback-\(suffix)"
                )
            }
        }
    }

    func testEngineRejectsNoShockBranchThatOmitsClearAction() throws {
        let document = try ScenarioDefinitionsCodec.load()
        let original = try XCTUnwrap(document.scenarios.first)
        let nodes = original.branchingNodes.map { node in
            ScenarioBranchNode(
                id: node.id,
                prompt: node.prompt,
                conditions: node.conditions.map { condition in
                    guard condition.condition == "noShockOutcome" else { return condition }
                    return ScenarioBranchCondition(
                        id: condition.id,
                        condition: condition.condition,
                        values: condition.values,
                        nextNodeID: condition.nextNodeID,
                        requiredActionIDs: condition.requiredActionIDs.filter {
                            !$0.hasSuffix("action-clear-for-aed")
                        },
                        feedbackStatements: condition.feedbackStatements,
                        sourceReferences: condition.sourceReferences
                    )
                },
                feedbackStatements: node.feedbackStatements,
                sourceReferences: node.sourceReferences
            )
        }
        let invalidScenario = ScenarioDefinition(
            id: original.id,
            title: original.title,
            summary: original.summary,
            initialState: original.initialState,
            branchingNodes: nodes,
            criticalActions: original.criticalActions,
            criticalErrors: original.criticalErrors,
            randomisation: original.randomisation,
            scoringCategoryMapping: original.scoringCategoryMapping,
            feedbackStatements: original.feedbackStatements,
            sourceReferences: original.sourceReferences
        )
        let invalidDocument = ScenarioDefinitionsDocument(
            schemaVersion: document.schemaVersion,
            courseID: document.courseID,
            contentVersion: document.contentVersion,
            metadata: document.metadata,
            designProvenance: document.designProvenance,
            aedStateMachine: document.aedStateMachine,
            shockPatterns: document.shockPatterns,
            scenarios: [invalidScenario] + document.scenarios.dropFirst()
        )

        XCTAssertThrowsError(
            try ScenarioEngine(
                document: invalidDocument,
                scenarioID: original.id,
                selector: DeterministicScenarioPatternSelector(patternID: "S-N-N")
            )
        ) { error in
            XCTAssertEqual(
                error as? ScenarioEngineError,
                .aedOutcomeBranchMissingSafetyAction(
                    scenarioID: original.id,
                    condition: "noShockOutcome"
                )
            )
        }
    }

    func testAccessibleBystanderAssignmentHasEquivalentScoringEvidence() throws {
        let document = try ScenarioDefinitionsCodec.load()
        var gazeEngine = try makeEngine(document: document, scenarioID: "scenario-c-workplace")
        var accessibleEngine = try makeEngine(document: document, scenarioID: "scenario-c-workplace")

        try gazeEngine.assignBystander(
            "bystander_01",
            assignment: .getAED,
            method: .gazeAndPinch
        )
        try accessibleEngine.assignBystander(
            "bystander_01",
            assignment: .getAED,
            method: .accessibleControl
        )

        let gaze = try DebriefBuilder.build(from: gazeEngine.eventLog)
        let accessible = try DebriefBuilder.build(from: accessibleEngine.eventLog)
        XCTAssertEqual(gaze.scoreOutcome, accessible.scoreOutcome)
        XCTAssertEqual(gaze.recommendedXP, accessible.recommendedXP)
    }

    func testScenarioBDistractionNeverChangesScoreIncludingWithAccessibilitySupport() throws {
        let document = try ScenarioDefinitionsCodec.load()
        var baseline = try makeEngine(
            document: document,
            scenarioID: "scenario-b-shopping-centre"
        )
        var distracted = baseline
        try distracted.presentScenarioBDistraction(
            id: "public-address-announcement",
            accessibilitySupportUsed: true
        )

        let baselineDebrief = try DebriefBuilder.build(from: baseline.eventLog)
        let distractedDebrief = try DebriefBuilder.build(from: distracted.eventLog)
        XCTAssertEqual(baselineDebrief.scoreOutcome, distractedDebrief.scoreOutcome)
        XCTAssertEqual(baselineDebrief.recommendedXP, distractedDebrief.recommendedXP)
        XCTAssertEqual(distracted.eventLog.last?.affectsScore, false)

        // Keep the value mutable so this test also verifies no hidden completion side effect.
        baseline.completeSession()
    }

    func testCriticalCorrectionAndDebriefReplayAreDerivedOnlyFromRecordedLog() throws {
        let document = try ScenarioDefinitionsCodec.load()
        var engine = try makeEngine(document: document, scenarioID: "scenario-a-home")

        engine.submit(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))
        engine.submit(.checkResponse(isUnresponsive: true))
        engine.submit(.shoutForHelp(helpActivated: false))

        let correction = try XCTUnwrap(engine.currentCorrection)
        XCTAssertEqual(correction.code, "project_authored.emergency_help_not_activated")
        XCTAssertEqual(
            correction.systemAudioCueID,
            "sys.scenario-a-home-feedback-sequence"
        )
        XCTAssertFalse(correction.sourceReferences.isEmpty)
        XCTAssertEqual(correction.replayAnchor.domain, .drsabc)

        let encodedLog = try JSONEncoder().encode(engine.eventLog)
        let restoredLog = try JSONDecoder().decode(
            [IntegratedScenarioEventRecord].self,
            from: encodedLog
        )
        let firstDebrief = try DebriefBuilder.build(from: restoredLog)

        try engine.acknowledgeCorrection()
        engine.submit(DRSABCEvent.acknowledgeCorrection)
        let secondDebriefFromOriginalLog = try DebriefBuilder.build(from: restoredLog)

        XCTAssertEqual(firstDebrief, secondDebriefFromOriginalLog)
        XCTAssertEqual(firstDebrief.feedback.count, 1)
        XCTAssertEqual(firstDebrief.replayAnchors, [correction.replayAnchor])
        XCTAssertTrue(firstDebrief.scoreOutcome.hasUnsafeCompletion)
        XCTAssertEqual(firstDebrief.recommendedXP, 0)
        XCTAssertEqual(firstDebrief.practiceRecommendation.daysUntilNextPractice, 1)
    }

    func testAEDNextAnalysisCycleRequiresCompletedPriorCycleAndFreshClearCheck() throws {
        var machine = AEDStateMachine()

        let prematureCycle = machine.handle(.beginNextAnalysisCycle)
        XCTAssertFalse(prematureCycle.wasAccepted)
        XCTAssertEqual(machine.state, .awaitingPads)

        XCTAssertTrue(
            machine.handle(.placePads(rightPadCorrect: true, leftPadCorrect: true))
                .wasAccepted
        )
        XCTAssertTrue(
            machine.handle(
                .interactiveAnalysisClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: true,
                    anyoneTouching: false
                )
            ).wasAccepted
        )
        XCTAssertTrue(
            machine.handle(.receiveAnalysisOutcome(.noShock, anyoneTouching: false))
                .wasAccepted
        )
        XCTAssertTrue(machine.handle(.resumeCompressions).wasAccepted)

        let incompleteCycle = machine.handle(.beginNextAnalysisCycle)
        XCTAssertFalse(incompleteCycle.wasAccepted)
        XCTAssertEqual(machine.state, .resumeCompressions)

        XCTAssertTrue(machine.handle(.finish).wasAccepted)
        XCTAssertEqual(machine.state, .complete)
        XCTAssertTrue(machine.handle(.beginNextAnalysisCycle).wasAccepted)
        XCTAssertEqual(machine.state, .padsCorrect)

        let outcomeWithoutFreshClear = machine.handle(
            .receiveAnalysisOutcome(.shock, anyoneTouching: false)
        )
        XCTAssertFalse(outcomeWithoutFreshClear.wasAccepted)
        XCTAssertEqual(machine.state, .padsCorrect)

        XCTAssertTrue(
            machine.handle(
                .interactiveAnalysisClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: true,
                    anyoneTouching: false
                )
            ).wasAccepted
        )
        XCTAssertTrue(
            machine.handle(.receiveAnalysisOutcome(.shock, anyoneTouching: false))
                .wasAccepted
        )
        XCTAssertTrue(machine.handle(.beginCharging(anyoneTouching: false)).wasAccepted)
        XCTAssertTrue(machine.handle(.chargingComplete(anyoneTouching: false)).wasAccepted)
        XCTAssertTrue(
            machine.handle(
                .interactiveClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: true,
                    anyoneTouching: false
                )
            ).wasAccepted
        )
        XCTAssertTrue(machine.handle(.pressShockControl(anyoneTouching: false)).wasAccepted)
        XCTAssertTrue(machine.handle(.resumeCompressions).wasAccepted)
        XCTAssertTrue(machine.handle(.finish).wasAccepted)

        let replayed = try StateMachineReplay.verified(machine.eventLog) {
            AEDStateMachine()
        }
        XCTAssertEqual(replayed.state, .complete)
    }

    @MainActor
    func testIntegratedSessionRunsEveryApprovedAnalysisThroughAEDReducer() throws {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "N-S-N",
            audioDirector: NoOpAudioDirector()
        )
        XCTAssertNil(model.errorMessage)

        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: true)
        model.selectedBystanderAssignment = .callSimulated995
        model.assignSelectedTask(to: "bystander_01", method: .accessibleControl)
        model.selectedBystanderAssignment = .getAED
        model.assignSelectedTask(to: "bystander_02", method: .gazeAndPinch)
        model.chooseAEDDistance(.near)
        model.assessBreathing(.absentOrAbnormal)
        performSupportedCPRCycle(model)
        model.prepareAndApplyAED()

        XCTAssertEqual(model.stage, .aedAnalysisClear)
        model.confirmClearForAEDAnalysis(anyoneTouching: false)
        XCTAssertEqual(model.stage, .aedAnalysingDecision)
        XCTAssertEqual(model.aedState, .analysing)
        model.receiveAEDAnalysisDecision()
        XCTAssertEqual(model.lastAnalysisOutcome, .noShock)
        XCTAssertEqual(model.stage, .aedResume)
        XCTAssertEqual(model.aedState, .noShockAdvised)
        model.resumeCPRAfterAEDDecision()

        XCTAssertEqual(model.stage, .aedAnalysisClear)
        model.confirmClearForAEDAnalysis(anyoneTouching: false)
        model.receiveAEDAnalysisDecision()
        XCTAssertEqual(model.lastAnalysisOutcome, .shock)
        XCTAssertEqual(model.stage, .aedCharging)
        XCTAssertEqual(model.aedState, .charging)
        model.completeAEDCharging(anyoneTouching: false)
        XCTAssertEqual(model.stage, .aedClearConfirmation)
        XCTAssertEqual(model.aedState, .clearConfirmation)
        model.confirmClearBeforeSimulatedShock(anyoneTouching: false)
        XCTAssertEqual(model.stage, .aedSimulatedShock)
        XCTAssertEqual(model.aedState, .clearConfirmation)
        model.deliverSimulatedShock(anyoneTouching: false)
        XCTAssertEqual(model.stage, .aedResume)
        XCTAssertEqual(model.aedState, .simulatedShock)
        model.resumeCPRAfterAEDDecision()

        XCTAssertEqual(model.stage, .aedAnalysisClear)
        model.confirmClearForAEDAnalysis(anyoneTouching: false)
        model.receiveAEDAnalysisDecision()
        XCTAssertEqual(model.lastAnalysisOutcome, .noShock)
        XCTAssertEqual(model.stage, .aedResume)
        model.resumeCPRAfterAEDDecision()

        XCTAssertEqual(model.analysisRound, 3)
        XCTAssertEqual(model.aedState, .complete)
        XCTAssertEqual(model.stage, .debrief)
        let debrief = try XCTUnwrap(model.debrief)
        XCTAssertEqual(debrief.cprCadenceAccuracy ?? -1, 1, accuracy: 0.000_001)
        XCTAssertEqual(
            debrief.longestCompressionGapSeconds ?? -1,
            60.0 / 110.0,
            accuracy: 0.000_001
        )
        XCTAssertNil(model.correction)
        XCTAssertNil(model.errorMessage)

        let aedRecords = model.eventLog.filter {
            if case .aed = $0.event { return true }
            return false
        }
        XCTAssertFalse(aedRecords.isEmpty)
        XCTAssertTrue(aedRecords.allSatisfy(\.wasAccepted))

        let cycleResetCount = aedRecords.reduce(into: 0) { count, record in
            if case .aed(.beginNextAnalysisCycle) = record.event { count += 1 }
        }
        let analysisClearCount = aedRecords.reduce(into: 0) { count, record in
            if case .aed(.interactiveAnalysisClearCheck) = record.event { count += 1 }
        }
        let outcomes = model.eventLog.compactMap { record -> AEDAnalysisOutcome? in
            guard case let .analysisOutcome(_, outcome) = record.event else { return nil }
            return outcome
        }

        XCTAssertEqual(cycleResetCount, 2)
        XCTAssertEqual(analysisClearCount, 3)
        XCTAssertEqual(outcomes, [.noShock, .shock, .noShock])
    }

    @MainActor
    func testIntegratedNormalBreathingDebriefDoesNotInventCPROrAEDFailure() throws {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: true)
        model.selectedBystanderAssignment = .callSimulated995
        model.assignSelectedTask(to: "bystander_01", method: .accessibleControl)
        model.selectedBystanderAssignment = .getAED
        model.assignSelectedTask(to: "bystander_02", method: .accessibleControl)
        model.chooseAEDDistance(.near)
        model.assessBreathing(.normal)

        let debrief = try XCTUnwrap(model.debrief)
        XCTAssertEqual(model.stage, .debrief)
        XCTAssertFalse(model.eventLog.contains { record in
            if case .cpr = record.event { return true }
            return false
        })
        XCTAssertFalse(model.eventLog.contains { record in
            if case .aed = record.event { return true }
            return false
        })

        let contributions = Dictionary(
            uniqueKeysWithValues: debrief.scoreOutcome.contributions.map {
                ($0.dimension, $0.normalisedScore)
            }
        )
        XCTAssertEqual(contributions[.cprSequenceAndRhythm], 1)
        XCTAssertEqual(contributions[.aedPreparationAndPlacement], 1)
        XCTAssertFalse(debrief.scoreOutcome.hasUnsafeCompletion)
        XCTAssertEqual(debrief.recommendedXP, 100)
    }

    @MainActor
    func testUnsafeSceneCorrectionPreservesBranchCursorForSafeRetry() throws {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )
        let initialNode = try XCTUnwrap(model.engine?.currentBranchNodeID)

        model.assessScene(unsafeEntry: true)
        XCTAssertEqual(model.stage, .correction)
        XCTAssertEqual(model.engine?.currentBranchNodeID, initialNode)
        XCTAssertNotNil(model.correction)

        model.acknowledgeCorrection()
        XCTAssertEqual(model.stage, .sceneSafety)
        XCTAssertEqual(model.engine?.currentBranchNodeID, initialNode)
        model.assessScene(unsafeEntry: false)

        XCTAssertEqual(model.stage, .response)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.engine?.currentBranchNodeID,
            "scenario-a-home-branch-responder-availability"
        )
    }

    @MainActor
    func testRepeatedCriticalErrorCreatesFreshCorrectionWithoutDoubleScoring() throws {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )

        model.assessScene(unsafeEntry: true)
        XCTAssertEqual(model.stage, .correction)
        model.acknowledgeCorrection()
        XCTAssertEqual(model.stage, .sceneSafety)

        model.assessScene(unsafeEntry: true)

        XCTAssertEqual(model.stage, .correction)
        XCTAssertEqual(
            model.correction?.code,
            DRSABCCriticalFailure.unsafeSceneEntry.rawValue
        )
        let occurrences = model.eventLog.filter { record in
            guard case let .criticalError(_, code, _, _) = record.event else {
                return false
            }
            return code == DRSABCCriticalFailure.unsafeSceneEntry.rawValue
        }
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(occurrences.filter(\.affectsScore).count, 1)

        model.acknowledgeCorrection()
        model.assessScene(unsafeEntry: false)
        XCTAssertEqual(model.stage, .response)
    }

    @MainActor
    func testOutOfStageSpatialEquivalentActionsCannotAdvanceClinicalSession() {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )
        let initialLog = model.eventLog

        model.assignSelectedTask(to: "bystander_01", method: .gazeAndPinch)
        model.chooseAEDDistance(.near)
        model.assessBreathing(.absentOrAbnormal)
        model.performCPR(unsafeXiphoidPlacement: false, timestampSeconds: 0)
        model.performCPR(
            unsafeXiphoidPlacement: false,
            timestampSeconds: 60.0 / 110.0
        )
        model.performCPR(
            unsafeXiphoidPlacement: false,
            timestampSeconds: 120.0 / 110.0
        )
        model.prepareAndApplyAED()
        model.confirmClearForAEDAnalysis(anyoneTouching: false)
        model.receiveAEDAnalysisDecision()

        XCTAssertEqual(model.stage, .sceneSafety)
        XCTAssertEqual(model.eventLog, initialLog)
        XCTAssertEqual(model.cprCompressionCount, 0)
        XCTAssertFalse(model.callAssigned)
        XCTAssertFalse(model.aedRetrievalAssigned)
        XCTAssertEqual(model.engine?.drsabcState, .step(.danger))
        XCTAssertEqual(model.engine?.cprState, .positioning)
        XCTAssertEqual(model.engine?.aedState, .awaitingPads)
    }

    @MainActor
    func testIntegratedCPRCountsOnlyReducerAcceptedCompressionBeats() {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "N-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: true)
        model.selectedBystanderAssignment = .callSimulated995
        model.assignSelectedTask(to: "bystander_01", method: .accessibleControl)
        model.selectedBystanderAssignment = .getAED
        model.assignSelectedTask(to: "bystander_02", method: .accessibleControl)
        model.chooseAEDDistance(.near)
        model.assessBreathing(.absentOrAbnormal)

        model.performCPR(unsafeXiphoidPlacement: false, timestampSeconds: 0)
        model.performCPR(unsafeXiphoidPlacement: false, timestampSeconds: 0)
        XCTAssertEqual(model.cprCompressionCount, 1)
        XCTAssertEqual(model.stage, .cpr)

        model.performCPR(
            unsafeXiphoidPlacement: false,
            timestampSeconds: 60.0 / 110.0
        )
        model.performCPR(unsafeXiphoidPlacement: false, timestampSeconds: -1)
        XCTAssertEqual(model.cprCompressionCount, 2)
        XCTAssertEqual(model.stage, .cpr)

        model.performCPR(
            unsafeXiphoidPlacement: false,
            timestampSeconds: 120.0 / 110.0
        )
        XCTAssertEqual(model.cprCompressionCount, 3)
        XCTAssertEqual(model.stage, .cpr)

        for index in 3..<model.requiredCompressionCount {
            model.performCPR(
                unsafeXiphoidPlacement: false,
                timestampSeconds: Double(index) * 60.0 / 110.0
            )
        }
        XCTAssertEqual(model.cprCompressionCount, model.requiredCompressionCount)
        XCTAssertEqual(model.stage, .aedPreparation)

        let compressionRecords = model.eventLog.filter { record in
            if case .cpr(.compressionDetected) = record.event { return true }
            return false
        }
        XCTAssertEqual(compressionRecords.count, model.requiredCompressionCount + 2)
        XCTAssertEqual(
            compressionRecords.filter(\.wasAccepted).count,
            model.requiredCompressionCount
        )
    }

    @MainActor
    func testOutOfBandAcceptedCompressionsCannotEarnSafeCPRScoreOrXP() throws {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "N-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: true)
        model.selectedBystanderAssignment = .callSimulated995
        model.assignSelectedTask(to: "bystander_01", method: .accessibleControl)
        model.selectedBystanderAssignment = .getAED
        model.assignSelectedTask(to: "bystander_02", method: .accessibleControl)
        model.chooseAEDDistance(.near)
        model.assessBreathing(.absentOrAbnormal)

        for index in 0..<model.requiredCompressionCount {
            model.performCPR(
                unsafeXiphoidPlacement: false,
                timestampSeconds: Double(index) * 1.5
            )
        }

        XCTAssertEqual(model.stage, .aedPreparation)
        let debrief = try DebriefBuilder.build(from: model.eventLog)
        let cpr = try XCTUnwrap(
            debrief.scoreOutcome.contributions.first {
                $0.dimension == .cprSequenceAndRhythm
            }
        )
        XCTAssertEqual(debrief.cprCadenceAccuracy, 0)
        XCTAssertEqual(cpr.normalisedScore, 0)
        XCTAssertTrue(debrief.scoreOutcome.hasUnsafeCompletion)
        XCTAssertFalse(debrief.scoreOutcome.xpEligible)
        XCTAssertEqual(debrief.recommendedXP, 0)
    }

    @MainActor
    func testFarAEDBranchRecordsSupportedDelayMinimisationEvidence() throws {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "N-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: false)
        model.chooseAEDDistance(.far)

        let farBranchActions = model.eventLog.flatMap { record -> [ScenarioRequiredActionSnapshot] in
            guard case let .branchSelected(_, conditionID, actions) = record.event,
                  conditionID.contains("condition-far")
            else { return [] }
            return actions
        }
        XCTAssertTrue(farBranchActions.contains {
            $0.id.hasSuffix("action-minimise-delay") && $0.dimension == .time
        })
        XCTAssertTrue(model.eventLog.contains { record in
            guard record.wasAccepted, record.affectsScore,
                  case let .requiredActionCompleted(actionID, _) = record.event
            else { return false }
            return actionID.hasSuffix("action-minimise-delay")
        })
        let debrief = try DebriefBuilder.build(from: model.eventLog)
        XCTAssertEqual(
            debrief.scoreOutcome.contributions.first { $0.dimension == .time }?.normalisedScore,
            1
        )
    }

    @MainActor
    func testXiphoidCompressionAfterRhythmBeginsGetsGuidedCorrectionAndRecovery() {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "N-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: true)
        model.selectedBystanderAssignment = .callSimulated995
        model.assignSelectedTask(to: "bystander_01", method: .accessibleControl)
        model.selectedBystanderAssignment = .getAED
        model.assignSelectedTask(to: "bystander_02", method: .accessibleControl)
        model.chooseAEDDistance(.near)
        model.assessBreathing(.absentOrAbnormal)

        model.performCPR(unsafeXiphoidPlacement: false, timestampSeconds: 0)
        model.performCPR(
            unsafeXiphoidPlacement: true,
            timestampSeconds: 60.0 / 110.0
        )

        XCTAssertEqual(model.cprCompressionCount, 1)
        XCTAssertEqual(model.stage, .correction)
        XCTAssertEqual(
            model.correction?.code,
            CPRPracticeCriticalFailure.compressionOnXiphoid.rawValue
        )

        model.acknowledgeCorrection()
        model.performCPR(
            unsafeXiphoidPlacement: false,
            timestampSeconds: 120.0 / 110.0
        )
        XCTAssertEqual(model.stage, .cpr)
        XCTAssertEqual(model.cprCompressionCount, 2)
    }

    @MainActor
    func testScenarioBFocusSupportAndLoneFarBranchesReachBreathingWithoutPenalty() {
        let model = IntegratedScenarioSessionModel()
        model.prepare(
            scenarioID: "scenario-b-shopping-centre",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        XCTAssertEqual(model.stage, .distraction)

        model.continuePastDistraction(accessibilitySupportUsed: true)
        XCTAssertEqual(model.stage, .responderContext)
        model.chooseResponderAvailability(bystanderAvailable: false)
        XCTAssertEqual(model.stage, .aedDistance)
        model.chooseAEDDistance(.far)

        XCTAssertEqual(model.stage, .breathing)
        XCTAssertTrue(model.callAssigned)
        XCTAssertTrue(model.aedRetrievalAssigned)
        XCTAssertTrue(model.eventLog.contains { record in
            guard case let .distractionPresented(_, usedSupport) = record.event else {
                return false
            }
            return usedSupport && !record.affectsScore
        })
        XCTAssertTrue(model.eventLog.contains { record in
            guard case let .branchSelected(_, conditionID, _) = record.event else {
                return false
            }
            return conditionID.contains("condition-alone")
        })
        XCTAssertTrue(model.eventLog.contains { record in
            guard case let .branchSelected(_, conditionID, _) = record.event else {
                return false
            }
            return conditionID.contains("condition-far")
        })
    }

    private func makeEngine(
        document: ScenarioDefinitionsDocument,
        scenarioID: String
    ) throws -> ScenarioEngine {
        try ScenarioEngine(
            document: document,
            scenarioID: scenarioID,
            selector: DeterministicScenarioPatternSelector(patternID: "S-N-N")
        )
    }

    @MainActor
    private func performSupportedCPRCycle(_ model: IntegratedScenarioSessionModel) {
        for index in 0..<model.requiredCompressionCount {
            model.performCPR(
                unsafeXiphoidPlacement: false,
                timestampSeconds: Double(index) * 60.0 / 110.0
            )
        }
        XCTAssertEqual(model.cprCompressionCount, model.requiredCompressionCount)
        XCTAssertEqual(model.stage, .aedPreparation)
    }
}
