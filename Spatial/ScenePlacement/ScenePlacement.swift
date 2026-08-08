import RealityKit

/// Namespace for scene-placement policies added in later phases.
enum ScenePlacement {}

/// Comfort policy for the immersive simulation interface.
///
/// A head target is sampled once, leaving the interface world-stable after placement.
/// Recentring explicitly samples the learner's current look direction again; no continuous
/// head-locked motion is used for the panel or its captions.
@MainActor
enum ImmersivePanelPlacementPolicy {
    static let trackingMode: AnchoringComponent.TrackingMode = .once
    static let distanceMetres: Float = 1.35

    static func makeAnchor() -> AnchorEntity {
        AnchorEntity(.head, trackingMode: trackingMode)
    }

    static func interfaceOffset(
        horizontalBias: Float,
        isSeated: Bool
    ) -> SIMD3<Float> {
        [horizontalBias, isSeated ? -0.12 : -0.04, -distanceMetres]
    }

    static func recentre(_ anchor: AnchorEntity) {
        // Replacing the component creates a fresh one-shot head target, so the panel samples
        // the learner's current look direction without ever entering continuous tracking.
        anchor.anchoring = AnchoringComponent(.head, trackingMode: trackingMode)
    }
}
