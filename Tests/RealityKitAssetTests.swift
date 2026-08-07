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
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Compiled RealityKit scene contract failures:\n\(failures.joined(separator: "\n"))"
        )
    }

    func testAllFiftyImportedUSDZResourcesLoadFromCompiledCatalog() async {
        // Reality Composer Pro compiles the source USDZ files into one .reality archive.
        // Loading every approved package-relative resource path verifies catalog presence
        // more strongly than checking for raw .usdz files, which are not separately copied
        // into the app bundle.
        let registry = AssetRegistry()
        var failures: [String] = []

        XCTAssertEqual(Self.deliveryAssetNames.count, 50)
        XCTAssertEqual(Set(Self.deliveryAssetNames).count, 50)

        for assetName in Self.deliveryAssetNames {
            do {
                _ = try await registry.loadEntity(named: assetName)
            } catch {
                failures.append("\(assetName): \(error)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Compiled RealityKit delivery-asset failures:\n\(failures.joined(separator: "\n"))"
        )
    }
}

private enum MissingResourceProbeError: Error, Sendable {
    case expectedFailure
}

private extension RealityKitAssetTests {
    static let deliveryAssetNames = [
        "Assets/accessibility-audio-beacon",
        "Assets/accessibility-switch-puck",
        "Assets/accessibility-text-block",
        "Assets/achievement-vault-environment",
        "Assets/badge_m01",
        "Assets/badge_m02",
        "Assets/badge_m03",
        "Assets/badge_m04",
        "Assets/badge_m05",
        "Assets/badge_m06",
        "Assets/badge_m07",
        "Assets/badge_m08",
        "Assets/badge_m09",
        "Assets/badge_m10",
        "Assets/badge_m11",
        "Assets/badge_m12",
        "Assets/badge_m13",
        "Assets/badge_m14",
        "Assets/capstone-environment",
        "Assets/certificate-pedestal",
        "Assets/companion-orb-bot",
        "Assets/constellation-star",
        "Assets/control-panel",
        "Assets/gesture-practice-cube",
        "Assets/gesture-practice-orb",
        "Assets/gesture-practice-ring",
        "Assets/observatory-environment",
        "Assets/portal_m01",
        "Assets/portal_m02",
        "Assets/portal_m03",
        "Assets/portal_m04",
        "Assets/portal_m05",
        "Assets/portal_m06",
        "Assets/portal_m07",
        "Assets/portal_m08",
        "Assets/portal_m09",
        "Assets/portal_m10",
        "Assets/portal_m11",
        "Assets/portal_m12",
        "Assets/portal_m13",
        "Assets/portal_m14",
        "Assets/practice-window-frame",
        "Assets/privacy-shield",
        "Assets/safety-props-set",
        "Assets/ShowcaseOnly/battery-prop",
        "Assets/ShowcaseOnly/headband",
        "Assets/ShowcaseOnly/headset-mockup",
        "Assets/ShowcaseOnly/light-seal-cushion",
        "Assets/theatre-environment",
        "Assets/xp-orb"
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
            return manikinModelNames + aedTrainerModelNames + ["clear_zone"]
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
