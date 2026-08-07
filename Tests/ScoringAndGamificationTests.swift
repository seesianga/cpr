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
