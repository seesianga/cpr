import simd
import XCTest
@testable import LifesaverVision

@MainActor
final class CPRPracticeSessionModelTests: XCTestCase {
    func testDeniedTrackingFallbackCompletesSourceBackedCycleAndAwardsXP() async throws {
        let driver = SimulatedHandInput(startState: .permissionDenied)
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)

        XCTAssertEqual(model.handTrackingState, .permissionDenied)
        XCTAssertTrue(model.handTrackingState.usesAccessibleFallback)

        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)
        let lastTimestamp = recordCompleteFallbackCycle(in: model, startingAt: 1_000)
        await model.endSession(currentXP: 20, at: lastTimestamp + 0.1)

        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.totalCompressions, model.minimumCompressionsForCompletion)
        XCTAssertEqual(summary.completedCycles, 1)
        XCTAssertTrue(summary.scoreOutcome.passed)
        XCTAssertEqual(summary.depthAssessment.status, .notPhysicallyAssessed)
        XCTAssertEqual(summary.forceAssessment.status, .notPhysicallyAssessed)
        XCTAssertGreaterThan(model.gamificationDecision?.xpAwarded ?? 0, 0)
        await model.stop()
    }

    func testSimulatedHandInputStreamCompletesScoredSessionWithoutPhysicalMeasurements() async throws {
        let driver = SimulatedHandInput(
            detectorConfiguration: HandSignalDetectorConfiguration(
                maximumHandSampleAgeSeconds: 0.20,
                smoothingFactor: 1,
                minimumDirectionalChangeMetres: 0.001,
                oscillationHysteresisMetres: 0.02,
                minimumCompressionIntervalSeconds: 0.20,
                minimumGapReportedAsInterruptionSeconds: 1.1,
                maximumTrackingRadiusMetres: 0.60,
                targetLateralMarginMetres: 0,
                maximumHeightAboveTargetMetres: 0.40,
                maximumDistanceBelowTargetMetres: 0.05,
                maximumStackedPalmSeparationMetres: 0.16
            )
        )
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)
        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)

        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        _ = driver.submit(
            SimulatedHandFrame(timestampSeconds: 0, leftPalmWorld: [0, 0.16, 0])
        )
        await Task.yield()
        for index in 0..<model.minimumCompressionsForCompletion {
            let cycleStart = Double(index) * interval
            _ = driver.submit(
                SimulatedHandFrame(
                    timestampSeconds: cycleStart + 0.10,
                    leftPalmWorld: [0, 0.10, 0]
                )
            )
            _ = driver.submit(
                SimulatedHandFrame(
                    timestampSeconds: cycleStart + 0.20,
                    leftPalmWorld: [0, 0.16, 0]
                )
            )
            await Task.yield()
        }

        for _ in 0..<200 {
            if model.metrics.totalCompressions == model.minimumCompressionsForCompletion {
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(
            model.metrics.totalCompressions,
            model.minimumCompressionsForCompletion
        )
        XCTAssertEqual(model.metrics.completedCycles, 1)
        await model.endSession()

        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(model.state, .complete)
        XCTAssertTrue(summary.scoreOutcome.passed)
        XCTAssertTrue(summary.scoreOutcome.xpEligible)
        XCTAssertEqual(summary.depthAssessment.status, .notPhysicallyAssessed)
        XCTAssertNil(summary.depthAssessment.value)
        XCTAssertEqual(summary.forceAssessment.status, .notPhysicallyAssessed)
        XCTAssertNil(summary.forceAssessment.value)
        await model.stop()
    }

    func testZeroCompressionAttemptCannotCreateCompletionRecordOrXP() async throws {
        let driver = SimulatedHandInput(startState: .permissionDenied)
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)

        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)
        await model.endSession(at: 1_000)

        XCTAssertNil(model.summary)
        XCTAssertNil(model.gamificationDecision)
        XCTAssertEqual(model.state, .compressionCycles)
        XCTAssertTrue(model.latestFeedback?.contains("about 100 compressions") == true)
        await model.stop()
    }

    func testTransientXiphoidTransitDoesNotRecordCriticalPlacementFailure() async throws {
        let driver = SimulatedHandInput()
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)
        model.confirmPositioning()
        XCTAssertEqual(model.state, .landmarkCheck)

        _ = driver.submit(
            SimulatedHandFrame(
                timestampSeconds: 0,
                leftPalmWorld: [0, 0.12, 0.30]
            )
        )
        _ = driver.submit(
            SimulatedHandFrame(
                timestampSeconds: 0.20,
                leftPalmWorld: [0, 0.12, 0]
            )
        )

        for _ in 0..<40 where model.state != .compressionCycles {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.state, .compressionCycles)
        XCTAssertTrue(model.criticalFailures.isEmpty)
        XCTAssertEqual(model.metrics.totalCompressions, 0)
        await model.stop()
    }

    func testSustainedXiphoidPlacementDwellRecordsCriticalFailure() async throws {
        let driver = SimulatedHandInput()
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)
        model.confirmPositioning()

        for timestamp in [0.0, 0.20, HandSignalDetector.criticalPlacementDwellSeconds] {
            _ = driver.submit(
                SimulatedHandFrame(
                    timestampSeconds: timestamp,
                    leftPalmWorld: [0, 0.12, 0.30]
                )
            )
        }

        for _ in 0..<40 where model.state != .correctiveFeedback {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.state, .correctiveFeedback)
        XCTAssertEqual(model.criticalFailures, [.compressionOnXiphoid])
        XCTAssertEqual(model.metrics.totalCompressions, 0)
        await model.stop()
    }

    func testTerminalGapAboveTenSecondsIsRecordedAndBlocksXP() async throws {
        let driver = SimulatedHandInput(startState: .permissionDenied)
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)

        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)
        let lastTimestamp = recordCompleteFallbackCycle(in: model, startingAt: 2_000)
        await model.endSession(at: lastTimestamp + 10.01)

        let summary = try XCTUnwrap(model.summary)
        XCTAssertEqual(summary.longestInterruptionSeconds, 10.01, accuracy: 0.001)
        XCTAssertTrue(summary.scoreOutcome.hasUnsafeCompletion)
        XCTAssertFalse(summary.scoreOutcome.xpEligible)
        XCTAssertEqual(model.gamificationDecision?.xpAwarded, 0)
        await model.stop()
    }

    func testPauseDurationIsExcludedFromFallbackCadenceAndInterruption() async throws {
        let driver = SimulatedHandInput()
        let model = CPRPracticeSessionModel(handTracking: driver)
        try await prepare(model, driver: driver)

        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)
        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        model.recordFallbackCompression(at: 100)
        await model.setPaused(true, at: 100)
        await model.setPaused(false, at: 110)
        model.recordFallbackCompression(at: 110 + interval)

        XCTAssertEqual(model.metrics.latestCadencePerMinute ?? 0, 110, accuracy: 0.001)
        XCTAssertTrue(model.metrics.interruptions.isEmpty)
        await model.stop()
    }

    func testScoredSummarySurvivesGamificationPolicyLoadFailure() async throws {
        let driver = SimulatedHandInput(startState: .permissionDenied)
        let model = CPRPracticeSessionModel(
            handTracking: driver,
            badgeRuleLoader: { _ in throw FixtureError.missingBadgePolicy }
        )
        try await prepare(model, driver: driver)

        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)
        let lastTimestamp = recordCompleteFallbackCycle(in: model, startingAt: 3_000)
        await model.endSession(at: lastTimestamp + 0.1)

        XCTAssertNotNil(model.summary)
        XCTAssertNil(model.gamificationDecision)
        XCTAssertTrue(model.latestFeedback?.contains("summary is available") == true)
        XCTAssertTrue(model.latestFeedback?.contains("No XP was awarded") == true)
        await model.stop()
    }

    func testMetronomeUsesInjectedAudioDirectorCue() async throws {
        let audio = RecordingAudioDirector()
        let model = CPRPracticeSessionModel(audioDirector: audio)

        await model.prepare()
        try await Task.sleep(for: .milliseconds(650))
        await model.stop()

        let snapshot = await audio.snapshot()
        XCTAssertTrue(snapshot.wasPrepared)
        XCTAssertTrue(snapshot.wasStopped)
        XCTAssertTrue(snapshot.cueIDs.contains("sfx.metronome"))
    }

    func testInterruptionPresentationNeverReliesOnColourAlone() {
        let inactive = CPRInterruptionPresentation(seconds: 0)
        XCTAssertEqual(inactive.status, .inactive)
        XCTAssertFalse(inactive.label.isEmpty)
        XCTAssertFalse(inactive.systemImage.isEmpty)

        let underway = CPRInterruptionPresentation(seconds: 10)
        XCTAssertEqual(underway.status, .underway)
        XCTAssertTrue(underway.label.contains("underway"))

        let exceeded = CPRInterruptionPresentation(seconds: 10.1)
        XCTAssertEqual(exceeded.status, .thresholdExceeded)
        XCTAssertTrue(exceeded.isThresholdExceeded)
        XCTAssertTrue(exceeded.label.contains("10-second"))
        XCTAssertTrue(exceeded.systemImage.contains("exclamationmark"))
    }

    private func prepare(
        _ model: CPRPracticeSessionModel,
        driver: SimulatedHandInput
    ) async throws {
        await model.prepare()
        let targets = try makeTargets()
        model.configureHandTracking(targets: targets)
        await model.startHandTracking()
        XCTAssertEqual(model.loadState, .ready)
    }

    @discardableResult
    private func recordCompleteFallbackCycle(
        in model: CPRPracticeSessionModel,
        startingAt start: Double
    ) -> Double {
        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        var timestamp = start
        for index in 0..<model.minimumCompressionsForCompletion {
            timestamp = start + Double(index) * interval
            model.recordFallbackCompression(at: timestamp)
        }
        return timestamp
    }

    private func makeTargets() throws -> HandTrackingTargets {
        let sternum = try XCTUnwrap(HandTrackingTargetVolume(
            worldFromTargetTransform: matrix_identity_float4x4,
            localCenter: .zero,
            localExtents: [0.20, 0.02, 0.20]
        ))
        var xiphoidTransform = matrix_identity_float4x4
        xiphoidTransform.columns.3 = [0, 0, 0.30, 1]
        let xiphoid = try XCTUnwrap(HandTrackingTargetVolume(
            worldFromTargetTransform: xiphoidTransform,
            localCenter: .zero,
            localExtents: [0.08, 0.02, 0.08]
        ))
        return HandTrackingTargets(sternum: sternum, xiphoidAvoidZone: xiphoid)
    }
}

private enum FixtureError: Error {
    case missingBadgePolicy
}

private actor RecordingAudioDirector: AudioDirector {
    struct Snapshot: Sendable {
        let wasPrepared: Bool
        let wasStopped: Bool
        let cueIDs: [String]
    }

    private var wasPrepared = false
    private var wasStopped = false
    private var cueIDs: [String] = []

    func prepare() async throws {
        wasPrepared = true
    }

    func play(_ cue: AudioCue) async {
        cueIDs.append(cue.rawValue)
    }

    func stopAll() async {
        wasStopped = true
    }

    func snapshot() -> Snapshot {
        Snapshot(
            wasPrepared: wasPrepared,
            wasStopped: wasStopped,
            cueIDs: cueIDs
        )
    }
}
