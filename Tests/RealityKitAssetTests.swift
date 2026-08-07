import Foundation
import RealityKit
import XCTest
@testable import LifesaverVision

@MainActor
final class RealityKitAssetTests: XCTestCase {
    func testRealityKitContentCompiledArchiveIsPresent() throws {
        let archiveURL = try XCTUnwrap(
            AssetRegistry().compiledArchiveURL,
            "RealityKitContent.reality must be embedded in the RealityKitContent package bundle"
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: archiveURL.path),
            "Expected compiled RealityKit archive at \(archiveURL.path)"
        )
    }

    func testMissingAssetReturnsGracefulRegistryError() async {
        let requestedName = "deliberately-missing-spatial-resource"
        let registry = AssetRegistry(loader: { _, _ in
            throw MissingResourceProbeError.expectedFailure
        })

        do {
            _ = try await registry.loadEntity(named: requestedName)
            XCTFail("A missing RealityKit resource must not be reported as loaded")
        } catch let error as AssetRegistryError {
            guard case let .resourceUnavailable(name, diagnostic) = error else {
                return XCTFail("Expected resourceUnavailable, received \(error)")
            }

            XCTAssertEqual(name, requestedName)
            XCTAssertTrue(diagnostic.contains("expectedFailure"))
            XCTAssertTrue(error.localizedDescription.contains(requestedName))
        } catch {
            XCTFail("AssetRegistry must translate loader failures into a safe error: \(error)")
        }
    }

    func testRealMissingCatalogAssetReturnsGracefulRegistryError() async {
        let requestedName = "resource-that-does-not-exist-in-reality-catalog"

        do {
            _ = try await AssetRegistry().loadEntity(named: requestedName)
            XCTFail("A missing compiled-catalog resource must not be reported as loaded")
        } catch let error as AssetRegistryError {
            guard case let .resourceUnavailable(name, diagnostic) = error else {
                return XCTFail("Expected resourceUnavailable, received \(error)")
            }

            XCTAssertEqual(name, requestedName)
            XCTAssertFalse(diagnostic.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains(requestedName))
        } catch {
            XCTFail("A real RealityKit lookup failure must use the graceful error path: \(error)")
        }
    }

    func testAllThirteenScenesResolveRegistryAndAuthoredRuntimeContracts() async {
        let registry = AssetRegistry()
        var failures: [String] = []

        XCTAssertEqual(SpatialSceneName.allCases.count, 13)

        for scene in SpatialSceneName.allCases {
            do {
                let root = try await registry.loadScene(scene)
                XCTAssertTrue(registry.isSceneCached(scene))

                let placementContracts = try registry.placementContracts(for: scene)
                for placement in placementContracts {
                    guard let anchor = registry.firstEntity(
                        named: placement.anchorName,
                        in: root
                    ) else {
                        failures.append(
                            "\(scene.rawValue): missing composition anchor \(placement.anchorName)"
                        )
                        continue
                    }
                    XCTAssertEqual(
                        anchor.children.filter { $0.name == placement.semanticName }.count,
                        1,
                        "\(scene.rawValue)/\(placement.anchorName) must contain exactly one mapped payload"
                    )
                }

                let requiredNames = registry.semanticEntityNames(for: scene)
                XCTAssertEqual(
                    Set(requiredNames).count,
                    requiredNames.count,
                    "\(scene.rawValue) must not declare duplicate semantic targets"
                )

                let missingNames = requiredNames.filter {
                    registry.firstEntity(named: $0, in: root) == nil
                }
                if !missingNames.isEmpty {
                    failures.append(
                        "\(scene.rawValue): registry contract missing \(missingNames.joined(separator: ", "))"
                    )
                }

                let decoratedNames = try registry.decorateSemanticEntities(in: root, for: scene)
                XCTAssertEqual(
                    decoratedNames,
                    requiredNames,
                    "\(scene.rawValue) must decorate its complete registry contract"
                )
                for name in requiredNames {
                    guard let entity = registry.firstEntity(named: name, in: root) else {
                        continue
                    }

                    XCTAssertNotNil(
                        entity.components[InputTargetComponent.self],
                        "\(scene.rawValue)/\(name) is missing InputTargetComponent"
                    )
                    if let collision = entity.components[CollisionComponent.self] {
                        XCTAssertFalse(
                            collision.shapes.isEmpty,
                            "\(scene.rawValue)/\(name) has no simplified collision proxy"
                        )
                    } else {
                        XCTFail("\(scene.rawValue)/\(name) is missing CollisionComponent")
                    }
                    XCTAssertNotNil(
                        entity.components[HoverEffectComponent.self],
                        "\(scene.rawValue)/\(name) is missing HoverEffectComponent"
                    )
                    XCTAssertNotNil(
                        entity.components[AccessibilityComponent.self],
                        "\(scene.rawValue)/\(name) is missing AccessibilityComponent"
                    )
                }

                // This separately maintained list protects the authored clinical-model
                // contract from accidentally shrinking with AssetRegistry.descriptors.
                let authoredNames = Self.originalClinicalEntityNames(for: scene)
                XCTAssertEqual(
                    Set(authoredNames).count,
                    authoredNames.count,
                    "\(scene.rawValue) must not declare duplicate authored-model targets"
                )
                let missingAuthoredNames = authoredNames.filter {
                    registry.firstEntity(named: $0, in: root) == nil
                }
                if !missingAuthoredNames.isEmpty {
                    failures.append(
                        "\(scene.rawValue): authored-model contract missing "
                            + missingAuthoredNames.joined(separator: ", ")
                    )
                }
            } catch {
                failures.append("\(scene.rawValue): failed to load or decorate (\(error))")
            }
            registry.releaseScene(scene)
            XCTAssertFalse(registry.isSceneCached(scene))
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Compiled RealityKit scene contract failures:\n\(failures.joined(separator: "\n"))"
        )
    }

    func testAllFiftyLooseUSDZResourcesLoadFromAppBundle() async throws {
        // The lightweight RealityKit archive contains only authored USDA. Every approved
        // payload must remain independently loadable from the app's USDZ subdirectory.
        let registry = AssetRegistry()
        var failures: [String] = []

        XCTAssertEqual(Self.deliveryAssetNames.count, 50)
        XCTAssertEqual(Set(Self.deliveryAssetNames).count, 50)
        XCTAssertEqual(try registry.deliveryAssetNames(), Self.deliveryAssetNames)
        XCTAssertEqual(SpatialSceneName.allCases.count + Self.deliveryAssetNames.count, 63)

        for assetName in Self.deliveryAssetNames {
            do {
                _ = try await registry.loadLooseAsset(named: assetName)
            } catch {
                failures.append("\(assetName): \(error)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Loose RealityKit delivery-asset failures:\n\(failures.joined(separator: "\n"))"
        )
    }

    func testSceneCacheReturnsOneRootUntilExplicitEviction() async throws {
        let counter = EntityLoadCounter()
        let registry = AssetRegistry(loader: { name, _ in
            counter.count += 1
            let entity = Entity()
            entity.name = name
            return entity
        })

        let first = try await registry.loadScene(.chainOfSurvivalVolume)
        let second = try await registry.loadScene(.chainOfSurvivalVolume)
        XCTAssertTrue(first === second)
        XCTAssertEqual(counter.count, 1)
        XCTAssertTrue(registry.isSceneCached(.chainOfSurvivalVolume))

        registry.releaseScene(.chainOfSurvivalVolume)
        XCTAssertFalse(registry.isSceneCached(.chainOfSurvivalVolume))

        let third = try await registry.loadScene(.chainOfSurvivalVolume)
        XCTAssertFalse(first === third)
        XCTAssertEqual(counter.count, 2)
        registry.releaseScene(.chainOfSurvivalVolume)
    }

    func testMissingCompositionAnchorFailsBeforePayloadAttachment() async {
        let registry = AssetRegistry(loader: { name, _ in
            let entity = Entity()
            entity.name = name
            return entity
        })

        do {
            _ = try await registry.loadScene(.academyLobby)
            XCTFail("A skeleton missing declared anchors must not be cached or presented")
        } catch let error as AssetRegistryError {
            guard case let .compositionAnchorMissing(scene, anchor) = error else {
                return XCTFail("Expected compositionAnchorMissing, received \(error)")
            }
            XCTAssertEqual(scene, SpatialSceneName.academyLobby.rawValue)
            XCTAssertEqual(anchor, "anchor_observatory_environment")
            XCTAssertFalse(registry.isSceneCached(.academyLobby))
        } catch {
            XCTFail("Expected a safe AssetRegistryError, received \(error)")
        }
    }

    func testCompositionManifestCoversAllScenesAndFortySevenPlacements() throws {
        let registry = AssetRegistry()
        let placements = try SpatialSceneName.allCases.flatMap {
            try registry.placementContracts(for: $0)
        }

        XCTAssertEqual(placements.count, 47)
        XCTAssertTrue(placements.allSatisfy { $0.anchorName.hasPrefix("anchor_") })
        XCTAssertTrue(placements.allSatisfy { !$0.semanticName.isEmpty })
        XCTAssertTrue(
            placements.allSatisfy { Self.deliveryAssetNames.contains($0.resourceName) }
        )
    }
}

private enum MissingResourceProbeError: Error, Sendable {
    case expectedFailure
}

@MainActor
private final class EntityLoadCounter {
    var count = 0
}

private extension RealityKitAssetTests {
    static let deliveryAssetNames = [
        "accessibility-audio-beacon",
        "accessibility-switch-puck",
        "accessibility-text-block",
        "achievement-vault-environment",
        "badge_m01",
        "badge_m02",
        "badge_m03",
        "badge_m04",
        "badge_m05",
        "badge_m06",
        "badge_m07",
        "badge_m08",
        "badge_m09",
        "badge_m10",
        "badge_m11",
        "badge_m12",
        "badge_m13",
        "badge_m14",
        "battery-prop",
        "capstone-environment",
        "certificate-pedestal",
        "companion-orb-bot",
        "constellation-star",
        "control-panel",
        "gesture-practice-cube",
        "gesture-practice-orb",
        "gesture-practice-ring",
        "headband",
        "headset-mockup",
        "light-seal-cushion",
        "observatory-environment",
        "portal_m01",
        "portal_m02",
        "portal_m03",
        "portal_m04",
        "portal_m05",
        "portal_m06",
        "portal_m07",
        "portal_m08",
        "portal_m09",
        "portal_m10",
        "portal_m11",
        "portal_m12",
        "portal_m13",
        "portal_m14",
        "practice-window-frame",
        "privacy-shield",
        "safety-props-set",
        "theatre-environment",
        "xp-orb"
    ]

    static func originalClinicalEntityNames(for scene: SpatialSceneName) -> [String] {
        switch scene {
        case .heartAndLungsVolume:
            return cardiopulmonaryModelNames
        case .drsabcTrainingRoom:
            return manikinModelNames + ["bystander_01"]
        case .cprPracticeRoom:
            return manikinModelNames + ["clear_zone"]
        case .aedPreparationRoom:
            return manikinModelNames + aedTrainerModelNames
        case .aedPlacementRoom:
            return manikinModelNames
                + aedTrainerModelNames
                + ["bystander_01", "bystander_02", "clear_zone"]
        case .scenarioHome,
             .scenarioShoppingCentre,
             .scenarioWorkplace,
             .scenarioCommunityFacility:
            return manikinModelNames
                + aedTrainerModelNames
                + ["bystander_01", "bystander_02", "clear_zone"]
        case .academyLobby,
             .chainOfSurvivalVolume,
             .achievementGallery,
             .debriefSpace:
            return []
        }
    }

    static let manikinModelNames = [
        "training_manikin",
        "sternum_target",
        "xiphoid_avoid_zone",
        "aed_right_pad_zone",
        "aed_left_pad_zone"
    ]

    static let aedTrainerModelNames = [
        "aed_trainer",
        "aed_case",
        "aed_unit",
        "aed_power_button",
        "aed_shock_button",
        "aed_status_light",
        "aed_connector",
        "aed_left_pad",
        "aed_right_pad",
        "aed_pad_left",
        "aed_pad_right",
        "electrode_packet",
        "prep_cloth",
        "training_scissors",
        "training_razor",
        "glove_box"
    ]

    static let cardiopulmonaryModelNames = [
        "heart_model",
        "heart_ra",
        "heart_rv",
        "heart_la",
        "heart_lv",
        "lungs_model",
        "lungs_left",
        "lungs_right"
    ]
}
