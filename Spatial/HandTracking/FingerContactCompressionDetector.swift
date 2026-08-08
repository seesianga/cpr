import Foundation
import simd

/// Filter constants for classifying compression CONTACT CYCLES against the torso.
///
/// These reject tracking jitter and define an interaction release plane. They are not
/// compression-depth, force, or recoil values and are never surfaced as measurements.
struct FingerContactCompressionConfiguration: Sendable, Equatable {
    let maximumSampleAgeSeconds: Double
    /// How far above the anterior surface a descending node may be and still count as
    /// contact entry.
    let entryToleranceMetres: Float
    /// Rise above the deepest point of the current contact required before a release is
    /// recognised. Trough-relative, because a resistance-free virtual chest lets hands
    /// bottom out below the surface; a fixed release plane would miss those cycles.
    let releaseHysteresisMetres: Float
    /// How far outside the torso frontal plane (normalized u/v) contact is still tracked.
    let frontalMarginNormalized: Double
    let minimumCompressionIntervalSeconds: Double
    let maximumStackedPalmSeparationMetres: Float
    /// Session-scoped auto-tuning of the entry and release filters, driven by the
    /// per-cycle distance log. Nil disables adaptation entirely.
    let adaptiveTuning: CompressionAdaptiveThresholdTuning?

    init(
        maximumSampleAgeSeconds: Double,
        entryToleranceMetres: Float,
        releaseHysteresisMetres: Float,
        frontalMarginNormalized: Double,
        minimumCompressionIntervalSeconds: Double,
        maximumStackedPalmSeparationMetres: Float,
        adaptiveTuning: CompressionAdaptiveThresholdTuning? = .practiceDefault
    ) {
        self.maximumSampleAgeSeconds = maximumSampleAgeSeconds
        self.entryToleranceMetres = entryToleranceMetres
        self.releaseHysteresisMetres = releaseHysteresisMetres
        self.frontalMarginNormalized = frontalMarginNormalized
        self.minimumCompressionIntervalSeconds = minimumCompressionIntervalSeconds
        self.maximumStackedPalmSeparationMetres = maximumStackedPalmSeparationMetres
        self.adaptiveTuning = adaptiveTuning
    }

    static let practiceDefault = FingerContactCompressionConfiguration(
        maximumSampleAgeSeconds: 0.15,
        entryToleranceMetres: 0.02,
        releaseHysteresisMetres: 0.012,
        frontalMarginNormalized: 0.06,
        minimumCompressionIntervalSeconds: 0.25,
        maximumStackedPalmSeparationMetres: 0.20
    )
}

/// Bounds and trigger rules for widening the detection filters when real learner motion
/// is repeatedly just missing the static thresholds. Every adjustment is clamped; the
/// active thresholds remain jitter filters and never become measured clinical values.
struct CompressionAdaptiveThresholdTuning: Sendable, Equatable {
    /// The entry tolerance may widen up to this ceiling, never beyond.
    let maximumEntryToleranceMetres: Float
    /// Amount added to the entry tolerance per widening step.
    let entryToleranceStepMetres: Float
    /// Descents reversing between the entry tolerance and this far above it count as
    /// near-miss cycles (the learner is bouncing just above the virtual surface).
    let nearMissBandMetres: Float
    /// Distinct near-miss descents inside `adaptationWindowSeconds` required to widen.
    let nearMissesBeforeWidening: Int
    /// Rolling evidence window for both trigger rules.
    let adaptationWindowSeconds: Double
    /// The release hysteresis may shrink down to this floor, never below.
    let minimumReleaseHysteresisMetres: Float
    /// Counted cycles with travel below `shallowTravelFactor × releaseHysteresis`
    /// inside the window required before the hysteresis relaxes.
    let shallowCyclesBeforeRelaxing: Int
    /// A counted cycle is "shallow" when its descent travel is below this multiple of
    /// the active release hysteresis, so follow-up bounces risk never re-arming.
    let shallowTravelFactor: Float

    static let practiceDefault = CompressionAdaptiveThresholdTuning(
        maximumEntryToleranceMetres: 0.05,
        entryToleranceStepMetres: 0.008,
        nearMissBandMetres: 0.03,
        nearMissesBeforeWidening: 3,
        adaptationWindowSeconds: 6,
        minimumReleaseHysteresisMetres: 0.006,
        shallowCyclesBeforeRelaxing: 4,
        shallowTravelFactor: 1.8
    )
}

/// One recorded contact-descent for the distance log.
///
/// Heights are metres relative to the virtual anterior torso surface (negative =
/// below it). These are virtual-surface interaction distances used for coaching
/// feedback and threshold tuning — never a physical compression-depth measurement.
struct CompressionDistanceSample: Codable, Equatable, Sendable {
    /// Surface-entry time for counted/suppressed cycles; reversal time for near misses.
    let timestampSeconds: Double
    /// Local maximum height where the descent began.
    let descentStartHeightMetres: Float
    /// Deepest height the contact node reached during this descent.
    let troughHeightMetres: Float
    let placement: CPRHandPlacementZone
    /// False for near-miss descents that reversed above the entry band and for cycles
    /// suppressed by the refractory interval.
    let countedAsCompression: Bool

    /// Total distance travelled from the descent start to the trough.
    var descentDistanceMetres: Float {
        max(0, descentStartHeightMetres - troughHeightMetres)
    }

    /// How far below the virtual surface the descent bottomed out (0 when it did not).
    var depthBelowSurfaceMetres: Float {
        max(0, -troughHeightMetres)
    }
}

/// A clamped threshold adjustment made by the adaptive tuner, surfaced so session
/// models can log it and explain the change to the learner.
struct CompressionThresholdAdaptation: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// Repeated descents reversed just above the entry band: entry tolerance widened.
        case nearMissDescentsAboveEntryBand
        /// Counted cycles were too shallow for reliable re-arming: hysteresis relaxed.
        case shallowCyclesBelowReleaseHysteresis
    }

    let timestampSeconds: Double
    let entryToleranceMetres: Float
    let releaseHysteresisMetres: Float
    let reason: Reason
}

/// Distance telemetry accumulated by the detector since the previous drain.
struct CompressionDistanceTelemetry: Sendable, Equatable {
    let samples: [CompressionDistanceSample]
    let adaptation: CompressionThresholdAdaptation?

    var isEmpty: Bool { samples.isEmpty && adaptation == nil }
}

/// One detected contact-cycle compression, timestamped at surface entry.
struct FingerContactCompression: Sendable, Equatable {
    let timestampSeconds: Double
    let placement: CPRHandPlacementZone
    let handStacking: CPRHandStackingHeuristic
    /// Where the contact node entered, for grid-region diagnostics. Never persisted.
    let contactWorldPosition: SIMD3<Float>
}

/// Detects compressions as CONTACT CYCLES rather than free-space oscillations.
///
/// Real CPR posture on a resistance-free virtual manikin produces small 1.5–3 cm
/// bounces around (and often below) the chest surface. A compression is: the contact
/// node DESCENDS into the surface entry band (one compression per entry, timestamped at
/// entry), then rises `releaseHysteresisMetres` above the deepest point it reached,
/// re-arming the next entry. Placement is the grid region containing the contact point.
/// Pure value type; retains node positions for at most one frame.
struct FingerContactCompressionDetector: Sendable {
    /// Rolling distance-log capacity; oldest samples are dropped first.
    static let maximumDistanceLogEntries = 200

    private struct RecentNodes: Sendable {
        let timestampSeconds: Double
        let nodes: TrackedHandNodes
    }

    private struct ActiveContactCycle: Sendable {
        let entryTimestampSeconds: Double
        let descentStartHeightMetres: Float
        let placement: CPRHandPlacementZone
        let countedAsCompression: Bool
    }

    private let targets: HandTrackingTargets
    private let configuration: FingerContactCompressionConfiguration

    private var hands: [TrackedHandChirality: RecentNodes] = [:]
    private var isInContact = false
    private var troughHeightMetres: Float?
    private var previousHeightMetres: Float?
    private var lastCompressionTimestamp: Double?

    /// Active (possibly adapted) thresholds. They start from the configuration and only
    /// move inside the tuning clamps; `reset()` restores the configured values.
    private(set) var activeEntryToleranceMetres: Float
    private(set) var activeReleaseHysteresisMetres: Float

    private var descentStartHeightMetres: Float?
    private var isDescending = false
    private var activeCycle: ActiveContactCycle?
    private var nearMissTimestamps: [Double] = []
    private var shallowCycleTimestamps: [Double] = []
    private(set) var distanceLog: [CompressionDistanceSample] = []
    private var pendingDistanceSamples: [CompressionDistanceSample] = []
    private var pendingAdaptation: CompressionThresholdAdaptation?

    init(
        targets: HandTrackingTargets,
        configuration: FingerContactCompressionConfiguration = .practiceDefault
    ) {
        self.targets = targets
        self.configuration = configuration
        activeEntryToleranceMetres = configuration.entryToleranceMetres
        activeReleaseHysteresisMetres = configuration.releaseHysteresisMetres
    }

    /// Returns and clears the distance samples and any threshold adaptation recorded
    /// since the previous drain, so callers can forward them as derived events.
    mutating func drainDistanceTelemetry() -> CompressionDistanceTelemetry {
        let telemetry = CompressionDistanceTelemetry(
            samples: pendingDistanceSamples,
            adaptation: pendingAdaptation
        )
        pendingDistanceSamples.removeAll(keepingCapacity: true)
        pendingAdaptation = nil
        return telemetry
    }

    mutating func process(
        _ observation: TrackedHandNodesObservation
    ) -> [FingerContactCompression] {
        guard observation.timestampSeconds.isFinite,
              observation.timestampSeconds >= 0
        else { return [] }
        if let existing = hands[observation.chirality],
           observation.timestampSeconds < existing.timestampSeconds {
            return []
        }

        if let nodes = observation.nodes, nodes.palmProxy.allFinite {
            hands[observation.chirality] = RecentNodes(
                timestampSeconds: observation.timestampSeconds,
                nodes: nodes
            )
        } else {
            hands.removeValue(forKey: observation.chirality)
        }
        return evaluate(at: observation.timestampSeconds)
    }

    /// Atomically updates both hands for deterministic simulator and unit-test input.
    mutating func processFrame(
        timestampSeconds: Double,
        leftNodes: TrackedHandNodes?,
        rightNodes: TrackedHandNodes?
    ) -> [FingerContactCompression] {
        guard timestampSeconds.isFinite, timestampSeconds >= 0 else { return [] }
        update(.left, nodes: leftNodes, timestampSeconds: timestampSeconds)
        update(.right, nodes: rightNodes, timestampSeconds: timestampSeconds)
        return evaluate(at: timestampSeconds)
    }

    mutating func reset() {
        hands.removeAll(keepingCapacity: false)
        endContactTracking()
        lastCompressionTimestamp = nil
        activeEntryToleranceMetres = configuration.entryToleranceMetres
        activeReleaseHysteresisMetres = configuration.releaseHysteresisMetres
        nearMissTimestamps.removeAll(keepingCapacity: false)
        shallowCycleTimestamps.removeAll(keepingCapacity: false)
        distanceLog.removeAll(keepingCapacity: false)
        pendingDistanceSamples.removeAll(keepingCapacity: false)
        pendingAdaptation = nil
    }

    private mutating func endContactTracking() {
        // An in-flight contact cycle interrupted by hand loss or leaving the torso
        // footprint still contributes its measured descent to the distance log.
        if let cycle = activeCycle, let trough = troughHeightMetres {
            recordSample(
                CompressionDistanceSample(
                    timestampSeconds: cycle.entryTimestampSeconds,
                    descentStartHeightMetres: cycle.descentStartHeightMetres,
                    troughHeightMetres: trough,
                    placement: cycle.placement,
                    countedAsCompression: cycle.countedAsCompression
                )
            )
        }
        activeCycle = nil
        isInContact = false
        troughHeightMetres = nil
        previousHeightMetres = nil
        descentStartHeightMetres = nil
        isDescending = false
    }

    private mutating func update(
        _ chirality: TrackedHandChirality,
        nodes: TrackedHandNodes?,
        timestampSeconds: Double
    ) {
        if let nodes, nodes.palmProxy.allFinite {
            hands[chirality] = RecentNodes(
                timestampSeconds: timestampSeconds,
                nodes: nodes
            )
        } else {
            hands.removeValue(forKey: chirality)
        }
    }

    private mutating func evaluate(at timestampSeconds: Double) -> [FingerContactCompression] {
        hands = hands.filter {
            timestampSeconds - $0.value.timestampSeconds <=
                configuration.maximumSampleAgeSeconds
        }

        guard let contactNode = contactNodeWorldPosition() else {
            endContactTracking()
            return []
        }

        guard let geometry = surfaceGeometry(for: contactNode) else {
            // The node is not over the torso's frontal footprint (or geometry failed):
            // any held contact ends without completing a cycle.
            endContactTracking()
            return []
        }

        let height = geometry.heightAboveSurfaceMetres
        defer { previousHeightMetres = height }

        if isInContact {
            let trough = min(troughHeightMetres ?? height, height)
            troughHeightMetres = trough
            if height >= trough + activeReleaseHysteresisMetres {
                completeActiveCycle(troughHeightMetres: trough, at: timestampSeconds)
                isInContact = false
                troughHeightMetres = nil
                // The release point starts the next descent's travel measurement.
                descentStartHeightMetres = height
                isDescending = false
            }
            return []
        }

        updateDescentTracking(
            height: height,
            placement: geometry.placement,
            at: timestampSeconds
        )

        guard let previousHeight = previousHeightMetres,
              height < previousHeight,
              height <= activeEntryToleranceMetres
        else { return [] }
        isInContact = true
        troughHeightMetres = height

        let countedAsCompression: Bool
        if let lastCompressionTimestamp,
           timestampSeconds - lastCompressionTimestamp <
            configuration.minimumCompressionIntervalSeconds {
            countedAsCompression = false
        } else {
            countedAsCompression = true
            lastCompressionTimestamp = timestampSeconds
        }
        activeCycle = ActiveContactCycle(
            entryTimestampSeconds: timestampSeconds,
            descentStartHeightMetres: max(
                descentStartHeightMetres ?? previousHeight,
                previousHeight
            ),
            placement: geometry.placement,
            countedAsCompression: countedAsCompression
        )
        guard countedAsCompression else { return [] }

        return [
            FingerContactCompression(
                timestampSeconds: timestampSeconds,
                placement: geometry.placement,
                handStacking: handStackingHeuristic(),
                contactWorldPosition: contactNode
            )
        ]
    }

    // MARK: - Distance log and adaptive thresholds

    private mutating func updateDescentTracking(
        height: Float,
        placement: CPRHandPlacementZone,
        at timestampSeconds: Double
    ) {
        guard let previousHeight = previousHeightMetres else {
            descentStartHeightMetres = height
            isDescending = false
            return
        }
        if height < previousHeight {
            if !isDescending {
                isDescending = true
                descentStartHeightMetres = max(
                    descentStartHeightMetres ?? previousHeight,
                    previousHeight
                )
            }
        } else if height > previousHeight {
            if isDescending {
                recordNearMissIfNeeded(
                    reversalTroughMetres: previousHeight,
                    placement: placement,
                    at: timestampSeconds
                )
                isDescending = false
                descentStartHeightMetres = height
            } else {
                descentStartHeightMetres = max(descentStartHeightMetres ?? height, height)
            }
        }
    }

    /// A descent that reversed above the entry band is a candidate missed compression.
    /// Enough of them inside the window — while nothing is being counted — widens the
    /// entry tolerance one clamped step so genuine motion stops being missed.
    private mutating func recordNearMissIfNeeded(
        reversalTroughMetres: Float,
        placement: CPRHandPlacementZone,
        at timestampSeconds: Double
    ) {
        guard let tuning = configuration.adaptiveTuning else { return }
        let start = descentStartHeightMetres ?? reversalTroughMetres
        let travel = start - reversalTroughMetres
        guard reversalTroughMetres > activeEntryToleranceMetres,
              reversalTroughMetres <= activeEntryToleranceMetres + tuning.nearMissBandMetres,
              travel >= activeReleaseHysteresisMetres
        else { return }

        recordSample(
            CompressionDistanceSample(
                timestampSeconds: timestampSeconds,
                descentStartHeightMetres: start,
                troughHeightMetres: reversalTroughMetres,
                placement: placement,
                countedAsCompression: false
            )
        )

        nearMissTimestamps.append(timestampSeconds)
        nearMissTimestamps.removeAll {
            timestampSeconds - $0 > tuning.adaptationWindowSeconds
        }
        let compressionsAreLanding = lastCompressionTimestamp.map {
            timestampSeconds - $0 <= tuning.adaptationWindowSeconds
        } ?? false
        guard !compressionsAreLanding,
              nearMissTimestamps.count >= tuning.nearMissesBeforeWidening,
              activeEntryToleranceMetres < tuning.maximumEntryToleranceMetres
        else { return }

        activeEntryToleranceMetres = min(
            tuning.maximumEntryToleranceMetres,
            activeEntryToleranceMetres + tuning.entryToleranceStepMetres
        )
        nearMissTimestamps.removeAll(keepingCapacity: true)
        pendingAdaptation = CompressionThresholdAdaptation(
            timestampSeconds: timestampSeconds,
            entryToleranceMetres: activeEntryToleranceMetres,
            releaseHysteresisMetres: activeReleaseHysteresisMetres,
            reason: .nearMissDescentsAboveEntryBand
        )
    }

    private mutating func completeActiveCycle(
        troughHeightMetres trough: Float,
        at timestampSeconds: Double
    ) {
        guard let cycle = activeCycle else { return }
        activeCycle = nil
        let sample = CompressionDistanceSample(
            timestampSeconds: cycle.entryTimestampSeconds,
            descentStartHeightMetres: cycle.descentStartHeightMetres,
            troughHeightMetres: trough,
            placement: cycle.placement,
            countedAsCompression: cycle.countedAsCompression
        )
        recordSample(sample)
        relaxReleaseHysteresisIfNeeded(for: sample, at: timestampSeconds)
    }

    /// Counted cycles whose travel barely exceeds the release hysteresis risk never
    /// re-arming between bounces. A run of them relaxes the hysteresis toward the
    /// clamped floor, sized against the median of recent counted travel.
    private mutating func relaxReleaseHysteresisIfNeeded(
        for sample: CompressionDistanceSample,
        at timestampSeconds: Double
    ) {
        guard let tuning = configuration.adaptiveTuning,
              sample.countedAsCompression,
              sample.descentDistanceMetres <
                activeReleaseHysteresisMetres * tuning.shallowTravelFactor
        else { return }
        shallowCycleTimestamps.append(timestampSeconds)
        shallowCycleTimestamps.removeAll {
            timestampSeconds - $0 > tuning.adaptationWindowSeconds
        }
        guard shallowCycleTimestamps.count >= tuning.shallowCyclesBeforeRelaxing,
              activeReleaseHysteresisMetres > tuning.minimumReleaseHysteresisMetres
        else { return }

        let countedTravels = distanceLog
            .suffix(16)
            .filter(\.countedAsCompression)
            .map(\.descentDistanceMetres)
            .sorted()
        let median = countedTravels.isEmpty
            ? sample.descentDistanceMetres
            : countedTravels[countedTravels.count / 2]
        activeReleaseHysteresisMetres = max(
            tuning.minimumReleaseHysteresisMetres,
            min(activeReleaseHysteresisMetres, median * 0.6)
        )
        shallowCycleTimestamps.removeAll(keepingCapacity: true)
        pendingAdaptation = CompressionThresholdAdaptation(
            timestampSeconds: timestampSeconds,
            entryToleranceMetres: activeEntryToleranceMetres,
            releaseHysteresisMetres: activeReleaseHysteresisMetres,
            reason: .shallowCyclesBelowReleaseHysteresis
        )
    }

    private mutating func recordSample(_ sample: CompressionDistanceSample) {
        distanceLog.append(sample)
        if distanceLog.count > Self.maximumDistanceLogEntries {
            distanceLog.removeFirst(distanceLog.count - Self.maximumDistanceLogEntries)
        }
        pendingDistanceSamples.append(sample)
    }

    /// The palm proxy of the LOWER hand of the stacked pair — the hand in chest contact.
    private func contactNodeWorldPosition() -> SIMD3<Float>? {
        hands.min { lhs, rhs in
            let lhsHeight = height(of: lhs.value.nodes.palmProxy)
            let rhsHeight = height(of: rhs.value.nodes.palmProxy)
            if abs(lhsHeight - rhsHeight) <= Float.ulpOfOne {
                return lhs.key == .left && rhs.key == .right
            }
            return lhsHeight < rhsHeight
        }.map { $0.value.nodes.palmProxy }
    }

    private func height(of worldPosition: SIMD3<Float>) -> Float {
        if let grid = targets.grid,
           let height = heightAboveGridSurface(of: worldPosition, grid: grid) {
            return height
        }
        return heightAboveVolumeSurface(of: worldPosition, volume: targets.sternum)
    }

    private struct SurfaceGeometry {
        let heightAboveSurfaceMetres: Float
        let placement: CPRHandPlacementZone
    }

    private func surfaceGeometry(for worldPosition: SIMD3<Float>) -> SurfaceGeometry? {
        if let grid = targets.grid {
            guard let normalized = grid.normalizedPoint(fromWorld: worldPosition),
                  let height = heightAboveGridSurface(of: worldPosition, grid: grid)
            else { return nil }
            let margin = configuration.frontalMarginNormalized
            guard (0 - margin...1 + margin).contains(Double(normalized.x)),
                  (0 - margin...1 + margin).contains(Double(normalized.y))
            else { return nil }

            let placement: CPRHandPlacementZone = switch grid.region(
                containingWorld: worldPosition
            ) {
            case .xiphoidAvoidZone: .xiphoidAvoidZone
            case .sternumCompressionSite: .sternumTarget
            case .padSiteRightClavicle, .padSiteLeftLateral, nil: .outsideTarget
            }
            return SurfaceGeometry(heightAboveSurfaceMetres: height, placement: placement)
        }

        // Entity-volume fallback when no grid is available: track over the sternum
        // volume's frontal footprint only, classifying via the authored volumes.
        let local = targets.sternum.localPosition(of: worldPosition)
        let halfExtents = targets.sternum.localExtents * 0.5
        let frontalAllowance: Float = 0.05
        guard abs(local.x - targets.sternum.localCenter.x) <= halfExtents.x + frontalAllowance,
              abs(local.z - targets.sternum.localCenter.z) <= halfExtents.z + frontalAllowance
        else { return nil }

        let xiphoidHeight = heightAboveVolumeSurface(
            of: worldPosition,
            volume: targets.xiphoidAvoidZone
        )
        let xiphoidLocal = targets.xiphoidAvoidZone.localPosition(of: worldPosition)
        let xiphoidHalf = targets.xiphoidAvoidZone.localExtents * 0.5
        let isOverXiphoid =
            abs(xiphoidLocal.x - targets.xiphoidAvoidZone.localCenter.x) <= xiphoidHalf.x &&
            abs(xiphoidLocal.z - targets.xiphoidAvoidZone.localCenter.z) <= xiphoidHalf.z
        if isOverXiphoid {
            return SurfaceGeometry(
                heightAboveSurfaceMetres: xiphoidHeight,
                placement: .xiphoidAvoidZone
            )
        }

        let sternumHeight = heightAboveVolumeSurface(
            of: worldPosition,
            volume: targets.sternum
        )
        let isOverSternum =
            abs(local.x - targets.sternum.localCenter.x) <= halfExtents.x &&
            abs(local.z - targets.sternum.localCenter.z) <= halfExtents.z
        return SurfaceGeometry(
            heightAboveSurfaceMetres: sternumHeight,
            placement: isOverSternum ? .sternumTarget : .outsideTarget
        )
    }

    private func heightAboveGridSurface(
        of worldPosition: SIMD3<Float>,
        grid: TorsoGridMap
    ) -> Float? {
        grid.heightAboveAnteriorSurfaceMetres(ofWorld: worldPosition)
    }

    private func heightAboveVolumeSurface(
        of worldPosition: SIMD3<Float>,
        volume: HandTrackingTargetVolume
    ) -> Float {
        let local = volume.localPosition(of: worldPosition)
        return local.y - (volume.localCenter.y + volume.localExtents.y * 0.5)
    }

    private func handStackingHeuristic() -> CPRHandStackingHeuristic {
        guard let left = hands[.left], let right = hands[.right] else {
            return .indeterminate
        }
        let separation = simd_distance(
            left.nodes.palmProxy,
            right.nodes.palmProxy
        )
        return separation <= configuration.maximumStackedPalmSeparationMetres
            ? .likelyStacked
            : .separated
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
