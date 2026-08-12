import Foundation
import simd

/// Deterministically reduces transient palm-centroid observations into discrete CPR signals.
///
/// The detector retains only small filter state and timestamps of already-detected compression
/// events. It never retains an ARKit anchor, skeleton, joint collection, or frame stream.
struct HandSignalDetector: Sendable {
    /// Product-authored transient-signal filter. This is not a clinical timing threshold.
    static let criticalPlacementDwellSeconds = 0.4

    private struct RecentPalm: Sendable {
        let timestampSeconds: Double
        let worldPosition: SIMD3<Float>
    }

    private enum MotionPhase: Sendable {
        case unknown
        case descending
        case ascending
    }

    private let targets: HandTrackingTargets
    private let configuration: HandSignalDetectorConfiguration

    private var palms: [TrackedHandChirality: RecentPalm] = [:]
    private var latestTrackingAvailability: Bool?
    private var latestPlacement: CPRHandPlacementZone?
    private var latestStacking: CPRHandStackingHeuristic?
    private var contactChirality: TrackedHandChirality?
    private var criticalPlacementStartedAt: Double?
    private var criticalPlacementDwellEmitted = false

    private var motionPhase: MotionPhase = .unknown
    private var corridorExitStartedAt: Double?
    private var smoothedHeight: Float?
    private var previousHeight: Float?
    private var lastMotionTimestamp: Double?
    private var descentStartHeight: Float?
    private var troughHeight: Float?
    private var troughTimestamp: Double?
    private var troughPlacement: CPRHandPlacementZone = .unavailable
    private var troughStacking: CPRHandStackingHeuristic = .indeterminate
    private var ascentPeakHeight: Float?

    private var lastCompressionTimestamp: Double?
    private var recentCompressionTimestamps: [Double] = []

    init(
        targets: HandTrackingTargets,
        configuration: HandSignalDetectorConfiguration = .practiceDefault
    ) {
        self.targets = targets
        self.configuration = configuration
    }

    mutating func process(_ observation: TrackedPalmObservation) -> [HandTrackingDerivedEvent] {
        guard observation.timestampSeconds.isFinite,
              observation.timestampSeconds >= 0,
              observation.palmCentroidWorld?.allFinite ?? true
        else { return [] }

        if let existing = palms[observation.chirality],
           observation.timestampSeconds < existing.timestampSeconds {
            return []
        }

        if let palmCentroidWorld = observation.palmCentroidWorld {
            palms[observation.chirality] = RecentPalm(
                timestampSeconds: observation.timestampSeconds,
                worldPosition: palmCentroidWorld
            )
        } else {
            palms.removeValue(forKey: observation.chirality)
        }

        return evaluate(at: observation.timestampSeconds)
    }

    /// Atomically updates both hands for deterministic simulator and unit-test input.
    mutating func processFrame(
        timestampSeconds: Double,
        leftPalmWorld: SIMD3<Float>?,
        rightPalmWorld: SIMD3<Float>?
    ) -> [HandTrackingDerivedEvent] {
        guard timestampSeconds.isFinite,
              timestampSeconds >= 0,
              leftPalmWorld?.allFinite ?? true,
              rightPalmWorld?.allFinite ?? true
        else { return [] }

        updatePalm(.left, position: leftPalmWorld, timestampSeconds: timestampSeconds)
        updatePalm(.right, position: rightPalmWorld, timestampSeconds: timestampSeconds)
        return evaluate(at: timestampSeconds)
    }

    mutating func reset() {
        palms.removeAll(keepingCapacity: false)
        latestTrackingAvailability = nil
        latestPlacement = nil
        latestStacking = nil
        contactChirality = nil
        resetCriticalPlacementDwell()
        resetMotion()
        corridorExitStartedAt = nil
        lastCompressionTimestamp = nil
        recentCompressionTimestamps.removeAll(keepingCapacity: false)
    }

    private mutating func updatePalm(
        _ chirality: TrackedHandChirality,
        position: SIMD3<Float>?,
        timestampSeconds: Double
    ) {
        if let position {
            palms[chirality] = RecentPalm(
                timestampSeconds: timestampSeconds,
                worldPosition: position
            )
        } else {
            palms.removeValue(forKey: chirality)
        }
    }

    private mutating func evaluate(at timestampSeconds: Double) -> [HandTrackingDerivedEvent] {
        discardStalePalms(at: timestampSeconds)

        var events: [HandTrackingDerivedEvent] = []
        let trackingAvailable = !palms.isEmpty
        if latestTrackingAvailability != trackingAvailable {
            latestTrackingAvailability = trackingAvailable
            events.append(.trackingAvailabilityChanged(isAvailable: trackingAvailable))
        }

        guard let contact = contactPalm() else {
            emitClassificationChanges(
                placement: .unavailable,
                stacking: .indeterminate,
                into: &events
            )
            contactChirality = nil
            resetCriticalPlacementDwell()
            resetMotion()
            corridorExitStartedAt = nil
            lastCompressionTimestamp = nil
            recentCompressionTimestamps.removeAll(keepingCapacity: false)
            return events
        }

        let placement = placement(for: contact.palm.worldPosition)
        let stacking = handStackingHeuristic()
        emitClassificationChanges(placement: placement, stacking: stacking, into: &events)

        let sternumLocalPosition = targets.sternum.localPosition(of: contact.palm.worldPosition)
        let offset = sternumLocalPosition - targets.sternum.localCenter
        let isWithinTrackingCorridor = hypot(offset.x, offset.z) <= configuration.maximumTrackingRadiusMetres &&
            offset.y <= configuration.maximumHeightAboveTargetMetres &&
            offset.y >= -configuration.maximumDistanceBelowTargetMetres

        if isWithinTrackingCorridor {
            corridorExitStartedAt = nil
        } else {
            // Natural drift briefly exits the corridor mid-cycle during real stacked-hand
            // CPR. Within the configured grace window the oscillation phase state
            // survives; only a sustained exit resets it (grace 0 = original behaviour).
            contactChirality = contact.chirality
            resetCriticalPlacementDwell()
            let exitStartedAt = corridorExitStartedAt ?? timestampSeconds
            corridorExitStartedAt = exitStartedAt
            guard configuration.corridorExitGraceSeconds > 0,
                  timestampSeconds - exitStartedAt <= configuration.corridorExitGraceSeconds
            else {
                resetMotion()
                return events
            }
        }

        if contactChirality != contact.chirality {
            contactChirality = contact.chirality
            resetCriticalPlacementDwell()
            resetMotion()
        }

        events.append(contentsOf: criticalPlacementDwellEvents(
            placement: placement,
            timestampSeconds: timestampSeconds
        ))

        events.append(contentsOf: processMotion(
            height: offset.y,
            timestampSeconds: timestampSeconds,
            placement: placement,
            stacking: stacking
        ))
        return events
    }

    private mutating func processMotion(
        height: Float,
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        stacking: CPRHandStackingHeuristic
    ) -> [HandTrackingDerivedEvent] {
        let clampedSmoothingFactor = min(max(configuration.smoothingFactor, 0), 1)
        let filteredHeight: Float
        if let smoothedHeight {
            filteredHeight = clampedSmoothingFactor * height +
                (1 - clampedSmoothingFactor) * smoothedHeight
        } else {
            filteredHeight = height
        }
        smoothedHeight = filteredHeight

        guard let previousHeight,
              let lastMotionTimestamp,
              timestampSeconds > lastMotionTimestamp
        else {
            self.previousHeight = filteredHeight
            lastMotionTimestamp = timestampSeconds
            return []
        }

        let change = filteredHeight - previousHeight
        self.previousHeight = filteredHeight
        self.lastMotionTimestamp = timestampSeconds

        switch motionPhase {
        case .unknown:
            if change <= -configuration.minimumDirectionalChangeMetres {
                beginDescent(
                    from: previousHeight,
                    currentHeight: filteredHeight,
                    timestampSeconds: timestampSeconds,
                    placement: placement,
                    stacking: stacking
                )
            } else if change >= configuration.minimumDirectionalChangeMetres {
                motionPhase = .ascending
                ascentPeakHeight = filteredHeight
                troughHeight = previousHeight
            }
            return []

        case .descending:
            if troughHeight.map({ filteredHeight < $0 }) ?? true {
                recordTrough(
                    height: filteredHeight,
                    timestampSeconds: timestampSeconds,
                    placement: placement,
                    stacking: stacking
                )
            }

            guard change >= configuration.minimumDirectionalChangeMetres else {
                return []
            }

            var events: [HandTrackingDerivedEvent] = []
            if let descentStartHeight,
               let troughHeight,
               descentStartHeight - troughHeight >= configuration.oscillationHysteresisMetres,
               let troughTimestamp {
                events = recordCompression(
                    timestampSeconds: troughTimestamp,
                    placement: troughPlacement,
                    stacking: troughStacking
                )
            }
            motionPhase = .ascending
            ascentPeakHeight = filteredHeight
            return events

        case .ascending:
            if ascentPeakHeight.map({ filteredHeight > $0 }) ?? true {
                ascentPeakHeight = filteredHeight
            }

            guard change <= -configuration.minimumDirectionalChangeMetres else {
                return []
            }

            let peak = ascentPeakHeight ?? previousHeight
            let completedAscent = troughHeight.map {
                peak - $0 >= configuration.oscillationHysteresisMetres
            } ?? true
            guard completedAscent else { return [] }

            beginDescent(
                from: peak,
                currentHeight: filteredHeight,
                timestampSeconds: timestampSeconds,
                placement: placement,
                stacking: stacking
            )
            return []
        }
    }

    private mutating func beginDescent(
        from startHeight: Float,
        currentHeight: Float,
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        stacking: CPRHandStackingHeuristic
    ) {
        motionPhase = .descending
        descentStartHeight = startHeight
        ascentPeakHeight = nil
        recordTrough(
            height: currentHeight,
            timestampSeconds: timestampSeconds,
            placement: placement,
            stacking: stacking
        )
    }

    private mutating func recordTrough(
        height: Float,
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        stacking: CPRHandStackingHeuristic
    ) {
        troughHeight = height
        troughTimestamp = timestampSeconds
        troughPlacement = placement
        troughStacking = stacking
    }

    private mutating func recordCompression(
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        stacking: CPRHandStackingHeuristic
    ) -> [HandTrackingDerivedEvent] {
        if let lastCompressionTimestamp,
           timestampSeconds - lastCompressionTimestamp < configuration.minimumCompressionIntervalSeconds {
            return []
        }

        var events: [HandTrackingDerivedEvent] = []
        if let lastCompressionTimestamp {
            let gap = timestampSeconds - lastCompressionTimestamp
            if gap >= configuration.minimumGapReportedAsInterruptionSeconds {
                events.append(.interruptionMeasured(durationSeconds: gap))
            }
        }

        events.append(.compressionDetected(
            timestampSeconds: timestampSeconds,
            placement: placement,
            handStacking: stacking
        ))

        self.lastCompressionTimestamp = timestampSeconds
        recentCompressionTimestamps.append(timestampSeconds)
        if recentCompressionTimestamps.count > 6 {
            recentCompressionTimestamps.removeFirst(recentCompressionTimestamps.count - 6)
        }
        if let cadence = rollingCadencePerMinute() {
            events.append(.cadenceUpdated(ratePerMinute: cadence))
        }
        return events
    }

    private func rollingCadencePerMinute() -> Double? {
        guard recentCompressionTimestamps.count >= 2 else { return nil }
        let intervals = zip(
            recentCompressionTimestamps.dropFirst(),
            recentCompressionTimestamps
        ).map(-)
        let positiveIntervals = intervals.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !positiveIntervals.isEmpty else { return nil }

        let middle = positiveIntervals.count / 2
        let medianInterval: Double
        if positiveIntervals.count.isMultiple(of: 2) {
            medianInterval = (positiveIntervals[middle - 1] + positiveIntervals[middle]) / 2
        } else {
            medianInterval = positiveIntervals[middle]
        }
        return 60 / medianInterval
    }

    private func contactPalm() -> (chirality: TrackedHandChirality, palm: RecentPalm)? {
        palms.min { lhs, rhs in
            let lhsHeight = abs(
                targets.sternum.localPosition(of: lhs.value.worldPosition).y -
                    targets.sternum.localCenter.y
            )
            let rhsHeight = abs(
                targets.sternum.localPosition(of: rhs.value.worldPosition).y -
                    targets.sternum.localCenter.y
            )
            if abs(lhsHeight - rhsHeight) <= Float.ulpOfOne {
                return lhs.key == .left && rhs.key == .right
            }
            return lhsHeight < rhsHeight
        }.map { (chirality: $0.key, palm: $0.value) }
    }

    private func placement(for worldPosition: SIMD3<Float>) -> CPRHandPlacementZone {
        let arguments = (
            lateralMarginMetres: configuration.targetLateralMarginMetres,
            maximumHeightAboveTargetMetres: configuration.maximumHeightAboveTargetMetres,
            maximumDistanceBelowTargetMetres: configuration.maximumDistanceBelowTargetMetres
        )
        if targets.xiphoidAvoidZone.containsProjectedPosition(
            worldPosition,
            lateralMarginMetres: arguments.lateralMarginMetres,
            maximumHeightAboveTargetMetres: arguments.maximumHeightAboveTargetMetres,
            maximumDistanceBelowTargetMetres: arguments.maximumDistanceBelowTargetMetres
        ) {
            return .xiphoidAvoidZone
        }
        if targets.sternum.containsProjectedPosition(
            worldPosition,
            lateralMarginMetres: arguments.lateralMarginMetres,
            maximumHeightAboveTargetMetres: arguments.maximumHeightAboveTargetMetres,
            maximumDistanceBelowTargetMetres: arguments.maximumDistanceBelowTargetMetres
        ) {
            return .sternumTarget
        }
        return .outsideTarget
    }

    private func handStackingHeuristic() -> CPRHandStackingHeuristic {
        guard let left = palms[.left], let right = palms[.right] else {
            return .indeterminate
        }
        let leftLocal = targets.sternum.localPosition(of: left.worldPosition)
        let rightLocal = targets.sternum.localPosition(of: right.worldPosition)
        let delta = leftLocal - rightLocal
        guard simd_length(delta) <= configuration.maximumStackedPalmSeparationMetres
        else { return .separated }
        // Stacking means one palm ABOVE the other. In the sternum's local frame Y is
        // anterior, so the X/Z components are the offset across the chest: two hands
        // resting side by side clear the straight-line test but not this one.
        let acrossChest = simd_length(SIMD2<Float>(delta.x, delta.z))
        return acrossChest <= configuration.maximumStackedLateralSeparationMetres
            ? .likelyStacked
            : .separated
    }

    private mutating func emitClassificationChanges(
        placement: CPRHandPlacementZone,
        stacking: CPRHandStackingHeuristic,
        into events: inout [HandTrackingDerivedEvent]
    ) {
        if latestPlacement != placement {
            latestPlacement = placement
            events.append(.placementChanged(placement))
        }
        if latestStacking != stacking {
            latestStacking = stacking
            events.append(.handStackingChanged(stacking))
        }
    }

    private mutating func discardStalePalms(at timestampSeconds: Double) {
        palms = palms.filter {
            timestampSeconds - $0.value.timestampSeconds <=
                configuration.maximumHandSampleAgeSeconds
        }
    }

    private mutating func resetMotion() {
        motionPhase = .unknown
        smoothedHeight = nil
        previousHeight = nil
        lastMotionTimestamp = nil
        descentStartHeight = nil
        troughHeight = nil
        troughTimestamp = nil
        troughPlacement = .unavailable
        troughStacking = .indeterminate
        ascentPeakHeight = nil
    }

    private mutating func criticalPlacementDwellEvents(
        placement: CPRHandPlacementZone,
        timestampSeconds: Double
    ) -> [HandTrackingDerivedEvent] {
        guard placement == .xiphoidAvoidZone else {
            resetCriticalPlacementDwell()
            return []
        }
        guard let criticalPlacementStartedAt else {
            self.criticalPlacementStartedAt = timestampSeconds
            criticalPlacementDwellEmitted = false
            return []
        }
        guard !criticalPlacementDwellEmitted,
              timestampSeconds - criticalPlacementStartedAt >=
                Self.criticalPlacementDwellSeconds
        else { return [] }
        criticalPlacementDwellEmitted = true
        return [.placementDwellConfirmed(.xiphoidAvoidZone)]
    }

    private mutating func resetCriticalPlacementDwell() {
        criticalPlacementStartedAt = nil
        criticalPlacementDwellEmitted = false
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
