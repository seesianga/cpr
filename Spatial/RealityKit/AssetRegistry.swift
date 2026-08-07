import Foundation
import RealityKit
import RealityKitContent

/// The independently loadable Reality Composer Pro scene layers shipped by the app.
enum SpatialSceneName: String, CaseIterable, Identifiable, Sendable {
    case academyLobby = "AcademyLobby"
    case heartAndLungsVolume = "HeartAndLungsVolume"
    case chainOfSurvivalVolume = "ChainOfSurvivalVolume"
    case drsabcTrainingRoom = "DRSABCTrainingRoom"
    case cprPracticeRoom = "CPRPracticeRoom"
    case aedPreparationRoom = "AEDPreparationRoom"
    case aedPlacementRoom = "AEDPlacementRoom"
    case scenarioHome = "Scenario_Home"
    case scenarioShoppingCentre = "Scenario_ShoppingCentre"
    case scenarioWorkplace = "Scenario_Workplace"
    case scenarioCommunityFacility = "Scenario_CommunityFacility"
    case achievementGallery = "AchievementGallery"
    case debriefSpace = "DebriefSpace"

    var id: String { rawValue }
}

enum AssetRegistryError: Error, Equatable, LocalizedError {
    case resourceUnavailable(name: String, diagnostic: String)
    case semanticEntityMissing(scene: String, name: String)

    var errorDescription: String? {
        switch self {
        case let .resourceUnavailable(name, _):
            return "The spatial resource \"\(name)\" is unavailable. You can leave this space safely and try again."
        case let .semanticEntityMissing(scene, name):
            return "The spatial scene \"\(scene)\" is missing its required \"\(name)\" training target."
        }
    }
}

/// Loads package content and adds safe interaction affordances to authored semantic targets.
@MainActor
final class AssetRegistry {
    typealias EntityLoader = @MainActor @Sendable (String, Bundle) async throws -> Entity

    private enum CollisionProxy {
        case box
        case capsule
    }

    private struct SemanticDescriptor {
        let name: String
        let label: LocalizedStringResource
        let description: LocalizedStringResource
        let collisionProxy: CollisionProxy
    }

    private let bundle: Bundle
    private let entityLoader: EntityLoader

    init(
        bundle: Bundle = realityKitContentBundle,
        loader: EntityLoader? = nil
    ) {
        self.bundle = bundle
        entityLoader = loader ?? { name, bundle in
            try await Entity(named: name, in: bundle)
        }
    }

    var compiledArchiveURL: URL? {
        bundle.url(forResource: "RealityKitContent", withExtension: "reality")
    }

    func loadScene(_ scene: SpatialSceneName) async throws -> Entity {
        let entity = try await loadEntity(named: scene.rawValue)
        entity.name = scene.rawValue
        return entity
    }

    func loadEntity(named name: String) async throws -> Entity {
        do {
            return try await entityLoader(name, bundle)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw AssetRegistryError.resourceUnavailable(
                name: name,
                diagnostic: String(describing: error)
            )
        }
    }

    func firstEntity(named name: String, in root: Entity) -> Entity? {
        if root.name == name {
            return root
        }

        for child in root.children {
            if let match = firstEntity(named: name, in: child) {
                return match
            }
        }
        return nil
    }

    func entities(named name: String, in root: Entity) -> [Entity] {
        var matches: [Entity] = root.name == name ? [root] : []
        for child in root.children {
            matches.append(contentsOf: entities(named: name, in: child))
        }
        return matches
    }

    func requiredEntity(named name: String, in root: Entity, scene: SpatialSceneName) throws -> Entity {
        guard let entity = firstEntity(named: name, in: root) else {
            throw AssetRegistryError.semanticEntityMissing(scene: scene.rawValue, name: name)
        }
        return entity
    }

    /// Validates every target before applying components, avoiding a partially interactive clinical scene.
    @discardableResult
    func decorateSemanticEntities(in root: Entity, for scene: SpatialSceneName) throws -> [String] {
        let descriptors = Self.descriptors(for: scene)
        let resolved = try descriptors.map { descriptor in
            (
                descriptor,
                try requiredEntity(named: descriptor.name, in: root, scene: scene)
            )
        }

        for (descriptor, entity) in resolved {
            decorate(entity, with: descriptor)
        }
        return resolved.map { $0.0.name }
    }

    func semanticEntityNames(for scene: SpatialSceneName) -> [String] {
        Self.descriptors(for: scene).map(\.name)
    }

    private func decorate(_ entity: Entity, with descriptor: SemanticDescriptor) {
        let bounds = entity.visualBounds(recursive: true, relativeTo: entity)
        let center = bounds.isEmpty ? SIMD3<Float>.zero : bounds.center
        let rawSize = bounds.isEmpty ? SIMD3<Float>(repeating: 0.04) : bounds.extents
        let size = SIMD3<Float>(
            max(rawSize.x, 0.04),
            max(rawSize.y, 0.04),
            max(rawSize.z, 0.04)
        )

        let shape: ShapeResource
        switch descriptor.collisionProxy {
        case .box:
            shape = ShapeResource.generateBox(size: size)
                .offsetBy(translation: center)
        case .capsule:
            let radius = max(min(size.x, size.z) * 0.5, 0.02)
            let height = max(size.y, radius * 2)
            shape = ShapeResource.generateCapsule(height: height, radius: radius)
                .offsetBy(translation: center)
        }

        entity.components.set(InputTargetComponent(allowedInputTypes: .all))
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(HoverEffectComponent())

        var accessibility = AccessibilityComponent()
        accessibility.isAccessibilityElement = true
        accessibility.label = descriptor.label
        accessibility.customContent = [
            AccessibilityComponent.CustomContent(
                label: "Description",
                value: descriptor.description,
                importance: .default
            )
        ]
        entity.components.set(accessibility)
    }
}

private extension AssetRegistry {
    private static let manikinTargets: [SemanticDescriptor] = [
        .init(
            name: "training_manikin",
            label: "Training manikin",
            description: "A non-graphic practice manikin used for internal skills learning.",
            collisionProxy: .box
        ),
        .init(
            name: "sternum_target",
            label: "Lower-half sternum target",
            description: "Hand-placement practice target. Physical compression depth and force are not assessed.",
            collisionProxy: .box
        ),
        .init(
            name: "xiphoid_avoid_zone",
            label: "Xiphoid avoidance area",
            description: "A visual area to avoid during hand-placement practice.",
            collisionProxy: .capsule
        )
    ]

    private static let padPlacementTargets: [SemanticDescriptor] = [
        .init(
            name: "aed_right_pad_zone",
            label: "Right AED pad zone",
            description: "Practice zone on the casualty's right chest below the right collarbone.",
            collisionProxy: .box
        ),
        .init(
            name: "aed_left_pad_zone",
            label: "Left AED pad zone",
            description: "Practice zone on the casualty's left chest below and lateral to the left nipple.",
            collisionProxy: .box
        )
    ]

    private static let aedControls: [SemanticDescriptor] = [
        .init(
            name: "aed_power_button",
            label: "AED power button",
            description: "Training-only power control on the brand-neutral AED trainer.",
            collisionProxy: .capsule
        ),
        .init(
            name: "aed_status_light",
            label: "AED status light",
            description: "Training-only status indicator.",
            collisionProxy: .capsule
        ),
        .init(
            name: "aed_connector",
            label: "AED pad connector",
            description: "Training connector for the electrode pads.",
            collisionProxy: .box
        ),
        .init(
            name: "aed_left_pad",
            label: "Left AED training pad",
            description: "Brand-neutral electrode pad for placement practice.",
            collisionProxy: .box
        ),
        .init(
            name: "aed_right_pad",
            label: "Right AED training pad",
            description: "Brand-neutral electrode pad for placement practice.",
            collisionProxy: .box
        )
    ]

    private static let preparationProps: [SemanticDescriptor] = [
        .init(name: "electrode_packet", label: "Electrode packet", description: "Training packet containing simulated AED pads.", collisionProxy: .box),
        .init(name: "prep_cloth", label: "Preparation cloth", description: "Training prop for chest preparation practice.", collisionProxy: .box),
        .init(name: "training_scissors", label: "Training scissors", description: "Blunt simulated preparation scissors.", collisionProxy: .box),
        .init(name: "training_razor", label: "Training razor", description: "Non-functional simulated preparation razor.", collisionProxy: .box),
        .init(name: "glove_box", label: "Glove box", description: "Training personal-protective-equipment prop.", collisionProxy: .box)
    ]

    private static let scenarioPeople: [SemanticDescriptor] = [
        .init(name: "bystander_01", label: "Bystander one", description: "Abstract, non-graphic scenario bystander.", collisionProxy: .capsule),
        .init(name: "bystander_02", label: "Bystander two", description: "Abstract, non-graphic scenario bystander.", collisionProxy: .capsule)
    ]

    private static let clearZone: [SemanticDescriptor] = [
        .init(name: "clear_zone", label: "Clear zone", description: "Practice boundary used during the simulated AED sequence.", collisionProxy: .box)
    ]

    private static func descriptors(for scene: SpatialSceneName) -> [SemanticDescriptor] {
        switch scene {
        case .academyLobby:
            return (1...11).map { index in
                SemanticDescriptor(
                    name: String(format: "portal_m%02d", index),
                    label: "Learning module portal",
                    description: "Opens a Lifesaver Vision learning module.",
                    collisionProxy: .box
                )
            } + [
                .init(name: "companion_orb_bot", label: "Academy guide", description: "Calm spatial guide and narration anchor.", collisionProxy: .capsule),
                .init(name: "control_panel", label: "Academy control panel", description: "Shared-space academy controls.", collisionProxy: .box)
            ]
        case .heartAndLungsVolume:
            return [
                .init(name: "heart_model", label: "Heart model", description: "Stylised, non-graphic heart learning model.", collisionProxy: .capsule),
                .init(name: "heart_ra", label: "Right atrium", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "heart_rv", label: "Right ventricle", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "heart_la", label: "Left atrium", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "heart_lv", label: "Left ventricle", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "lungs_model", label: "Lungs model", description: "Stylised, non-graphic lungs learning model.", collisionProxy: .box),
                .init(name: "lungs_left", label: "Left lung", description: "Selectable left lung in the stylised model.", collisionProxy: .capsule),
                .init(name: "lungs_right", label: "Right lung", description: "Selectable right lung in the stylised model.", collisionProxy: .capsule)
            ]
        case .chainOfSurvivalVolume:
            return (1...7).map { index in
                SemanticDescriptor(
                    name: "chain_ring_\(index)",
                    label: "Chain of Survival step",
                    description: "Placeholder for an SME-reviewed Chain of Survival learning step.",
                    collisionProxy: .capsule
                )
            }
        case .drsabcTrainingRoom:
            return manikinTargets + [
                .init(name: "safety_hazards", label: "Scene hazards", description: "Training hazards for the danger-check step.", collisionProxy: .box),
                .init(name: "bystander_01", label: "Bystander", description: "Abstract, non-graphic training bystander.", collisionProxy: .capsule)
            ]
        case .cprPracticeRoom:
            return manikinTargets + clearZone + [
                .init(name: "control_panel", label: "Practice control panel", description: "Controls for the CPR practice session.", collisionProxy: .box)
            ]
        case .aedPreparationRoom:
            return manikinTargets + aedControls + preparationProps
        case .aedPlacementRoom:
            return manikinTargets + padPlacementTargets + aedControls + clearZone
        case .scenarioHome, .scenarioShoppingCentre, .scenarioWorkplace, .scenarioCommunityFacility:
            return manikinTargets + padPlacementTargets + aedControls + scenarioPeople + clearZone
        case .achievementGallery:
            let badges = (1...14).map { index in
                SemanticDescriptor(
                    name: String(format: "badge_m%02d", index),
                    label: "Internal achievement badge",
                    description: "An internal learning achievement, not an SRFAC certification.",
                    collisionProxy: .capsule
                )
            }
            let stars = (1...7).map { index in
                SemanticDescriptor(
                    name: String(format: "constellation_star_%02d", index),
                    label: "Mastery constellation star",
                    description: "A visual marker in the internal learning mastery map.",
                    collisionProxy: .capsule
                )
            }
            return badges + stars + [
                .init(name: "certificate_pedestal", label: "Completion record pedestal", description: "Displays an internal completion record requiring instructor sign-off; it is not SRFAC certification.", collisionProxy: .box),
                .init(name: "xp_orb", label: "Learning progress orb", description: "Visualises internal learning progress.", collisionProxy: .capsule)
            ]
        case .debriefSpace:
            return [
                .init(name: "control_panel", label: "Debrief control panel", description: "Controls for reviewing and leaving the debrief.", collisionProxy: .box)
            ]
        }
    }
}
