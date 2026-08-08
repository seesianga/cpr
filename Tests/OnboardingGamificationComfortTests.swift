import Foundation
import RealityKit
import XCTest
@testable import LifesaverVision

@MainActor
final class OnboardingGamificationComfortTests: XCTestCase {
    func testOnboardingCompletionIsScopedToLearnerCourseAndVersion() throws {
        let suiteName = "OnboardingCompletionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = OnboardingCompletionStore(defaults: defaults)

        XCTAssertFalse(store.isComplete(
            learnerID: "learner-a",
            courseID: "course-a",
            contentVersion: "1.0.0"
        ))
        store.markComplete(
            learnerID: "learner-a",
            courseID: "course-a",
            contentVersion: "1.0.0"
        )

        XCTAssertTrue(store.isComplete(
            learnerID: "learner-a",
            courseID: "course-a",
            contentVersion: "1.0.0"
        ))
        XCTAssertFalse(store.isComplete(
            learnerID: "learner-b",
            courseID: "course-a",
            contentVersion: "1.0.0"
        ))
        XCTAssertFalse(store.isComplete(
            learnerID: "learner-a",
            courseID: "course-a",
            contentVersion: "2.0.0"
        ))

        store.clear(learnerID: "learner-a")
        XCTAssertFalse(store.isComplete(
            learnerID: "learner-a",
            courseID: "course-a",
            contentVersion: "1.0.0"
        ))
    }

    func testOnboardingPracticeRequiresBothPauseAndActualExit() {
        XCTAssertFalse(OnboardingPracticeGate.isComplete(
            pausePractised: false,
            exitPractised: false
        ))
        XCTAssertFalse(OnboardingPracticeGate.isComplete(
            pausePractised: false,
            exitPractised: true
        ))
        XCTAssertFalse(OnboardingPracticeGate.isComplete(
            pausePractised: true,
            exitPractised: false
        ))
        XCTAssertTrue(OnboardingPracticeGate.isComplete(
            pausePractised: true,
            exitPractised: true
        ))
    }

    func testComfortCalibrationIsSessionScopedInAppModel() {
        let model = AppModel()
        model.configureOnboardingSession(
            posture: .seated,
            dominantHand: .left,
            inputMethod: .eyesAndHands
        )

        XCTAssertEqual(model.onboardingComfortPosture, .seated)
        XCTAssertEqual(model.onboardingDominantHand, .left)
        XCTAssertEqual(model.onboardingInputMethod, .eyesAndHands)
    }

    func testComfortCalibrationDefaultsToUnsetAndAcceptsNoHandPreference() {
        let model = AppModel()

        XCTAssertNil(model.onboardingComfortPosture)
        XCTAssertNil(model.onboardingDominantHand)
        XCTAssertNil(model.onboardingInputMethod)

        model.configureOnboardingSession(
            posture: .standing,
            dominantHand: .noPreference,
            inputMethod: .accessibilityControl
        )

        XCTAssertEqual(model.onboardingComfortPosture, .standing)
        XCTAssertEqual(model.onboardingDominantHand, .noPreference)
        XCTAssertEqual(model.onboardingInputMethod, .accessibilityControl)
    }

    func testInternalAEDRoomTransitionClearsOnlyAfterSelectedRoomLoads() {
        let model = AppModel()
        model.selectPractice(.aed)

        model.moveAEDPractice(to: .aedPlacementRoom)
        XCTAssertEqual(model.selectedSimulationScene, .aedPlacementRoom)
        XCTAssertTrue(model.isSimulationRoomTransitionInFlight)

        model.simulationRoomDidLoad(.aedPreparationRoom)
        XCTAssertTrue(model.isSimulationRoomTransitionInFlight)

        model.simulationRoomDidLoad(.aedPlacementRoom)
        XCTAssertFalse(model.isSimulationRoomTransitionInFlight)
    }

    func testComfortSuggestionAppearsAtTwelveMinutesPersistsAndNeverEndsSession() {
        let session = ImmersionComfortSession()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        session.start(at: start)
        session.update(at: start.addingTimeInterval(719))
        XCTAssertFalse(session.isBreakSuggestionVisible)

        session.update(at: start.addingTimeInterval(720))
        XCTAssertTrue(session.isBreakSuggestionVisible)
        XCTAssertTrue(session.didSuggestBreak)

        session.update(at: start.addingTimeInterval(900))
        XCTAssertTrue(session.isBreakSuggestionVisible)
        session.dismissSuggestion()
        XCTAssertFalse(session.isBreakSuggestionVisible)
        XCTAssertEqual(session.elapsedImmersionTime, 900, accuracy: 0.001)
    }

    func testComfortTimerExcludesInactiveTime() {
        let session = ImmersionComfortSession()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        session.start(at: start)
        session.suspend(at: start.addingTimeInterval(300))
        session.resume(at: start.addingTimeInterval(900))
        session.update(at: start.addingTimeInterval(1_319))
        XCTAssertEqual(session.elapsedImmersionTime, 719, accuracy: 0.001)
        XCTAssertFalse(session.isBreakSuggestionVisible)
        session.update(at: start.addingTimeInterval(1_320))
        XCTAssertTrue(session.isBreakSuggestionVisible)
    }

    func testInternalRoomTaskDoesNotResetContinuousComfortTime() {
        let session = ImmersionComfortSession(breakThreshold: 12)
        let start = Date(timeIntervalSince1970: 2_000)
        session.startIfNeeded(at: start)
        session.update(at: start.addingTimeInterval(8))

        session.startIfNeeded(at: start.addingTimeInterval(9))
        session.update(at: start.addingTimeInterval(12))

        XCTAssertEqual(session.elapsedImmersionTime, 12, accuracy: 0.001)
        XCTAssertTrue(session.isBreakSuggestionVisible)
    }

    func testImmersivePanelIsPlacedOnceAndRecentreUsesFreshOneShotTarget() {
        XCTAssertEqual(ImmersivePanelPlacementPolicy.trackingMode, .once)
        let anchor = ImmersivePanelPlacementPolicy.makeAnchor()
        XCTAssertEqual(anchor.anchoring.trackingMode, .once)

        ImmersivePanelPlacementPolicy.recentre(anchor)

        XCTAssertEqual(anchor.anchoring.trackingMode, .once)
        XCTAssertEqual(
            ImmersivePanelPlacementPolicy.interfaceOffset(
                horizontalBias: -0.10,
                isSeated: true
            ),
            SIMD3<Float>(-0.10, -0.12, -1.35)
        )
    }

    func testEffectiveReduceMotionUsesSystemOrAppPreference() {
        XCTAssertFalse(SpatialAccessibility.effectiveReduceMotion(
            systemSetting: false,
            appSetting: false
        ))
        XCTAssertTrue(SpatialAccessibility.effectiveReduceMotion(
            systemSetting: true,
            appSetting: false
        ))
        XCTAssertTrue(SpatialAccessibility.effectiveReduceMotion(
            systemSetting: false,
            appSetting: true
        ))
    }

    func testMasteryMatrixKeepsLockedModuleLockedAndSeparatesLearningFromPractice() {
        let m4 = presentedModule(id: "M4", title: "Hands-only CPR", presentable: true)
        let m9 = presentedModule(id: "M9", title: "Child awareness", presentable: false)
        let attempt = PracticeAttemptEvidence(
            id: "attempt-1",
            activityID: "M4-cpr-practice",
            attemptKind: "practice",
            completedAt: Date(timeIntervalSince1970: 1_700_000_000),
            score: 92,
            passed: true,
            criticalErrorCodes: []
        )

        let rows = MasteryMatrixBuilder().build(
            modules: [m4, m9],
            completedModuleIDs: ["M4"],
            attempts: [attempt]
        )

        let m4Row = rows[0]
        XCTAssertEqual(
            m4Row.cells.first(where: { $0.skill == .knowledge })?.status,
            .learningComplete
        )
        XCTAssertEqual(
            m4Row.cells.first(where: { $0.skill == .rhythm })?.status,
            .safePracticeEvidence
        )
        XCTAssertTrue(rows[1].cells.allSatisfy { $0.status == .locked })
    }

    func testUnsafeAttemptsDoNotCountTowardStreakXPOrPersonalBest() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let safe = PracticeAttemptEvidence(
            id: "safe",
            activityID: "M4-cpr-practice",
            attemptKind: "practice",
            completedAt: now,
            score: 90,
            passed: true,
            criticalErrorCodes: []
        )
        let unsafe = PracticeAttemptEvidence(
            id: "unsafe",
            activityID: "M5-aed-practice",
            attemptKind: "practice",
            completedAt: now,
            score: 100,
            passed: true,
            criticalErrorCodes: ["unsafe.contact"]
        )

        let summary = PracticeDashboardSummary.make(
            attempts: [safe, unsafe],
            through: now,
            calendar: calendar
        )

        XCTAssertEqual(summary.successfulAttemptCount, 1)
        XCTAssertEqual(summary.derivedXP, 100)
        XCTAssertEqual(summary.personalBests.map(\.activityID), ["M4-cpr-practice"])
    }

    func testBadgeAssetsHaveStableConfiguredMappingAndFourteenPlaceholders() {
        let rules = [
            BadgeRule(
                id: "first",
                title: "First",
                metric: "metric",
                comparison: .atLeast,
                target: 1
            )
        ]
        let catalogue = AchievementBadgeDescriptor.catalogue(rules: rules)

        XCTAssertEqual(catalogue.count, 14)
        XCTAssertEqual(catalogue.first?.id, "first")
        XCTAssertEqual(catalogue.first?.assetName, "badge_m01")
        XCTAssertEqual(catalogue.last?.assetName, "badge_m14")
        XCTAssertFalse(try XCTUnwrap(catalogue.last).isConfigured)
    }

    private func presentedModule(
        id: String,
        title: String,
        presentable: Bool
    ) -> PresentedCourseModule {
        PresentedCourseModule(
            module: Module(
                id: id,
                title: title,
                summary: "Summary",
                order: Int(id.dropFirst()) ?? 0,
                lessons: [],
                sourceReferences: []
            ),
            isPresentable: presentable,
            lockReasons: presentable ? [] : [.unavailable]
        )
    }
}
