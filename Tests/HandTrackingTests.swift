import RealityKit
import XCTest
@testable import LifesaverVision

@MainActor
final class HandTrackingTests: XCTestCase {
    func testDetectorClassifiesAuthoredPlacementZones() throws {
        var detector = HandSignalDetector(
            targets: try makeTargets(),
            configuration: testConfiguration
        )

        let sternumEvents = detector.processFrame(
            timestampSeconds: 0,
            leftPalmWorld: [0, 0.12, 0],
            rightPalmWorld: nil
        )
        let xiphoidEvents = detector.processFrame(
            timestampSeconds: 0.1,
            leftPalmWorld: [0, 0.12, 0.30],
            rightPalmWorld: nil
        )
        let outsideEvents = detector.processFrame(
            timestampSeconds: 0.2,
            leftPalmWorld: [0.35, 0.12, 0],
            rightPalmWorld: nil
        )

        XCTAssertTrue(sternumEvents.contains(.placementChanged(.sternumTarget)))
        XCTAssertTrue(xiphoidEvents.contains(.placementChanged(.xiphoidAvoidZone)))
        XCTAssertTrue(outsideEvents.contains(.placementChanged(.outsideTarget)))
    }

    func testDetectorRejectsJitterAndProducesCadenceFromDiscreteCycles() throws {
        var noiseDetector = HandSignalDetector(
            targets: try makeTargets(),
            configuration: testConfiguration
        )
        let noiseEvents = [
            noiseDetector.processFrame(timestampSeconds: 0, leftPalmWorld: [0, 0.150, 0], rightPalmWorld: nil),
            noiseDetector.processFrame(timestampSeconds: 0.1, leftPalmWorld: [0, 0.149, 0], rightPalmWorld: nil),
            noiseDetector.processFrame(timestampSeconds: 0.2, leftPalmWorld: [0, 0.151, 0], rightPalmWorld: nil)
        ].flatMap { $0 }
        XCTAssertFalse(noiseEvents.containsCompression)

        var detector = HandSignalDetector(
            targets: try makeTargets(),
            configuration: testConfiguration
        )
        let interval = 60.0 / 110.0
        let events = [
            detector.processFrame(timestampSeconds: 0, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 0.10, leftPalmWorld: [0, 0.10, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 0.20, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 0.10 + interval, leftPalmWorld: [0, 0.10, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 0.20 + interval, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil)
        ].flatMap { $0 }

        XCTAssertEqual(events.compressions.count, 2)
        guard case let .compressionDetected(firstTimestamp, firstPlacement, firstStacking) = events.compressions[0],
              case let .compressionDetected(secondTimestamp, _, _) = events.compressions[1]
        else { return XCTFail("Expected two derived compression events") }
        XCTAssertEqual(firstTimestamp, 0.10, accuracy: 0.000_001)
        XCTAssertEqual(secondTimestamp, 0.10 + interval, accuracy: 0.000_001)
        XCTAssertEqual(firstPlacement, .sternumTarget)
        XCTAssertEqual(firstStacking, .indeterminate)

        guard let cadence = events.compactMap(\.cadencePerMinute).last else {
            return XCTFail("Expected a derived cadence after the second compression")
        }
        XCTAssertEqual(cadence, 110, accuracy: 0.001)
    }

    func testDetectorReportsStackingConservatively() throws {
        var detector = HandSignalDetector(
            targets: try makeTargets(),
            configuration: testConfiguration
        )

        let oneHand = detector.processFrame(
            timestampSeconds: 0,
            leftPalmWorld: [0, 0.10, 0],
            rightPalmWorld: nil
        )
        let stacked = detector.processFrame(
            timestampSeconds: 0.1,
            leftPalmWorld: [0, 0.10, 0],
            rightPalmWorld: [0.02, 0.14, 0.01]
        )
        let separated = detector.processFrame(
            timestampSeconds: 0.2,
            leftPalmWorld: [0, 0.10, 0],
            rightPalmWorld: [0.30, 0.14, 0]
        )

        XCTAssertTrue(oneHand.contains(.handStackingChanged(.indeterminate)))
        XCTAssertTrue(stacked.contains(.handStackingChanged(.likelyStacked)))
        XCTAssertTrue(separated.contains(.handStackingChanged(.separated)))
    }

    func testDetectorReportsInterruptionWithoutApplyingClinicalThreshold() throws {
        var detector = HandSignalDetector(
            targets: try makeTargets(),
            configuration: testConfiguration
        )
        let events = [
            detector.processFrame(timestampSeconds: 0, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 0.1, leftPalmWorld: [0, 0.10, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 0.2, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 2.1, leftPalmWorld: [0, 0.10, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 2.2, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil)
        ].flatMap { $0 }

        XCTAssertTrue(events.contains(.interruptionMeasured(durationSeconds: 2.0)))
        XCTAssertEqual(events.compressions.count, 2)
    }

    func testTrackingLossEmitsUnavailableSignalsAndResetsCadenceContinuity() throws {
        var detector = HandSignalDetector(
            targets: try makeTargets(),
            configuration: testConfiguration
        )
        _ = detector.processFrame(
            timestampSeconds: 0,
            leftPalmWorld: [0, 0.12, 0],
            rightPalmWorld: nil
        )

        let lostEvents = detector.processFrame(
            timestampSeconds: 0.1,
            leftPalmWorld: nil,
            rightPalmWorld: nil
        )

        XCTAssertTrue(lostEvents.contains(.trackingAvailabilityChanged(isAvailable: false)))
        XCTAssertTrue(lostEvents.contains(.placementChanged(.unavailable)))

        let restartedEvents = [
            detector.processFrame(timestampSeconds: 1, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 1.1, leftPalmWorld: [0, 0.10, 0], rightPalmWorld: nil),
            detector.processFrame(timestampSeconds: 1.2, leftPalmWorld: [0, 0.16, 0], rightPalmWorld: nil)
        ].flatMap { $0 }
        XCTAssertEqual(restartedEvents.compressions.count, 1)
        XCTAssertTrue(restartedEvents.compactMap(\.cadencePerMinute).isEmpty)
    }

    func testSimulatedInputStreamDrivesExactCPREventsAndHonoursPause() async throws {
        let driver = SimulatedHandInput(detectorConfiguration: testConfiguration)
        driver.configure(targets: try makeTargets())
        await driver.start()

        let cadenceReceived = expectation(description: "Derived cadence reached protocol stream")
        let streamTask = Task { @MainActor in
            var events: [HandTrackingDerivedEvent] = []
            for await event in driver.signals {
                guard !Task.isCancelled else { break }
                events.append(event)
                if event.cadencePerMinute != nil {
                    cadenceReceived.fulfill()
                    break
                }
            }
            return events
        }

        let interval = 60.0 / 110.0
        let frames = [
            SimulatedHandFrame(timestampSeconds: 0, leftPalmWorld: [0, 0.16, 0]),
            SimulatedHandFrame(timestampSeconds: 0.1, leftPalmWorld: [0, 0.10, 0]),
            SimulatedHandFrame(timestampSeconds: 0.2, leftPalmWorld: [0, 0.16, 0]),
            SimulatedHandFrame(timestampSeconds: 0.1 + interval, leftPalmWorld: [0, 0.10, 0]),
            SimulatedHandFrame(timestampSeconds: 0.2 + interval, leftPalmWorld: [0, 0.16, 0])
        ]
        for frame in frames {
            _ = driver.submit(frame)
        }
        await fulfillment(of: [cadenceReceived], timeout: 2)
        let signals = await streamTask.value

        var machine = CPRPracticeStateMachine()
        _ = machine.handle(.confirmPositioning)
        _ = machine.handle(.classifyHandPlacement(.sternumTarget))
        for event in signals.compactMap(\.cprPracticeEvent) {
            _ = machine.handle(event)
        }

        XCTAssertEqual(machine.metrics.totalCompressions, 2)
        XCTAssertEqual(machine.metrics.latestCadencePerMinute ?? 0, 110, accuracy: 0.001)

        driver.pause()
        XCTAssertEqual(driver.state, .paused)
        XCTAssertTrue(driver.submit(
            SimulatedHandFrame(timestampSeconds: 2, leftPalmWorld: [0, 0.10, 0])
        ).isEmpty)
    }

    func testDeniedHandTrackingKeepsManualCoursePathCompletable() async throws {
        let driver = SimulatedHandInput(startState: .permissionDenied)
        driver.configure(targets: try makeTargets())
        await driver.start()

        XCTAssertEqual(driver.state, .permissionDenied)
        XCTAssertTrue(driver.state.usesAccessibleFallback)
        XCTAssertNotNil(driver.state.fallbackExplanation)
        XCTAssertTrue(driver.submit(
            SimulatedHandFrame(timestampSeconds: 0, leftPalmWorld: [0, 0.10, 0])
        ).isEmpty)

        // Accessible controls submit the same typed engine events; they do not depend on ARKit.
        var machine = CPRPracticeStateMachine()
        _ = machine.handle(.confirmPositioning)
        _ = machine.handle(.classifyHandPlacement(.sternumTarget))
        _ = machine.handle(.compressionDetected(
            timestampSeconds: 0,
            placement: .sternumTarget,
            handStacking: .indeterminate
        ))
        _ = machine.handle(.stop(.emergencyTeamTookOver))
        _ = machine.handle(.finish)
        XCTAssertEqual(machine.state, .complete)
    }

    func testUnavailableSensorCannotSupplyDepthOrForce() async throws {
        let provider = UnavailableCPRSensorProvider()
        let connected = await provider.isVerifiedExternalSensorConnected
        let measurement = try await provider.latestMeasurement()

        XCTAssertFalse(connected)
        XCTAssertNil(measurement)
    }

    func testAssetRegistryExtractsWorldAlignedHandTargets() throws {
        let root = Entity()
        root.orientation = simd_quatf(angle: .pi / 5, axis: [0, 1, 0])

        let sternum = ModelEntity(mesh: .generateBox(size: 0.20))
        sternum.name = "sternum_target"
        sternum.position = [0.05, 0.10, -0.20]
        root.addChild(sternum)

        let xiphoid = ModelEntity(mesh: .generateBox(size: 0.06))
        xiphoid.name = "xiphoid_avoid_zone"
        xiphoid.position = [0.05, 0.10, 0.10]
        root.addChild(xiphoid)

        let registry = AssetRegistry()
        let targets = try registry.handTrackingTargets(in: root)
        var detector = HandSignalDetector(
            targets: targets,
            configuration: testConfiguration
        )
        let sternumWorld = sternum.convert(position: [0, 0.05, 0], to: nil)

        let events = detector.processFrame(
            timestampSeconds: 0,
            leftPalmWorld: sternumWorld,
            rightPalmWorld: nil
        )

        XCTAssertTrue(events.contains(.placementChanged(.sternumTarget)))
    }

    private var testConfiguration: HandSignalDetectorConfiguration {
        HandSignalDetectorConfiguration(
            maximumHandSampleAgeSeconds: 0.20,
            smoothingFactor: 1,
            minimumDirectionalChangeMetres: 0.001,
            oscillationHysteresisMetres: 0.02,
            minimumCompressionIntervalSeconds: 0.20,
            minimumGapReportedAsInterruptionSeconds: 1.0,
            maximumTrackingRadiusMetres: 0.60,
            targetLateralMarginMetres: 0,
            maximumHeightAboveTargetMetres: 0.40,
            maximumDistanceBelowTargetMetres: 0.05,
            maximumStackedPalmSeparationMetres: 0.16
        )
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

private extension Array where Element == HandTrackingDerivedEvent {
    var compressions: [HandTrackingDerivedEvent] {
        filter {
            if case .compressionDetected = $0 { return true }
            return false
        }
    }

    var containsCompression: Bool {
        !compressions.isEmpty
    }
}

private extension HandTrackingDerivedEvent {
    var cadencePerMinute: Double? {
        if case let .cadenceUpdated(rate) = self { return rate }
        return nil
    }
}
