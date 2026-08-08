import XCTest
@testable import LifesaverVision

final class StateMachineCoreTests: XCTestCase {
    func testPracticeContentContractLoadsSourceBackedPoliciesAndBothAEDTaxonomies() throws {
        let contract = try PracticeMachineContentContract.make(
            course: CourseContentCodec.loadCourse(named: "course_v1"),
            scenarios: ScenarioDefinitionsCodec.load(),
            facts: ClinicalFactCatalogue.loadBundled()
        )

        XCTAssertEqual(contract.drsabcPolicy.maximumBreathingCheckSeconds, 10)
        XCTAssertEqual(contract.drsabcPolicy.aedNearWalkingSeconds, 60)
        XCTAssertFalse(contract.drsabcPolicy.loneRescuerLeavesCasualty)
        XCTAssertEqual(contract.cprPolicy.minimumRatePerMinute, 100)
        XCTAssertEqual(contract.cprPolicy.maximumRatePerMinute, 120)
        XCTAssertEqual(contract.cprPolicy.practiceTempoPerMinute, 110)
        XCTAssertEqual(contract.cprPolicy.preferredCompressionsPerCycle, 100)
        XCTAssertEqual(contract.cprPolicy.maximumRestSeconds, 10)
        XCTAssertEqual(contract.authoredAEDStateIDs.count, 11)
        XCTAssertEqual(
            contract.runtimeAEDStateIDs,
            Set(AEDPracticeState.allCases.map(\.rawValue))
        )
        XCTAssertTrue(contract.simulatedCallTitle.contains("SIMULATION"))
        XCTAssertTrue(contract.simulatedCallBody.contains("never dials"))
        XCTAssertTrue(contract.simulatedCallBody.contains("hang up only when told"))
        XCTAssertFalse(contract.simulatedCallSourceReferences.isEmpty)
    }

    func testPracticeContentContractFailsClosedForBlockedFactsAndPerScenarioBranches() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let scenarios = try ScenarioDefinitionsCodec.load()
        let factsURL = try XCTUnwrap(
            Bundle.main.url(forResource: "CLINICAL_FACTS_EXTRACT", withExtension: "json")
        )
        let factsDocument = try JSONDecoder().decode(
            ClinicalFactsDocument.self,
            from: Data(contentsOf: factsURL)
        )
        let blockedFacts = factsDocument.facts.map { fact in
            guard fact.id == "fact.compression.rate" else { return fact }
            return ClinicalFact(
                id: fact.id,
                statement: fact.statement,
                values: fact.values,
                sources: fact.sources,
                reviewStatus: .requiresSMEReview,
                supersedes2018: fact.supersedes2018,
                notes: fact.notes
            )
        }
        let blockedCatalogue = ClinicalFactCatalogue(
            document: ClinicalFactsDocument(
                version: factsDocument.version,
                extractedAt: factsDocument.extractedAt,
                citationConvention: factsDocument.citationConvention,
                languageNote: factsDocument.languageNote,
                facts: blockedFacts
            )
        )
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: course,
                scenarios: scenarios,
                facts: blockedCatalogue
            )
        ) { error in
            XCTAssertEqual(
                error as? PracticeMachineContentError,
                .blockedClinicalFact("fact.compression.rate")
            )
        }

        let blockedDispatcherFacts = factsDocument.facts.map { fact in
            guard fact.id == "fact.drsabc.dispatcherCapabilities" else { return fact }
            return ClinicalFact(
                id: fact.id,
                statement: fact.statement,
                values: fact.values,
                sources: fact.sources,
                reviewStatus: .requiresSMEReview,
                supersedes2018: fact.supersedes2018,
                notes: fact.notes
            )
        }
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: course,
                scenarios: scenarios,
                facts: ClinicalFactCatalogue(
                    document: ClinicalFactsDocument(
                        version: factsDocument.version,
                        extractedAt: factsDocument.extractedAt,
                        citationConvention: factsDocument.citationConvention,
                        languageNote: factsDocument.languageNote,
                        facts: blockedDispatcherFacts
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PracticeMachineContentError,
                .blockedClinicalFact("fact.drsabc.dispatcherCapabilities")
            )
        }

        let dispatcherWithoutSources = factsDocument.facts.map { fact in
            guard fact.id == "fact.drsabc.dispatcherCapabilities" else { return fact }
            return ClinicalFact(
                id: fact.id,
                statement: fact.statement,
                values: fact.values,
                sources: [],
                reviewStatus: fact.reviewStatus,
                supersedes2018: fact.supersedes2018,
                notes: fact.notes
            )
        }
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: course,
                scenarios: scenarios,
                facts: ClinicalFactCatalogue(
                    document: ClinicalFactsDocument(
                        version: factsDocument.version,
                        extractedAt: factsDocument.extractedAt,
                        citationConvention: factsDocument.citationConvention,
                        languageNote: factsDocument.languageNote,
                        facts: dispatcherWithoutSources
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PracticeMachineContentError,
                .missingClinicalFactSources("fact.drsabc.dispatcherCapabilities")
            )
        }

        let first = try XCTUnwrap(scenarios.scenarios.first)
        let incompleteFirst = ScenarioDefinition(
            id: first.id,
            title: first.title,
            summary: first.summary,
            initialState: first.initialState,
            branchingNodes: first.branchingNodes.filter {
                !$0.conditions.contains { condition in
                    condition.condition == "shockOutcome" ||
                        condition.condition == "noShockOutcome"
                }
            },
            criticalActions: first.criticalActions,
            criticalErrors: first.criticalErrors,
            randomisation: first.randomisation,
            scoringCategoryMapping: first.scoringCategoryMapping,
            feedbackStatements: first.feedbackStatements,
            sourceReferences: first.sourceReferences
        )
        let incompleteScenarios = ScenarioDefinitionsDocument(
            schemaVersion: scenarios.schemaVersion,
            courseID: scenarios.courseID,
            contentVersion: scenarios.contentVersion,
            metadata: scenarios.metadata,
            designProvenance: scenarios.designProvenance,
            aedStateMachine: scenarios.aedStateMachine,
            shockPatterns: scenarios.shockPatterns,
            scenarios: [incompleteFirst] + scenarios.scenarios.dropFirst()
        )
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: course,
                scenarios: incompleteScenarios,
                facts: ClinicalFactCatalogue(document: factsDocument)
            )
        ) { error in
            guard case let .missingScenarioBranches(missing) = error as? PracticeMachineContentError else {
                return XCTFail("Expected per-scenario branch failure, received \(error)")
            }
            XCTAssertTrue(missing.contains("scenario-a-home:shockOutcome"))
            XCTAssertTrue(missing.contains("scenario-a-home:noShockOutcome"))
        }
    }

    func testPracticeContentContractRejectsUnreviewedOrUnreferencedGuidanceBlocks() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let scenarios = try ScenarioDefinitionsCodec.load()
        let facts = try ClinicalFactCatalogue.loadBundled()

        let blockedBlockCourse = replacingContentBlock(
            id: "M3-B5",
            in: course
        ) { block in
            ContentBlock(
                id: block.id,
                kind: block.kind,
                title: block.title,
                body: block.body,
                sourceReferences: block.sourceReferences,
                reviewStatus: .clinicalReviewRequired
            )
        }
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: blockedBlockCourse,
                scenarios: scenarios,
                facts: facts
            )
        ) { error in
            XCTAssertEqual(
                error as? PracticeMachineContentError,
                .blockedCourseBlock("M3-B5")
            )
        }

        let unreferencedCourse = replacingContentBlock(
            id: "M3-B5",
            in: course
        ) { block in
            ContentBlock(
                id: block.id,
                kind: block.kind,
                title: block.title,
                body: block.body,
                sourceReferences: [],
                reviewStatus: block.reviewStatus
            )
        }
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: unreferencedCourse,
                scenarios: scenarios,
                facts: facts
            )
        ) { error in
            XCTAssertEqual(
                error as? PracticeMachineContentError,
                .missingCourseBlockSourceReferences("M3-B5")
            )
        }

        let blockedReferenceCourse = replacingContentBlock(
            id: "M3-B5",
            in: course
        ) { block in
            let references = block.sourceReferences.enumerated().map { index, reference in
                guard index == 0 else { return reference }
                return SourceReference(
                    id: reference.id,
                    document: reference.document,
                    edition: reference.edition,
                    section: reference.section,
                    page: reference.page,
                    reviewStatus: "requires_sme_review",
                    reviewer: reference.reviewer,
                    lastClinicalReviewDate: reference.lastClinicalReviewDate,
                    contentVersion: reference.contentVersion,
                    clinicalFactID: reference.clinicalFactID
                )
            }
            return ContentBlock(
                id: block.id,
                kind: block.kind,
                title: block.title,
                body: block.body,
                sourceReferences: references,
                reviewStatus: block.reviewStatus
            )
        }
        let blockedReferenceID = try XCTUnwrap(
            course.modules
                .flatMap(\.lessons)
                .flatMap(\.contentBlocks)
                .first(where: { $0.id == "M3-B5" })?
                .sourceReferences.first?.id
        )
        XCTAssertThrowsError(
            try PracticeMachineContentContract.make(
                course: blockedReferenceCourse,
                scenarios: scenarios,
                facts: facts
            )
        ) { error in
            XCTAssertEqual(
                error as? PracticeMachineContentError,
                .blockedCourseBlockSourceReference(
                    blockID: "M3-B5",
                    referenceID: blockedReferenceID
                )
            )
        }
    }

    func testDRSABCGaspingBranchReachesCompressionsAndCapturesBranchInputs() {
        var machine = DRSABCStateMachine()

        machine.handle(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))
        machine.handle(.checkResponse(isUnresponsive: true))
        machine.handle(.shoutForHelp(helpActivated: true))
        machine.handle(.rehearse995Call(clearlyLabelledSimulation: true))
        machine.handle(
            .delegateAED(
                bystanderAvailable: true,
                alone: false,
                distance: .near,
                learnerLeavesCasualty: false
            )
        )
        machine.handle(
            .assessBreathing(
                durationSeconds: 8,
                casualtyGasping: true,
                breathingNormal: false,
                treatedGaspingAsNormal: false
            )
        )

        XCTAssertEqual(machine.state, .step(.compressions))
        XCTAssertEqual(machine.selectedAEDDistance, .near)
        XCTAssertEqual(machine.wasBystanderAvailable, true)
        XCTAssertTrue(machine.criticalFailures.isEmpty)
        XCTAssertEqual(machine.eventLog.map(\.sequence), Array(0..<6))
    }

    func testDRSABCUnsafeEntryFailsFastIntoCorrectiveFeedbackBeforeProgress() {
        var machine = DRSABCStateMachine()

        let entry = machine.handle(
            .inspectDanger(sceneUnsafe: true, enteredUnsafeScene: true)
        )

        guard case let .correctiveFeedback(remediation, retry) = machine.state else {
            return XCTFail("Unsafe entry must enter corrective feedback")
        }
        XCTAssertEqual(remediation.code, .unsafeSceneEntry)
        XCTAssertEqual(retry, .danger)
        XCTAssertEqual(machine.criticalFailures, [.unsafeSceneEntry])
        XCTAssertTrue(entry.wasAccepted)
        XCTAssertEqual(entry.stateAfter, machine.state)
    }

    func testDRSABCFailureToCallForHelpMustCorrectBeforeProgress() {
        var machine = DRSABCStateMachine()
        machine.handle(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))
        machine.handle(.checkResponse(isUnresponsive: true))

        machine.handle(.shoutForHelp(helpActivated: false))

        guard case let .correctiveFeedback(remediation, retry) = machine.state else {
            return XCTFail("Missing help activation must be corrected")
        }
        XCTAssertEqual(remediation.code, .helpNotActivated)
        XCTAssertEqual(retry, .shout)
        XCTAssertEqual(machine.criticalFailures, [.helpNotActivated])
    }

    func testDRSABCLoneRescuerNeverLeavesCasualty() {
        var machine = drsabcAtAEDDelegation()

        machine.handle(
            .delegateAED(
                bystanderAvailable: false,
                alone: true,
                distance: .far,
                learnerLeavesCasualty: true
            )
        )

        guard case let .correctiveFeedback(remediation, retry) = machine.state else {
            return XCTFail("A lone rescuer leaving must enter corrective feedback")
        }
        XCTAssertEqual(remediation.code, .loneRescuerMustStay)
        XCTAssertEqual(retry, .aedDelegation)
        XCTAssertEqual(machine.criticalFailures, [.loneRescuerLeft])
    }

    func testDRSABCGaspingMistakenAsNormalRequiresCorrection() {
        var machine = drsabcAtBreathingCheck()

        machine.handle(
            .assessBreathing(
                durationSeconds: 7,
                casualtyGasping: true,
                breathingNormal: true,
                treatedGaspingAsNormal: true
            )
        )

        guard case let .correctiveFeedback(remediation, retry) = machine.state else {
            return XCTFail("Gasping-as-normal must enter corrective feedback")
        }
        XCTAssertEqual(remediation.code, .gaspingIsNotNormalBreathing)
        XCTAssertEqual(retry, .breathingCheck)
        XCTAssertEqual(machine.criticalFailures, [.gaspingTreatedAsNormal])
    }

    func testDRSABCNormalBreathingRoutesToMonitoringNotCompressions() {
        var machine = drsabcAtBreathingCheck()

        machine.handle(
            .assessBreathing(
                durationSeconds: 6,
                casualtyGasping: false,
                breathingNormal: true,
                treatedGaspingAsNormal: false
            )
        )

        XCTAssertEqual(machine.state, .step(.monitoringNormalBreathing))
    }

    func testDRSABCResponsiveCasualtyDoesNotInferBreathingAssessment() {
        var machine = DRSABCStateMachine()
        machine.handle(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))

        machine.handle(.checkResponse(isUnresponsive: false))

        XCTAssertEqual(machine.state, .step(.responsiveCasualty))
    }

    func testInvalidTransitionIsRejectedLoggedAndDoesNotMutateState() {
        var machine = DRSABCStateMachine()

        let entry = machine.handle(.completeStep)

        XCTAssertFalse(entry.wasAccepted)
        XCTAssertEqual(machine.state, .step(.danger))
        XCTAssertEqual(machine.eventLog, [entry])
        guard case .rejected = entry.outcome else {
            return XCTFail("Invalid event must be represented as a rejection")
        }
    }

    func testCPRMachineTracksCyclesRateAndSupportedRestWindow() {
        var machine = cprAtCompressionCycles()

        for index in 0..<100 {
            machine.handle(
                .compressionDetected(
                    timestampSeconds: Double(index) * 60 / 110,
                    placement: .sternumTarget,
                    handStacking: .likelyStacked
                )
            )
        }
        machine.handle(.startRest)
        machine.handle(.endRest(durationSeconds: 8))

        XCTAssertEqual(machine.state, .compressionCycles)
        XCTAssertEqual(machine.metrics.totalCompressions, 100)
        XCTAssertEqual(machine.metrics.completedCycles, 1)
        XCTAssertEqual(machine.metrics.compressionsSinceRest, 0)
        XCTAssertEqual(machine.metrics.averageCadencePerMinute ?? 0, 110, accuracy: 0.001)
        XCTAssertEqual(machine.metrics.interruptions.count, 1)
        XCTAssertFalse(machine.metrics.interruptions[0].exceededSupportedMaximum)
        XCTAssertTrue(machine.criticalFailures.isEmpty)
    }

    func testCPRXiphoidPlacementCorrectsAndProlongedInterruptionIsFlagged() {
        var machine = CPRPracticeStateMachine()
        machine.handle(.confirmPositioning)
        machine.handle(.classifyHandPlacement(.xiphoidAvoidZone))

        XCTAssertEqual(machine.state, .correctiveFeedback)
        XCTAssertEqual(machine.criticalFailures, [.compressionOnXiphoid])

        machine.handle(.acknowledgeCorrection)
        machine.handle(.classifyHandPlacement(.sternumTarget))
        machine.handle(
            .compressionDetected(
                timestampSeconds: 0,
                placement: .sternumTarget,
                handStacking: .likelyStacked
            )
        )
        machine.handle(.recordInterruption(durationSeconds: 10.01))

        XCTAssertEqual(
            Set(machine.criticalFailures),
            Set([.compressionOnXiphoid, .prolongedInterruption])
        )
        XCTAssertEqual(machine.metrics.longestInterruptionSeconds, 10.01, accuracy: 0.001)
    }

    func testCPREarlyRestIsRejectedAndSupportedStopCompletes() {
        var machine = cprAtCompressionCycles()

        let earlyRest = machine.handle(.startRest)
        XCTAssertFalse(earlyRest.wasAccepted)
        XCTAssertEqual(machine.state, .compressionCycles)

        machine.handle(.stop(.aedAnalysing))
        machine.handle(.finish)
        XCTAssertEqual(machine.state, .complete)
    }

    func testCPRFirstCompressionHasNoFabricatedCadenceAndOngoingXiphoidIsAuthoritative() {
        var machine = cprAtCompressionCycles()

        machine.handle(
            .compressionDetected(
                timestampSeconds: 0,
                placement: .sternumTarget,
                handStacking: .indeterminate
            )
        )
        XCTAssertNil(machine.metrics.latestCadencePerMinute)
        XCTAssertEqual(machine.metrics.totalCompressions, 1)

        machine.handle(
            .compressionDetected(
                timestampSeconds: 60 / 110,
                placement: .xiphoidAvoidZone,
                handStacking: .likelyStacked
            )
        )

        XCTAssertEqual(machine.state, .correctiveFeedback)
        XCTAssertEqual(machine.metrics.totalCompressions, 1)
        XCTAssertEqual(machine.criticalFailures, [.compressionOnXiphoid])
    }

    func testCPRCadenceBoundariesAreClassifiedByTheEngine() {
        var machine = cprAtCompressionCycles()
        var timestamp = 0.0
        machine.handle(
            .compressionDetected(
                timestampSeconds: timestamp,
                placement: .sternumTarget,
                handStacking: .likelyStacked
            )
        )
        for cadence in [99.0, 100.0, 120.0, 121.0] {
            timestamp += 60 / cadence
            machine.handle(
                .compressionDetected(
                    timestampSeconds: timestamp,
                    placement: .sternumTarget,
                    handStacking: .likelyStacked
                )
            )
        }

        XCTAssertEqual(
            machine.metrics.cadenceBands,
            [
                .belowSupportedBand,
                .withinSupportedBand,
                .withinSupportedBand,
                .aboveSupportedBand
            ]
        )
    }

    func testCPRExactlyTenSecondsIsAllowedAndEveryStopReasonIsAccepted() {
        var interruptionMachine = cprAtCompressionCycles()
        interruptionMachine.handle(.recordInterruption(durationSeconds: 10))
        XCTAssertTrue(interruptionMachine.criticalFailures.isEmpty)

        for reason in CPRStopReason.allCases {
            var machine = cprAtCompressionCycles()
            let stop = machine.handle(.stop(reason))
            XCTAssertTrue(stop.wasAccepted, reason.rawValue)
            XCTAssertEqual(machine.state, .stopped, reason.rawValue)
        }
    }

    func testPoliciesRejectUnsafeOrNonFiniteConfiguration() {
        XCTAssertThrowsError(
            try DRSABCPolicy.validated(
                maximumBreathingCheckSeconds: 10,
                aedNearWalkingSeconds: 60,
                loneRescuerLeavesCasualty: true
            )
        )
        XCTAssertThrowsError(
            try CPRPracticePolicy.validated(
                minimumRatePerMinute: 120,
                maximumRatePerMinute: 100,
                practiceTempoPerMinute: 110,
                preferredCompressionsPerCycle: 0,
                maximumRestSeconds: .infinity
            )
        )
    }

    func testAEDPreparationPredicatesBlockPadsUntilAllPresentedConditionsResolved() {
        let requirements = Set(AEDChestCondition.allCases)
        var machine = AEDStateMachine(requiredChestConditions: requirements)

        let blocked = machine.handle(
            .placePads(rightPadCorrect: true, leftPadCorrect: true)
        )
        XCTAssertFalse(blocked.wasAccepted)
        XCTAssertEqual(machine.state, .awaitingPads)

        machine.handle(.performPreparation(.shavePadSites))
        machine.handle(.performPreparation(.moveJewelleryClear))
        let insufficientClearance = machine.handle(
            .performPreparation(.confirmImplantedDeviceClearance(fingerBreadths: 3))
        )
        XCTAssertFalse(insufficientClearance.wasAccepted)
        machine.handle(.performPreparation(.confirmImplantedDeviceClearance(fingerBreadths: 4)))
        machine.handle(.performPreparation(.removeMedicationPatch))
        machine.handle(.performPreparation(.dryChest))
        machine.handle(.placePads(rightPadCorrect: true, leftPadCorrect: true))

        XCTAssertTrue(machine.preparation.isReadyForPads)
        XCTAssertEqual(machine.state, .padsCorrect)
    }

    func testAEDIncorrectPadsRequireRetry() {
        var machine = AEDStateMachine()

        let placement = machine.handle(
            .placePads(rightPadCorrect: true, leftPadCorrect: false)
        )

        XCTAssertEqual(machine.state, .padsIncorrect)
        guard case let .accepted(_, remediation) = placement.outcome else {
            return XCTFail("Incorrect pads must be an accepted corrective state")
        }
        XCTAssertEqual(remediation?.code, .padsIncorrect)
        machine.handle(.retryPadPlacement)
        XCTAssertEqual(machine.state, .awaitingPads)
    }

    func testAEDShockPathBlocksTouchAndRequiresInteractiveClearSweep() {
        var machine = aedAtPadsCorrect()

        let blockedAnalysis = machine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: false,
                anyoneTouching: true
            )
        )
        XCTAssertFalse(blockedAnalysis.wasAccepted)
        XCTAssertEqual(machine.state, .padsCorrect)

        machine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        machine.handle(.receiveAnalysisOutcome(.shock, anyoneTouching: false))
        machine.handle(.beginCharging(anyoneTouching: false))
        machine.handle(.chargingComplete(anyoneTouching: false))

        let barePress = machine.handle(.pressShockControl(anyoneTouching: false))
        XCTAssertFalse(barePress.wasAccepted)
        XCTAssertEqual(machine.state, .clearConfirmation)

        let touchingSweep = machine.handle(
            .interactiveClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: false,
                anyoneTouching: true
            )
        )
        XCTAssertFalse(touchingSweep.wasAccepted)
        XCTAssertEqual(machine.state, .clearConfirmation)

        machine.handle(
            .interactiveClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        let blockedShock = machine.handle(.pressShockControl(anyoneTouching: true))
        XCTAssertFalse(blockedShock.wasAccepted)
        XCTAssertNotEqual(machine.state, .simulatedShock)

        let staleClearPress = machine.handle(.pressShockControl(anyoneTouching: false))
        XCTAssertFalse(staleClearPress.wasAccepted)
        machine.handle(
            .interactiveClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        machine.handle(.pressShockControl(anyoneTouching: false))
        XCTAssertEqual(machine.state, .simulatedShock)
    }

    func testAEDAnalysisOutcomeIsRejectedWhileAnyoneIsTouching() {
        var machine = aedAtPadsCorrect()
        machine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )

        let blocked = machine.handle(
            .receiveAnalysisOutcome(.shock, anyoneTouching: true)
        )

        XCTAssertFalse(blocked.wasAccepted)
        XCTAssertEqual(machine.state, .analysing)
        XCTAssertEqual(machine.criticalFailures, [.contactDuringAnalysis])
        guard case .rejected(reason: .anyoneTouchingDuringAnalysis, remediation: _) = blocked.outcome else {
            return XCTFail("Touch during analysis must be an explicit rejection")
        }
    }

    func testAEDShockAndNoShockPathsBothRequireResumeCompressions() {
        var shockMachine = aedAtPadsCorrect()
        shockMachine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        shockMachine.handle(.receiveAnalysisOutcome(.shock, anyoneTouching: false))
        shockMachine.handle(.beginCharging(anyoneTouching: false))
        shockMachine.handle(.chargingComplete(anyoneTouching: false))
        shockMachine.handle(
            .interactiveClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        shockMachine.handle(.pressShockControl(anyoneTouching: false))
        XCTAssertEqual(shockMachine.state, .simulatedShock)
        let prematureShockFinish = shockMachine.handle(.finish)
        XCTAssertFalse(prematureShockFinish.wasAccepted)
        XCTAssertEqual(shockMachine.state, .simulatedShock)
        shockMachine.handle(.resumeCompressions)
        XCTAssertEqual(shockMachine.state, .resumeCompressions)

        var noShockMachine = aedAtPadsCorrect()
        noShockMachine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        noShockMachine.handle(.receiveAnalysisOutcome(.noShock, anyoneTouching: false))
        XCTAssertEqual(noShockMachine.state, .noShockAdvised)
        let prematureFinish = noShockMachine.handle(.finish)
        XCTAssertFalse(prematureFinish.wasAccepted)
        noShockMachine.handle(.resumeCompressions)
        XCTAssertEqual(noShockMachine.state, .resumeCompressions)
    }

    func testAEDRepeatedAnalysisCycleRetainsPadsAndReappliesEverySafetyGate() {
        var machine = aedAtPadsCorrect()
        machine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        machine.handle(.receiveAnalysisOutcome(.noShock, anyoneTouching: false))
        machine.handle(.resumeCompressions)
        machine.handle(.finish)
        XCTAssertEqual(machine.state, .complete)

        let restart = machine.handle(.beginNextAnalysisCycle)
        XCTAssertTrue(restart.wasAccepted)
        XCTAssertEqual(machine.state, .padsCorrect)
        XCTAssertTrue(machine.preparation.isReadyForPads)

        let outcomeWithoutClear = machine.handle(
            .receiveAnalysisOutcome(.shock, anyoneTouching: false)
        )
        XCTAssertFalse(outcomeWithoutClear.wasAccepted)
        XCTAssertEqual(machine.state, .padsCorrect)

        machine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        machine.handle(.receiveAnalysisOutcome(.shock, anyoneTouching: false))
        machine.handle(.beginCharging(anyoneTouching: false))
        machine.handle(.chargingComplete(anyoneTouching: false))
        let shockWithoutSecondClear = machine.handle(
            .pressShockControl(anyoneTouching: false)
        )
        XCTAssertFalse(shockWithoutSecondClear.wasAccepted)
        XCTAssertEqual(machine.state, .clearConfirmation)
    }

    func testAEDFailureToResumeWithinCoachedWindowIsCritical() {
        for outcome in [AEDAnalysisOutcome.shock, .noShock] {
            var machine = aedAwaitingResume(after: outcome)

            machine.handle(.coachedResumeWindowExpired)

            XCTAssertTrue(machine.resumeWindowHasExpired, String(describing: outcome))
            XCTAssertEqual(
                machine.criticalFailures,
                [.cprNotResumed],
                String(describing: outcome)
            )
            XCTAssertEqual(
                machine.state,
                outcome == .shock ? .simulatedShock : .noShockAdvised,
                String(describing: outcome)
            )
        }
    }

    func testReplayProducesIdenticalStatesMetricsFailuresAndLog() throws {
        var drsabc = drsabcAtBreathingCheck()
        drsabc.handle(
            .assessBreathing(
                durationSeconds: 5,
                casualtyGasping: true,
                breathingNormal: true,
                treatedGaspingAsNormal: true
            )
        )
        let replayedDRSABC = try StateMachineReplay.verified(drsabc.eventLog) {
            DRSABCStateMachine()
        }
        XCTAssertEqual(replayedDRSABC.state, drsabc.state)
        XCTAssertEqual(replayedDRSABC.criticalFailures, drsabc.criticalFailures)
        XCTAssertEqual(replayedDRSABC.eventLog, drsabc.eventLog)

        var cpr = cprAtCompressionCycles()
        cpr.handle(
            .compressionDetected(
                timestampSeconds: 0,
                placement: .sternumTarget,
                handStacking: .likelyStacked
            )
        )
        cpr.handle(.recordInterruption(durationSeconds: 12))
        let replayedCPR = try StateMachineReplay.verified(cpr.eventLog) {
            CPRPracticeStateMachine()
        }
        XCTAssertEqual(replayedCPR.state, cpr.state)
        XCTAssertEqual(replayedCPR.metrics, cpr.metrics)
        XCTAssertEqual(replayedCPR.criticalFailures, cpr.criticalFailures)

        var aed = aedAtPadsCorrect()
        aed.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: false,
                anyoneTouching: true
            )
        )
        aed.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        aed.handle(.receiveAnalysisOutcome(.noShock, anyoneTouching: false))
        aed.handle(.coachedResumeWindowExpired)
        let replayedAED = try StateMachineReplay.verified(aed.eventLog) {
            AEDStateMachine()
        }
        XCTAssertEqual(replayedAED.state, aed.state)
        XCTAssertEqual(replayedAED.criticalFailures, aed.criticalFailures)
        XCTAssertEqual(replayedAED.eventLog, aed.eventLog)
    }

    func testNonFiniteInputIsSanitisedIntoCodableReplayableRejection() throws {
        var cpr = cprAtCompressionCycles()
        let rejection = cpr.handle(
            .compressionDetected(
                timestampSeconds: .nan,
                placement: .sternumTarget,
                handStacking: .indeterminate
            )
        )
        XCTAssertFalse(rejection.wasAccepted)
        XCTAssertNoThrow(try JSONEncoder().encode(cpr.eventLog))
        let replayed = try StateMachineReplay.verified(cpr.eventLog) {
            CPRPracticeStateMachine()
        }
        XCTAssertEqual(replayed.eventLog, cpr.eventLog)

        var drsabc = drsabcAtBreathingCheck()
        drsabc.handle(
            .assessBreathing(
                durationSeconds: .infinity,
                casualtyGasping: false,
                breathingNormal: false,
                treatedGaspingAsNormal: false
            )
        )
        XCTAssertNoThrow(try JSONEncoder().encode(drsabc.eventLog))
        _ = try StateMachineReplay.verified(drsabc.eventLog) {
            DRSABCStateMachine()
        }
    }

    func testReplayRejectsNonContiguousAndDivergentEntries() {
        var machine = DRSABCStateMachine()
        machine.handle(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))
        let original = machine.eventLog[0]

        let nonContiguous = StateMachineEventLogEntry(
            sequence: 2,
            stateBefore: original.stateBefore,
            event: original.event,
            outcome: original.outcome,
            evidence: original.evidence
        )
        XCTAssertThrowsError(
            try StateMachineReplay.verified([nonContiguous]) {
                DRSABCStateMachine()
            }
        ) { error in
            XCTAssertEqual(
                error as? StateMachineReplayError,
                .nonContiguousSequence(expected: 0, actual: 2)
            )
        }

        let divergent = StateMachineEventLogEntry(
            sequence: original.sequence,
            stateBefore: original.stateBefore,
            event: original.event,
            outcome: original.outcome,
            evidence: ["tampered": "true"]
        )
        XCTAssertThrowsError(
            try StateMachineReplay.verified([divergent]) {
                DRSABCStateMachine()
            }
        ) { error in
            XCTAssertEqual(
                error as? StateMachineReplayError,
                .divergentEntry(sequence: 0)
            )
        }
    }
}

private extension StateMachineCoreTests {
    func replacingContentBlock(
        id blockID: String,
        in course: Course,
        transform: (ContentBlock) -> ContentBlock
    ) -> Course {
        let modules = course.modules.map { module in
            Module(
                id: module.id,
                title: module.title,
                summary: module.summary,
                order: module.order,
                lessons: module.lessons.map { lesson in
                    Lesson(
                        id: lesson.id,
                        title: lesson.title,
                        summary: lesson.summary,
                        order: lesson.order,
                        learningObjectives: lesson.learningObjectives,
                        contentBlocks: lesson.contentBlocks.map { block in
                            block.id == blockID ? transform(block) : block
                        },
                        interactiveActivities: lesson.interactiveActivities,
                        scenarios: lesson.scenarios,
                        assessments: lesson.assessments,
                        sourceReferences: lesson.sourceReferences
                    )
                },
                sourceReferences: module.sourceReferences,
                reviewStatus: module.reviewStatus,
                accessRequirements: module.accessRequirements
            )
        }
        return Course(
            id: course.id,
            title: course.title,
            summary: course.summary,
            version: course.version,
            modules: modules,
            instructorRequirement: course.instructorRequirement,
            completionRule: course.completionRule,
            sourceReferences: course.sourceReferences
        )
    }

    func drsabcAtAEDDelegation() -> DRSABCStateMachine {
        var machine = DRSABCStateMachine()
        machine.handle(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))
        machine.handle(.checkResponse(isUnresponsive: true))
        machine.handle(.shoutForHelp(helpActivated: true))
        machine.handle(.rehearse995Call(clearlyLabelledSimulation: true))
        return machine
    }

    func drsabcAtBreathingCheck() -> DRSABCStateMachine {
        var machine = drsabcAtAEDDelegation()
        machine.handle(
            .delegateAED(
                bystanderAvailable: true,
                alone: false,
                distance: .near,
                learnerLeavesCasualty: false
            )
        )
        return machine
    }

    func cprAtCompressionCycles() -> CPRPracticeStateMachine {
        var machine = CPRPracticeStateMachine()
        machine.handle(.confirmPositioning)
        machine.handle(.classifyHandPlacement(.sternumTarget))
        return machine
    }

    func aedAtPadsCorrect() -> AEDStateMachine {
        var machine = AEDStateMachine()
        machine.handle(.placePads(rightPadCorrect: true, leftPadCorrect: true))
        return machine
    }

    func aedAwaitingResume(after outcome: AEDAnalysisOutcome) -> AEDStateMachine {
        var machine = aedAtPadsCorrect()
        machine.handle(
            .interactiveAnalysisClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: true,
                anyoneTouching: false
            )
        )
        machine.handle(.receiveAnalysisOutcome(outcome, anyoneTouching: false))
        if outcome == .shock {
            machine.handle(.beginCharging(anyoneTouching: false))
            machine.handle(.chargingComplete(anyoneTouching: false))
            machine.handle(
                .interactiveClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: true,
                    anyoneTouching: false
                )
            )
            machine.handle(.pressShockControl(anyoneTouching: false))
        }
        return machine
    }
}
