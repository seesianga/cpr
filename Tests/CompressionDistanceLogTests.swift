import XCTest
import simd
@testable import LifesaverVision

/// Coverage for the per-compression distance log and the clamped adaptive thresholds:
/// every contact cycle records its measured virtual travel, near-miss descents widen
/// the entry tolerance when compressions are being missed, and session models surface
/// the log plus adaptation feedback.
final class CompressionDistanceLogTests: XCTestCase {

    // MARK: - Detector distance log

    func testEveryContactCycleRecordsADistanceSample() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())

        let frequency = 110.0 / 60
        let durationSeconds = 20.0
        var compressions = 0
        var samples: [CompressionDistanceSample] = []
        var time = 0.0
        while time <= durationSeconds {
            // Height oscillates in [-0.005, +0.020] m: bottoms just below the surface.
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0075 + 0.0125 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            compressions += detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeNodes(palmProxy: contact + [0, 0.03, 0]),
                rightNodes: makeNodes(palmProxy: contact)
            ).count
            samples.append(contentsOf: detector.drainDistanceTelemetry().samples)
            time += 1 / 60.0
        }

        let expectedCycles = durationSeconds * frequency
        XCTAssertGreaterThanOrEqual(
            Double(samples.count),
            expectedCycles * 0.9,
            "Each completed contact cycle must contribute a distance sample"
        )
        XCTAssertEqual(samples.count, detector.distanceLog.count)
        XCTAssertLessThanOrEqual(
            detector.distanceLog.count,
            FingerContactCompressionDetector.maximumDistanceLogEntries
        )

        let counted = samples.filter(\.countedAsCompression)
        XCTAssertGreaterThanOrEqual(counted.count, compressions - 1)
        for sample in counted {
            XCTAssertEqual(sample.placement, .sternumTarget)
            // The sinusoid spans 2.5 cm; each recorded travel must sit near it.
            XCTAssertEqual(sample.descentDistanceMetres, 0.025, accuracy: 0.010)
            XCTAssertGreaterThanOrEqual(sample.depthBelowSurfaceMetres, 0)
            XCTAssertLessThanOrEqual(sample.depthBelowSurfaceMetres, 0.006)
        }
    }

    func testNearMissBouncesWidenEntryToleranceAndRecoverMissedCompressions() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())
        XCTAssertEqual(detector.activeEntryToleranceMetres, 0.02, accuracy: 0.0001)

        // Genuine pumping motion whose troughs sit at 2.5 cm — just ABOVE the static
        // 2 cm entry band, so the static thresholds would miss every cycle.
        let frequency = 110.0 / 60
        var compressions = 0
        var adaptations: [CompressionThresholdAdaptation] = []
        var compressionsAfterAdaptation = 0
        var time = 0.0
        while time <= 15 {
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0375 + 0.0125 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            let detected = detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeNodes(palmProxy: contact + [0, 0.03, 0]),
                rightNodes: makeNodes(palmProxy: contact)
            ).count
            compressions += detected
            if !adaptations.isEmpty {
                compressionsAfterAdaptation += detected
            }
            adaptations.append(
                contentsOf: detector.drainDistanceTelemetry().adaptation.map { [$0] } ?? []
            )
            time += 1 / 60.0
        }

        let widening = try XCTUnwrap(
            adaptations.first,
            "Repeated near-miss descents must widen the entry tolerance"
        )
        XCTAssertEqual(widening.reason, .nearMissDescentsAboveEntryBand)
        XCTAssertGreaterThan(detector.activeEntryToleranceMetres, 0.02)
        XCTAssertLessThanOrEqual(detector.activeEntryToleranceMetres, 0.05)
        XCTAssertGreaterThan(
            compressionsAfterAdaptation,
            0,
            "Once the threshold adapts, previously missed cycles must register"
        )
        let nearMisses = detector.distanceLog.filter { !$0.countedAsCompression }
        XCTAssertFalse(nearMisses.isEmpty, "Near-miss descents belong in the log")
    }

    func testResetRestoresConfiguredThresholdsAndClearsLog() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())
        let frequency = 110.0 / 60
        var time = 0.0
        while time <= 8 {
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0375 + 0.0125 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            _ = detector.processFrame(
                timestampSeconds: time,
                leftNodes: nil,
                rightNodes: makeNodes(palmProxy: contact)
            )
            time += 1 / 60.0
        }
        XCTAssertGreaterThan(detector.activeEntryToleranceMetres, 0.02)

        detector.reset()

        XCTAssertEqual(detector.activeEntryToleranceMetres, 0.02, accuracy: 0.0001)
        XCTAssertEqual(detector.activeReleaseHysteresisMetres, 0.012, accuracy: 0.0001)
        XCTAssertTrue(detector.distanceLog.isEmpty)
        XCTAssertTrue(detector.drainDistanceTelemetry().isEmpty)
    }

    func testComposedDetectorEmitsDistanceAndAdaptationEvents() throws {
        var detector = ComposedHandSignalDetector(targets: try makeGridTargets())

        let frequency = 110.0 / 60
        var events: [HandTrackingDerivedEvent] = []
        var time = 0.0
        while time <= 15 {
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0375 + 0.0125 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            events.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeNodes(palmProxy: contact + [0, 0.03, 0]),
                rightNodes: makeNodes(palmProxy: contact)
            ))
            time += 1 / 60.0
        }

        let samples = events.compactMap { event -> CompressionDistanceSample? in
            if case let .compressionDistanceMeasured(sample) = event { return sample }
            return nil
        }
        XCTAssertFalse(samples.isEmpty, "Distance samples must surface as derived events")
        XCTAssertEqual(samples, Array(detector.compressionDistanceLog.suffix(samples.count)))

        let adaptations = events.compactMap { event -> CompressionThresholdAdaptation? in
            if case let .compressionThresholdAdapted(adaptation) = event { return adaptation }
            return nil
        }
        XCTAssertFalse(adaptations.isEmpty)
        XCTAssertEqual(adaptations.first?.reason, .nearMissDescentsAboveEntryBand)
    }

    // MARK: - Session model surfacing

    @MainActor
    func testCPRSessionModelRecordsDistanceLogAndAdaptationFeedback() async throws {
        let handInput = SimulatedHandInput()
        let model = CPRPracticeSessionModel(handTracking: handInput)
        await model.prepare()
        XCTAssertEqual(model.loadState, .ready)

        let sample = CompressionDistanceSample(
            timestampSeconds: 1.0,
            descentStartHeightMetres: 0.02,
            troughHeightMetres: -0.004,
            placement: .sternumTarget,
            countedAsCompression: true
        )
        handInput.emit(.compressionDistanceMeasured(sample))
        try await waitUntil { model.compressionDistanceLog.count == 1 }
        XCTAssertEqual(model.compressionDistanceLog.first, sample)
        XCTAssertEqual(
            try XCTUnwrap(model.recentContactTravelAverageMetres),
            0.024,
            accuracy: 0.0005
        )

        let adaptation = CompressionThresholdAdaptation(
            timestampSeconds: 2.0,
            entryToleranceMetres: 0.028,
            releaseHysteresisMetres: 0.012,
            reason: .nearMissDescentsAboveEntryBand
        )
        handInput.emit(.compressionThresholdAdapted(adaptation))
        try await waitUntil { model.latestThresholdAdaptation == adaptation }
        let feedback = try XCTUnwrap(model.latestFeedback)
        XCTAssertTrue(
            feedback.contains("widened its contact-detection range"),
            "Adaptation must explain itself to the learner: \(feedback)"
        )
        await model.stop()
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        timeoutSeconds: Double = 1.0,
        _ condition: () -> Bool
    ) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeoutSeconds {
                return XCTFail("Timed out waiting for condition")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func makeManikinGrid() -> TorsoGridMap? {
        TorsoGridMap(
            descriptor: .placeholderDefault,
            worldFromTorsoTransform: matrix_identity_float4x4,
            localBoundsCenter: [0, 0.12, 0],
            localBoundsExtents: [0.46, 0.18, 0.72],
            landmarkWorldPositions: [:]
        )
    }

    private func makeGridTargets() throws -> HandTrackingTargets {
        let grid = try XCTUnwrap(makeManikinGrid())
        return HandTrackingTargets(
            sternum: try XCTUnwrap(grid.worldVolume(for: .sternumCompressionSite)),
            xiphoidAvoidZone: try XCTUnwrap(grid.worldVolume(for: .xiphoidAvoidZone)),
            grid: grid
        )
    }

    private func makeNodes(palmProxy: SIMD3<Float>) -> TrackedHandNodes {
        TrackedHandNodes(
            thumbTip: palmProxy + [-0.05, 0.02, 0],
            indexTip: palmProxy + [0.05, 0.02, 0],
            middleMetacarpal: palmProxy,
            wrist: palmProxy + [0, 0.02, -0.08]
        )
    }
}
