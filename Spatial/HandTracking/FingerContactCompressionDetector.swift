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

    init(
        maximumSampleAgeSeconds: Double,
        entryToleranceMetres: Float,
        releaseHysteresisMetres: Float,
        frontalMarginNormalized: Double,
        minimumCompressionIntervalSeconds: Double,
        maximumStackedPalmSeparationMetres: Float
    ) {
        self.maximumSampleAgeSeconds = maximumSampleAgeSeconds
        self.entryToleranceMetres = entryToleranceMetres
        self.releaseHysteresisMetres = releaseHysteresisMetres
        self.frontalMarginNormalized = frontalMarginNormalized
        self.minimumCompressionIntervalSeconds = minimumCompressionIntervalSeconds
        self.maximumStackedPalmSeparationMetres = maximumStackedPalmSeparationMetres
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
    private struct RecentNodes: Sendable {
        let timestampSeconds: Double
        let nodes: TrackedHandNodes
    }

    private let targets: HandTrackingTargets
    private let configuration: FingerContactCompressionConfiguration

    private var hands: [TrackedHandChirality: RecentNodes] = [:]
    private var isInContact = false
    private var troughHeightMetres: Float?
    private var previousHeightMetres: Float?
    private var lastCompressionTimestamp: Double?

    init(
        targets: HandTrackingTargets,
        configuration: FingerContactCompressionConfiguration = .practiceDefault
    ) {
        self.targets = targets
        self.configuration = configuration
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
    }

    private mutating func endContactTracking() {
        isInContact = false
        troughHeightMetres = nil
        previousHeightMetres = nil
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
            if height >= trough + configuration.releaseHysteresisMetres {
                isInContact = false
                troughHeightMetres = nil
            }
            return []
        }

        guard let previousHeight = previousHeightMetres,
              height < previousHeight,
              height <= configuration.entryToleranceMetres
        else { return [] }
        isInContact = true
        troughHeightMetres = height

        if let lastCompressionTimestamp,
           timestampSeconds - lastCompressionTimestamp <
            configuration.minimumCompressionIntervalSeconds {
            return []
        }
        lastCompressionTimestamp = timestampSeconds

        return [
            FingerContactCompression(
                timestampSeconds: timestampSeconds,
                placement: geometry.placement,
                handStacking: handStackingHeuristic(),
                contactWorldPosition: contactNode
            )
        ]
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
