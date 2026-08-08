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
    case manifestUnavailable(diagnostic: String)
    case compositionAnchorMissing(scene: String, name: String)
    case semanticEntityMissing(scene: String, name: String)

    var errorDescription: String? {
        switch self {
        case let .resourceUnavailable(name, _):
            return "The spatial resource \"\(name)\" is unavailable. You can leave this space safely and try again."
        case .manifestUnavailable:
            return "The spatial asset manifest is unavailable. You can leave this space safely and try again."
        case let .compositionAnchorMissing(scene, name):
            return "The spatial scene \"\(scene)\" is missing its required composition anchor \"\(name)\"."
        case let .semanticEntityMissing(scene, name):
            return "The spatial scene \"\(scene)\" is missing its required \"\(name)\" training target."
        }
    }
}

struct SpatialAssetPlacement: Decodable, Equatable, Sendable {
    let anchorName: String
    let resourceName: String
    let semanticName: String
}

struct SpatialEntityAccessibilityContract: Equatable, Sendable {
    let name: String
    let label: String
    let actionHint: String?

    var isActionable: Bool { actionHint != nil }
}

private struct SpatialAssetManifest: Decodable, Sendable {
    struct Scene: Decodable, Sendable {
        let sceneName: String
        let placements: [SpatialAssetPlacement]
    }

    let schemaVersion: Int
    let bundleSubdirectory: String
    let resources: [String]
    let scenes: [Scene]
}

/// Loads package content and adds safe interaction affordances to authored semantic targets.
@MainActor
final class AssetRegistry {
    typealias EntityLoader = @MainActor @Sendable (String, Bundle) async throws -> Entity
    typealias LooseEntityLoader = @MainActor @Sendable (URL) async throws -> Entity

    private enum CollisionProxy {
        case box
        case capsule
    }

    private struct SemanticDescriptor {
        let name: String
        let label: LocalizedStringResource
        let description: LocalizedStringResource
        let collisionProxy: CollisionProxy
        let activationHint: LocalizedStringResource?

        init(
            name: String,
            label: LocalizedStringResource,
            description: LocalizedStringResource,
            collisionProxy: CollisionProxy,
            activationHint: LocalizedStringResource? = nil
        ) {
            self.name = name
            self.label = label
            self.description = description
            self.collisionProxy = collisionProxy
            self.activationHint = activationHint
        }
    }

    private let sceneBundle: Bundle
    private let assetBundle: Bundle
    private let entityLoader: EntityLoader
    private let looseEntityLoader: LooseEntityLoader
    private var cachedManifest: SpatialAssetManifest?
    private var cachedScenes: [SpatialSceneName: Entity] = [:]

    /// The active semantic-slot mapping for practice assets. Swapping in a new
    /// manikin/defibrillator/patch set replaces this descriptor; resolution of grid,
    /// targets, and grabbable items flows through it rather than name literals.
    var practiceAssetDescriptor: PracticeAssetDescriptor = .placeholderDescriptor

    init(
        bundle: Bundle = realityKitContentBundle,
        assetBundle: Bundle = .main,
        loader: EntityLoader? = nil,
        looseLoader: LooseEntityLoader? = nil
    ) {
        sceneBundle = bundle
        self.assetBundle = assetBundle
        entityLoader = loader ?? { name, bundle in
            try await Entity(named: name, in: bundle)
        }
        looseEntityLoader = looseLoader ?? { url in
            try await Entity(contentsOf: url)
        }
    }

    var compiledArchiveURL: URL? {
        sceneBundle.url(forResource: "RealityKitContent", withExtension: "reality")
    }

    func loadScene(_ scene: SpatialSceneName) async throws -> Entity {
        if let cachedScene = cachedScenes[scene] {
            return cachedScene
        }

        let entity = try await loadEntity(named: scene.rawValue)
        entity.name = scene.rawValue
        do {
            try await composeLooseAssets(in: entity, for: scene)
        } catch {
            entity.removeFromParent()
            throw error
        }
        cachedScenes[scene] = entity
        return entity
    }

    func loadEntity(named name: String) async throws -> Entity {
        do {
            return try await entityLoader(name, sceneBundle)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw AssetRegistryError.resourceUnavailable(
                name: name,
                diagnostic: String(describing: error)
            )
        }
    }

    func loadLooseAsset(named name: String) async throws -> Entity {
        let url = try looseAssetURL(named: name)
        do {
            return try await looseEntityLoader(url)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw AssetRegistryError.resourceUnavailable(
                name: name,
                diagnostic: String(describing: error)
            )
        }
    }

    func deliveryAssetNames() throws -> [String] {
        try manifest().resources
    }

    func placementContracts(for scene: SpatialSceneName) throws -> [SpatialAssetPlacement] {
        let loadedManifest = try manifest()
        guard let sceneManifest = loadedManifest.scenes.first(where: {
            $0.sceneName == scene.rawValue
        }) else {
            throw AssetRegistryError.manifestUnavailable(
                diagnostic: "No placement entry for \(scene.rawValue)"
            )
        }
        return sceneManifest.placements
    }

    func isSceneCached(_ scene: SpatialSceneName) -> Bool {
        cachedScenes[scene] != nil
    }

    func releaseScene(_ scene: SpatialSceneName) {
        cachedScenes.removeValue(forKey: scene)?.removeFromParent()
    }

    func releaseAllScenes() {
        for scene in cachedScenes.values {
            scene.removeFromParent()
        }
        cachedScenes.removeAll(keepingCapacity: false)
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

    func accessibilityContracts(
        for scene: SpatialSceneName
    ) -> [SpatialEntityAccessibilityContract] {
        Self.descriptors(for: scene).map(Self.accessibilityContract)
    }

    /// Decorates the independently loadable AED trainer without requiring a manikin room.
    /// The laboratory uses the same controls and preparation props as the immersive AED rooms.
    @discardableResult
    func decorateAEDTrainerEntities(in root: Entity) throws -> [String] {
        let descriptors = Self.enablingActivationForAll(
            Self.aedControls + Self.preparationProps,
            action: "Select this component in the AED explorer."
        )
        let resolved = try descriptors.map { descriptor in
            guard let entity = firstEntity(named: descriptor.name, in: root) else {
                throw AssetRegistryError.semanticEntityMissing(
                    scene: "AEDTrainer",
                    name: descriptor.name
                )
            }
            return (descriptor, entity)
        }

        for (descriptor, entity) in resolved {
            decorate(entity, with: descriptor)
        }
        return resolved.map { $0.0.name }
    }

    func aedTrainerEntityNames() -> [String] {
        (Self.aedControls + Self.preparationProps).map(\.name)
    }

    func aedTrainerAccessibilityContracts() -> [SpatialEntityAccessibilityContract] {
        Self.enablingActivationForAll(
            Self.aedControls + Self.preparationProps,
            action: "Select this component in the AED explorer."
        ).map(Self.accessibilityContract)
    }

    private func looseAssetURL(named name: String) throws -> URL {
        let loadedManifest = try manifest()
        guard loadedManifest.resources.contains(name) else {
            throw AssetRegistryError.resourceUnavailable(
                name: name,
                diagnostic: "Resource is not declared in spatial_asset_manifest_v1.json"
            )
        }
        guard let url = assetBundle.url(
            forResource: name,
            withExtension: "usdz",
            subdirectory: loadedManifest.bundleSubdirectory
        ) else {
            throw AssetRegistryError.resourceUnavailable(
                name: name,
                diagnostic: "Missing loose bundle resource USDZ/\(name).usdz"
            )
        }
        return url
    }

    private func manifest() throws -> SpatialAssetManifest {
        if let cachedManifest {
            return cachedManifest
        }

        guard let url = assetBundle.url(
            forResource: "spatial_asset_manifest_v1",
            withExtension: "json"
        ) else {
            throw AssetRegistryError.manifestUnavailable(
                diagnostic: "spatial_asset_manifest_v1.json is missing from the app bundle"
            )
        }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(SpatialAssetManifest.self, from: data)
            guard decoded.schemaVersion == 1 else {
                throw AssetRegistryError.manifestUnavailable(
                    diagnostic: "Unsupported schema version \(decoded.schemaVersion)"
                )
            }
            cachedManifest = decoded
            return decoded
        } catch let registryError as AssetRegistryError {
            throw registryError
        } catch {
            throw AssetRegistryError.manifestUnavailable(
                diagnostic: String(describing: error)
            )
        }
    }

    private func composeLooseAssets(in root: Entity, for scene: SpatialSceneName) async throws {
        let placements = try placementContracts(for: scene)
        var prototypes: [String: Entity] = [:]

        for placement in placements {
            guard let anchor = firstEntity(named: placement.anchorName, in: root) else {
                throw AssetRegistryError.compositionAnchorMissing(
                    scene: scene.rawValue,
                    name: placement.anchorName
                )
            }

            let prototype: Entity
            if let cachedPrototype = prototypes[placement.resourceName] {
                prototype = cachedPrototype
            } else {
                let loadedPrototype = try await loadLooseAsset(named: placement.resourceName)
                prototypes[placement.resourceName] = loadedPrototype
                prototype = loadedPrototype
            }

            let payload = prototype.clone(recursive: true)
            payload.name = placement.semanticName
            anchor.addChild(payload)
        }
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
        accessibility.value = descriptor.activationHint == nil
            ? "Spatial learning object"
            : "Interactive spatial control"
        var customContent = [
            AccessibilityComponent.CustomContent(
                label: "Description",
                value: descriptor.description,
                importance: .default
            )
        ]
        if let activationHint = descriptor.activationHint {
            accessibility.systemActions = .activate
            customContent.append(
                AccessibilityComponent.CustomContent(
                    label: "Action",
                    value: activationHint,
                    importance: .high
                )
            )
        }
        accessibility.customContent = customContent
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
            name: "aed_case",
            label: "AED trainer case",
            description: "Brand-neutral carrying case for the simulated AED trainer.",
            collisionProxy: .box
        ),
        .init(
            name: "aed_unit",
            label: "AED trainer unit",
            description: "Brand-neutral, non-functional AED unit for practice.",
            collisionProxy: .box
        ),
        .init(
            name: "aed_power_button",
            label: "AED power button",
            description: "Training-only power control on the brand-neutral AED trainer.",
            collisionProxy: .capsule
        ),
        .init(
            name: "aed_shock_button",
            label: "Simulated AED shock control",
            description: "Training-only control. It cannot deliver an electrical shock and remains safety-gated by the interactive clear check.",
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

    private static func enablingActivation(
        _ descriptors: [SemanticDescriptor],
        actionsByName: [String: String]
    ) -> [SemanticDescriptor] {
        descriptors.map { descriptor in
            guard let action = actionsByName[descriptor.name] else { return descriptor }
            return SemanticDescriptor(
                name: descriptor.name,
                label: descriptor.label,
                description: descriptor.description,
                collisionProxy: descriptor.collisionProxy,
                activationHint: LocalizedStringResource(stringLiteral: action)
            )
        }
    }

    private static func enablingActivationForAll(
        _ descriptors: [SemanticDescriptor],
        action: String
    ) -> [SemanticDescriptor] {
        enablingActivation(
            descriptors,
            actionsByName: Dictionary(
                uniqueKeysWithValues: descriptors.map { ($0.name, action) }
            )
        )
    }

    private static func accessibilityContract(
        _ descriptor: SemanticDescriptor
    ) -> SpatialEntityAccessibilityContract {
        SpatialEntityAccessibilityContract(
            name: descriptor.name,
            label: String(localized: descriptor.label),
            actionHint: descriptor.activationHint.map { String(localized: $0) }
        )
    }

    private static func descriptors(for scene: SpatialSceneName) -> [SemanticDescriptor] {
        switch scene {
        case .academyLobby:
            return (1...11).map { index in
                SemanticDescriptor(
                    name: String(format: "portal_m%02d", index),
                    label: "Module \(index) portal",
                    description: "Spatial marker for Lifesaver Vision module \(index).",
                    collisionProxy: .box
                )
            } + [
                .init(name: "companion_orb_bot", label: "Academy guide", description: "Calm spatial guide and narration anchor.", collisionProxy: .capsule),
                .init(name: "control_panel", label: "Academy control panel", description: "Shared-space academy controls.", collisionProxy: .box)
            ]
        case .heartAndLungsVolume:
            return enablingActivation([
                .init(name: "heart_model", label: "Heart model", description: "Stylised, non-graphic heart learning model.", collisionProxy: .capsule),
                .init(name: "heart_ra", label: "Right atrium", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "heart_rv", label: "Right ventricle", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "heart_la", label: "Left atrium", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "heart_lv", label: "Left ventricle", description: "Selectable chamber in the stylised heart model.", collisionProxy: .capsule),
                .init(name: "lungs_model", label: "Lungs model", description: "Stylised, non-graphic lungs learning model.", collisionProxy: .box),
                .init(name: "lungs_left", label: "Left lung", description: "Selectable left lung in the stylised model.", collisionProxy: .capsule),
                .init(name: "lungs_right", label: "Right lung", description: "Selectable right lung in the stylised model.", collisionProxy: .capsule)
            ], actionsByName: [
                "heart_ra": "Select the right atrium orientation label.",
                "heart_rv": "Select the right ventricle orientation label.",
                "heart_la": "Select the left atrium orientation label.",
                "heart_lv": "Select the left ventricle orientation label.",
                "lungs_left": "Select the left lung orientation label.",
                "lungs_right": "Select the right lung orientation label."
            ])
        case .chainOfSurvivalVolume:
            return enablingActivationForAll((1...7).map { index in
                SemanticDescriptor(
                    name: "chain_ring_\(index)",
                    label: "Chain of Survival ring \(index)",
                    description: "Review-gated ring \(index) in the unscored Chain of Survival activity.",
                    collisionProxy: .capsule
                )
            }, action: "Select or move this ring in the unscored ordering activity.")
        case .drsabcTrainingRoom:
            return enablingActivation(manikinTargets + [
                .init(name: "safety_hazards", label: "Scene hazards", description: "Training hazards for the danger-check step.", collisionProxy: .box),
                .init(name: "bystander_01", label: "Bystander", description: "Abstract, non-graphic training bystander.", collisionProxy: .capsule)
            ], actionsByName: [
                "safety_hazards": "Inspect the training scene for danger.",
                "training_manikin": "Check the training manikin for responsiveness.",
                "bystander_01": "Activate help through the training bystander."
            ])
        case .cprPracticeRoom:
            return enablingActivation(manikinTargets + clearZone + [
                .init(name: "control_panel", label: "Practice control panel", description: "Controls for the CPR practice session.", collisionProxy: .box)
            ], actionsByName: [
                "sternum_target": "Select the hand-placement practice target.",
                "xiphoid_avoid_zone": "Report the avoidance-area selection for guided correction.",
                "control_panel": "Record an accessible fallback compression."
            ])
        case .aedPreparationRoom:
            return enablingActivation(
                manikinTargets + aedControls + preparationProps,
                actionsByName: [
                    "training_razor": "Complete the presented training-razor preparation action.",
                    "prep_cloth": "Complete the presented drying-cloth preparation action."
                ]
            )
        case .aedPlacementRoom:
            return enablingActivation(
                manikinTargets + padPlacementTargets + aedControls + scenarioPeople + clearZone,
                actionsByName: [
                    "aed_shock_button": "Activate the simulated shock control when the clear check permits it.",
                    "bystander_01": "Confirm that bystander one is clear.",
                    "bystander_02": "Confirm that bystander two is clear.",
                    "clear_zone": "Activate the visual clear-zone sweep."
                ]
            )
        case .scenarioHome, .scenarioShoppingCentre, .scenarioWorkplace, .scenarioCommunityFacility:
            return enablingActivation(
                manikinTargets + padPlacementTargets + aedControls + scenarioPeople + clearZone,
                actionsByName: [
                    "training_manikin": "Check the training manikin for responsiveness when prompted.",
                    "bystander_01": "Assign the selected simulated task to bystander one.",
                    "bystander_02": "Assign the selected simulated task to bystander two.",
                    "sternum_target": "Perform the current simulated CPR action at the placement target.",
                    "xiphoid_avoid_zone": "Report the unsafe placement selection for immediate guided correction.",
                    "aed_case": "Complete the current simulated AED preparation step when prompted.",
                    "aed_unit": "Continue the current simulated AED trainer prompt.",
                    "aed_power_button": "Switch on and prepare the simulated AED when prompted.",
                    "aed_shock_button": "Deliver the simulated shock only after the clear check permits it.",
                    "aed_status_light": "Continue the current simulated AED trainer prompt.",
                    "aed_connector": "Complete simulated AED preparation and pad application when prompted.",
                    "aed_left_pad": "Complete simulated pad application when prompted.",
                    "aed_right_pad": "Complete simulated pad application when prompted.",
                    "aed_left_pad_zone": "Complete simulated pad application when prompted.",
                    "aed_right_pad_zone": "Complete simulated pad application when prompted.",
                    "clear_zone": "Confirm the current simulated AED clear check when prompted."
                ]
            )
        case .achievementGallery:
            let badges = (1...14).map { index in
                SemanticDescriptor(
                    name: String(format: "badge_m%02d", index),
                    label: "Module \(index) internal achievement badge",
                    description: "Internal module \(index) learning achievement; not an SRFAC certification.",
                    collisionProxy: .capsule
                )
            }
            let stars = (1...7).map { index in
                SemanticDescriptor(
                    name: String(format: "constellation_star_%02d", index),
                    label: "Mastery constellation star \(index)",
                    description: "A visual marker in the internal learning mastery map.",
                    collisionProxy: .capsule
                )
            }
            return badges + stars + [
                .init(name: "certificate_pedestal", label: "Completion record pedestal", description: "Displays an internal completion record requiring instructor sign-off; it is not SRFAC certification.", collisionProxy: .box),
                .init(name: "xp_orb", label: "Learning progress orb", description: "Visualises internal learning progress.", collisionProxy: .capsule)
            ]
        case .debriefSpace:
            // Restart and dashboard return are distinct labelled attachment buttons.
            // The decorative panel has no single safe activation, so it must not hover.
            return []
        }
    }
}
