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
struct HandTrackingTargets: Sendable {
    let sternum: HandTrackingTargetVolume
    let xiphoidAvoidZone: HandTrackingTargetVolume
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

/// Derived practice signals. Deliberately absent: compression depth, force, recoil distance,
/// raw hand transforms, and raw joint positions.
enum HandTrackingDerivedEvent: Codable, Equatable, Sendable {
    case trackingAvailabilityChanged(isAvailable: Bool)
    case placementChanged(CPRHandPlacementZone)
    case handStackingChanged(CPRHandStackingHeuristic)
    case interruptionMeasured(durationSeconds: Double)
    case compressionDetected(
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        handStacking: CPRHandStackingHeuristic
    )
    case cadenceUpdated(ratePerMinute: Double)

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
             .handStackingChanged,
             .cadenceUpdated:
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
