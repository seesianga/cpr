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
                let accessibilityContracts = registry.accessibilityContracts(for: scene)
                let accessibilityByName = Dictionary(
                    uniqueKeysWithValues: accessibilityContracts.map { ($0.name, $0) }
                )
                XCTAssertEqual(
                    Set(requiredNames).count,
                    requiredNames.count,
                    "\(scene.rawValue) must not declare duplicate semantic targets"
                )
                XCTAssertEqual(accessibilityContracts.map(\.name), requiredNames)

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
                    if let accessibility = entity.components[AccessibilityComponent.self],
                       let contract = accessibilityByName[name] {
                        XCTAssertEqual(
                            accessibility.systemActions,
                            contract.isActionable ? .activate : [],
                            "\(scene.rawValue)/\(name) has inaccurate activation semantics"
                        )
                        XCTAssertEqual(
                            accessibility.customContent.count,
                            contract.isActionable ? 2 : 1,
                            "\(scene.rawValue)/\(name) has an inaccurate action hint"
                        )
                    } else {
                        XCTFail("\(scene.rawValue)/\(name) is missing AccessibilityComponent")
                    }
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

    func testHeartAndLungsLaboratoryUsesApprovedScopeAndReducedMotionPolicy() throws {
        let model = try SpatialLaboratoryContent.loadBundled().heartAndLungs

        XCTAssertEqual(
            model.parts.map(\.id),
            ["heart_ra", "heart_rv", "heart_la", "heart_lv", "lungs_left", "lungs_right"]
        )
        XCTAssertTrue(model.parts.allSatisfy { $0.excerpt.blockID == "M1-B8" })
        XCTAssertTrue(
            model.parts.allSatisfy { $0.excerpt.narrationCue?.rawValue == "nar.M1-B8" }
        )
        XCTAssertEqual(model.excerpt(for: .simplifiedVF).blockID, "M1-B4")
        XCTAssertEqual(
            model.excerpt(for: .simplifiedVF).narrationCue?.rawValue,
            "nar.M1-B4"
        )

        let normalMotion = model.visualPresentation(for: .normal, reduceMotion: false)
        XCTAssertEqual(normalMotion.motionStyle, .calmPulse)
        XCTAssertTrue(normalMotion.isAnimated)

        let reducedNormal = model.visualPresentation(for: .normal, reduceMotion: true)
        XCTAssertEqual(reducedNormal.motionStyle, .staticNormal)
        XCTAssertFalse(reducedNormal.isAnimated)
        XCTAssertEqual(reducedNormal.heartScale(at: 3), 1)

        let reducedVF = model.visualPresentation(for: .simplifiedVF, reduceMotion: true)
        XCTAssertEqual(reducedVF.motionStyle, .staticVF)
        XCTAssertFalse(reducedVF.isAnimated)
        XCTAssertTrue(reducedVF.statusText.contains("Static simplified-VF"))
    }

    func testLaboratoryRequiresAuthoritativePresentationForEveryLinkedModule() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let linkedModules = course.modules
            .filter { SpatialLaboratoryAccessPolicy.requiredModuleIDs.contains($0.id) }
            .map {
                PresentedCourseModule(module: $0, isPresentable: true, lockReasons: [])
            }
        XCTAssertEqual(
            SpatialLaboratoryAccessPolicy.authorisedModes(in: linkedModules),
            Set(SpatialLaboratoryMode.allCases)
        )

        let withoutM5 = linkedModules.filter { $0.id != "M5" }
        XCTAssertEqual(
            SpatialLaboratoryAccessPolicy.authorisedModes(in: withoutM5),
            [.heartAndLungs, .chainOfSurvival]
        )
        XCTAssertEqual(
            SpatialLaboratoryAccessPolicy.lockedModuleIDs(in: withoutM5),
            ["M5"]
        )

        let explicitlyLocked = linkedModules.map { item in
            item.id == "M2"
                ? PresentedCourseModule(
                    module: item.module,
                    isPresentable: false,
                    lockReasons: [.unavailable]
                )
                : item
        }
        XCTAssertEqual(
            SpatialLaboratoryAccessPolicy.lockedModuleIDs(in: explicitlyLocked),
            ["M2"]
        )
    }

    func testSevenRingLaboratoryIsUnscoredReviewGatedAndUsesOneReorderPath() throws {
        var model = try SpatialLaboratoryContent.loadBundled().chainOfSurvival

        XCTAssertFalse(ChainOfSurvivalLaboratoryModel.isScored)
        XCTAssertEqual(model.rings.count, 7)
        XCTAssertEqual(Set(model.rings.map(\.id)).count, 7)
        XCTAssertEqual(model.reviewExcerpt.reviewStatus, .clinicalReviewRequired)
        XCTAssertNil(model.reviewExcerpt.narrationCue)
        XCTAssertEqual(model.purposeExcerpt.narrationCue?.rawValue, "nar.M2-B2")
        XCTAssertEqual(
            model.rings.sorted { $0.correctIndex < $1.correctIndex }.map(\.title),
            [
                "Prevention",
                "Early Activation and AED Access",
                "Early CPR",
                "Early Defibrillation",
                "Emergency Medical Services (Ambulance)",
                "Advanced Cardiac Life Support",
                "Recovery"
            ]
        )
        XCTAssertEqual(model.rings.first?.purpose, "healthy lifestyle and regular check-ups reduce risk")
        XCTAssertEqual(
            model.rings.last?.purpose,
            "community and medical rehabilitation support after survival"
        )
        XCTAssertNotEqual(model.orderedRingIDs, model.correctRingIDs)
        XCTAssertTrue(model.rings.allSatisfy { !$0.purpose.isEmpty })
        XCTAssertTrue(model.rings.allSatisfy { !$0.orderSources.isEmpty })
        XCTAssertTrue(model.rings.allSatisfy { !$0.purposeSources.isEmpty })

        XCTAssertEqual(model.check(), .orderAndPurposeNeedReview)
        for (index, ringID) in model.correctRingIDs.enumerated() {
            _ = model.move(ringID: ringID, to: index)
            model.assignPurpose(ringID, to: ringID)
        }

        XCTAssertEqual(model.orderedRingIDs, model.correctRingIDs)
        XCTAssertEqual(model.check(), .complete)
        XCTAssertTrue(model.lastCheck?.message.contains("unscored") == true)
    }

    func testAEDExplorerMapsEveryTrainerTargetToSourceCheckedCourseText() throws {
        let content = try SpatialLaboratoryContent.loadBundled().aedExplorer
        let registryNames = AssetRegistry().aedTrainerEntityNames()

        XCTAssertEqual(content.components.count, 13)
        XCTAssertEqual(Set(content.components.map(\.id)), Set(registryNames))
        XCTAssertTrue(content.components.allSatisfy {
            $0.excerpt.reviewStatus == .sourceChecked &&
                !$0.excerpt.sourceReferences.isEmpty &&
                $0.excerpt.narrationCue != nil
        })
        XCTAssertEqual(content.component(named: "training_razor")?.excerpt.blockID, "M5-B6")
        XCTAssertEqual(content.component(named: "prep_cloth")?.excerpt.blockID, "M5-B10")
        XCTAssertEqual(
            content.preparationCallouts.map(\.blockID),
            ["M5-B5", "M5-B6", "M5-B7", "M5-B8", "M5-B9", "M5-B10"]
        )
        XCTAssertTrue(content.preparationCallouts.allSatisfy {
            !$0.sourceReferences.isEmpty && $0.narrationCue != nil
        })
    }

    func testSpatialAccessibilityLabelsAreDistinctAndOnlyRealActionsActivate() {
        let registry = AssetRegistry()
        let lobby = registry.accessibilityContracts(for: .academyLobby)
        let rings = registry.accessibilityContracts(for: .chainOfSurvivalVolume)
        let gallery = registry.accessibilityContracts(for: .achievementGallery)
        let cpr = registry.accessibilityContracts(for: .cprPracticeRoom)
        let aedPlacement = registry.accessibilityContracts(for: .aedPlacementRoom)
        let scenario = registry.accessibilityContracts(for: .scenarioHome)

        let portals = lobby.filter { $0.name.hasPrefix("portal_m") }
        XCTAssertEqual(Set(portals.map(\.label)).count, portals.count)
        XCTAssertTrue(portals.allSatisfy { !$0.isActionable })

        XCTAssertEqual(Set(rings.map(\.label)).count, 7)
        XCTAssertTrue(rings.allSatisfy(\.isActionable))

        let badges = gallery.filter { $0.name.hasPrefix("badge_m") }
        XCTAssertEqual(Set(badges.map(\.label)).count, 14)
        XCTAssertTrue(badges.allSatisfy { !$0.isActionable })

        XCTAssertEqual(
            Set(cpr.filter(\.isActionable).map(\.name)),
            ["sternum_target", "xiphoid_avoid_zone", "control_panel"]
        )
        XCTAssertEqual(
            Set(aedPlacement.filter(\.isActionable).map(\.name)),
            ["aed_shock_button", "bystander_01", "bystander_02", "clear_zone"]
        )
        XCTAssertEqual(
            Set(scenario.filter(\.isActionable).map(\.name)),
            [
                "training_manikin", "bystander_01", "bystander_02",
                "sternum_target", "xiphoid_avoid_zone",
                "aed_right_pad_zone", "aed_left_pad_zone", "aed_case", "aed_unit",
                "aed_power_button", "aed_shock_button", "aed_status_light", "aed_connector",
                "aed_left_pad", "aed_right_pad", "clear_zone"
            ]
        )
        XCTAssertTrue(registry.aedTrainerAccessibilityContracts().allSatisfy(\.isActionable))
    }

    /// Operator spec (2026-08-10): the pads are the size of the body guide's painted
    /// sections (~0.085 × 0.135 m), coloured by side — the casualty's LEFT pad blue,
    /// the RIGHT pad orange — matching the guide's blue and orange sections. The
    /// authored asset is the source of colour and size, so this loads it and measures.
    func testAEDPadsMatchTheGuideSectionFootprint() async throws {
        let registry = AssetRegistry()
        let root = try await registry.loadEntity(named: "AEDTrainer")

        for padName in ["aed_pad_left", "aed_pad_right"] {
            let pad = try XCTUnwrap(registry.firstEntity(named: padName, in: root))
            // Relative to the parent so the pad's own scale op is included; relative to
            // the pad itself the cube reads as its unscaled unit size.
            let extents = pad.visualBounds(
                recursive: true,
                relativeTo: try XCTUnwrap(pad.parent)
            ).extents
            XCTAssertEqual(extents.x, 0.085, accuracy: 0.002, "\(padName) width")
            XCTAssertEqual(extents.z, 0.135, accuracy: 0.002, "\(padName) length")
            XCTAssertLessThan(extents.y, 0.02, "\(padName) stays a thin electrode pad")
        }
    }

    func testStandaloneAEDTrainerDecoratesWithoutAManikinRoom() async throws {
        let registry = AssetRegistry()
        let root = try await registry.loadEntity(named: "AEDTrainer")
        let decorated = try registry.decorateAEDTrainerEntities(in: root)

        XCTAssertEqual(decorated, registry.aedTrainerEntityNames())
        let contracts = Dictionary(uniqueKeysWithValues:
            registry.aedTrainerAccessibilityContracts().map { ($0.name, $0) }
        )
        for name in decorated {
            let entity = try XCTUnwrap(registry.firstEntity(named: name, in: root))
            XCTAssertNotNil(entity.components[InputTargetComponent.self])
            XCTAssertNotNil(entity.components[CollisionComponent.self])
            XCTAssertNotNil(entity.components[HoverEffectComponent.self])
            let accessibility = try XCTUnwrap(entity.components[AccessibilityComponent.self])
            XCTAssertTrue(contracts[name]?.isActionable == true)
            XCTAssertEqual(accessibility.systemActions, .activate)
            XCTAssertEqual(accessibility.customContent.count, 2)
        }
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
