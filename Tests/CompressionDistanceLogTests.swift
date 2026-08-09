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

    // MARK: - Per-descent log presentation

    func testLogEntriesAreNewestFirstAndNumberedChronologically() {
        let samples = (0..<3).map { index in
            makeSample(timestampSeconds: 10 + Double(index))
        }

        let entries = CPRCompressionDistanceLogPresenter.entries(from: samples)

        XCTAssertEqual(entries.map(\.id), [3, 2, 1])
        XCTAssertEqual(entries.map(\.elapsedSeconds), [2, 1, 0])
        XCTAssertEqual(entries.map(\.elapsedLabel), ["t+2.0s", "t+1.0s", "t+0.0s"])
        // 0.02 m start to a -0.005 m trough: 25 mm travelled, 5 mm past the surface.
        XCTAssertEqual(entries.first?.travelMillimetres, 25)
        XCTAssertEqual(entries.first?.belowSurfaceMillimetres, 5)
    }

    func testLogEntryDistinguishesNearMissFromRefractorySuppression() {
        let nearMiss = makeSample(
            timestampSeconds: 1,
            troughHeightMetres: 0.025,
            countedAsCompression: false,
            resolution: .reversedAboveEntryBand
        )
        let suppressed = makeSample(
            timestampSeconds: 2,
            countedAsCompression: false,
            resolution: .releasedNormally
        )
        let interrupted = makeSample(
            timestampSeconds: 3,
            countedAsCompression: false,
            resolution: .interruptedBeforeRelease
        )

        let entries = CPRCompressionDistanceLogPresenter.entries(
            from: [nearMiss, suppressed, interrupted]
        )

        XCTAssertEqual(entries.map(\.isCounted), [false, false, false])
        XCTAssertTrue(entries[0].statusLabel.contains("tracking lost"))
        XCTAssertTrue(entries[1].statusLabel.contains("too soon"))
        XCTAssertTrue(entries[2].statusLabel.contains("Near miss"))
    }

    func testLogDisplayLimitKeepsTheMostRecentDescents() {
        let samples = (0..<30).map { makeSample(timestampSeconds: Double($0)) }

        let entries = CPRCompressionDistanceLogPresenter.entries(from: samples, limit: 5)

        XCTAssertEqual(entries.map(\.id), [30, 29, 28, 27, 26])
        XCTAssertEqual(CPRCompressionDistanceLogPresenter.entries(from: samples, limit: 0), [])
        XCTAssertEqual(CPRCompressionDistanceLogPresenter.entries(from: []), [])
    }

    func testLogSummaryTalliesCountedAndInBandDescents() {
        let samples = [
            // 25 mm of travel: counted, but short of the 40–60 mm target band.
            makeSample(timestampSeconds: 1),
            makeSample(timestampSeconds: 2, countedAsCompression: false),
            // 45 mm of travel: counted and inside the band.
            makeSample(timestampSeconds: 3, troughHeightMetres: -0.025)
        ]

        let summary = CPRCompressionDistanceLogPresenter.summary(from: samples)

        XCTAssertEqual(summary.countedDescents, 2)
        XCTAssertEqual(summary.totalDescents, 3)
        XCTAssertEqual(summary.withinTargetBandDescents, 1)
        XCTAssertEqual(summary.label, "2 counted of 3 descents, 1 in the 40–60 mm band")
    }

    func testTravelBandClassifiesAgainstTheFortyToSixtyMillimetreTarget() {
        XCTAssertEqual(CPRCompressionTravelBand(travelMetres: 0.039), .belowTargetBand)
        XCTAssertEqual(CPRCompressionTravelBand(travelMetres: 0.040), .withinTargetBand)
        XCTAssertEqual(CPRCompressionTravelBand(travelMetres: 0.050), .withinTargetBand)
        XCTAssertEqual(CPRCompressionTravelBand(travelMetres: 0.060), .withinTargetBand)
        XCTAssertEqual(CPRCompressionTravelBand(travelMetres: 0.061), .aboveTargetBand)
        XCTAssertEqual(CPRCompressionTravelBand(travelMetres: .nan), .belowTargetBand)
        XCTAssertTrue(CPRCompressionTravelBand(travelMetres: 0.05).isWithinTargetBand)
    }

    func testLogEntryCarriesTheTravelBand() {
        let entries = CPRCompressionDistanceLogPresenter.entries(
            from: [makeSample(timestampSeconds: 1, troughHeightMetres: -0.025)]
        )

        let entry = entries.first
        XCTAssertEqual(entry?.travelMillimetres, 45)
        XCTAssertEqual(entry?.travelBand, .withinTargetBand)
        XCTAssertEqual(entry?.travelBand.label, "40–60 mm")
    }

    // MARK: - Stacked CPR grip without fingertip nodes

    /// The interlaced, palm-down CPR grip occludes the thumb and index tips. Contact
    /// classification only needs the palm proxy and wrist, so it must keep counting.
    func testInterlacedGripWithoutFingertipNodesStillCountsStackedCompressions() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())

        let frequency = 110.0 / 60
        var compressions: [FingerContactCompression] = []
        var time = 0.0
        while time <= 10 {
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0075 + 0.0125 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            compressions.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeGripNodes(palmProxy: contact + [0, 0.03, 0]),
                rightNodes: makeGripNodes(palmProxy: contact)
            ))
            time += 1 / 60.0
        }

        XCTAssertGreaterThan(
            compressions.count,
            10,
            "A grip with no tracked fingertips must still produce compressions"
        )
        XCTAssertTrue(
            compressions.allSatisfy { $0.handStacking == .likelyStacked },
            "Both hands are tracked, so the grip must read as stacked"
        )
    }

    /// Straight-line distance alone cannot separate a stacked pair from a side-by-side
    /// pair: both sit within arm's reach. Only the offset ACROSS the chest can.
    func testSideBySideHandsAreNotClassifiedAsStacked() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())

        let frequency = 110.0 / 60
        var compressions: [FingerContactCompression] = []
        var time = 0.0
        while time <= 10 {
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0075 + 0.0125 * cos(phase))
            // Both palms at the same height, 15 cm apart across the chest.
            let left = SIMD3<Float>(-0.075, 0.21 + height, 0.095)
            let right = SIMD3<Float>(0.075, 0.21 + height, 0.095)
            compressions.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeGripNodes(palmProxy: left),
                rightNodes: makeGripNodes(palmProxy: right)
            ))
            time += 1 / 60.0
        }

        XCTAssertFalse(compressions.isEmpty, "Contact cycles still register from one hand")
        XCTAssertTrue(
            compressions.allSatisfy { $0.handStacking == .separated },
            "Hands resting side by side must not read as a stacked CPR grip"
        )
    }

    @MainActor
    func testAcceptedCompressionsAnnounceTheRunningCount() async throws {
        let driver = SimulatedHandInput(startState: .permissionDenied)
        let announcer = RecordingCompressionCountAnnouncer()
        let model = CPRPracticeSessionModel(
            handTracking: driver,
            countAnnouncer: announcer
        )
        await model.prepare()
        XCTAssertEqual(model.loadState, .ready)
        model.confirmPositioning()
        model.choosePlacement(.sternumTarget)

        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        for index in 0..<5 {
            model.recordFallbackCompression(at: 1_000 + Double(index) * interval)
        }

        XCTAssertGreaterThan(model.metrics.totalCompressions, 0)
        XCTAssertEqual(
            announcer.announcedCounts,
            Array(1...model.metrics.totalCompressions),
            "Every accepted compression announces the running tally exactly once"
        )
        await model.stop()
    }

    func testInterruptedContactCycleIsTaggedInTheDistanceLog() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())

        var time = 0.0
        for height in stride(from: Float(0.05), through: Float(-0.005), by: -0.005) {
            _ = detector.processFrame(
                timestampSeconds: time,
                leftNodes: nil,
                rightNodes: makeNodes(palmProxy: SIMD3<Float>(0, 0.21 + height, 0.095))
            )
            time += 1 / 60.0
        }
        _ = detector.drainDistanceTelemetry()

        // Hand tracking drops while the contact cycle is still open.
        _ = detector.processFrame(timestampSeconds: time, leftNodes: nil, rightNodes: nil)

        let interrupted = try XCTUnwrap(
            detector.drainDistanceTelemetry().samples.last,
            "An abandoned contact cycle must still reach the log"
        )
        XCTAssertEqual(interrupted.resolution, .interruptedBeforeRelease)
    }

    // MARK: - Helpers

    private func makeSample(
        timestampSeconds: Double,
        troughHeightMetres: Float = -0.005,
        countedAsCompression: Bool = true,
        resolution: CompressionDistanceSample.Resolution = .releasedNormally
    ) -> CompressionDistanceSample {
        CompressionDistanceSample(
            timestampSeconds: timestampSeconds,
            descentStartHeightMetres: 0.02,
            troughHeightMetres: troughHeightMetres,
            placement: .sternumTarget,
            countedAsCompression: countedAsCompression,
            resolution: resolution
        )
    }

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

    /// A stacked, palm-down grip as ARKit reports it: metacarpal and wrist tracked, the
    /// interlaced thumb and index tips lost to occlusion.
    private func makeGripNodes(palmProxy: SIMD3<Float>) -> TrackedHandNodes {
        TrackedHandNodes(
            middleMetacarpal: palmProxy,
            wrist: palmProxy + [0, 0.02, -0.08]
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
