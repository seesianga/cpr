import RealityKit

/// Operator decision (2026-08-10): outside the curated practice rooms, anything a
/// learner never interacts with is hidden, so the passthrough demo shows the work — the
/// manikin, the pads, the module subjects — and not virtual set dressing floating in a
/// real room.
///
/// The lists are the residue of a full cross-check of scene contents against every
/// interaction surface (tap lists per experience, pinch-grab items, drag targets,
/// load-required descriptors, bounds sources). Three rules kept entities out of them:
/// - `anchor_*` Xforms are load-required (`compositionAnchorMissing`), so a backdrop is
///   hidden via its PAYLOAD entity and the anchor stays.
/// - Anything in a scene's descriptor set is load-required (`semanticEntityMissing`)
///   even when it is never tapped there — the lobby's `control_panel` stays for that
///   reason while the Debrief copy, whose descriptor set is deliberately empty, hides.
/// - The manikin and everything on it always stays.
///
/// Hiding is the house style: opacity (bounds survive for every consumer that measures)
/// plus input/collision stripping, so nothing invisible can swallow a pinch.
enum SceneDeclutter {

    /// The rooms the operator curates by hand — the declutter never touches them.
    static let exemptScenes: Set<SpatialSceneName> = [
        .cprPracticeRoom, .aedPreparationRoom, .aedPlacementRoom
    ]

    /// The AED kit props that ride along in every integrated-scenario room without
    /// being part of its interaction set: the scenario descriptor sets omit
    /// `preparationProps`, and the scenario tap list matches none of these.
    private static let scenarioKitProps = [
        "electrode_packet", "prep_cloth", "training_scissors", "training_razor",
        "glove_box"
    ]

    static func hiddenEntityNames(for scene: SpatialSceneName) -> [String] {
        switch scene {
        case .cprPracticeRoom, .aedPreparationRoom, .aedPlacementRoom:
            []
        case .academyLobby:
            ["observatory_environment"]
        case .heartAndLungsVolume:
            ["practice_window_frame"]
        case .chainOfSurvivalVolume:
            // Every entity is a drag-interactive chain ring; nothing to hide.
            []
        case .drsabcTrainingRoom:
            ["practice_floor"]
        case .scenarioHome:
            ["capstone_environment"] + scenarioKitProps
        case .scenarioShoppingCentre:
            ["theatre_environment"] + scenarioKitProps
        case .scenarioWorkplace:
            ["capstone_environment"] + scenarioKitProps
        case .scenarioCommunityFacility:
            ["theatre_environment"] + scenarioKitProps
        case .achievementGallery:
            ["achievement_vault_environment"]
        case .debriefSpace:
            // The Debrief control panel is undecorated set-dressing; its descriptor
            // set is empty on purpose and the restart/return controls are SwiftUI
            // attachments, not scene entities.
            ["theatre_environment", "control_panel"]
        }
    }

    /// Applies the scene's declutter after semantic decoration, so stripping input
    /// wins over anything decoration added.
    @MainActor
    static func apply(in scene: Entity, for sceneName: SpatialSceneName) {
        for name in hiddenEntityNames(for: sceneName) {
            guard let entity = PracticeVisualModelLoader.firstEntity(
                named: name,
                in: scene
            ) else { continue }
            entity.components.set(OpacityComponent(opacity: 0))
            PracticeVisualModelLoader.makeNonInteractive(entity)
        }
    }
}
