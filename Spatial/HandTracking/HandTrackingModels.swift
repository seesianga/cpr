import Foundation
import simd

/// Which tracked hand produced a transient palm observation.
enum TrackedHandChirality: String, Codable, Hashable, Sendable {
    case left
    case right
}

/// An oriented, metres-scale practice target expressed in the immersive world's coordinates.
///
/// This value contains authored target geometry only. It is not a physical sensor and it must
/// never be used to infer compression depth or force.
struct HandTrackingTargetVolume: Sendable {
    let targetFromWorldTransform: simd_float4x4
    let localCenter: SIMD3<Float>
    let localExtents: SIMD3<Float>

    init?(
        worldFromTargetTransform: simd_float4x4,
        localCenter: SIMD3<Float>,
        localExtents: SIMD3<Float>
    ) {
        let determinant = simd_determinant(worldFromTargetTransform)
        guard determinant.isFinite,
              abs(determinant) > Float.ulpOfOne,
              localCenter.allFinite,
              localExtents.allFinite,
              localExtents.x > 0,
              localExtents.y > 0,
              localExtents.z > 0
        else { return nil }

        targetFromWorldTransform = simd_inverse(worldFromTargetTransform)
        self.localCenter = localCenter
        self.localExtents = localExtents
    }

    func localPosition(of worldPosition: SIMD3<Float>) -> SIMD3<Float> {
        let local = targetFromWorldTransform * SIMD4<Float>(worldPosition, 1)
        return SIMD3<Float>(local.x, local.y, local.z)
    }

    func containsProjectedPosition(
        _ worldPosition: SIMD3<Float>,
        lateralMarginMetres: Float,
        maximumHeightAboveTargetMetres: Float,
        maximumDistanceBelowTargetMetres: Float
    ) -> Bool {
        let position = localPosition(of: worldPosition)
        let halfExtents = localExtents * 0.5
        let minimumY = localCenter.y - halfExtents.y - maximumDistanceBelowTargetMetres
        let maximumY = localCenter.y + halfExtents.y + maximumHeightAboveTargetMetres

        return abs(position.x - localCenter.x) <= halfExtents.x + lateralMarginMetres &&
            abs(position.z - localCenter.z) <= halfExtents.z + lateralMarginMetres &&
            position.y >= minimumY &&
            position.y <= maximumY
    }
}

/// Authored targets needed for CPR placement and motion classification.
///
/// When a torso grid is available it is the authority for detection geometry; the
/// sternum and xiphoid volumes are then grid-derived. Without a grid the authored
/// entity volumes remain the detection source, so older call sites keep working.
struct HandTrackingTargets: Sendable {
    let sternum: HandTrackingTargetVolume
    let xiphoidAvoidZone: HandTrackingTargetVolume
    let grid: TorsoGridMap?

    init(
        sternum: HandTrackingTargetVolume,
        xiphoidAvoidZone: HandTrackingTargetVolume,
        grid: TorsoGridMap? = nil
    ) {
        self.sternum = sternum
        self.xiphoidAvoidZone = xiphoidAvoidZone
        self.grid = grid
    }
}

/// Product-level filtering constants for converting hand motion into discrete practice events.
///
/// These thresholds reject tracking jitter. They are not clinical compression-depth values and
/// are never surfaced to the learner or included in a score.
struct HandSignalDetectorConfiguration: Sendable, Equatable {
    let maximumHandSampleAgeSeconds: Double
    let smoothingFactor: Float
    let minimumDirectionalChangeMetres: Float
    let oscillationHysteresisMetres: Float
    let minimumCompressionIntervalSeconds: Double
    let minimumGapReportedAsInterruptionSeconds: Double
    let maximumTrackingRadiusMetres: Float
    let targetLateralMarginMetres: Float
    let maximumHeightAboveTargetMetres: Float
    let maximumDistanceBelowTargetMetres: Float
    let maximumStackedPalmSeparationMetres: Float
    /// How long a corridor exit may last before oscillation phase state resets.
    /// Zero preserves the original reset-on-exit behaviour.
    let corridorExitGraceSeconds: Double

    init(
        maximumHandSampleAgeSeconds: Double,
        smoothingFactor: Float,
        minimumDirectionalChangeMetres: Float,
        oscillationHysteresisMetres: Float,
        minimumCompressionIntervalSeconds: Double,
        minimumGapReportedAsInterruptionSeconds: Double,
        maximumTrackingRadiusMetres: Float,
        targetLateralMarginMetres: Float,
        maximumHeightAboveTargetMetres: Float,
        maximumDistanceBelowTargetMetres: Float,
        maximumStackedPalmSeparationMetres: Float,
        corridorExitGraceSeconds: Double = 0
    ) {
        self.maximumHandSampleAgeSeconds = maximumHandSampleAgeSeconds
        self.smoothingFactor = smoothingFactor
        self.minimumDirectionalChangeMetres = minimumDirectionalChangeMetres
        self.oscillationHysteresisMetres = oscillationHysteresisMetres
        self.minimumCompressionIntervalSeconds = minimumCompressionIntervalSeconds
        self.minimumGapReportedAsInterruptionSeconds = minimumGapReportedAsInterruptionSeconds
        self.maximumTrackingRadiusMetres = maximumTrackingRadiusMetres
        self.targetLateralMarginMetres = targetLateralMarginMetres
        self.maximumHeightAboveTargetMetres = maximumHeightAboveTargetMetres
        self.maximumDistanceBelowTargetMetres = maximumDistanceBelowTargetMetres
        self.maximumStackedPalmSeparationMetres = maximumStackedPalmSeparationMetres
        self.corridorExitGraceSeconds = corridorExitGraceSeconds
    }

    static let practiceDefault = HandSignalDetectorConfiguration(
        maximumHandSampleAgeSeconds: 0.15,
        smoothingFactor: 0.45,
        minimumDirectionalChangeMetres: 0.0015,
        oscillationHysteresisMetres: 0.012,
        minimumCompressionIntervalSeconds: 0.25,
        // Reporting a missed-beat gap is an operational UI heuristic. The source-backed
        // critical threshold remains the CPR engine's maximumRestSeconds value.
        minimumGapReportedAsInterruptionSeconds: 1.1,
        maximumTrackingRadiusMetres: 0.42,
        targetLateralMarginMetres: 0.025,
        maximumHeightAboveTargetMetres: 0.30,
        maximumDistanceBelowTargetMetres: 0.04,
        maximumStackedPalmSeparationMetres: 0.16
    )

    /// Retune for real stacked-hand CPR posture on a resistance-free virtual manikin
    /// (device evidence: 1.5–3 cm bounces). Smaller oscillation hysteresis, lighter
    /// smoothing so small bounces survive filtering, a corridor that tolerates the
    /// stacked-hand centroid offset, and a grace window so transient drift out of the
    /// corridor no longer wipes oscillation phase state. Used as the secondary trigger
    /// beside the finger-contact detector; jitter filtering only, never clinical values.
    static let contactComposedRetuned = HandSignalDetectorConfiguration(
        maximumHandSampleAgeSeconds: 0.15,
        smoothingFactor: 0.6,
        minimumDirectionalChangeMetres: 0.0015,
        oscillationHysteresisMetres: 0.008,
        minimumCompressionIntervalSeconds: 0.25,
        minimumGapReportedAsInterruptionSeconds: 1.1,
        maximumTrackingRadiusMetres: 0.55,
        targetLateralMarginMetres: 0.025,
        maximumHeightAboveTargetMetres: 0.30,
        maximumDistanceBelowTargetMetres: 0.06,
        maximumStackedPalmSeparationMetres: 0.20,
        corridorExitGraceSeconds: 0.75
    )
}

/// A short-lived, already-reduced observation passed across the ARKit privacy boundary.
///
/// It contains one palm centroid rather than a hand anchor, skeleton, or joint stream. A nil
/// centroid means that tracking for that hand was removed or became unreliable.
struct TrackedPalmObservation: Sendable, Equatable {
    let timestampSeconds: Double
    let chirality: TrackedHandChirality
    let palmCentroidWorld: SIMD3<Float>?
}

/// Reduced per-hand node positions for contact and pinch classification.
///
/// This is a fixed, named reduction — never a skeleton, joint collection, or transform
/// stream. Thumb, index, palm proxy, and wrist are required for classification; the
/// remaining fingertips are optional because ARKit frequently loses them.
struct TrackedHandNodes: Sendable, Equatable {
    let thumbTip: SIMD3<Float>
    let indexTip: SIMD3<Float>
    let middleMetacarpal: SIMD3<Float>
    let wrist: SIMD3<Float>
    let middleTip: SIMD3<Float>?
    let ringTip: SIMD3<Float>?
    let littleTip: SIMD3<Float>?

    /// The stacked-pair contact proxy used for compression contact cycles.
    var palmProxy: SIMD3<Float> { middleMetacarpal }

    var pinchMidpointWorld: SIMD3<Float> { (thumbTip + indexTip) / 2 }

    var pinchGapMetres: Float { simd_distance(thumbTip, indexTip) }

    init(
        thumbTip: SIMD3<Float>,
        indexTip: SIMD3<Float>,
        middleMetacarpal: SIMD3<Float>,
        wrist: SIMD3<Float>,
        middleTip: SIMD3<Float>? = nil,
        ringTip: SIMD3<Float>? = nil,
        littleTip: SIMD3<Float>? = nil
    ) {
        self.thumbTip = thumbTip
        self.indexTip = indexTip
        self.middleMetacarpal = middleMetacarpal
        self.wrist = wrist
        self.middleTip = middleTip
        self.ringTip = ringTip
        self.littleTip = littleTip
    }
}

/// Transient node observation for one hand. Nil nodes mean the hand was removed or
/// became unreliable.
struct TrackedHandNodesObservation: Sendable, Equatable {
    let timestampSeconds: Double
    let chirality: TrackedHandChirality
    let nodes: TrackedHandNodes?
}

/// One reduced frame crossing the privacy boundary: the legacy palm centroid plus the
/// finger-node reduction, produced together inside the detached reduction task.
struct TrackedHandReducedFrame: Sendable, Equatable {
    let palm: TrackedPalmObservation
    let nodes: TrackedHandNodesObservation
}

/// A derived pinch-grab interaction against a named practice item. The midpoint is an
/// already-derived interaction point (like a cursor), not a joint position stream.
struct GrabInteractionSample: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case began
        case moved
        case released
        case cancelled
    }

    let phase: Phase
    let itemIdentifier: String
    let timestampSeconds: Double
    /// Nil only for `.cancelled` (hand loss mid-drag).
    let midpointWorld: SIMD3<Float>?
}

/// Shared rolling-median cadence estimate over recent compression timestamps.
/// Operational display smoothing only — the practice state machines remain authoritative
/// for any scored rhythm evidence.
struct RollingCadenceEstimator: Sendable, Equatable {
    static let maximumRetainedTimestamps = 6

    private var recentTimestamps: [Double] = []

    mutating func record(timestampSeconds: Double) {
        recentTimestamps.append(timestampSeconds)
        if recentTimestamps.count > Self.maximumRetainedTimestamps {
            recentTimestamps.removeFirst(
                recentTimestamps.count - Self.maximumRetainedTimestamps
            )
        }
    }

    mutating func reset() {
        recentTimestamps.removeAll(keepingCapacity: false)
    }

    var cadencePerMinute: Double? {
        guard recentTimestamps.count >= 2 else { return nil }
        let intervals = zip(recentTimestamps.dropFirst(), recentTimestamps).map(-)
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
}

/// Derived practice signals. Deliberately absent: compression depth, force, recoil distance,
/// raw hand transforms, and raw joint positions.
enum HandTrackingDerivedEvent: Codable, Equatable, Sendable {
    case trackingAvailabilityChanged(isAvailable: Bool)
    case placementChanged(CPRHandPlacementZone)
    /// Emitted only after an in-corridor placement remains stable for the detector's
    /// critical-placement dwell threshold. It is a transit filter, not a clinical measure.
    case placementDwellConfirmed(CPRHandPlacementZone)
    case handStackingChanged(CPRHandStackingHeuristic)
    case interruptionMeasured(durationSeconds: Double)
    case compressionDetected(
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        handStacking: CPRHandStackingHeuristic
    )
    case cadenceUpdated(ratePerMinute: Double)
    case grabInteractionChanged(GrabInteractionSample)

    /// The exact event accepted by the pure CPR state machine, when this signal represents a
    /// detected compression. The state machine remains authoritative for cadence and scoring.
    var cprPracticeEvent: CPRPracticeEvent? {
        switch self {
        case let .compressionDetected(timestamp, placement, handStacking):
            .compressionDetected(
                timestampSeconds: timestamp,
                placement: placement,
                handStacking: handStacking
            )
        case let .interruptionMeasured(duration):
            .recordInterruption(durationSeconds: duration)
        case .trackingAvailabilityChanged,
             .placementChanged,
             .placementDwellConfirmed,
             .handStackingChanged,
             .cadenceUpdated,
             .grabInteractionChanged:
            nil
        }
    }
}

extension HandTrackingState {
    /// The fallback is a complete interaction path, not a reduced or blocked course mode.
    var usesAccessibleFallback: Bool {
        switch self {
        case .permissionDenied, .unavailable, .failed:
            true
        case .idle, .requestingPermission, .running, .paused:
            false
        }
    }

    var fallbackExplanation: String? {
        switch self {
        case .permissionDenied:
            "Hand tracking permission was not granted. Continue with gaze and pinch or the accessible practice controls. Automatic placement, rhythm, interruption, and hand-stacking guidance are unavailable. Depth and force are not physically assessed."
        case .unavailable:
            "Hand tracking is unavailable here. Continue with gaze and pinch or the accessible practice controls. Automatic placement, rhythm, interruption, and hand-stacking guidance are unavailable. Depth and force are not physically assessed."
        case let .failed(message):
            "Hand tracking stopped: \(message) Continue with gaze and pinch or the accessible practice controls. Depth and force are not physically assessed."
        case .idle, .requestingPermission, .running, .paused:
            nil
        }
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
