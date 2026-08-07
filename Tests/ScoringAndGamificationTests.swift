import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class ScoringAndGamificationTests: XCTestCase {
    private let scoringEngine = ScoringEngine()
    private let gamificationEngine = GamificationEngine()

    func testSafetyFirstWeightsAreExactAndSumToOne() throws {
        XCTAssertEqual(ScoringEngine.weights.count, ScoringDimension.allCases.count)
        XCTAssertEqual(try XCTUnwrap(ScoringEngine.weights[.sceneSafety]), 0.20, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(ScoringEngine.weights[.recognitionAndActivation]),
            0.20,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(ScoringEngine.weights[.cprSequenceAndRhythm]),
            0.25,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(ScoringEngine.weights[.aedPreparationAndPlacement]),
            0.20,
            accuracy: 0.000_001
        )
        XCTAssertEqual(try XCTUnwrap(ScoringEngine.weights[.communication]), 0.10, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(ScoringEngine.weights[.time]), 0.05, accuracy: 0.000_001)
        XCTAssertEqual(ScoringEngine.weights.values.reduce(0, +), 1.0, accuracy: 0.000_001)
    }

    func testMissingAndInvalidDimensionValuesAreRejected() {
        var missingTime = maximumDimensionScores()
        missingTime.removeValue(forKey: .time)

        XCTAssertThrowsError(
            try scoringEngine.evaluate(scoreInput(dimensionScores: missingTime))
        ) { error in
            XCTAssertEqual(error as? ScoringError, .missingDimension(.time))
        }

        var invalidSceneSafety = maximumDimensionScores()
        invalidSceneSafety[.sceneSafety] = .nan

        XCTAssertThrowsError(
            try scoringEngine.evaluate(scoreInput(dimensionScores: invalidSceneSafety))
        ) { error in
            XCTAssertEqual(error as? ScoringError, .invalidDimensionScore(.sceneSafety))
        }
    }

    func testCriticalErrorForcesFailureRemediationAndXPIneligibilityAtMaximumScores() throws {
        let criticalError = CriticalError(
            id: "critical-unsafe-contact",
            code: "unsafe.contact_during_aed_analysis",
            remediation: "Repeat the safety sequence before another scored attempt."
        )

        let outcome = try scoringEngine.evaluate(
            scoreInput(criticalErrors: [criticalError])
        )

        XCTAssertEqual(outcome.percentage, 100, accuracy: 0.000_001)
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(outcome.hasUnsafeCompletion)
        XCTAssertTrue(outcome.requiresMandatoryRemediation)
        XCTAssertFalse(outcome.xpEligible)
        XCTAssertEqual(outcome.remediationCodes, [criticalError.code])
    }

    func testMaximumTimeScoreCannotCompensateForUnsafeSceneSafety() throws {
        var scores = maximumDimensionScores()
        scores[.sceneSafety] = 0.59

        let outcome = try scoringEngine.evaluate(
            scoreInput(dimensionScores: scores),
            policy: .standard
        )

        XCTAssertGreaterThan(outcome.normalisedScore, ScoringPolicy.standard.passThreshold)
        XCTAssertEqual(
            outcome.contributions.first(where: { $0.dimension == .time })?.normalisedScore,
            1
        )
        XCTAssertFalse(outcome.passed)
        XCTAssertTrue(outcome.hasUnsafeCompletion)
        XCTAssertTrue(outcome.requiresMandatoryRemediation)
        XCTAssertFalse(outcome.xpEligible)
        XCTAssertTrue(outcome.remediationCodes.contains("safety_floor.sceneSafety"))
    }

    func testUnsafeCompletionAwardsZeroXPAndNoBadges() throws {
        var scores = maximumDimensionScores()
        scores[.sceneSafety] = 0
        let unsafeOutcome = try scoringEngine.evaluate(scoreInput(dimensionScores: scores))
        let badgeRule = BadgeRule(
            id: "data-driven-test",
            title: "Data-driven test badge",
            metric: "completedChecks",
            comparison: .atLeast,
            target: 1
        )

        let decision = gamificationEngine.evaluate(
            event: event(outcome: unsafeOutcome),
            currentXP: 200,
            metrics: BadgeMetricSnapshot(values: ["completedChecks": 10]),
            existingAwards: [],
            approvedSignOffs: [],
            policy: .standard(badgeRules: [badgeRule])
        )

        XCTAssertEqual(decision.xpAwarded, 0)
        XCTAssertEqual(decision.totalXP, 200)
        XCTAssertTrue(decision.newBadgeAwards.isEmpty)
    }

    func testLevelEightIsBlockedByXPAloneAndAllowedByApprovedPracticalSignOff() throws {
        let safeOutcome = try scoringEngine.evaluate(scoreInput())
        let gamificationEvent = event(outcome: safeOutcome)
        let policy = GamificationPolicy.standard(badgeRules: [])

        let withoutSignOff = gamificationEngine.evaluate(
            event: gamificationEvent,
            currentXP: 10_000,
            metrics: BadgeMetricSnapshot(values: [:]),
            existingAwards: [],
            approvedSignOffs: [],
            policy: policy
        )

        let approvedSignOff = PracticalSignOffValue(
            id: "sign-off-1",
            learnerID: gamificationEvent.learnerID,
            courseID: gamificationEvent.courseID,
            contentVersion: gamificationEvent.contentVersion,
            status: .approved,
            signedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let withSignOff = gamificationEngine.evaluate(
            event: gamificationEvent,
            currentXP: 10_000,
            metrics: BadgeMetricSnapshot(values: [:]),
            existingAwards: [],
            approvedSignOffs: [approvedSignOff],
            policy: policy
        )

        XCTAssertEqual(withoutSignOff.level.id, 7)
        XCTAssertFalse(withoutSignOff.level.requiresApprovedPracticalSignOff)
        XCTAssertEqual(withSignOff.level.id, 8)
        XCTAssertEqual(withSignOff.level.title, "Instructor-Verified Practitioner")
        XCTAssertTrue(withSignOff.level.requiresApprovedPracticalSignOff)
    }

    func testBadgeAwardUsesConfiguredMetricComparisonAndTarget() throws {
        let safeOutcome = try scoringEngine.evaluate(scoreInput())
        let configuredRule = BadgeRule(
            id: "configured-rule",
            title: "Configured Rule",
            metric: "customMetric",
            comparison: .atLeast,
            target: 4
        )
        let policy = GamificationPolicy.standard(badgeRules: [configuredRule])

        let belowTarget = gamificationEngine.evaluate(
            event: event(outcome: safeOutcome),
            currentXP: 0,
            metrics: BadgeMetricSnapshot(values: ["customMetric": 3]),
            existingAwards: [],
            approvedSignOffs: [],
            policy: policy
        )
        let atTarget = gamificationEngine.evaluate(
            event: event(outcome: safeOutcome),
            currentXP: 0,
            metrics: BadgeMetricSnapshot(values: ["customMetric": 4]),
            existingAwards: [],
            approvedSignOffs: [],
            policy: policy
        )

        XCTAssertTrue(belowTarget.newBadgeAwards.isEmpty)
        XCTAssertEqual(atTarget.newBadgeAwards.map(\.badgeID), [configuredRule.id])
        XCTAssertEqual(atTarget.newBadgeAwards.first?.sourceAttemptID, "attempt-1")
    }

    func testPracticeStreakDeduplicatesDaysAndDueDateUsesSpacedRepetitionPolicy() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let augustFifth = try date(year: 2026, month: 8, day: 5, hour: 9, calendar: calendar)
        let augustSixth = try date(year: 2026, month: 8, day: 6, hour: 10, calendar: calendar)
        let augustSeventh = try date(year: 2026, month: 8, day: 7, hour: 11, calendar: calendar)
        let duplicateSeventh = try date(year: 2026, month: 8, day: 7, hour: 17, calendar: calendar)

        let streak = gamificationEngine.practiceStreak(
            successfulPracticeDates: [augustFifth, augustSixth, augustSeventh, duplicateSeventh],
            through: duplicateSeventh,
            calendar: calendar
        )
        let dueDate = gamificationEngine.nextReviewDate(
            lastPractice: augustSeventh,
            successfulRepetitionCount: 2,
            policy: .standard,
            calendar: calendar
        )

        XCTAssertEqual(streak, 3)
        XCTAssertEqual(
            calendar.dateComponents([.day], from: augustSeventh, to: dueDate).day,
            7
        )
    }

    func testCPRPracticeScoreUsesOnlyCollectedPracticeDimensionsAndIsDeterministic() throws {
        let machine = completedPracticeMachine(handStacking: .likelyStacked)
        let input = practiceScoreInput(from: machine)

        let first = try scoringEngine.evaluate(input)
        let replayed = try scoringEngine.evaluate(input)

        XCTAssertEqual(first, replayed)
        XCTAssertEqual(
            first.contributions.map(\.dimension),
            CPRPracticeScoringDimension.allCases
        )
        XCTAssertEqual(first.normalisedScore, 1, accuracy: 0.000_001)
        XCTAssertEqual(first.percentage, 100, accuracy: 0.000_001)
        XCTAssertTrue(first.passed)
        XCTAssertTrue(first.xpEligible)
        XCTAssertFalse(first.hasUnsafeCompletion)

        let encodedInput = try XCTUnwrap(String(
            data: JSONEncoder().encode(input),
            encoding: .utf8
        ))
        XCTAssertFalse(encodedInput.contains("compressionDepth"))
        XCTAssertFalse(encodedInput.contains("forceNewtons"))
        XCTAssertFalse(encodedInput.contains("sceneSafety"))
        XCTAssertFalse(encodedInput.contains("communication"))
    }

    func testIndeterminatePostureDoesNotBlockAccessibleFallbackCompletion() throws {
        let machine = completedPracticeMachine(handStacking: .indeterminate)

        let outcome = try scoringEngine.evaluate(practiceScoreInput(from: machine))
        let posture = try XCTUnwrap(
            outcome.contributions.first(where: { $0.dimension == .postureHeuristic })
        )

        XCTAssertNil(posture.normalisedScore)
        XCTAssertFalse(posture.wasAssessed)
        XCTAssertEqual(posture.evidenceCount, 0)
        XCTAssertEqual(outcome.normalisedScore, 1, accuracy: 0.000_001)
        XCTAssertTrue(outcome.passed)
        XCTAssertTrue(outcome.xpEligible)
    }

    func testIncompleteCompressionCycleCannotPassOrEarnCompletionXP() throws {
        var machine = activePracticeMachine(
            handStacking: .indeterminate,
            compressionCount: 1
        )
        machine.handle(.stop(.emergencyTeamTookOver))
        machine.handle(.finish)

        let outcome = try scoringEngine.evaluate(practiceScoreInput(from: machine))

        XCTAssertEqual(machine.metrics.completedCycles, 0)
        XCTAssertFalse(outcome.passed)
        XCTAssertFalse(outcome.xpEligible)
    }

    func testCPRCriticalFailureBlocksPassAndXPAndProducesSortedUniqueRemediation() throws {
        let machine = completedPracticeMachine(handStacking: .likelyStacked)
        let input = CPRPracticeScoreInput(
            attemptID: "practice-attempt-unsafe",
            contentVersion: "1.0.0",
            metrics: machine.metrics,
            criticalFailures: [
                .prolongedInterruption,
                .compressionOnXiphoid,
                .prolongedInterruption
            ]
        )

        let outcome = try scoringEngine.evaluate(input)

        XCTAssertFalse(outcome.passed)
        XCTAssertFalse(outcome.xpEligible)
        XCTAssertTrue(outcome.hasUnsafeCompletion)
        XCTAssertTrue(outcome.requiresMandatoryRemediation)
        XCTAssertEqual(
            outcome.remediationCodes,
            [
                CPRPracticeCriticalFailure.compressionOnXiphoid.rawValue,
                CPRPracticeCriticalFailure.prolongedInterruption.rawValue
            ].sorted()
        )
    }

    func testCPRScoringInfersProlongedInterruptionFailureFromMetrics() throws {
        var machine = activePracticeMachine(handStacking: .likelyStacked, compressionCount: 4)
        machine.handle(.recordInterruption(durationSeconds: 10.01))
        machine.handle(.stop(.emergencyTeamTookOver))
        machine.handle(.finish)
        let input = CPRPracticeScoreInput(
            attemptID: "practice-attempt-interruption",
            contentVersion: "1.0.0",
            metrics: machine.metrics,
            // Defense in depth: scoring still blocks if a caller accidentally omits the
            // state machine's critical-failure array.
            criticalFailures: []
        )

        let outcome = try scoringEngine.evaluate(input)

        XCTAssertTrue(outcome.hasUnsafeCompletion)
        XCTAssertFalse(outcome.xpEligible)
        XCTAssertEqual(
            outcome.remediationCodes,
            [CPRPracticeCriticalFailure.prolongedInterruption.rawValue]
        )
    }

    func testCPRScoringRejectsInconsistentMetrics() {
        let machine = completedPracticeMachine(handStacking: .likelyStacked)
        var invalidMetrics = machine.metrics
        invalidMetrics.cadenceBands.removeLast()
        let input = CPRPracticeScoreInput(
            attemptID: "practice-attempt-invalid",
            contentVersion: "1.0.0",
            metrics: invalidMetrics,
            criticalFailures: []
        )

        XCTAssertThrowsError(try scoringEngine.evaluate(input)) { error in
            XCTAssertEqual(error as? CPRPracticeScoringError, .invalidMetrics)
        }
    }

    func testCPRSummaryWithNoVerifiedSensorLabelsDepthAndForceNotPhysicallyAssessed() async throws {
        let machine = completedPracticeMachine(handStacking: .indeterminate)
        let input = practiceScoreInput(from: machine)
        let fixtureMeasurement = CPRSensorMeasurement(
            providerIdentifier: "unit-test-sensor",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_010),
            compressionDepthMetres: 0.05,
            forceNewtons: 400
        )
        let unverifiedProvider = InMemoryCPRSensorProvider(
            isVerifiedExternalSensorConnected: false,
            measurement: fixtureMeasurement
        )

        let withoutProvider = try await scoringEngine.summarize(input)
        let withUnverifiedProvider = try await scoringEngine.summarize(
            input,
            sensorProvider: unverifiedProvider
        )

        for summary in [withoutProvider, withUnverifiedProvider] {
            XCTAssertEqual(summary.depthAssessment.status, .notPhysicallyAssessed)
            XCTAssertEqual(summary.depthAssessment.statusLabel, "Not physically assessed")
            XCTAssertNil(summary.depthAssessment.value)
            XCTAssertEqual(summary.forceAssessment.status, .notPhysicallyAssessed)
            XCTAssertEqual(summary.forceAssessment.statusLabel, "Not physically assessed")
            XCTAssertNil(summary.forceAssessment.value)
            XCTAssertEqual(summary.recordLabel, "Internal practice completion record")
            XCTAssertTrue(summary.certificationNotice.contains("not SRFAC certification"))
            XCTAssertTrue(summary.certificationNotice.contains("instructor sign-off"))
        }
    }

    func testCPRSummaryExposesOnlyValuesFromVerifiedExternalSensor() async throws {
        let machine = completedPracticeMachine(handStacking: .likelyStacked)
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_020)
        let verifiedProvider = InMemoryCPRSensorProvider(
            isVerifiedExternalSensorConnected: true,
            measurement: CPRSensorMeasurement(
                providerIdentifier: "unit-test-sensor",
                capturedAt: capturedAt,
                compressionDepthMetres: 0.051,
                forceNewtons: 410
            )
        )

        let summary = try await scoringEngine.summarize(
            practiceScoreInput(from: machine),
            sensorProvider: verifiedProvider
        )

        XCTAssertEqual(summary.depthAssessment.status, .verifiedExternalSensor)
        XCTAssertEqual(summary.depthAssessment.value, 0.051)
        XCTAssertEqual(summary.depthAssessment.unit, .metres)
        XCTAssertEqual(summary.depthAssessment.providerIdentifier, "unit-test-sensor")
        XCTAssertEqual(summary.depthAssessment.capturedAt, capturedAt)
        XCTAssertEqual(summary.forceAssessment.status, .verifiedExternalSensor)
        XCTAssertEqual(summary.forceAssessment.value, 410)
        XCTAssertEqual(summary.forceAssessment.unit, .newtons)
    }

    func testCPRPracticeGamificationUsesSafeCompletionXPAndXPEligibility() throws {
        let machine = completedPracticeMachine(handStacking: .indeterminate)
        let safeOutcome = try scoringEngine.evaluate(practiceScoreInput(from: machine))
        let safeEvent = practiceGamificationEvent(outcome: safeOutcome)
        let policy = GamificationPolicy.standard(badgeRules: [])

        let safeDecision = gamificationEngine.evaluate(
            event: safeEvent,
            currentXP: 25,
            metrics: BadgeMetricSnapshot(values: [:]),
            existingAwards: [],
            approvedSignOffs: [],
            policy: policy
        )

        let unsafeInput = CPRPracticeScoreInput(
            attemptID: "practice-attempt-unsafe-xp",
            contentVersion: "1.0.0",
            metrics: machine.metrics,
            criticalFailures: [.compressionOnXiphoid]
        )
        let unsafeOutcome = try scoringEngine.evaluate(unsafeInput)
        let unsafeDecision = gamificationEngine.evaluate(
            event: practiceGamificationEvent(outcome: unsafeOutcome),
            currentXP: 25,
            metrics: BadgeMetricSnapshot(values: [:]),
            existingAwards: [],
            approvedSignOffs: [],
            policy: policy
        )

        XCTAssertEqual(safeDecision.xpAwarded, policy.safeCompletionXP)
        XCTAssertEqual(safeDecision.totalXP, 25 + policy.safeCompletionXP)
        XCTAssertEqual(unsafeDecision.xpAwarded, 0)
        XCTAssertEqual(unsafeDecision.totalXP, 25)
        XCTAssertLessThan(safeDecision.level.id, 8)
        XCTAssertFalse(safeDecision.level.requiresApprovedPracticalSignOff)
    }

    private func maximumDimensionScores() -> [ScoringDimension: Double] {
        Dictionary(uniqueKeysWithValues: ScoringDimension.allCases.map { ($0, 1) })
    }

    private func scoreInput(
        dimensionScores: [ScoringDimension: Double]? = nil,
        criticalErrors: [CriticalError] = []
    ) -> ScenarioScoreInput {
        ScenarioScoreInput(
            attemptID: "attempt-1",
            contentVersion: "1.0.0",
            dimensionScores: dimensionScores ?? maximumDimensionScores(),
            criticalErrors: criticalErrors
        )
    }

    private func event(outcome: ScenarioScoreOutcome) -> GamificationEvent {
        GamificationEvent(
            learnerID: "learner-1",
            courseID: "course-1",
            contentVersion: outcome.contentVersion,
            sourceAttemptID: outcome.attemptID,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scoreOutcome: outcome
        )
    }

    private func activePracticeMachine(
        handStacking: CPRHandStackingHeuristic,
        compressionCount: Int = CPRPracticePolicy.sourceBacked.preferredCompressionsPerCycle
    ) -> CPRPracticeStateMachine {
        var machine = CPRPracticeStateMachine()
        machine.handle(.confirmPositioning)
        machine.handle(.classifyHandPlacement(.sternumTarget))
        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        for index in 0..<compressionCount {
            machine.handle(
                .compressionDetected(
                    timestampSeconds: Double(index) * interval,
                    placement: .sternumTarget,
                    handStacking: handStacking
                )
            )
        }
        return machine
    }

    private func completedPracticeMachine(
        handStacking: CPRHandStackingHeuristic
    ) -> CPRPracticeStateMachine {
        var machine = activePracticeMachine(handStacking: handStacking)
        machine.handle(.stop(.emergencyTeamTookOver))
        machine.handle(.finish)
        return machine
    }

    private func practiceScoreInput(
        from machine: CPRPracticeStateMachine
    ) -> CPRPracticeScoreInput {
        CPRPracticeScoreInput(
            attemptID: "practice-attempt-1",
            contentVersion: "1.0.0",
            metrics: machine.metrics,
            criticalFailures: machine.criticalFailures
        )
    }

    private func practiceGamificationEvent(
        outcome: CPRPracticeScoreOutcome
    ) -> CPRPracticeGamificationEvent {
        CPRPracticeGamificationEvent(
            learnerID: "learner-1",
            courseID: "course-1",
            contentVersion: outcome.contentVersion,
            sourceAttemptID: outcome.attemptID,
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scoreOutcome: outcome
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    calendar: calendar,
                    timeZone: calendar.timeZone,
                    year: year,
                    month: month,
                    day: day,
                    hour: hour
                )
            )
        )
    }
}
