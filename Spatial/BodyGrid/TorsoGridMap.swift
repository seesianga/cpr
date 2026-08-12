import Foundation
import simd

/// Named anatomical practice regions on the torso grid.
///
/// Regions are placement/interaction zones only. They carry no compression depth, force,
/// or recoil semantics and are never presented as physical measurements.
enum TorsoRegionID: String, Codable, CaseIterable, Hashable, Sendable {
    /// Upper chest on the patient's anatomical right, below the right clavicle.
    case padSiteRightClavicle
    /// The patient's left lower lateral chest.
    case padSiteLeftLateral
    /// Lower half of the sternum, centre chest.
    case sternumCompressionSite
    /// Immediately caudal to the compression site.
    case xiphoidAvoidZone
}

/// Optional authored landmark entities a body asset can provide to override the
/// proportional region defaults.
enum TorsoLandmark: String, Codable, CaseIterable, Hashable, Sendable {
    case sternum = "landmark_sternum"
    case xiphoid = "landmark_xiphoid"
    case rightClavicle = "landmark_right_clavicle"
    case leftLowerRibs = "landmark_left_lower_ribs"

    var regionID: TorsoRegionID {
        switch self {
        case .sternum: .sternumCompressionSite
        case .xiphoid: .xiphoidAvoidZone
        case .rightClavicle: .padSiteRightClavicle
        case .leftLowerRibs: .padSiteLeftLateral
        }
    }
}

/// A local body axis named by an asset descriptor. The grid never assumes an axis
/// convention; the descriptor declares it per asset.
enum BodyGridAxis: String, Codable, Hashable, Sendable {
    case positiveX, negativeX, positiveY, negativeY, positiveZ, negativeZ

    var localDirection: SIMD3<Float> {
        switch self {
        case .positiveX: SIMD3(1, 0, 0)
        case .negativeX: SIMD3(-1, 0, 0)
        case .positiveY: SIMD3(0, 1, 0)
        case .negativeY: SIMD3(0, -1, 0)
        case .positiveZ: SIMD3(0, 0, 1)
        case .negativeZ: SIMD3(0, 0, -1)
        }
    }

    var boundsComponentIndex: Int {
        switch self {
        case .positiveX, .negativeX: 0
        case .positiveY, .negativeY: 1
        case .positiveZ, .negativeZ: 2
        }
    }
}

/// A region footprint on the torso's frontal plane, in normalized coordinates.
///
/// u ∈ [0, 1] runs from the patient's anatomical RIGHT edge (u = 0) to the patient's
/// anatomical LEFT edge (u = 1). v ∈ [0, 1] runs from the cranial end (v = 0) toward
/// the feet (v = 1). No absolute metres appear in region definitions, so any body
/// scale produces identical normalized placement.
struct NormalizedRegionRect: Codable, Equatable, Sendable {
    var centerU: Double
    var centerV: Double
    let width: Double
    let height: Double

    var isValid: Bool {
        [centerU, centerV, width, height].allSatisfy(\.isFinite) &&
            width > 0 && width <= 1 &&
            height > 0 && height <= 1
    }

    func contains(u: Double, v: Double) -> Bool {
        abs(u - centerU) <= width / 2 && abs(v - centerV) <= height / 2
    }

    /// Distance from the region centre in region-normalized units: 1.0 lies on the
    /// region boundary ellipse, 0 at the centre. Scale independent by construction.
    func normalizedError(u: Double, v: Double) -> Double {
        let du = (u - centerU) / (width / 2)
        let dv = (v - centerV) / (height / 2)
        return (du * du + dv * dv).squareRoot()
    }

    /// Frontal-plane distance from the rect (0 when inside), in normalized u/v units.
    func outsideDistance(u: Double, v: Double) -> Double {
        let du = max(0, abs(u - centerU) - width / 2)
        let dv = max(0, abs(v - centerV) - height / 2)
        return (du * du + dv * dv).squareRoot()
    }

    func clampedInside(u: Double, v: Double) -> (u: Double, v: Double) {
        (
            min(max(u, centerU - width / 2), centerU + width / 2),
            min(max(v, centerV - height / 2), centerV + height / 2)
        )
    }
}

/// Declares the grid tiling, the asset's anatomical axis convention, and the named
/// region assignments in normalized coordinates. Codable so a swapped-in asset can
/// ship its own override next to its USDZ.
struct BodyGridDescriptor: Codable, Equatable, Sendable {
    let columns: Int
    let rows: Int
    /// Local body-asset axis pointing toward the patient's anatomical LEFT.
    let lateralAxisTowardPatientLeft: BodyGridAxis
    /// Local body-asset axis pointing from the head toward the FEET.
    let longitudinalAxisTowardFeet: BodyGridAxis
    /// Local body-asset axis pointing out of the chest (anterior).
    let anteriorAxis: BodyGridAxis
    let regions: [TorsoRegionID: NormalizedRegionRect]
    let sourceReferences: [SourceReference]

    var isValid: Bool {
        columns > 0 && rows > 0 &&
            Set([
                lateralAxisTowardPatientLeft.boundsComponentIndex,
                longitudinalAxisTowardFeet.boundsComponentIndex,
                anteriorAxis.boundsComponentIndex
            ]).count == 3 &&
            TorsoRegionID.allCases.allSatisfy { regions[$0]?.isValid == true } &&
            !sourceReferences.isEmpty
    }

    /// Proportional defaults for the placeholder training manikin
    /// (authored supine, head toward -Z, anatomical right -X, up +Y).
    ///
    /// The cited guidance establishes WHERE compressions and pads belong (lower half of
    /// sternum; right pad below the right clavicle; left pad on the lower left lateral
    /// chest). Translating that prose into normalized rectangles is interpretive, so the
    /// references are marked `requires_sme_review` until a qualified reviewer confirms
    /// the mapping.
    static let placeholderDefault = BodyGridDescriptor(
        columns: 8,
        rows: 10,
        lateralAxisTowardPatientLeft: .positiveX,
        longitudinalAxisTowardFeet: .positiveZ,
        anteriorAxis: .positiveY,
        regions: [
            .sternumCompressionSite: NormalizedRegionRect(
                centerU: 0.5, centerV: 0.632, width: 0.26, height: 0.28
            ),
            .xiphoidAvoidZone: NormalizedRegionRect(
                centerU: 0.5, centerV: 0.87, width: 0.18, height: 0.20
            ),
            .padSiteRightClavicle: NormalizedRegionRect(
                centerU: 0.185, centerV: 0.264, width: 0.26, height: 0.21
            ),
            .padSiteLeftLateral: NormalizedRegionRect(
                centerU: 0.91, centerV: 0.68, width: 0.18, height: 0.21
            )
        ],
        sourceReferences: [
            SourceReference(
                id: "grid-region-compression-site-v1",
                document: "CA-Manual-REV-1-2022.pdf",
                edition: "2022",
                section: "2.2 (C) Chest Compressions",
                page: "20",
                reviewStatus: "requires_sme_review",
                reviewer: nil,
                lastClinicalReviewDate: nil,
                contentVersion: "1.0.0",
                clinicalFactID: "fact.compression.site"
            ),
            SourceReference(
                id: "grid-region-pad-placement-v1",
                document: "CA-Manual-REV-1-2022.pdf",
                edition: "2022",
                section: "3.4 Placement of AED Electrode Pads",
                page: "34",
                reviewStatus: "requires_sme_review",
                reviewer: nil,
                lastClinicalReviewDate: nil,
                contentVersion: "1.0.0",
                clinicalFactID: "fact.aed.padPlacementAdult"
            )
        ]
    )
}

/// The outcome of releasing a grabbed pad over the torso.
struct TorsoGridSnapResolution: Equatable, Sendable {
    let regionID: TorsoRegionID
    /// Distance from the region centre in region-normalized units (never metres).
    let normalizedError: Double
    /// Where the pad should visually rest: on the anterior surface, clamped into the region.
    let worldSnapPosition: SIMD3<Float>
}

/// A scale-invariant map from world space onto the torso's normalized frontal plane.
///
/// Built once at scene load from the body asset's torso bounds. Every region lookup is
/// pure value math; the map retains no entities. Because regions are normalized, two
/// bodies of different physical size yield identical region placement.
struct TorsoGridMap: Equatable, Sendable {
    let descriptor: BodyGridDescriptor
    /// Resolved region rects after any landmark overrides.
    let regions: [TorsoRegionID: NormalizedRegionRect]

    private let originWorld: SIMD3<Float>
    private let lateralUnitWorld: SIMD3<Float>
    private let longitudinalUnitWorld: SIMD3<Float>
    private let anteriorUnitWorld: SIMD3<Float>
    /// Half sizes in metres along (lateral, longitudinal, anterior).
    private let halfSizeMetres: SIMD3<Float>

    /// Derives the map from the torso's world transform and its local visual bounds.
    /// Landmark world positions, when the asset provides them, override the proportional
    /// region centres (the right-clavicle landmark shifts its pad region caudally by half
    /// the region height so the region sits below the clavicle, not on it).
    init?(
        descriptor: BodyGridDescriptor,
        worldFromTorsoTransform: simd_float4x4,
        localBoundsCenter: SIMD3<Float>,
        localBoundsExtents: SIMD3<Float>,
        landmarkWorldPositions: [TorsoLandmark: SIMD3<Float>] = [:]
    ) {
        guard descriptor.isValid,
              localBoundsCenter.allFinite,
              localBoundsExtents.allFinite,
              localBoundsExtents.x > 0,
              localBoundsExtents.y > 0,
              localBoundsExtents.z > 0
        else { return nil }
        let determinant = simd_determinant(worldFromTorsoTransform)
        guard determinant.isFinite, abs(determinant) > Float.ulpOfOne else { return nil }

        func worldAxis(_ axis: BodyGridAxis) -> (unit: SIMD3<Float>, halfMetres: Float)? {
            let local4 = SIMD4<Float>(axis.localDirection, 0)
            let world4 = worldFromTorsoTransform * local4
            let world = SIMD3<Float>(world4.x, world4.y, world4.z)
            let length = simd_length(world)
            guard world.allFinite, length > Float.ulpOfOne else { return nil }
            let extent = localBoundsExtents[axis.boundsComponentIndex]
            return (world / length, length * extent / 2)
        }

        guard let lateral = worldAxis(descriptor.lateralAxisTowardPatientLeft),
              let longitudinal = worldAxis(descriptor.longitudinalAxisTowardFeet),
              let anterior = worldAxis(descriptor.anteriorAxis)
        else { return nil }

        let center4 = worldFromTorsoTransform * SIMD4<Float>(localBoundsCenter, 1)
        let origin = SIMD3<Float>(center4.x, center4.y, center4.z)
        guard origin.allFinite else { return nil }

        self.descriptor = descriptor
        originWorld = origin
        lateralUnitWorld = lateral.unit
        longitudinalUnitWorld = longitudinal.unit
        anteriorUnitWorld = anterior.unit
        halfSizeMetres = SIMD3(lateral.halfMetres, longitudinal.halfMetres, anterior.halfMetres)

        var resolvedRegions = descriptor.regions
        for (landmark, worldPosition) in landmarkWorldPositions {
            guard worldPosition.allFinite,
                  var rect = resolvedRegions[landmark.regionID]
            else { continue }
            let delta = worldPosition - origin
            let u = Double(simd_dot(delta, lateral.unit) / (2 * lateral.halfMetres)) + 0.5
            var v = Double(simd_dot(delta, longitudinal.unit) / (2 * longitudinal.halfMetres)) + 0.5
            if landmark == .rightClavicle {
                v += rect.height / 2
            }
            rect.centerU = min(max(u, rect.width / 2), 1 - rect.width / 2)
            rect.centerV = min(max(v, rect.height / 2), 1 - rect.height / 2)
            resolvedRegions[landmark.regionID] = rect
        }
        regions = resolvedRegions
    }

    /// (u, v, w): u lateral toward patient-left, v cranial→caudal, w posterior→anterior.
    /// All three are 0...1 inside the torso bounds.
    func normalizedPoint(fromWorld worldPosition: SIMD3<Float>) -> SIMD3<Float>? {
        guard worldPosition.allFinite else { return nil }
        let delta = worldPosition - originWorld
        return SIMD3(
            simd_dot(delta, lateralUnitWorld) / (2 * halfSizeMetres.x) + 0.5,
            simd_dot(delta, longitudinalUnitWorld) / (2 * halfSizeMetres.y) + 0.5,
            simd_dot(delta, anteriorUnitWorld) / (2 * halfSizeMetres.z) + 0.5
        )
    }

    /// Signed height above the torso's anterior surface, in metres (negative = inside).
    func heightAboveAnteriorSurfaceMetres(ofWorld worldPosition: SIMD3<Float>) -> Float? {
        guard let normalized = normalizedPoint(fromWorld: worldPosition) else { return nil }
        return (normalized.z - 1) * 2 * halfSizeMetres.z
    }

    func worldPoint(fromNormalized normalized: SIMD3<Float>) -> SIMD3<Float> {
        originWorld +
            lateralUnitWorld * ((normalized.x - 0.5) * 2 * halfSizeMetres.x) +
            longitudinalUnitWorld * ((normalized.y - 0.5) * 2 * halfSizeMetres.y) +
            anteriorUnitWorld * ((normalized.z - 0.5) * 2 * halfSizeMetres.z)
    }

    /// Frontal-plane region containment. The safety-critical avoid zone wins boundary
    /// overlaps, then the compression site, then the pad sites (deterministic order).
    func region(containingWorld worldPosition: SIMD3<Float>) -> TorsoRegionID? {
        guard let normalized = normalizedPoint(fromWorld: worldPosition) else { return nil }
        let u = Double(normalized.x)
        let v = Double(normalized.y)
        let priorityOrder: [TorsoRegionID] = [
            .xiphoidAvoidZone, .sternumCompressionSite,
            .padSiteRightClavicle, .padSiteLeftLateral
        ]
        return priorityOrder.first { regions[$0]?.contains(u: u, v: v) == true }
    }

    /// Bridges a named region to the existing target-volume math. The volume is a thin
    /// box whose top face lies on the torso's anterior surface, expressed in metres so
    /// detector margins keep their physical meaning.
    func worldVolume(for regionID: TorsoRegionID) -> HandTrackingTargetVolume? {
        guard let rect = regions[regionID] else { return nil }
        let thicknessMetres = max(0.024, halfSizeMetres.z * 0.3)
        let centerNormalized = SIMD3<Float>(Float(rect.centerU), Float(rect.centerV), 1)
        let surfaceCenter = worldPoint(fromNormalized: centerNormalized)
        let volumeCenter = surfaceCenter - anteriorUnitWorld * (thicknessMetres / 2)

        // Target-volume convention: local X lateral, Y up (anterior), Z longitudinal.
        let worldFromTarget = simd_float4x4(columns: (
            SIMD4<Float>(lateralUnitWorld, 0),
            SIMD4<Float>(anteriorUnitWorld, 0),
            SIMD4<Float>(longitudinalUnitWorld, 0),
            SIMD4<Float>(volumeCenter, 1)
        ))
        return HandTrackingTargetVolume(
            worldFromTargetTransform: worldFromTarget,
            localCenter: .zero,
            localExtents: SIMD3(
                Float(rect.width) * 2 * halfSizeMetres.x,
                thicknessMetres,
                Float(rect.height) * 2 * halfSizeMetres.y
            )
        )
    }

    /// The region's centre on the anterior surface, in world space.
    ///
    /// This is where a pad SEATS when released in its own section: the same normalized
    /// rect centre `worldVolume(for:)` builds its detection volume around, projected
    /// onto the torso surface, so the seated visual and the detection region can never
    /// disagree about where the section is.
    func worldSurfaceCenter(of regionID: TorsoRegionID) -> SIMD3<Float>? {
        guard let rect = regions[regionID] else { return nil }
        return worldPoint(
            fromNormalized: SIMD3(Float(rect.centerU), Float(rect.centerV), 1)
        )
    }

    /// Debug/overlay support: the anterior-surface frame (local X lateral toward
    /// patient-left, Y anterior, Z longitudinal toward feet), centred on the chest.
    var anteriorSurfaceWorldTransform: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(lateralUnitWorld, 0),
            SIMD4<Float>(anteriorUnitWorld, 0),
            SIMD4<Float>(longitudinalUnitWorld, 0),
            SIMD4<Float>(worldPoint(fromNormalized: SIMD3(0.5, 0.5, 1)), 1)
        ))
    }

    /// Full frontal-plane size in metres: (lateral width, longitudinal length).
    var frontalPlaneSizeMetres: SIMD2<Float> {
        SIMD2(halfSizeMetres.x * 2, halfSizeMetres.y * 2)
    }

    /// Snaps a release point to the nearest region when it lands inside the region or
    /// within `frontalSnapToleranceNormalized` of its boundary (an interaction allowance,
    /// not a clinical distance). Returns nil when the release is too far from any region.
    func snapResolution(
        forWorld worldPosition: SIMD3<Float>,
        frontalSnapToleranceNormalized: Double = 0.08
    ) -> TorsoGridSnapResolution? {
        guard let normalized = normalizedPoint(fromWorld: worldPosition),
              frontalSnapToleranceNormalized.isFinite,
              frontalSnapToleranceNormalized >= 0
        else { return nil }
        let u = Double(normalized.x)
        let v = Double(normalized.y)

        var candidates: [(regionID: TorsoRegionID, distance: Double)] = regions.map {
            (regionID: $0.key, distance: $0.value.outsideDistance(u: u, v: v))
        }
        candidates.sort { lhs, rhs in
            lhs.distance == rhs.distance
                ? lhs.regionID.rawValue < rhs.regionID.rawValue
                : lhs.distance < rhs.distance
        }
        guard let candidate = candidates.first,
              candidate.distance <= frontalSnapToleranceNormalized,
              let rect = regions[candidate.regionID]
        else { return nil }

        let clamped = rect.clampedInside(u: u, v: v)
        return TorsoGridSnapResolution(
            regionID: candidate.regionID,
            normalizedError: rect.normalizedError(u: clamped.u, v: clamped.v),
            worldSnapPosition: worldPoint(
                fromNormalized: SIMD3(Float(clamped.u), Float(clamped.v), 1)
            )
        )
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
