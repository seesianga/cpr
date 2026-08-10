import RealityKit
import XCTest
@testable import LifesaverVision

/// Pins the operator's 2026-08-10 whole-app declutter: set dressing hides everywhere
/// EXCEPT the hand-curated practice rooms, and nothing that is interacted with, load
/// required, or measured may ever drift into a hide list.
@MainActor
final class SceneDeclutterTests: XCTestCase {

    /// The curated rooms are exempt by policy — the declutter must return nothing for
    /// them, whatever future lists are added for other scenes.
    func testCuratedPracticeRoomsAreNeverDecluttered() {
        for scene in SceneDeclutter.exemptScenes {
            XCTAssertTrue(SceneDeclutter.hiddenEntityNames(for: scene).isEmpty)
        }
        XCTAssertEqual(
            SceneDeclutter.exemptScenes,
            [.cprPracticeRoom, .aedPreparationRoom, .aedPlacementRoom]
        )
    }

    /// Hide lists may only ever contain set dressing. Anchors are load-required
    /// (`compositionAnchorMissing`), and the interaction surface — tap targets across
    /// every experience, grabbable pads, the manikin and its measured children — must
    /// stay visible everywhere it appears.
    func testHideListsNeverTouchAnchorsOrInteractionSurfaces() {
        // Union of the semanticAncestor tap lists in SimulationSpaceRootView, the
        // pinch-grab identifiers, and the manikin/bounds entities. Deliberately
        // maintained by hand here: if a new interaction is added and its name is also
        // put in a hide list, this test is the tripwire.
        let interactionSurface: Set<String> = [
            // .aed and .integratedScenario tap lists
            "training_razor", "prep_cloth", "aed_case", "aed_unit", "electrode_packet",
            "aed_power_button", "aed_shock_button", "clear_zone", "bystander_01",
            "bystander_02",
            // .cpr tap list and manikin
            "sternum_target", "xiphoid_avoid_zone", "control_panel", "training_manikin",
            // .drsabc
            "safety_hazards",
            // grabbable pads and their zones
            "aed_left_pad", "aed_right_pad", "aed_right_pad_zone", "aed_left_pad_zone",
            // bounds sources and landmarks
            "torso_shell", "landmark_sternum", "landmark_xiphoid",
            "landmark_right_clavicle", "landmark_left_lower_ribs",
            // volume modules' interactive content
            "heart_ra", "heart_rv", "heart_la", "heart_lv", "lungs_left", "lungs_right",
            "chain_ring_1", "chain_ring_2", "chain_ring_3", "chain_ring_4",
            "chain_ring_5", "chain_ring_6", "chain_ring_7",
            // imported visual models
            "human_visual_model", "aed_visual_model", "aed_visual_case"
        ]

        for scene in SpatialSceneName.allCases {
            let hidden = SceneDeclutter.hiddenEntityNames(for: scene)
            for name in hidden {
                XCTAssertFalse(
                    name.hasPrefix("anchor_"),
                    "\(scene.rawValue): anchors are load-required; hide the payload"
                )
            }
            let collisions = Set(hidden).intersection(interactionSurface)
            // Names that are interactive in OTHER scenes may hide where they are
            // provably inert in THIS one. The scenario rooms hide the AED kit props
            // that only the preparation room taps; the Debrief space hides the
            // control panel whose tap match exists only in the .cpr experience branch
            // and whose Debrief descriptor set is deliberately empty.
            let allowed: Set<String>
            if scene.rawValue.hasPrefix("Scenario_") {
                allowed = ["electrode_packet", "prep_cloth", "training_razor"]
            } else if scene == .debriefSpace {
                allowed = ["control_panel"]
            } else {
                allowed = []
            }
            XCTAssertTrue(
                collisions.subtracting(allowed).isEmpty,
                "\(scene.rawValue) hides interactive entities: \(collisions)"
            )
        }
    }

    /// End to end on a real scene: the scenario room loses its backdrop and kit props,
    /// keeps the manikin, the grabbable pads and the anchors — and hidden entities
    /// keep their bounds but lose their input.
    func testScenarioHomeDecluttersSetDressingOnly() async throws {
        let registry = AssetRegistry()
        let scene = try await registry.loadScene(.scenarioHome)
        defer { registry.releaseScene(.scenarioHome) }
        try registry.decorateSemanticEntities(in: scene, for: .scenarioHome)

        SceneDeclutter.apply(in: scene, for: .scenarioHome)

        for hidden in ["capstone_environment", "prep_cloth", "glove_box"] {
            guard let entity = registry.firstEntity(named: hidden, in: scene) else {
                continue // Composition may omit optional dressing; absence is fine.
            }
            XCTAssertEqual(
                entity.components[OpacityComponent.self]?.opacity, 0,
                "\(hidden) must be hidden in a scenario room"
            )
            XCTAssertFalse(entity.components.has(InputTargetComponent.self))
        }

        for kept in ["training_manikin", "aed_left_pad", "aed_right_pad", "clear_zone"] {
            let entity = try XCTUnwrap(
                registry.firstEntity(named: kept, in: scene),
                "\(kept) must exist in the scenario room"
            )
            XCTAssertNil(
                entity.components[OpacityComponent.self],
                "\(kept) must stay visible"
            )
        }
        XCTAssertNotNil(
            registry.firstEntity(named: "anchor_capstone_environment", in: scene),
            "The load-required anchor must survive the declutter"
        )
    }
}
