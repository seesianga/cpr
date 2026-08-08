import Foundation
import simd

/// Composes the contact-cycle detector (primary), the retuned oscillation detector
/// (secondary), and the pinch-grab tracker over one reduced frame stream.
///
/// Compressions fire on EITHER signal, deduplicated inside the refractory window, so
/// small-amplitude real compressions (contact cycles) and larger free-space oscillations
/// both count exactly once. Interruption and cadence are re-derived from the deduplicated
/// compression stream so consumers keep the existing event vocabulary unchanged.
struct ComposedHandSignalDetector: Sendable {
    private var oscillationDetector: HandSignalDetector
    private var contactDetector: FingerContactCompressionDetector
    private var pinchTracker: PinchGrabTracker

    private let minimumCompressionIntervalSeconds: Double
    private let minimumGapReportedAsInterruptionSeconds: Double

    private var lastEmittedCompressionTimestamp: Double?
    private var cadenceEstimator = RollingCadenceEstimator()

    init(
        targets: HandTrackingTargets,
        oscillationConfiguration: HandSignalDetectorConfiguration = .contactComposedRetuned,
        contactConfiguration: FingerContactCompressionConfiguration = .practiceDefault,
        pinchConfiguration: PinchGrabConfiguration = .practiceDefault
    ) {
        oscillationDetector = HandSignalDetector(
            targets: targets,
            configuration: oscillationConfiguration
        )
        contactDetector = FingerContactCompressionDetector(
            targets: targets,
            configuration: contactConfiguration
        )
        pinchTracker = PinchGrabTracker(configuration: pinchConfiguration)
        minimumCompressionIntervalSeconds =
            oscillationConfiguration.minimumCompressionIntervalSeconds
        minimumGapReportedAsInterruptionSeconds =
            oscillationConfiguration.minimumGapReportedAsInterruptionSeconds
    }

    mutating func updateGrabbableItems(_ items: [PinchGrabItem]) {
        pinchTracker.updateItems(items)
    }

    mutating func process(_ frame: TrackedHandReducedFrame) -> [HandTrackingDerivedEvent] {
        let oscillationEvents = oscillationDetector.process(frame.palm)
        let contactCompressions = contactDetector.process(frame.nodes)
        let grabSamples = pinchTracker.process(frame.nodes)
        return compose(
            oscillationEvents: oscillationEvents,
            contactCompressions: contactCompressions,
            grabSamples: grabSamples
        ) + drainDistanceTelemetryEvents()
    }

    /// Atomically updates both hands for deterministic simulator and unit-test input.
    mutating func processFrame(
        timestampSeconds: Double,
        leftNodes: TrackedHandNodes?,
        rightNodes: TrackedHandNodes?
    ) -> [HandTrackingDerivedEvent] {
        let oscillationEvents = oscillationDetector.processFrame(
            timestampSeconds: timestampSeconds,
            leftPalmWorld: leftNodes?.palmProxy,
            rightPalmWorld: rightNodes?.palmProxy
        )
        let contactCompressions = contactDetector.processFrame(
            timestampSeconds: timestampSeconds,
            leftNodes: leftNodes,
            rightNodes: rightNodes
        )
        var grabSamples = pinchTracker.process(
            TrackedHandNodesObservation(
                timestampSeconds: timestampSeconds,
                chirality: .left,
                nodes: leftNodes
            )
        )
        grabSamples.append(contentsOf: pinchTracker.process(
            TrackedHandNodesObservation(
                timestampSeconds: timestampSeconds,
                chirality: .right,
                nodes: rightNodes
            )
        ))
        return compose(
            oscillationEvents: oscillationEvents,
            contactCompressions: contactCompressions,
            grabSamples: grabSamples
        ) + drainDistanceTelemetryEvents()
    }

    /// The rolling distance log recorded by the contact-cycle detector.
    var compressionDistanceLog: [CompressionDistanceSample] {
        contactDetector.distanceLog
    }

    private mutating func drainDistanceTelemetryEvents() -> [HandTrackingDerivedEvent] {
        let telemetry = contactDetector.drainDistanceTelemetry()
        var events = telemetry.samples.map(
            HandTrackingDerivedEvent.compressionDistanceMeasured
        )
        if let adaptation = telemetry.adaptation {
            events.append(.compressionThresholdAdapted(adaptation))
        }
        return events
    }

    mutating func reset(at timestampSeconds: Double = 0) -> [HandTrackingDerivedEvent] {
        oscillationDetector.reset()
        contactDetector.reset()
        lastEmittedCompressionTimestamp = nil
        cadenceEstimator.reset()
        return pinchTracker.reset(at: timestampSeconds)
            .map(HandTrackingDerivedEvent.grabInteractionChanged)
    }

    private struct CompressionCandidate {
        let timestampSeconds: Double
        let placement: CPRHandPlacementZone
        let handStacking: CPRHandStackingHeuristic
        /// Contact cycles are the primary signal and win timestamp ties.
        let isContactSignal: Bool
    }

    private mutating func compose(
        oscillationEvents: [HandTrackingDerivedEvent],
        contactCompressions: [FingerContactCompression],
        grabSamples: [GrabInteractionSample]
    ) -> [HandTrackingDerivedEvent] {
        var events: [HandTrackingDerivedEvent] = []
        var candidates: [CompressionCandidate] = []

        for event in oscillationEvents {
            switch event {
            case let .compressionDetected(timestamp, placement, handStacking):
                candidates.append(
                    CompressionCandidate(
                        timestampSeconds: timestamp,
                        placement: placement,
                        handStacking: handStacking,
                        isContactSignal: false
                    )
                )
            case .interruptionMeasured, .cadenceUpdated:
                // Re-derived below from the deduplicated compression stream.
                break
            case .compressionDistanceMeasured, .compressionThresholdAdapted:
                // Contact-detector telemetry only; drained separately, never produced
                // by the oscillation detector.
                break
            case .trackingAvailabilityChanged,
                 .placementChanged,
                 .placementDwellConfirmed,
                 .handStackingChanged,
                 .grabInteractionChanged:
                events.append(event)
            }
        }

        candidates.append(contentsOf: contactCompressions.map {
            CompressionCandidate(
                timestampSeconds: $0.timestampSeconds,
                placement: $0.placement,
                handStacking: $0.handStacking,
                isContactSignal: true
            )
        })

        candidates.sort { lhs, rhs in
            lhs.timestampSeconds == rhs.timestampSeconds
                ? lhs.isContactSignal && !rhs.isContactSignal
                : lhs.timestampSeconds < rhs.timestampSeconds
        }

        for candidate in candidates {
            if let lastEmittedCompressionTimestamp {
                let gap = candidate.timestampSeconds - lastEmittedCompressionTimestamp
                guard gap >= minimumCompressionIntervalSeconds else { continue }
                if gap >= minimumGapReportedAsInterruptionSeconds {
                    events.append(.interruptionMeasured(durationSeconds: gap))
                }
            }
            events.append(.compressionDetected(
                timestampSeconds: candidate.timestampSeconds,
                placement: candidate.placement,
                handStacking: candidate.handStacking
            ))
            lastEmittedCompressionTimestamp = candidate.timestampSeconds
            cadenceEstimator.record(timestampSeconds: candidate.timestampSeconds)
            if let cadence = cadenceEstimator.cadencePerMinute {
                events.append(.cadenceUpdated(ratePerMinute: cadence))
            }
        }

        events.append(contentsOf: grabSamples.map(
            HandTrackingDerivedEvent.grabInteractionChanged
        ))
        return events
    }
}
