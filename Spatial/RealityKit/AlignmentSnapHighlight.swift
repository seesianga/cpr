import Foundation
import RealityKit
import SwiftUI
import simd

/// A brief outline drawn around the manikin's chest the moment the body overlay registers
/// onto it.
///
/// Alignment is otherwise invisible: a correctly placed overlay looks like nothing
/// happened, which gives the learner no way to tell a good registration from a lucky one.
/// Tracing the chest once, on the transition into alignment, says "this is the surface you
/// are working on" without a line of instruction — and because it draws the *measured*
/// torso rectangle rather than a fixed graphic, an overlay that is subtly wrong shows up
/// as an outline that does not follow the manikin.
@MainActor
enum AlignmentSnapHighlight {
    static let entityName = "alignment_snap_highlight"
    static let durationSeconds: Double = 1.1
    private static let edgeThicknessMetres: Float = 0.008
    /// Lifted clear of the chest so the outline reads as a highlight rather than z-fighting
    /// with the skin it traces.
    private static let surfaceLiftMetres: Float = 0.012

    /// Draws the outline, replacing any previous one, and removes it when it finishes.
    ///
    /// Parented to the scene root rather than to the manikin, even though `reference` is
    /// measured in the manikin's space. Practice targets get their collision proxies from
    /// `visualBounds(recursive:)` at scene decoration, so a highlight hanging under the
    /// manikin during a room revisit would inflate the manikin's own tap target. Placing
    /// it beside the manikin and matching its transform keeps the geometry identical and
    /// the bounds untouched.
    ///
    /// With Reduce Motion the outline fades without the scale-in, because the settle is the
    /// only part that moves.
    @discardableResult
    static func present(
        in scene: Entity,
        host: Entity,
        reference: TorsoAlignmentReference,
        reduceMotion: Bool
    ) -> Entity? {
        guard reference.isUsable else { return nil }
        remove(from: scene)

        let width = reference.anatomicalExtents.x
        let length = reference.anatomicalExtents.y
        guard width > 1e-3, length > 1e-3 else { return nil }

        let outline = Entity()
        outline.name = entityName
        let surfaceCenter = reference.torsoCenter
            + reference.frame.anterior * (reference.anatomicalExtents.z / 2 + surfaceLiftMetres)
        let hostFromOutline = simd_float4x4(columns: (
            SIMD4<Float>(reference.frame.lateral, 0),
            SIMD4<Float>(reference.frame.anterior, 0),
            SIMD4<Float>(reference.frame.longitudinal, 0),
            SIMD4<Float>(surfaceCenter, 1)
        ))

        let thickness = edgeThicknessMetres
        let material = UnlitMaterial(color: .cyan)
        let edges: [(size: SIMD3<Float>, position: SIMD3<Float>)] = [
            ([width, thickness, thickness], [0, 0, -length / 2]),
            ([width, thickness, thickness], [0, 0, length / 2]),
            ([thickness, thickness, length], [-width / 2, 0, 0]),
            ([thickness, thickness, length], [width / 2, 0, 0])
        ]
        for edge in edges {
            let bar = ModelEntity(
                mesh: .generateBox(size: edge.size, cornerRadius: thickness / 2),
                materials: [material]
            )
            bar.position = edge.position
            outline.addChild(bar)
        }

        outline.components.set(OpacityComponent(opacity: 0))
        scene.addChild(outline)
        outline.setTransformMatrix(hostFromOutline, relativeTo: host)
        if !reduceMotion {
            outline.scale *= 1.06
        }
        animate(outline, baseScale: outline.scale / (reduceMotion ? 1 : 1.06), reduceMotion: reduceMotion)
        return outline
    }

    static func remove(from scene: Entity) {
        for child in scene.children where child.name == entityName {
            child.removeFromParent()
        }
    }

    /// Fades in, holds, fades out. Stepped from a task rather than an `AnimationResource`
    /// because `OpacityComponent` is not animatable by `move(to:)`, and a hand-stepped fade
    /// keeps the highlight a pure visual with no scene-graph animation state to unwind if
    /// the room is torn down mid-fade.
    private static func animate(
        _ outline: Entity,
        baseScale: SIMD3<Float>,
        reduceMotion: Bool
    ) {
        let frameCount = 33
        let step = durationSeconds / Double(frameCount)
        Task { @MainActor [weak outline] in
            for frame in 0...frameCount {
                guard let outline, outline.parent != nil else { return }
                let progress = Float(frame) / Float(frameCount)
                // Fast in, long hold, gentle out.
                let envelope: Float = progress < 0.18
                    ? progress / 0.18
                    : max(0, 1 - (progress - 0.18) / 0.82)
                outline.components.set(OpacityComponent(opacity: envelope * 0.85))
                if !reduceMotion {
                    outline.scale = baseScale * (1.06 - 0.06 * min(progress / 0.18, 1))
                }
                try? await Task.sleep(for: .seconds(step))
            }
            outline?.removeFromParent()
        }
    }
}
