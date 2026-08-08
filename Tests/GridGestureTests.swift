import XCTest
import simd
@testable import LifesaverVision

/// Phase coverage: anatomical torso grid, finger-contact compression cycles, pinch-grab
/// interaction, the physical AED pad sequence, and the composite physical score.
final class GridGestureTests: XCTestCase {

    // MARK: - D1: Torso grid

    func testGridRegionsAreScaleInvariantAcrossBodySizes() throws {
        let smallBody = try XCTUnwrap(makeManikinGrid())
        var scaled = matrix_identity_float4x4
        scaled.columns.0.x = 1.6
        scaled.columns.1.y = 1.6
        scaled.columns.2.z = 1.6
        scaled.columns.3 = [0.5, 0.1, -0.3, 1]
        let largeBody = try XCTUnwrap(makeManikinGrid(worldFromTorso: scaled))

        let samples: [SIMD3<Float>] = [
            [0.5, 0.632, 1], [0.5, 0.9, 1], [0.185, 0.264, 1],
            [0.91, 0.68, 1], [0.5, 0.05, 1], [0.05, 0.9, 1]
        ]
        for normalized in samples {
            let smallRegion = smallBody.region(
                containingWorld: smallBody.worldPoint(fromNormalized: normalized)
            )
            let largeRegion = largeBody.region(
                containingWorld: largeBody.worldPoint(fromNormalized: normalized)
            )
            XCTAssertEqual(smallRegion, largeRegion, "normalized \(normalized)")

            let roundTrip = try XCTUnwrap(largeBody.normalizedPoint(
                fromWorld: largeBody.worldPoint(fromNormalized: normalized)
            ))
            XCTAssertEqual(roundTrip.x, normalized.x, accuracy: 0.0001)
            XCTAssertEqual(roundTrip.y, normalized.y, accuracy: 0.0001)
        }
        XCTAssertEqual(smallBody.regions, largeBody.regions)

        let smallVolume = try XCTUnwrap(smallBody.worldVolume(for: .sternumCompressionSite))
        let largeVolume = try XCTUnwrap(largeBody.worldVolume(for: .sternumCompressionSite))
        XCTAssertEqual(
            largeVolume.localExtents.x,
            smallVolume.localExtents.x * 1.6,
            accuracy: 0.0001
        )
    }

    func testAnatomicalSidednessMatchesAuthoredManikin() throws {
        // Authored manikin: supine, head toward -Z, anatomical right is -X.
        let grid = try XCTUnwrap(makeManikinGrid())

        XCTAssertEqual(
            grid.region(containingWorld: [-0.145, 0.21, -0.17]),
            .padSiteRightClavicle,
            "The patient's RIGHT clavicle pad site must sit at negative X"
        )
        XCTAssertEqual(
            grid.region(containingWorld: [0.205, 0.21, 0.13]),
            .padSiteLeftLateral,
            "The patient's LEFT lower lateral pad site must sit at positive X"
        )
        XCTAssertEqual(
            grid.region(containingWorld: [0, 0.21, 0.095]),
            .sternumCompressionSite
        )
        XCTAssertEqual(
            grid.region(containingWorld: [0, 0.21, 0.31]),
            .xiphoidAvoidZone
        )

        let rightRect = try XCTUnwrap(grid.regions[.padSiteRightClavicle])
        let leftRect = try XCTUnwrap(grid.regions[.padSiteLeftLateral])
        XCTAssertLessThan(rightRect.centerU, 0.5)
        XCTAssertGreaterThan(leftRect.centerU, 0.5)
        XCTAssertLessThan(rightRect.centerV, leftRect.centerV, "Right pad is cranial")
    }

    func testLandmarkOverrideBeatsProportionalDefault() throws {
        let plainGrid = try XCTUnwrap(makeManikinGrid())
        let overriddenGrid = try XCTUnwrap(makeManikinGrid(
            landmarks: [
                .sternum: [0.05, 0.21, 0.05],
                .rightClavicle: [-0.145, 0.21, -0.25]
            ]
        ))

        let defaultSternum = try XCTUnwrap(plainGrid.regions[.sternumCompressionSite])
        let overriddenSternum = try XCTUnwrap(
            overriddenGrid.regions[.sternumCompressionSite]
        )
        XCTAssertNotEqual(defaultSternum, overriddenSternum)
        XCTAssertEqual(overriddenSternum.centerU, (0.05 + 0.23) / 0.46, accuracy: 0.001)
        XCTAssertEqual(overriddenSternum.centerV, (0.05 + 0.36) / 0.72, accuracy: 0.001)
        XCTAssertEqual(
            overriddenGrid.region(containingWorld: [0.05, 0.21, 0.05]),
            .sternumCompressionSite
        )

        // The clavicle landmark marks the clavicle itself; the pad region sits caudal.
        let clavicleV = Double((-0.25 + 0.36) / 0.72)
        let padRect = try XCTUnwrap(overriddenGrid.regions[.padSiteRightClavicle])
        XCTAssertEqual(padRect.centerV, clavicleV + padRect.height / 2, accuracy: 0.001)
    }

    // MARK: - D2.1: Finger-contact compression cycles

    func testSmallAmplitudeStackedBounceCyclesRegisterAtLeastNinetyPercent() throws {
        // The device failure case: genuine stacked-hand pumping with ~2.5 cm bounces
        // that bottom slightly below the resistance-free virtual chest surface.
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())

        let ratePerMinute = 110.0
        let frequency = ratePerMinute / 60
        let sampleRate = 60.0
        let durationSeconds = 40.0
        var compressions: [FingerContactCompression] = []

        var time = 0.0
        while time <= durationSeconds {
            // Height above surface oscillates in [-0.005, +0.020] m, starting at the top.
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.0075 + 0.0125 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            compressions.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeNodes(palmProxy: contact + [0, 0.03, 0]),
                rightNodes: makeNodes(palmProxy: contact)
            ))
            time += 1 / sampleRate
        }

        let expectedCycles = durationSeconds * frequency
        XCTAssertGreaterThanOrEqual(
            Double(compressions.count),
            expectedCycles * 0.9,
            "Small-amplitude contact cycles must register ≥90% (got \(compressions.count) of \(expectedCycles))"
        )
        let first = try XCTUnwrap(compressions.first)
        XCTAssertEqual(first.placement, .sternumTarget)
        XCTAssertEqual(first.handStacking, .likelyStacked)
    }

    func testHoverWithoutContactCountsNothing() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())
        var compressions: [FingerContactCompression] = []
        var time = 0.0
        while time <= 10 {
            let height = Float(0.05 + 0.003 * sin(2 * .pi * 1.8 * time))
            compressions.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: nil,
                rightNodes: makeNodes(palmProxy: [0, 0.21 + height, 0.095])
            ))
            time += 1 / 60.0
        }
        XCTAssertTrue(compressions.isEmpty, "Hovering above the chest is not a compression")
    }

    func testXiphoidContactClassifiesAsAvoidZone() throws {
        var detector = FingerContactCompressionDetector(targets: try makeGridTargets())
        // v = 0.9 lies in the xiphoid avoid region; descend into contact there.
        let xiphoidWorldZ: Float = (0.9 - 0.5) * 0.72
        var compressions: [FingerContactCompression] = []
        for (index, height) in [0.05, 0.03, 0.015, -0.002].enumerated() {
            compressions.append(contentsOf: detector.processFrame(
                timestampSeconds: Double(index) * 0.05,
                leftNodes: nil,
                rightNodes: makeNodes(
                    palmProxy: [0, 0.21 + Float(height), xiphoidWorldZ]
                )
            ))
        }
        XCTAssertEqual(compressions.count, 1)
        XCTAssertEqual(compressions.first?.placement, .xiphoidAvoidZone)
    }

    func testComposedDetectorDeduplicatesContactAndOscillationSignals() throws {
        var detector = ComposedHandSignalDetector(targets: try makeGridTargets())

        // Large 6 cm cycles trigger BOTH the contact detector and the retuned
        // oscillation detector; each cycle must surface exactly once.
        let frequency = 110.0 / 60
        var events: [HandTrackingDerivedEvent] = []
        var time = 0.0
        while time <= 20 {
            let phase = 2 * Double.pi * frequency * time
            let height = Float(0.025 + 0.03 * cos(phase))
            let contact = SIMD3<Float>(0, 0.21 + height, 0.095)
            events.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeNodes(palmProxy: contact + [0, 0.03, 0]),
                rightNodes: makeNodes(palmProxy: contact)
            ))
            time += 1 / 60.0
        }

        let compressionTimestamps: [Double] = events.compactMap {
            if case let .compressionDetected(timestamp, _, _) = $0 { return timestamp }
            return nil
        }
        let expectedCycles = 20 * frequency
        XCTAssertGreaterThanOrEqual(Double(compressionTimestamps.count), expectedCycles * 0.9)
        XCTAssertLessThanOrEqual(
            Double(compressionTimestamps.count),
            expectedCycles + 2,
            "Contact and oscillation signals for one cycle must deduplicate"
        )
        for (previous, current) in zip(
            compressionTimestamps,
            compressionTimestamps.dropFirst()
        ) {
            XCTAssertGreaterThanOrEqual(
                current - previous,
                0.25 - 0.0001,
                "Refractory interval must separate deduplicated compressions"
            )
        }

        // Interruption emission is preserved across the composed stream: hover for
        // two seconds, then a fresh contact cycle reports the measured gap.
        let gapStart = time
        while time <= gapStart + 2 {
            events.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: makeNodes(palmProxy: [0, 0.26, 0.095]),
                rightNodes: makeNodes(palmProxy: [0, 0.26, 0.095])
            ))
            time += 1 / 60.0
        }
        var resumeEvents: [HandTrackingDerivedEvent] = []
        for height in stride(from: Float(0.03), through: -0.004, by: -0.008) {
            resumeEvents.append(contentsOf: detector.processFrame(
                timestampSeconds: time,
                leftNodes: nil,
                rightNodes: makeNodes(palmProxy: [0, 0.21 + height, 0.095])
            ))
            time += 1 / 60.0
        }
        let interruption = resumeEvents.compactMap { event -> Double? in
            if case let .interruptionMeasured(duration) = event { return duration }
            return nil
        }.first
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(interruption), 1.1)
    }

    // MARK: - D2.2: Pinch grab

    func testPinchGrabHysteresisAndRelease() {
        var tracker = PinchGrabTracker()
        tracker.updateItems([
            PinchGrabItem(identifier: "aed_left_pad", worldPosition: [0.3, 0.2, 0.1])
        ])

        // Open hand near the item: nothing.
        XCTAssertTrue(tracker.process(observation(
            at: 0, midpoint: [0.31, 0.2, 0.1], pinchGap: 0.08
        )).isEmpty)

        // Close below the grab threshold: grab begins at the midpoint.
        let began = tracker.process(observation(
            at: 0.1, midpoint: [0.31, 0.2, 0.1], pinchGap: 0.02
        ))
        XCTAssertEqual(began.count, 1)
        XCTAssertEqual(began.first?.phase, .began)
        XCTAssertEqual(began.first?.itemIdentifier, "aed_left_pad")

        // A gap between grab and release thresholds must NOT flap into a release.
        let held = tracker.process(observation(
            at: 0.2, midpoint: [0.35, 0.25, 0.1], pinchGap: 0.035
        ))
        XCTAssertEqual(held.first?.phase, .moved)
        XCTAssertEqual(held.first?.midpointWorld, [0.35, 0.25, 0.1])

        // Opening past the release threshold releases at the final midpoint.
        let released = tracker.process(observation(
            at: 0.3, midpoint: [0.4, 0.3, 0.1], pinchGap: 0.05
        ))
        XCTAssertEqual(released.first?.phase, .released)
        XCTAssertEqual(released.first?.midpointWorld, [0.4, 0.3, 0.1])
    }

    func testPinchGrabCancelsOnMidDragHandLoss() {
        var tracker = PinchGrabTracker()
        tracker.updateItems([
            PinchGrabItem(identifier: "aed_right_pad", worldPosition: [0, 0.2, 0])
        ])
        XCTAssertEqual(
            tracker.process(observation(at: 0, midpoint: [0, 0.2, 0], pinchGap: 0.02))
                .first?.phase,
            .began
        )
        let lost = tracker.process(TrackedHandNodesObservation(
            timestampSeconds: 0.2,
            chirality: .right,
            nodes: nil
        ))
        XCTAssertEqual(lost.first?.phase, .cancelled)
        XCTAssertNil(lost.first?.midpointWorld)
    }

    func testPinchDoesNotGrabDistantItems() {
        var tracker = PinchGrabTracker()
        tracker.updateItems([
            PinchGrabItem(identifier: "aed_left_pad", worldPosition: [1.5, 0.2, 0.1])
        ])
        let outputs = tracker.process(observation(
            at: 0, midpoint: [0, 0.2, 0], pinchGap: 0.02
        ))
        XCTAssertTrue(outputs.isEmpty)
    }

    // MARK: - Snap-to-region and placement error

    func testSnapToRegionAndPlacementErrorMath() throws {
        let grid = try XCTUnwrap(makeManikinGrid())

        // Release at the left-lateral region centre: zero normalized error.
        let centre = grid.worldPoint(fromNormalized: [0.91, 0.68, 1])
        let centred = try XCTUnwrap(grid.snapResolution(forWorld: centre + [0, 0.05, 0]))
        XCTAssertEqual(centred.regionID, .padSiteLeftLateral)
        XCTAssertEqual(centred.normalizedError, 0, accuracy: 0.001)

        // Release just outside the region within the snap tolerance: clamps to the
        // region edge, error 1.0 in region-normalized units, never metres.
        let nearEdge = grid.worldPoint(fromNormalized: [0.80, 0.68, 1])
        let snapped = try XCTUnwrap(grid.snapResolution(forWorld: nearEdge))
        XCTAssertEqual(snapped.regionID, .padSiteLeftLateral)
        XCTAssertEqual(snapped.normalizedError, 1, accuracy: 0.01)
        let snappedNormalized = try XCTUnwrap(
            grid.normalizedPoint(fromWorld: snapped.worldSnapPosition)
        )
        XCTAssertEqual(snappedNormalized.x, 0.82, accuracy: 0.001)

        // Far from every region: no snap.
        XCTAssertNil(grid.snapResolution(
            forWorld: grid.worldPoint(fromNormalized: [0.5, 0.02, 1])
        ))
    }

    // MARK: - D3: Physical AED sequence through the existing state machine

    func testPhysicalPadPowerAndCPRHappyPathThroughAEDStateMachine() {
        var machine = AEDStateMachine()
        XCTAssertTrue(machine.handle(.pressPowerControl).wasAccepted)
        XCTAssertEqual(machine.state, .awaitingPads)

        XCTAssertTrue(machine.handle(.placePhysicalPad(AEDPhysicalPadPlacement(
            padSide: .right,
            regionID: .padSiteRightClavicle,
            normalizedPlacementError: 0.2
        ))).wasAccepted)
        XCTAssertEqual(machine.state, .awaitingPads)

        XCTAssertTrue(machine.handle(.placePhysicalPad(AEDPhysicalPadPlacement(
            padSide: .left,
            regionID: .padSiteLeftLateral,
            normalizedPlacementError: 0.4
        ))).wasAccepted)
        XCTAssertEqual(machine.state, .padsCorrect)
        XCTAssertEqual(machine.physicalPadPlacements.count, 2)

        XCTAssertTrue(machine.handle(.interactiveAnalysisClearCheck(
            clearZoneActivated: true,
            bystandersConfirmedClear: true,
            anyoneTouching: false
        )).wasAccepted)
        XCTAssertTrue(machine.handle(
            .receiveAnalysisOutcome(.shock, anyoneTouching: false)
        ).wasAccepted)
        XCTAssertTrue(machine.handle(.beginCharging(anyoneTouching: false)).wasAccepted)
        XCTAssertTrue(machine.handle(.chargingComplete(anyoneTouching: false)).wasAccepted)
        XCTAssertTrue(machine.handle(.interactiveClearCheck(
            clearZoneActivated: true,
            bystandersConfirmedClear: true,
            anyoneTouching: false
        )).wasAccepted)
        XCTAssertTrue(machine.handle(.pressShockControl(anyoneTouching: false)).wasAccepted)
        XCTAssertEqual(machine.state, .simulatedShock)
        XCTAssertTrue(machine.handle(.resumeCompressions).wasAccepted)
        XCTAssertEqual(machine.state, .resumeCompressions)
        XCTAssertTrue(machine.handle(.finish).wasAccepted)
        XCTAssertEqual(machine.state, .complete)
        XCTAssertTrue(machine.criticalFailures.isEmpty)
    }

    func testWrongRegionPhysicalPadIsRemediatedByExistingRules() {
        var machine = AEDStateMachine()
        _ = machine.handle(.pressPowerControl)

        let wrongRegion = machine.handle(.placePhysicalPad(AEDPhysicalPadPlacement(
            padSide: .right,
            regionID: .padSiteLeftLateral,
            normalizedPlacementError: 0.1
        )))
        XCTAssertTrue(wrongRegion.wasAccepted)
        XCTAssertEqual(machine.state, .padsIncorrect)
        guard case let .accepted(_, remediation) = wrongRegion.outcome else {
            return XCTFail("Expected accepted-with-remediation outcome")
        }
        XCTAssertEqual(remediation?.code, .padsIncorrect)

        XCTAssertTrue(machine.handle(.retryPadPlacement).wasAccepted)
        XCTAssertEqual(machine.state, .awaitingPads)
        XCTAssertTrue(machine.physicalPadPlacements.isEmpty)

        // A release outside the snap tolerance carries no region and no error and is
        // remediated the same way — never fabricated into a measured placement.
        let outside = machine.handle(.placePhysicalPad(AEDPhysicalPadPlacement(
            padSide: .left,
            regionID: nil,
            normalizedPlacementError: nil
        )))
        XCTAssertTrue(outside.wasAccepted)
        XCTAssertEqual(machine.state, .padsIncorrect)
    }

    func testInconsistentPhysicalPadEvidenceIsRejected() {
        var machine = AEDStateMachine()
        _ = machine.handle(.pressPowerControl)
        let entry = machine.handle(.placePhysicalPad(AEDPhysicalPadPlacement(
            padSide: .right,
            regionID: .padSiteRightClavicle,
            normalizedPlacementError: nil
        )))
        XCTAssertFalse(entry.wasAccepted)
        XCTAssertEqual(machine.state, .awaitingPads)
    }

    // MARK: - D4: Composite physical performance score

    func testPhysicalPerformanceBreakdownComposesThreeSourcedSubScores() throws {
        let breakdown = try XCTUnwrap(ScoringEngine().physicalPerformanceBreakdown(
            from: PhysicalPerformanceEvidence(
                compressionPlacements: [.sternumTarget, .sternumTarget, .xiphoidAvoidZone],
                compressionTimestamps: [0, 60.0 / 110, 120.0 / 110],
                padPlacements: [
                    AEDPhysicalPadPlacement(
                        padSide: .right,
                        regionID: .padSiteRightClavicle,
                        normalizedPlacementError: 0.2
                    ),
                    AEDPhysicalPadPlacement(
                        padSide: .left,
                        regionID: .padSiteLeftLateral,
                        normalizedPlacementError: 0.4
                    )
                ]
            )
        ))

        XCTAssertEqual(
            try XCTUnwrap(breakdown.cprLocationAccuracyPercentage),
            100.0 * 2 / 3,
            accuracy: 0.01
        )
        XCTAssertEqual(
            try XCTUnwrap(breakdown.padPlacementAccuracyPercentage),
            70,
            accuracy: 0.01
        )
        XCTAssertEqual(try XCTUnwrap(breakdown.tempoAccuracyPercentage), 100, accuracy: 0.01)
        XCTAssertEqual(
            try XCTUnwrap(breakdown.compositePercentage),
            (100.0 * 2 / 3 + 70 + 100) / 3,
            accuracy: 0.01
        )
        XCTAssertEqual(breakdown.compressionContactCount, 3)
        XCTAssertEqual(breakdown.xiphoidContactCount, 1)
        XCTAssertEqual(breakdown.tempoIntervalCount, 2)
        XCTAssertFalse(breakdown.sourceReferences.isEmpty)
    }

    func testMissingPhysicalEvidenceIsNeverScoredAsZero() throws {
        XCTAssertNil(try ScoringEngine().physicalPerformanceBreakdown(
            from: PhysicalPerformanceEvidence(
                compressionPlacements: [],
                compressionTimestamps: [],
                padPlacements: []
            )
        ))

        // Pads only (no guided compressions): the missing dimensions drop out of the
        // weighted denominator instead of dragging the composite down.
        let padsOnly = try XCTUnwrap(ScoringEngine().physicalPerformanceBreakdown(
            from: PhysicalPerformanceEvidence(
                compressionPlacements: [],
                compressionTimestamps: [],
                padPlacements: [
                    AEDPhysicalPadPlacement(
                        padSide: .right,
                        regionID: .padSiteRightClavicle,
                        normalizedPlacementError: 0
                    )
                ]
            )
        ))
        XCTAssertNil(padsOnly.cprLocationAccuracyPercentage)
        XCTAssertNil(padsOnly.tempoAccuracyPercentage)
        XCTAssertEqual(try XCTUnwrap(padsOnly.compositePercentage), 100, accuracy: 0.01)
    }

    // MARK: - D5: Descriptor seam

    func testPlaceholderDescriptorRoundTripsThroughJSON() throws {
        let descriptor = PracticeAssetDescriptor.placeholderDescriptor
        let encoded = try JSONEncoder().encode(descriptor)
        let decoded = try PracticeAssetDescriptor.decode(from: encoded)
        XCTAssertEqual(decoded, descriptor)
        XCTAssertTrue(descriptor.gridDescriptor.isValid)
        XCTAssertEqual(descriptor.gridDescriptor, .placeholderDefault)
    }

    func testGridDescriptorDefaultsCarrySourceReferencesRequiringSMEReview() {
        let descriptor = BodyGridDescriptor.placeholderDefault
        XCTAssertFalse(descriptor.sourceReferences.isEmpty)
        for reference in descriptor.sourceReferences {
            XCTAssertEqual(reference.reviewStatus, "requires_sme_review")
            XCTAssertFalse(reference.document.isEmpty)
        }
    }

    // MARK: - AED session model: physical grab path

    @MainActor
    func testGrabReleaseOverTorsoSubmitsPhysicalPadEvidence() async throws {
        let handInput = SimulatedHandInput()
        let model = AEDPracticeSessionModel(handTracking: handInput)
        model.prepare()
        let targets = try makeGridTargets()
        model.configureHandTracking(targets: targets)
        model.configurePhysicalInteraction(
            padItems: [
                .right: PinchGrabItem(identifier: "aed_right_pad", worldPosition: [0.5, 0, 0.5]),
                .left: PinchGrabItem(identifier: "aed_left_pad", worldPosition: [0.6, 0, 0.5])
            ],
            powerButton: PinchGrabItem(identifier: "aed_power_button", worldPosition: [0.8, 0, 0.5])
        )
        await model.startHandTracking()
        XCTAssertEqual(model.state, .powerOn)

        // Physical power press routes through the same reducer event as the button.
        handInput.emit(.grabInteractionChanged(GrabInteractionSample(
            phase: .began,
            itemIdentifier: "aed_power_button",
            timestampSeconds: 0,
            midpointWorld: [0.8, 0, 0.5]
        )))
        try await waitUntil { model.state == .awaitingPads }

        // The reducer still enforces chest preparation before any pad can attach.
        for item in model.preparationItems {
            model.completePreparation(item.condition)
        }
        XCTAssertTrue(model.isPreparationComplete)

        // Pick the right pad up and release it over the correct grid region.
        let grid = try XCTUnwrap(targets.grid)
        let rightSite = grid.worldPoint(fromNormalized: [0.185, 0.264, 1])
        handInput.emit(.grabInteractionChanged(GrabInteractionSample(
            phase: .began,
            itemIdentifier: "aed_right_pad",
            timestampSeconds: 0.5,
            midpointWorld: [0.5, 0, 0.5]
        )))
        try await waitUntil { model.activePadGrab != nil }
        handInput.emit(.grabInteractionChanged(GrabInteractionSample(
            phase: .moved,
            itemIdentifier: "aed_right_pad",
            timestampSeconds: 0.6,
            midpointWorld: rightSite + [0, 0.05, 0]
        )))
        handInput.emit(.grabInteractionChanged(GrabInteractionSample(
            phase: .released,
            itemIdentifier: "aed_right_pad",
            timestampSeconds: 0.7,
            midpointWorld: rightSite + [0, 0.05, 0]
        )))
        try await waitUntil { model.physicalPadPlacements[.right] != nil }

        let placement = try XCTUnwrap(model.physicalPadPlacements[.right])
        XCTAssertEqual(placement.regionID, .padSiteRightClavicle)
        XCTAssertEqual(try XCTUnwrap(placement.normalizedPlacementError), 0, accuracy: 0.01)
        XCTAssertTrue(placement.isInCorrectRegion)
        XCTAssertNil(model.activePadGrab)
        XCTAssertNotNil(model.padSnapPresentation)
        XCTAssertEqual(model.state, .awaitingPads)
        model.stop()
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

    /// Mirrors the authored placeholder manikin: torso bounds centred at (0, 0.12, 0)
    /// with extents (0.46, 0.18, 0.72); supine, head -Z, patient-right -X.
    private func makeManikinGrid(
        worldFromTorso: simd_float4x4 = matrix_identity_float4x4,
        landmarks: [TorsoLandmark: SIMD3<Float>] = [:]
    ) -> TorsoGridMap? {
        TorsoGridMap(
            descriptor: .placeholderDefault,
            worldFromTorsoTransform: worldFromTorso,
            localBoundsCenter: [0, 0.12, 0],
            localBoundsExtents: [0.46, 0.18, 0.72],
            landmarkWorldPositions: landmarks
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

    /// Nodes with a wide-open pinch so contact tests never trigger grab logic.
    private func makeNodes(palmProxy: SIMD3<Float>) -> TrackedHandNodes {
        TrackedHandNodes(
            thumbTip: palmProxy + [-0.05, 0.02, 0],
            indexTip: palmProxy + [0.05, 0.02, 0],
            middleMetacarpal: palmProxy,
            wrist: palmProxy + [0, 0.02, -0.08]
        )
    }

    private func observation(
        at timestampSeconds: Double,
        midpoint: SIMD3<Float>,
        pinchGap: Float
    ) -> TrackedHandNodesObservation {
        TrackedHandNodesObservation(
            timestampSeconds: timestampSeconds,
            chirality: .right,
            nodes: TrackedHandNodes(
                thumbTip: midpoint - [pinchGap / 2, 0, 0],
                indexTip: midpoint + [pinchGap / 2, 0, 0],
                middleMetacarpal: midpoint + [0, -0.05, 0],
                wrist: midpoint + [0, -0.05, -0.08]
            )
        )
    }
}
