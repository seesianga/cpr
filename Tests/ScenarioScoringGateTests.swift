import XCTest
@testable import LifesaverVision

final class ScenarioScoringGateTests: XCTestCase {
    func testSMEFlagInRuntimeScenarioBlocksActualScoredPersistenceDecision() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let facts = try ClinicalFactCatalogue.loadBundled()
        let document = try ScenarioDefinitionsCodec.load()
        let original = try XCTUnwrap(
            document.scenarios.first(where: { $0.id == "scenario-a-home" })
        )
        let originalReference = try XCTUnwrap(original.sourceReferences.first)
        let blockedReference = SourceReference(
            id: "\(originalReference.id)-sme-regression",
            document: originalReference.document,
            edition: originalReference.edition,
            section: originalReference.section,
            page: originalReference.page,
            reviewStatus: "requires_sme_review",
            reviewer: nil,
            lastClinicalReviewDate: nil,
            contentVersion: originalReference.contentVersion,
            clinicalFactID: originalReference.clinicalFactID
        )
        let blockedRuntimeScenario = ScenarioDefinition(
            id: original.id,
            title: original.title,
            summary: original.summary,
            initialState: original.initialState,
            branchingNodes: original.branchingNodes,
            criticalActions: original.criticalActions,
            criticalErrors: original.criticalErrors,
            randomisation: original.randomisation,
            scoringCategoryMapping: original.scoringCategoryMapping,
            feedbackStatements: original.feedbackStatements,
            sourceReferences: [blockedReference] + original.sourceReferences.dropFirst()
        )
        let blockedRuntimeDocument = ScenarioDefinitionsDocument(
            schemaVersion: document.schemaVersion,
            courseID: document.courseID,
            contentVersion: document.contentVersion,
            metadata: document.metadata,
            designProvenance: document.designProvenance,
            aedStateMachine: document.aedStateMachine,
            shockPatterns: document.shockPatterns,
            scenarios: document.scenarios.map {
                $0.id == blockedRuntimeScenario.id ? blockedRuntimeScenario : $0
            }
        )

        let engine = try ScenarioEngine(
            document: document,
            scenarioID: original.id,
            selector: DeterministicScenarioPatternSelector(patternID: "S-N-N")
        )
        let debrief = try DebriefBuilder.build(from: engine.eventLog)

        let decision = ScenarioScoringGate().authorizePersistence(
            document: blockedRuntimeDocument,
            course: course,
            facts: facts,
            lifecycle: .published,
            debrief: debrief,
            eventLog: engine.eventLog
        )

        XCTAssertEqual(decision, .practiceOnly(.clinicalReviewRequired))
        XCTAssertFalse(decision.permitsScoredPersistence)
    }

    func testSafeExactRuntimeScenarioCanAuthorizeScoredPersistence() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let facts = try ClinicalFactCatalogue.loadBundled()
        let document = try ScenarioDefinitionsCodec.load()
        let engine = try ScenarioEngine(
            document: document,
            scenarioID: "scenario-a-home",
            selector: DeterministicScenarioPatternSelector(patternID: "S-N-N")
        )
        let debrief = try DebriefBuilder.build(from: engine.eventLog)

        let decision = ScenarioScoringGate().authorizePersistence(
            document: document,
            course: course,
            facts: facts,
            lifecycle: .published,
            debrief: debrief,
            eventLog: engine.eventLog
        )

        XCTAssertEqual(
            decision,
            .scored(
                ScenarioScoringAuthorization(
                    courseID: document.courseID,
                    scenarioID: debrief.scenarioID,
                    contentVersion: document.contentVersion
                )
            )
        )
    }

    func testScenarioPersistenceMetadataUsesDebriefOutcomeVersion() throws {
        let document = try ScenarioDefinitionsCodec.load()
        let engine = try ScenarioEngine(
            document: document,
            scenarioID: "scenario-a-home",
            selector: DeterministicScenarioPatternSelector(patternID: "S-N-N")
        )
        let original = try DebriefBuilder.build(from: engine.eventLog)
        let carriedVersion = "2026.08-regression"
        let outcome = ScenarioScoreOutcome(
            attemptID: original.scoreOutcome.attemptID,
            contentVersion: carriedVersion,
            normalisedScore: original.scoreOutcome.normalisedScore,
            percentage: original.scoreOutcome.percentage,
            passed: original.scoreOutcome.passed,
            hasUnsafeCompletion: original.scoreOutcome.hasUnsafeCompletion,
            requiresMandatoryRemediation: original.scoreOutcome.requiresMandatoryRemediation,
            remediationCodes: original.scoreOutcome.remediationCodes,
            xpEligible: original.scoreOutcome.xpEligible,
            contributions: original.scoreOutcome.contributions
        )
        let debrief = ScenarioDebrief(
            scenarioID: original.scenarioID,
            scene: original.scene,
            selectedPatternID: original.selectedPatternID,
            scoreOutcome: outcome,
            timeline: original.timeline,
            feedback: original.feedback,
            replayAnchors: original.replayAnchors,
            recommendedXP: original.recommendedXP,
            cprCadenceAccuracy: original.cprCadenceAccuracy,
            longestCompressionGapSeconds: original.longestCompressionGapSeconds,
            practiceRecommendation: original.practiceRecommendation
        )

        XCTAssertEqual(
            ScenarioPersistenceMetadata(debrief: debrief).contentVersion,
            carriedVersion
        )
    }

    @MainActor
    func testStandalonePracticeSessionsExposeLoadedContractVersion() throws {
        let expected = try PracticeMachineContentContract.loadBundled().contentVersion
        let aed = AEDPracticeSessionModel()
        aed.prepareIfNeeded()
        let drsabc = DRSABCPracticeSessionModel()
        drsabc.prepare()

        XCTAssertEqual(aed.contentVersion, expected)
        XCTAssertEqual(drsabc.contentVersion, expected)
    }
}
