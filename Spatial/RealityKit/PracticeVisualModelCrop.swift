import Foundation
import RealityKit
import simd

/// Hides imported body geometry that has no physical counterpart underneath it.
///
/// The training manikin is a torso trainer: chest, head and upper limbs, and nothing
/// below. A full-body import therefore renders hips and legs hanging over the table with
/// no physical surface beneath them, which is exactly the cue that tells a learner the
/// overlay is not the thing they are touching.
///
/// Whole sub-entities that fall entirely outside the manikin's envelope are disabled,
/// which is free. The body mesh itself straddles the boundary, so it is cropped at the
/// triangle level — with the vertex buffers left untouched, so skinning, normals and UVs
/// survive and only the index buffer shrinks.
///
/// One consequence of leaving the vertex buffers alone: RealityKit derives
/// `visualBounds` from the position buffer rather than from the triangles that actually
/// reference it, so a cropped model keeps reporting its uncropped bounds. Nothing here
/// depends on those bounds — registration and prop sizing both measure the manikin, not
/// the import — and the alternative, remapping every parallel buffer including joint
/// influences, risks the skinning this approach exists to protect.
@MainActor
enum PracticeVisualModelCrop {

    struct Outcome: Equatable, Sendable {
        var disabledEntityCount = 0
        var croppedMeshCount = 0
        /// Meshes left whole because their vertex data could not be trusted to describe
        /// the geometry actually on screen.
        var skippedMeshCount = 0
        var keptTriangleCount = 0
        var removedTriangleCount = 0
        /// Set when a mesh was too coarsely tessellated for the strict rule and the
        /// centroid rule was used instead, which can leave a little overhang.
        var usedApproximateCrop = false

        var didCropAnything: Bool {
            disabledEntityCount > 0 || removedTriangleCount > 0
        }

        var summary: String {
            guard didCropAnything else { return "No geometry outside the manikin envelope" }
            return "\(removedTriangleCount) triangles and \(disabledEntityCount) parts hidden"
                + (usedApproximateCrop ? ", approximate on coarse mesh" : "")
                + (skippedMeshCount > 0 ? ", \(skippedMeshCount) mesh(es) left whole" : "")
        }
    }

    /// Breathing room around the manikin's measured envelope.
    ///
    /// Clothing and soft tissue legitimately sit a little proud of the shell the manikin
    /// is built from, so cutting exactly at the measured box shaves the silhouette.
    static let envelopeMarginMetres: Float = 0.06

    /// A crop is only believed when it removes something and leaves something. A crop that
    /// keeps everything did nothing; one that keeps almost nothing means the box and the
    /// mesh were measured in different spaces, and showing an invisible body is worse than
    /// showing an uncropped one.
    static let minimumKeptTriangleFraction: Float = 0.02

    /// Tolerance on the check that a mesh's stored vertices describe what is rendered.
    /// A rigged import whose bind pose differs from its rest pose fails this, and failing
    /// it means the crop is skipped rather than applied to the wrong region.
    static let vertexBoundsAgreementTolerance: Float = 0.15

    /// Meshes are replaced in place, so the originals are kept here to make the crop
    /// reversible from the in-headset toggle without reloading the archive.
    private static var originalMeshes: [Entity.ID: MeshResource] = [:]

    /// Crops `root` to the manikin envelope, expressed as a box in `host` space.
    static func apply(
        to root: Entity,
        envelopeCenter: SIMD3<Float>,
        envelopeExtents: SIMD3<Float>,
        host: Entity
    ) -> Outcome {
        guard envelopeCenter.allComponentsFinite,
              envelopeExtents.allComponentsFinite,
              envelopeExtents.min() > 1e-4
        else { return Outcome() }

        let halfExtents = envelopeExtents / 2 + SIMD3<Float>(repeating: envelopeMarginMetres)
        let envelope = BoundingBox(
            min: envelopeCenter - halfExtents,
            max: envelopeCenter + halfExtents
        )

        var outcome = Outcome()
        for entity in descendants(of: root) {
            restoreMesh(on: entity)
            entity.isEnabled = true
        }

        for entity in descendants(of: root) {
            guard entity.components[ModelComponent.self] != nil else { continue }
            let bounds = entity.visualBounds(recursive: false, relativeTo: host)
            guard !bounds.isEmpty else { continue }

            if !intersects(bounds, envelope) {
                entity.isEnabled = false
                outcome.disabledEntityCount += 1
                continue
            }
            if contains(envelope, bounds) { continue }

            cropMesh(on: entity, to: envelope, host: host, outcome: &outcome)
        }
        return outcome
    }

    /// Puts every mesh back and re-enables everything the crop switched off.
    static func restore(_ root: Entity) {
        for entity in descendants(of: root) {
            restoreMesh(on: entity)
            entity.isEnabled = true
        }
    }

    /// Drops cached originals for a subtree that is going away, so a room the learner
    /// never returns to does not hold its meshes alive.
    static func forget(_ root: Entity) {
        for entity in descendants(of: root) {
            originalMeshes.removeValue(forKey: entity.id)
        }
    }

    // MARK: - Mesh surgery

    private static func cropMesh(
        on entity: Entity,
        to envelope: BoundingBox,
        host: Entity,
        outcome: inout Outcome
    ) {
        guard var component = entity.components[ModelComponent.self] else { return }
        let source = originalMeshes[entity.id] ?? component.mesh
        let contents = source.contents

        guard vertexDataDescribesRenderedGeometry(contents, of: entity) else {
            outcome.skippedMeshCount += 1
            return
        }

        let hostFromEntity = entity.transformMatrix(relativeTo: host)

        // Two candidate cuts per part, from the same single pass over the triangles.
        //
        // Strict — every vertex inside — guarantees nothing renders past the manikin, and
        // on a dense body mesh it costs one row of triangles at the boundary. It is
        // useless on coarse geometry, though: a slab whose side faces are two long
        // triangles has no triangle fully inside anything, so strict would erase the body.
        // Centroid keeps such a mesh at the price of a little overhang. Strict is
        // preferred and the fallback is reported rather than applied silently.
        var strictParts: [[UInt32]] = []
        var centroidParts: [[UInt32]] = []
        var strictTotal = 0
        var centroidTotal = 0
        var originalTotal = 0

        func isInside(_ position: SIMD3<Float>) -> Bool {
            let inHost = hostFromEntity * SIMD4<Float>(position, 1)
            return envelope.contains(SIMD3<Float>(inHost.x, inHost.y, inHost.z))
        }

        for model in contents.models {
            for part in model.parts {
                guard let indices = part.triangleIndices?.elements, indices.count >= 3 else {
                    strictParts.append([])
                    centroidParts.append([])
                    continue
                }
                let positions = part.positions.elements
                originalTotal += indices.count / 3

                var strict: [UInt32] = []
                var centroid: [UInt32] = []
                strict.reserveCapacity(indices.count)
                centroid.reserveCapacity(indices.count)

                var triangle = 0
                while triangle + 2 < indices.count {
                    defer { triangle += 3 }
                    let a = Int(indices[triangle])
                    let b = Int(indices[triangle + 1])
                    let c = Int(indices[triangle + 2])
                    guard a < positions.count, b < positions.count, c < positions.count else {
                        continue
                    }
                    let corners = [positions[a], positions[b], positions[c]]
                    let face = [indices[triangle], indices[triangle + 1], indices[triangle + 2]]
                    let insideCount = corners.count(where: isInside)
                    if insideCount == 3 {
                        strict.append(contentsOf: face)
                    }
                    if isInside((corners[0] + corners[1] + corners[2]) / 3) {
                        centroid.append(contentsOf: face)
                    }
                }
                strictTotal += strict.count / 3
                centroidTotal += centroid.count / 3
                strictParts.append(strict)
                centroidParts.append(centroid)
            }
        }

        guard originalTotal > 0 else { return }
        let useStrict = Float(strictTotal) / Float(originalTotal) >= minimumKeptTriangleFraction
        let chosenParts = useStrict ? strictParts : centroidParts
        let keptTotal = useStrict ? strictTotal : centroidTotal

        guard Float(keptTotal) / Float(originalTotal) >= minimumKeptTriangleFraction else {
            // Nothing survived either rule. Either the box and the mesh disagree about
            // space, or this part genuinely lies outside — disabling it is correct either
            // way and cannot leave a half-rendered body behind.
            entity.isEnabled = false
            outcome.disabledEntityCount += 1
            return
        }
        guard keptTotal < originalTotal else { return }

        var partIndex = 0
        var croppedModels: [MeshResource.Model] = []
        for var model in contents.models {
            var croppedParts: [MeshResource.Part] = []
            for var part in model.parts {
                part.triangleIndices = MeshBuffers.TriangleIndices(chosenParts[partIndex])
                partIndex += 1
                croppedParts.append(part)
            }
            model.parts = MeshPartCollection(croppedParts)
            croppedModels.append(model)
        }

        var updated = contents
        updated.models = MeshModelCollection(croppedModels)
        guard let mesh = try? MeshResource.generate(from: updated) else {
            outcome.skippedMeshCount += 1
            return
        }

        if originalMeshes[entity.id] == nil {
            originalMeshes[entity.id] = source
        }
        component.mesh = mesh
        entity.components.set(component)
        outcome.croppedMeshCount += 1
        outcome.keptTriangleCount += keptTotal
        outcome.removedTriangleCount += originalTotal - keptTotal
        outcome.usedApproximateCrop = outcome.usedApproximateCrop || !useStrict
    }

    /// Whether a mesh's stored vertex positions match the bounds RealityKit reports for it.
    ///
    /// They diverge when a skinned mesh is rendered in a pose other than the one its
    /// vertices are stored in. Cropping against stored positions would then cut the wrong
    /// region of the body, so this is the gate that decides whether cropping is safe at
    /// all rather than something to detect afterwards.
    private static func vertexDataDescribesRenderedGeometry(
        _ contents: MeshResource.Contents,
        of entity: Entity
    ) -> Bool {
        var vertexBounds: BoundingBox?
        for model in contents.models {
            for part in model.parts {
                for position in part.positions.elements {
                    guard position.allComponentsFinite else { return false }
                    let point = BoundingBox(min: position, max: position)
                    vertexBounds = vertexBounds.map { $0.union(point) } ?? point
                }
            }
        }
        guard let vertexBounds else { return false }

        let rendered = entity.visualBounds(recursive: false, relativeTo: entity)
        guard !rendered.isEmpty else { return false }
        let scale = max(rendered.extents.max(), 1e-4)
        let centreDrift = simd_length(rendered.center - vertexBounds.center) / scale
        let sizeDrift = simd_length(rendered.extents - vertexBounds.extents) / scale
        return centreDrift <= vertexBoundsAgreementTolerance
            && sizeDrift <= vertexBoundsAgreementTolerance
    }

    private static func restoreMesh(on entity: Entity) {
        guard let original = originalMeshes.removeValue(forKey: entity.id),
              var component = entity.components[ModelComponent.self]
        else { return }
        component.mesh = original
        entity.components.set(component)
    }

    // MARK: - Geometry helpers

    private static func descendants(of root: Entity) -> [Entity] {
        var result: [Entity] = [root]
        var index = 0
        while index < result.count {
            result.append(contentsOf: result[index].children)
            index += 1
        }
        return result
    }

    static func intersects(_ lhs: BoundingBox, _ rhs: BoundingBox) -> Bool {
        all(lhs.min .<= rhs.max) && all(rhs.min .<= lhs.max)
    }

    static func contains(_ outer: BoundingBox, _ inner: BoundingBox) -> Bool {
        all(outer.min .<= inner.min) && all(inner.max .<= outer.max)
    }
}
