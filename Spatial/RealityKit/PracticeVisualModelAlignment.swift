import Foundation
import RealityKit
import simd

/// Measures the authored manikin and the imported body in one shared frame, then registers
/// one onto the other.
///
/// Everything here is measurement plus `TorsoAlignmentSolver`; no dimension is written in
/// source. Swap `TrainingManikin.usda` for a larger torso and the overlay follows it,
/// because the numbers come out of `visualBounds` at load time.
@MainActor
enum PracticeVisualModelAlignment {

    /// A pair of entities that mean the same anatomy on each body.
    ///
    /// Scale is only trustworthy when both sides of the ratio measure the same thing, so
    /// the import's chest is never compared against the manikin's whole figure. Ordered
    /// best-first; the first pair that resolves on both bodies wins.
    struct SemanticProxyPair {
        let subjectEntityName: String
        let referenceEntityNames: [String]
    }

    static let humanTorsoProxies: [SemanticProxyPair] = [
        // The torso garment is the closest thing the export has to a chest.
        .init(subjectEntityName: "human_visual_clothing_top", referenceEntityNames: ["torso_shell"]),
        // The author's pad guide spans right clavicle to left lateral chest, which is very
        // nearly the manikin's pad-zone span — the same anatomy on both sides.
        .init(
            subjectEntityName: "human_visual_aed_guide",
            referenceEntityNames: ["aed_right_pad_zone", "aed_left_pad_zone"]
        ),
        // Last resort. A whole-body span against a torso box is a known over-estimate, so
        // the residual is reported rather than hidden and stays nudgeable in the headset.
        .init(subjectEntityName: "human_visual_model", referenceEntityNames: ["torso_shell"])
    ]

    /// The manikin's physical extent. Imported geometry outside this box overlays nothing
    /// real, so it is what the crop measures against.
    static let physicalEnvelopeEntityNames = ["torso_shell", "head", "right_arm", "left_arm"]

    /// Anatomical registration landmarks, best-first. Transform-only landmarks are
    /// preferred over the visible zone markers: they carry no geometry, so hiding a marker
    /// can never move one.
    static let manikinRegistrationEntityNames = ["landmark_sternum", "sternum_target"]
    static let humanRegistrationEntityNames = ["human_visual_sternum_site", "human_visual_cpr_guide"]

    // MARK: - Reference

    /// The best manikin measurement available in this scene: the first proxy pair that
    /// resolves on both bodies, in declared preference order.
    static func bestReference(
        in scene: Entity,
        host: Entity,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor
    ) -> TorsoAlignmentReference? {
        for proxy in humanTorsoProxies {
            if let reference = measureReference(
                in: scene,
                host: host,
                descriptor: descriptor,
                proxy: proxy
            ) {
                return reference
            }
        }
        return nil
    }

    /// Measures the manikin. Returns nil when the scene has no usable torso, in which case
    /// the caller keeps whatever placement it already had.
    static func measureReference(
        in scene: Entity,
        host: Entity,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor,
        proxy: SemanticProxyPair
    ) -> TorsoAlignmentReference? {
        guard let torso = firstEntity(named: descriptor.body.torsoRootEntityName, in: scene)
        else { return nil }

        guard let proxyBounds = unionBounds(
            ofEntitiesNamed: proxy.referenceEntityNames,
            in: scene,
            relativeTo: host
        ) else { return nil }

        let frame = anatomicalFrame(
            of: torso,
            relativeTo: host,
            descriptor: descriptor.gridDescriptor
        )
        let envelope = unionBounds(
            ofEntitiesNamed: physicalEnvelopeEntityNames,
            in: scene,
            relativeTo: host
        ) ?? proxyBounds

        let reference = TorsoAlignmentReference(
            frame: frame,
            torsoCenter: proxyBounds.center,
            anatomicalExtents: frame.extents(ofAxisAlignedExtents: proxyBounds.extents),
            registrationPoint: firstPosition(
                ofEntitiesNamed: manikinRegistrationEntityNames,
                in: scene,
                relativeTo: host
            ),
            physicalEnvelopeCenter: envelope.center,
            physicalEnvelopeExtents: envelope.extents
        )
        return reference.isUsable ? reference : nil
    }

    /// The declared anatomical directions of the torso, expressed in the host's space.
    ///
    /// The descriptor names axes in the torso's own space; the torso may be rotated under
    /// the host, so the axes are pushed through that transform rather than assumed to be
    /// the host's own X/Y/Z.
    static func anatomicalFrame(
        of torso: Entity,
        relativeTo host: Entity,
        descriptor: BodyGridDescriptor
    ) -> TorsoAnatomicalFrame {
        let hostFromTorso = torso.transformMatrix(relativeTo: host)
        func direction(_ axis: BodyGridAxis) -> SIMD3<Float> {
            let local = SIMD4<Float>(axis.localDirection, 0)
            let world = hostFromTorso * local
            let vector = SIMD3<Float>(world.x, world.y, world.z)
            let length = simd_length(vector)
            guard length > 1e-6, vector.allComponentsFinite else {
                return axis.localDirection
            }
            return vector / length
        }
        return TorsoAnatomicalFrame(
            lateral: direction(descriptor.lateralAxisTowardPatientLeft),
            longitudinal: direction(descriptor.longitudinalAxisTowardFeet),
            anterior: direction(descriptor.anteriorAxis)
        )
    }

    // MARK: - Subject

    /// Measures the import with its own transform neutralised, so the numbers describe the
    /// mesh as authored rather than the mesh as currently placed.
    static func measureSubject(
        entity: Entity,
        host: Entity,
        proxy: SemanticProxyPair
    ) -> TorsoAlignmentSubject? {
        let restore = entity.transform
        entity.transform = Transform()
        defer { entity.transform = restore }

        guard let full = boundsIfPresent(of: entity, relativeTo: host) else { return nil }
        // No silent fallback to whole-body bounds. Substituting the full figure whenever a
        // named proxy is missing would make every pair "succeed", so the loop in
        // `solvePlacement` could never fall through to the next one — and a chest scale
        // derived from head-to-toe height is exactly the error that made the body arrive
        // at the wrong size. The last declared pair names the model root, so the honest
        // whole-body case is reached explicitly instead.
        guard let proxyEntity = firstEntity(named: proxy.subjectEntityName, in: entity),
              let torso = boundsIfPresent(of: proxyEntity, relativeTo: host)
        else { return nil }

        let subject = TorsoAlignmentSubject(
            torsoCenter: torso.center,
            torsoExtents: torso.extents,
            registrationPoint: firstPosition(
                ofEntitiesNamed: humanRegistrationEntityNames,
                in: entity,
                relativeTo: host
            ),
            fullCenter: full.center,
            fullExtents: full.extents
        )
        return subject.isUsable ? subject : nil
    }

    // MARK: - Solve

    /// Registers `model` onto the manikin and returns the placement to persist.
    ///
    /// Rotation, scale and offset all come out of the solve; the caller's existing
    /// `hidesPlaceholder` and crop preferences are carried through untouched so a solve
    /// never resets an operator's display choices.
    static func solvePlacement(
        for model: PracticeVisualModel,
        in scene: Entity,
        currentPlacement: PracticeVisualModelPlacement,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor
    ) -> (placement: PracticeVisualModelPlacement, reference: TorsoAlignmentReference)? {
        guard model == .human,
              let host = firstEntity(named: model.hostEntityName, in: scene),
              let entity = firstEntity(named: model.semanticRootName, in: host)
        else { return nil }

        for proxy in humanTorsoProxies {
            guard let reference = measureReference(
                in: scene,
                host: host,
                descriptor: descriptor,
                proxy: proxy
            ),
                let subject = measureSubject(entity: entity, host: host, proxy: proxy),
                let solution = TorsoAlignmentSolver.solve(reference: reference, subject: subject)
            else { continue }

            var placement = currentPlacement
            placement.setOrientation(solution.rotation)
            placement.scale = solution.scale
            placement.offsetMetres = solution.offsetMetres
            return (placement.sanitized, reference)
        }
        return nil
    }

    /// Sizes a prop as a measured fraction of the registered body, rather than at the
    /// authored scale it happened to be exported with.
    static func solvePropPlacement(
        for model: PracticeVisualModel,
        in scene: Entity,
        currentPlacement: PracticeVisualModelPlacement,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor
    ) -> PracticeVisualModelPlacement? {
        guard model == .aed,
              let manikin = firstEntity(named: descriptor.body.figureEntityName, in: scene),
              let host = firstEntity(named: model.hostEntityName, in: scene),
              let entity = firstEntity(named: model.semanticRootName, in: host)
        else { return nil }

        guard let chestWidthMetres = bestReference(
            in: scene,
            host: manikin,
            descriptor: descriptor
        )?.chestWidthMetres else { return nil }

        // Measured rotated but unscaled and unmoved, so the extents describe the prop as
        // it will actually sit rather than as it was exported.
        let previous = currentPlacement.sanitized
        let restore = entity.transform
        entity.transform = Transform(rotation: previous.orientation)
        let measured = boundsIfPresent(of: entity, relativeTo: host)
        // The proportion is defined against the unit's face, so the width comes from the
        // case when the export names one. Whole-model bounds also span the laid-out pads,
        // which nearly doubles the measured width and halves the rendered unit; the
        // whole-model centre is still the right thing to hold still below, because
        // scaling acts on the whole model.
        let sizingBounds = model.sizingProxyEntityName
            .flatMap { firstEntity(named: $0, in: entity) }
            .flatMap { boundsIfPresent(of: $0, relativeTo: host) }
        entity.transform = restore
        guard let measured else { return nil }

        guard let scale = ProportionalPropSizing.scale(
            chestWidthMetres: chestWidthMetres,
            measuredPropWidthMetres: (sizingBounds ?? measured).extents.max()
        ) else { return nil }

        var placement = currentPlacement
        placement.scale = scale
        // Hold the prop's centre still while it resizes. Scaling happens about the export
        // origin, so without this the AED slides off the mount it was fitted to by however
        // far that origin sits from its centre of mass.
        placement.offsetMetres = previous.offsetMetres + measured.center * (previous.scale - scale)
        return placement.sanitized
    }

    // MARK: - Accuracy

    /// Re-measures the live scene after placement.
    ///
    /// Deliberately not derived from the solution: reading the transforms back catches
    /// clamping, hierarchy scale and later manual nudges, none of which the solver knows
    /// about. A number that can only ever say "perfect" is not evidence.
    static func measureAccuracy(
        for model: PracticeVisualModel,
        in scene: Entity,
        placement: PracticeVisualModelPlacement,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor
    ) -> TorsoAlignmentAccuracy? {
        guard model == .human,
              let host = firstEntity(named: model.hostEntityName, in: scene),
              let entity = firstEntity(named: model.semanticRootName, in: host)
        else { return nil }

        for proxy in humanTorsoProxies {
            guard let reference = measureReference(
                in: scene,
                host: host,
                descriptor: descriptor,
                proxy: proxy
            ),
                let subject = measureSubject(entity: entity, host: host, proxy: proxy),
                let solution = TorsoAlignmentSolver.solve(reference: reference, subject: subject)
            else { continue }

            // Everything below reads the placement the entity is actually carrying, not
            // the one the solver would have chosen.
            let live = placement.sanitized
            let liveRotation = simd_float3x3(live.orientation)
            let liveExtents = reference.frame.extents(
                ofAxisAlignedExtents: TorsoAlignmentSolver.rotatedExtents(
                    subject.torsoExtents * live.scale,
                    by: liveRotation
                )
            )

            return TorsoAlignmentSolver.accuracy(
                reference: reference,
                measuredRegistrationPoint: subject.registrationPoint.map {
                    live.offsetMetres + liveRotation * ($0 * live.scale)
                },
                measuredFrame: solution.subjectLocalFrame.rotated(by: liveRotation),
                measuredChestWidthMetres: liveExtents.x,
                measuredChestLengthMetres: liveExtents.y
            )
        }
        return nil
    }

    // MARK: - Entity measurement helpers

    static func firstEntity(named name: String, in root: Entity) -> Entity? {
        if root.name == name { return root }
        for child in root.children {
            if let match = firstEntity(named: name, in: child) { return match }
        }
        return nil
    }

    static func boundsIfPresent(of entity: Entity, relativeTo frame: Entity) -> BoundingBox? {
        let bounds = entity.visualBounds(recursive: true, relativeTo: frame)
        guard !bounds.isEmpty,
              bounds.center.allComponentsFinite,
              bounds.extents.allComponentsFinite
        else { return nil }
        return bounds
    }

    static func unionBounds(
        ofEntitiesNamed names: [String],
        in root: Entity,
        relativeTo frame: Entity
    ) -> BoundingBox? {
        var union: BoundingBox?
        for name in names {
            guard let entity = firstEntity(named: name, in: root),
                  let bounds = boundsIfPresent(of: entity, relativeTo: frame)
            else { continue }
            union = union.map { $0.union(bounds) } ?? bounds
        }
        return union
    }

    private static func firstPosition(
        ofEntitiesNamed names: [String],
        in root: Entity,
        relativeTo frame: Entity
    ) -> SIMD3<Float>? {
        for name in names {
            guard let entity = firstEntity(named: name, in: root) else { continue }
            let position = entity.position(relativeTo: frame)
            if position.allComponentsFinite { return position }
        }
        return nil
    }
}
