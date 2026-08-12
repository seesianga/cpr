import Foundation
import simd

/// Anatomical basis of a supine body, expressed as unit directions in a shared frame.
///
/// The manikin declares its convention through `BodyGridDescriptor`; an imported mesh
/// declares nothing, so its basis is *solved* rather than assumed. Everything downstream
/// works in these three named directions instead of raw X/Y/Z, which is what lets a body
/// authored in any axis convention register onto the manikin without hand-tuned Euler
/// angles.
struct TorsoAnatomicalFrame: Equatable, Sendable {
    /// Toward the patient's anatomical LEFT.
    let lateral: SIMD3<Float>
    /// From the head toward the FEET.
    let longitudinal: SIMD3<Float>
    /// Out of the chest (anterior).
    let anterior: SIMD3<Float>

    init(lateral: SIMD3<Float>, longitudinal: SIMD3<Float>, anterior: SIMD3<Float>) {
        self.lateral = lateral
        self.longitudinal = longitudinal
        self.anterior = anterior
    }

    /// The frame an asset descriptor declares, in the body asset's own local space.
    init(descriptor: BodyGridDescriptor) {
        self.init(
            lateral: descriptor.lateralAxisTowardPatientLeft.localDirection,
            longitudinal: descriptor.longitudinalAxisTowardFeet.localDirection,
            anterior: descriptor.anteriorAxis.localDirection
        )
    }

    /// Anatomical (lateral, longitudinal, anterior) components of a direction.
    func components(of vector: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            simd_dot(vector, lateral),
            simd_dot(vector, longitudinal),
            simd_dot(vector, anterior)
        )
    }

    /// Extent of an axis-aligned box along each anatomical direction.
    ///
    /// The magnitude goes on the axis rather than the extents: an AABB's width along an
    /// arbitrary direction is the sum of its extents projected onto that direction's
    /// component magnitudes.
    func extents(ofAxisAlignedExtents extents: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(
            simd_dot(simd_abs(lateral), extents),
            simd_dot(simd_abs(longitudinal), extents),
            simd_dot(simd_abs(anterior), extents)
        )
    }

    func rotated(by rotation: simd_float3x3) -> TorsoAnatomicalFrame {
        TorsoAnatomicalFrame(
            lateral: rotation * lateral,
            longitudinal: rotation * longitudinal,
            anterior: rotation * anterior
        )
    }
}

/// What the authored manikin provides: the target the imported body must register onto.
///
/// Measured from the scene every time, never hardcoded — swapping the manikin asset for a
/// differently sized one moves the reference with it.
struct TorsoAlignmentReference: Equatable, Sendable {
    let frame: TorsoAnatomicalFrame
    /// Centre of the manikin's torso, in the host entity's space.
    let torsoCenter: SIMD3<Float>
    /// Torso size along (lateral, longitudinal, anterior), in metres.
    let anatomicalExtents: SIMD3<Float>
    /// The sternum compression site — the anatomical point both bodies share, and the
    /// point registration actually solves for.
    let registrationPoint: SIMD3<Float>?
    /// The manikin's full physical envelope (torso + head + upper limbs). Body geometry
    /// outside this box has no physical counterpart to overlay, so it is cropped away.
    let physicalEnvelopeCenter: SIMD3<Float>
    let physicalEnvelopeExtents: SIMD3<Float>

    var chestWidthMetres: Float { anatomicalExtents.x }
    var chestLengthMetres: Float { anatomicalExtents.y }

    var isUsable: Bool {
        torsoCenter.allComponentsFinite &&
            anatomicalExtents.allComponentsFinite &&
            anatomicalExtents.x > 1e-4 &&
            anatomicalExtents.y > 1e-4 &&
            anatomicalExtents.z > 1e-4
    }
}

/// What the imported mesh provides, measured **unrotated and unscaled** in the host's
/// space. Every candidate orientation is evaluated analytically from these numbers, so the
/// mesh is measured once rather than 24 times.
struct TorsoAlignmentSubject: Equatable, Sendable {
    /// Bounds of the part of the import that stands in for the torso. When the export
    /// separates a torso garment this is that garment; otherwise it is the whole body,
    /// and the solver's shape term absorbs the difference.
    let torsoCenter: SIMD3<Float>
    let torsoExtents: SIMD3<Float>
    /// The import's own sternum site, when the export author marked one.
    let registrationPoint: SIMD3<Float>?
    /// Whole-import bounds, used to report how much geometry the crop removes.
    let fullCenter: SIMD3<Float>
    let fullExtents: SIMD3<Float>

    var isUsable: Bool {
        torsoCenter.allComponentsFinite &&
            torsoExtents.allComponentsFinite &&
            torsoExtents.min() > 1e-5
    }
}

/// Registration residual, in the units a human can argue about: centimetres and degrees.
///
/// Measured from the live scene after alignment, not predicted from the solve, so it
/// reflects transform-hierarchy and clamping effects rather than just restating the
/// solver's intent.
struct TorsoAlignmentAccuracy: Equatable, Sendable {
    /// Distance between the import's sternum site and the manikin's, in centimetres.
    let registrationOffsetCentimetres: Float
    /// Angle between the two bodies' head→feet axes.
    let longitudinalErrorDegrees: Float
    /// Angle between the two bodies' anterior (out-of-chest) axes.
    let anteriorErrorDegrees: Float
    /// Chest width mismatch after uniform scaling, in centimetres.
    let chestWidthErrorCentimetres: Float
    /// Chest length mismatch after uniform scaling, in centimetres.
    let chestLengthErrorCentimetres: Float

    /// Interaction tolerances, not clinical ones. They bound when the overlay reads as
    /// "sitting on the manikin", nothing more.
    static let offsetToleranceCentimetres: Float = 2
    static let rotationToleranceDegrees: Float = 6
    static let sizeToleranceCentimetres: Float = 4

    /// Whether the overlay is registered: landmark on landmark, axes aligned, chest the
    /// right width.
    ///
    /// Length is measured and shown but deliberately not part of the gate. A uniform
    /// scale can satisfy exactly one dimension, and width is the one chosen — it is what
    /// the learner sees against the manikin's silhouette and what the lateral pad geometry
    /// is referenced against. The remaining length difference is the real proportional gap
    /// between a human torso and a rectangular trainer, not a registration error, and the
    /// only way to null it would be a non-uniform scale that visibly distorts the body.
    var isAligned: Bool {
        registrationOffsetCentimetres <= Self.offsetToleranceCentimetres &&
            longitudinalErrorDegrees <= Self.rotationToleranceDegrees &&
            anteriorErrorDegrees <= Self.rotationToleranceDegrees &&
            abs(chestWidthErrorCentimetres) <= Self.sizeToleranceCentimetres
    }

    /// The worst rotation axis, which is the one worth reporting in a single line.
    var rotationErrorDegrees: Float {
        max(longitudinalErrorDegrees, anteriorErrorDegrees)
    }

    var summary: String {
        String(
            format: "%.1f cm  ·  %.1f°  ·  width %+.1f cm  ·  length %+.1f cm",
            registrationOffsetCentimetres,
            rotationErrorDegrees,
            chestWidthErrorCentimetres,
            chestLengthErrorCentimetres
        )
    }
}

/// Before/after pair for one alignment run. The "before" figure is the demonstrable one:
/// it is how far off the overlay was under the previous placement.
struct TorsoAlignmentReport: Equatable, Sendable {
    let before: TorsoAlignmentAccuracy
    let after: TorsoAlignmentAccuracy

    var improvedOffsetCentimetres: Float {
        before.registrationOffsetCentimetres - after.registrationOffsetCentimetres
    }

    var improvedRotationDegrees: Float {
        before.rotationErrorDegrees - after.rotationErrorDegrees
    }

    var demoLine: String {
        String(
            format: "Alignment %.1f cm / %.0f° → %.1f cm / %.0f°",
            before.registrationOffsetCentimetres,
            before.rotationErrorDegrees,
            after.registrationOffsetCentimetres,
            after.rotationErrorDegrees
        )
    }
}

/// Rotation, uniform scale and offset that register an import onto the manikin.
struct TorsoAlignmentSolution: Equatable, Sendable {
    let rotation: simd_float3x3
    let scale: Float
    let offsetMetres: SIMD3<Float>
    /// Where the import's own chest, head-to-feet and left axes lie **in its local space**
    /// — the solver's estimate of the export's anatomical convention.
    ///
    /// Retained because it is what makes later accuracy measurement possible: rotate this
    /// by whatever orientation the entity actually carries and compare against the
    /// manikin's frame, and a manual nudge in the headset reads out in degrees.
    let subjectLocalFrame: TorsoAnatomicalFrame
    /// How well the rotated aspect ratio matched; lower is better. Retained so a poor
    /// best-of-24 can be reported rather than silently accepted.
    let shapeResidual: Float
}

/// Registers an imported body mesh onto the authored manikin.
///
/// The problem the solver exists for: a Reality Composer Pro export arrives in whatever
/// axis convention, origin and unit scale its author used, and none of that is inspectable
/// from a compiled `.reality` archive. Fitting the whole import into the manikin's
/// bounding box — the previous behaviour — compounds two errors, because the box included
/// the head and arms and the import included legs, so the tightest-axis scale shrank the
/// body and the box centre put its hips where its chest belonged.
///
/// This solves the registration properly instead: pick the orientation that makes the
/// import's proportions and sternum landmark agree with the manikin's, scale by the ratio
/// of measured chest widths, then translate so the two sternum sites coincide.
enum TorsoAlignmentSolver {
    /// The 24 orientation-preserving rotations of a cube.
    ///
    /// An export's convention differs from the manikin's by one of these and nothing
    /// finer, so the search is exact rather than an optimisation with a tolerance.
    static let axisAlignedRotations: [simd_float3x3] = {
        let axes: [SIMD3<Float>] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        var rotations: [simd_float3x3] = []
        for firstAxis in 0..<3 {
            for firstSign in [Float(1), -1] {
                let column0 = axes[firstAxis] * firstSign
                for secondAxis in 0..<3 where secondAxis != firstAxis {
                    for secondSign in [Float(1), -1] {
                        let column1 = axes[secondAxis] * secondSign
                        rotations.append(
                            simd_float3x3(columns: (
                                column0,
                                column1,
                                simd_cross(column0, column1)
                            ))
                        )
                    }
                }
            }
        }
        return rotations
    }()

    /// Landmark agreement is weighted above aspect-ratio agreement: a body is roughly
    /// front/back symmetric in silhouette, so proportions alone cannot tell face-up from
    /// face-down. The sternum landmark can, and getting that wrong buries the compression
    /// site inside the mesh.
    private static let landmarkWeight: Float = 3

    static func solve(
        reference: TorsoAlignmentReference,
        subject: TorsoAlignmentSubject
    ) -> TorsoAlignmentSolution? {
        guard reference.isUsable, subject.isUsable else { return nil }

        var best: (solution: TorsoAlignmentSolution, cost: Float)?
        for rotation in axisAlignedRotations {
            guard let candidate = evaluate(
                rotation: rotation,
                reference: reference,
                subject: subject
            ) else { continue }
            if best == nil || candidate.cost < best!.cost - 1e-6 {
                best = candidate
            }
        }
        return best?.solution
    }

    private static func evaluate(
        rotation: simd_float3x3,
        reference: TorsoAlignmentReference,
        subject: TorsoAlignmentSubject
    ) -> (solution: TorsoAlignmentSolution, cost: Float)? {
        // Rotating an axis-aligned box by an axis-aligned rotation permutes and negates
        // its axes, so the rotated extents are exact rather than a conservative bound.
        let rotatedExtents = rotatedExtents(subject.torsoExtents, by: rotation)
        let rotatedCenter = rotation * subject.torsoCenter
        let subjectAnatomicalExtents = reference.frame.extents(
            ofAxisAlignedExtents: rotatedExtents
        )
        guard subjectAnatomicalExtents.min() > 1e-5 else { return nil }

        let scale = reference.chestWidthMetres / subjectAnatomicalExtents.x
        guard scale.isFinite, scale > 0 else { return nil }

        // Log-ratio so a 2× overshoot and a 2× undershoot cost the same.
        var shapeResidual: Float = 0
        for axis in 0..<3 {
            let scaled = subjectAnatomicalExtents[axis] * scale
            let target = reference.anatomicalExtents[axis]
            guard scaled > 1e-6, target > 1e-6 else { return nil }
            shapeResidual += abs(log(scaled / target))
        }

        var landmarkResidual: Float = 0
        if let subjectPoint = subject.registrationPoint,
           let referencePoint = reference.registrationPoint {
            let subjectOffset = reference.frame.components(
                of: (rotation * subjectPoint - rotatedCenter) * scale
            )
            let referenceOffset = reference.frame.components(
                of: referencePoint - reference.torsoCenter
            )
            // Normalised by torso size so the term stays comparable across body scales.
            landmarkResidual = simd_length(
                (subjectOffset - referenceOffset) / reference.anatomicalExtents
            )
        }

        let offset: SIMD3<Float>
        if let subjectPoint = subject.registrationPoint,
           let referencePoint = reference.registrationPoint {
            offset = referencePoint - (rotation * subjectPoint) * scale
        } else {
            offset = reference.torsoCenter - rotatedCenter * scale
        }
        guard offset.allComponentsFinite else { return nil }

        let solution = TorsoAlignmentSolution(
            rotation: rotation,
            scale: scale,
            offsetMetres: offset,
            // R maps subject-local into host space and, by construction, onto the
            // reference frame — so the subject's own convention is Rᵀ applied to it.
            subjectLocalFrame: reference.frame.rotated(by: rotation.transpose),
            shapeResidual: shapeResidual
        )
        return (solution, shapeResidual + landmarkResidual * landmarkWeight)
    }

    /// Residual between two placed bodies, computed from live measurements.
    ///
    /// `measuredFrame` is where the import's anatomical axes actually ended up; the
    /// caller obtains it by rotating the solved frame by the entity's live orientation, so
    /// a manual nudge in the headset shows up here as degrees.
    static func accuracy(
        reference: TorsoAlignmentReference,
        measuredRegistrationPoint: SIMD3<Float>?,
        measuredFrame: TorsoAnatomicalFrame,
        measuredChestWidthMetres: Float,
        measuredChestLengthMetres: Float
    ) -> TorsoAlignmentAccuracy {
        let offsetCentimetres: Float
        if let measuredRegistrationPoint,
           let referencePoint = reference.registrationPoint,
           measuredRegistrationPoint.allComponentsFinite {
            offsetCentimetres = simd_distance(measuredRegistrationPoint, referencePoint) * 100
        } else {
            offsetCentimetres = .infinity
        }

        return TorsoAlignmentAccuracy(
            registrationOffsetCentimetres: offsetCentimetres,
            longitudinalErrorDegrees: angleDegrees(
                reference.frame.longitudinal,
                measuredFrame.longitudinal
            ),
            anteriorErrorDegrees: angleDegrees(
                reference.frame.anterior,
                measuredFrame.anterior
            ),
            chestWidthErrorCentimetres: (measuredChestWidthMetres - reference.chestWidthMetres) * 100,
            chestLengthErrorCentimetres: (measuredChestLengthMetres - reference.chestLengthMetres) * 100
        )
    }

    /// Extents of an axis-aligned box after rotation.
    ///
    /// Exact for the axis-aligned rotations the solver searches; a tight conservative
    /// bound for the arbitrary orientations a manual nudge can produce.
    static func rotatedExtents(
        _ extents: SIMD3<Float>,
        by rotation: simd_float3x3
    ) -> SIMD3<Float> {
        componentMagnitudes(of: rotation) * extents
    }

    static func angleDegrees(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        let lhsLength = simd_length(lhs)
        let rhsLength = simd_length(rhs)
        guard lhsLength > 1e-6, rhsLength > 1e-6 else { return .infinity }
        let cosine = min(max(simd_dot(lhs, rhs) / (lhsLength * rhsLength), -1), 1)
        return acos(cosine) * 180 / .pi
    }
}

/// Sizes a prop as a fraction of the body it is used on.
///
/// The AED was authored at a fixed scale against a placeholder torso. Once the body's size
/// is derived from the manikin, a fixed prop scale is a bug waiting for the first
/// differently sized manikin, so the prop is expressed as a ratio of measured chest width
/// instead.
enum ProportionalPropSizing {
    /// An adult AED sits at roughly a quarter to a third of chest width across its face,
    /// which puts the anatomically faithful band at 0.25–0.30. Shipped at HALF that
    /// midpoint: at 0.28 the operator judged the unit twice too large against the physical
    /// demo scene (2026-08-10), where it competes with a real table and a real manikin
    /// rather than sitting alone in a virtual room. Still a fraction, not a fixed size, so
    /// it keeps tracking the measured chest.
    static let aedWidthAsFractionOfChestWidth: Float = 0.14

    static let minimumScale: Float = 0.05
    static let maximumScale: Float = 20

    /// Uniform scale that brings `measuredPropWidthMetres` to the target fraction of
    /// `chestWidthMetres`. Returns nil rather than a guess when either measurement is
    /// unusable, so the caller keeps the authored scale.
    static func scale(
        chestWidthMetres: Float,
        measuredPropWidthMetres: Float,
        fraction: Float = aedWidthAsFractionOfChestWidth
    ) -> Float? {
        guard chestWidthMetres.isFinite, chestWidthMetres > 1e-4,
              measuredPropWidthMetres.isFinite, measuredPropWidthMetres > 1e-5,
              fraction.isFinite, fraction > 0
        else { return nil }
        let scale = (chestWidthMetres * fraction) / measuredPropWidthMetres
        guard scale.isFinite, scale >= minimumScale, scale <= maximumScale else {
            return nil
        }
        return scale
    }
}

extension SIMD3 where Scalar == Float {
    var allComponentsFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}

/// Component-wise magnitude of a rotation matrix, used to rotate box extents exactly.
private func componentMagnitudes(of matrix: simd_float3x3) -> simd_float3x3 {
    simd_float3x3(columns: (
        simd_abs(matrix.columns.0),
        simd_abs(matrix.columns.1),
        simd_abs(matrix.columns.2)
    ))
}
