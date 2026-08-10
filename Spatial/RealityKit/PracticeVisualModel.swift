import Foundation
import RealityKit

enum PracticeVisualModelError: Error, Sendable, Equatable {
    case resourceMissing(name: String)
    case loadFailed(name: String, diagnostic: String)

    var errorDescription: String {
        switch self {
        case let .resourceMissing(name):
            "Missing bundled model Reality/\(name).reality."
        case let .loadFailed(name, diagnostic):
            "The model \(name).reality could not be loaded: \(diagnostic)"
        }
    }
}

/// A model authored in Reality Composer Pro 3 and exported as a compiled `.reality`
/// archive.
///
/// The archive is encrypted and cannot be edited on disk, so its authored entity names
/// are remapped after loading rather than in the source asset.
///
/// These models are VISUAL ONLY. The authored `TrainingManikin.usda` / `AEDTrainer.usda`
/// skeletons remain the single source of truth for every detection target, so the
/// mapping below deliberately renames into a separate `*_visual_*` namespace. Renaming
/// an exported mesh onto a semantic name such as `sternum_target` would both collide
/// with the authored entity that already owns it and silently move a clinically
/// meaningful zone onto un-surveyed geometry.
enum PracticeVisualModel: String, CaseIterable, Sendable {
    case human = "Human"
    case aed = "AED"

    /// Bundle subdirectory written by the `Media/3D/Reality` copy-files phase.
    static let bundleSubdirectory = "Reality"
    static let fileExtension = "reality"

    var resourceName: String { rawValue }

    /// Name given to the loaded root once it is attached to the authored skeleton.
    var semanticRootName: String {
        switch self {
        case .human: "human_visual_model"
        case .aed: "aed_visual_model"
        }
    }

    /// Scene entities removed from the demo by operator decision (2026-08-10), judged
    /// from a photograph of the live AED preparation table: keep the imported yellow
    /// unit, the two gold grabbable pads and the blue electrode packet — hide the rest
    /// of the authored kit, plus the import's own patch visuals, which duplicate the
    /// gold pads without being grabbable.
    ///
    /// Hidden by opacity like every other visibility decision here, so bounds survive,
    /// and tied to the same "Hide placeholder body" switch for developer inspection.
    /// Their input and collision components are stripped when hidden and NOT restored
    /// by the switch: an invisible shock button that still takes gaze-pinch would fire
    /// from a stray pinch at the visible unit it sits on. Every step these props served
    /// keeps its labelled control in the practice panel, so no session state becomes
    /// unreachable.
    var operatorHiddenEntityNames: [String] {
        switch self {
        case .human: return []
        case .aed: return [
            // The authored unit's controls — the panel's labelled buttons carry these.
            "aed_power_button", "aed_shock_button", "aed_status_light", "aed_connector",
            // Preparation kit props — panel buttons complete the same steps.
            "training_razor", "training_scissors", "prep_cloth", "glove_box",
            // The clear-zone ring — "Activate clear-zone ring" remains in the panel.
            "clear_zone",
            // The import's own patch visuals: decoration that mimics the grabbable
            // gold pads one hand-width away from them.
            "aed_visual_left_pad", "aed_visual_right_pad"
        ]
        }
    }

    /// Entity whose measured bounds proportional sizing is taken against, when the
    /// proportion is expressed against a specific part rather than the whole model.
    ///
    /// The AED's chest-width fraction is defined against the unit's face, but the
    /// whole-model bounds also span the laid-out pads and cable run — under the combined
    /// export that nearly doubles the span, which would render the unit at roughly half
    /// the stated fraction. Sizing falls back to whole-model bounds when the named entity
    /// is absent, so an export without the case name still gets a sensible size.
    var sizingProxyEntityName: String? {
        switch self {
        case .human: nil
        case .aed: "aed_visual_case"
        }
    }

    /// This model's authored root INSIDE an export, for exports that carry more than one
    /// model.
    ///
    /// Reality Composer Pro's "export selection" wraps the whole composition in a scene
    /// root (named "Selection"), so a single delivered file can contain the human AND the
    /// AED side by side. Loading that file for one model must take only that model's
    /// subtree — attaching the whole root would hang a second body off the AED mount. A
    /// single-model export's root already carries this name, so it resolves to itself and
    /// loads exactly as before.
    var authoredRootEntityName: String { rawValue }

    /// Entity in the authored skeleton this model hangs beneath.
    var hostEntityName: String {
        switch self {
        case .human: "training_manikin"
        case .aed: "aed_unit"
        }
    }

    /// The shipped placement: what a fresh install shows before anyone touches a control.
    ///
    /// The human's values are not derived — they were tuned by eye in the headset against
    /// the PHYSICAL torso trainer on the demo table (2026-08-10) and read back off the
    /// developer panel. The solver registers against the authored virtual skeleton, which
    /// is not the frame the physical unit occupies, so a metrically "perfect" solve can
    /// still sit visibly wrong on the real chest; these numbers are the configuration that
    /// looked right on it. Roll 180° is still what turns the prone export face-up, and it
    /// combines with yaw 180° here — both must be right BEFORE any fit, because fitting
    /// measures the rotated bounding box.
    ///
    /// Everything remains operator-adjustable in the placement panel; this is only where
    /// the controls start.
    var defaultPlacement: PracticeVisualModelPlacement {
        switch self {
        case .human:
            var placement = PracticeVisualModelPlacement.identity
            placement.offsetMetres = SIMD3<Float>(0.00, 0.19, 0.80)
            placement.rollDegrees = 180
            placement.pitchDegrees = 0
            placement.yawDegrees = 180
            placement.scale = 0.43
            placement.hidesPlaceholder = true
            // Off per the same physical-demo configuration: at this placement the body
            // reads correctly whole, and the crop is one toggle away if it stops doing so.
            placement.cropsToPhysicalEnvelope = false
            return placement
        case .aed:
            // Operator-pinned on 2026-08-10, taken from the device's own placement store
            // rather than from a photo of the panel: a photographed "0.96×" was first
            // misread as "0.06×" and shipped, which rendered the unit at 2.5 cm; the
            // operator stepped the scale back up in the headset (0.060 × 1.1³⁰ — thirty
            // presses), and THAT stored value is what ships. At this scale the case
            // renders ≈43 cm across — real-world AED trainer size. The proportional
            // solve remains one button away if a measured size is ever wanted instead.
            var placement = PracticeVisualModelPlacement.identity
            placement.offsetMetres = SIMD3<Float>(-0.247, 0.047, -0.072)
            placement.rollDegrees = 0
            placement.pitchDegrees = 0
            placement.yawDegrees = 0
            placement.scale = 1.047
            placement.hidesPlaceholder = true
            return placement
        }
    }

    /// Whether the first attach runs the registration solver over the default placement.
    ///
    /// Neither model does, and for the same reason: both defaults are operator-pinned
    /// configurations judged against the PHYSICAL demo scene (2026-08-10), and an
    /// automatic solve would replace them with values that are only right against the
    /// virtual skeleton. "Align to manikin" stays in the panel as the explicit way to
    /// invoke the solver for either model.
    var solvesOnFirstAttach: Bool {
        false
    }

    /// Placeholder geometry this model visually replaces.
    ///
    /// These are hidden with an opacity component rather than disabled: `torso_shell` is
    /// the torso grid's bounds source, and a disabled entity reports no visual bounds,
    /// which would collapse every detection region. Opacity leaves bounds intact.
    ///
    /// The zone markers (`sternum_target`, `xiphoid_avoid_zone`, the pad zones) stay
    /// visible — they are coaching affordances, not placeholder body geometry.
    var replacedPlaceholderEntityNames: [String] {
        switch self {
        case .human: ["torso_shell", "head", "right_arm", "left_arm"]
        // Shells only. The buttons, connector, status light and pads stay visible:
        // they are the entities the AED interaction actually drives.
        case .aed: ["aed_case_shell", "aed_case_handle", "aed_unit_shell"]
        }
    }

    /// Authored markers whose job this model's own guidance geometry has taken over.
    ///
    /// The amber pad-zone slabs were the pad guidance before the body export shipped one.
    /// The export's `human_visual_aed_guide` now marks both pad sites on the body itself,
    /// so the slabs are duplicate coaching that floats above the chest, and two competing
    /// targets is worse guidance than one.
    ///
    /// Only the *surfaces* are listed. Their parent zone Xforms carry the collision and
    /// bounds that pad-drop classification reads, and hiding those would delete pad
    /// detection along with the visuals — so this list is hidden by opacity for the same
    /// reason `torso_shell` is, and the parents are left alone.
    var supersededLegacyEntityNames: [String] {
        switch self {
        case .human: ["aed_right_pad_zone_surface", "aed_left_pad_zone_surface"]
        case .aed: []
        }
    }

    /// Authored Reality Composer Pro name → this project's visual name.
    ///
    /// Every value is namespaced `*_visual_*` on purpose; see the type's note.
    var nameMapping: [String: String] {
        switch self {
        case .human: [
            "Human": "human_visual_model",
            "Human_body": "human_visual_body",
            "Human_clothe": "human_visual_clothing",
            "Tshirts": "human_visual_clothing_top",
            "Pants": "human_visual_clothing_bottom",
            // Confirmed by the asset author as the sternum compression site.
            "Human_detection_area": "human_visual_sternum_site",
            "Human_CPR_guide": "human_visual_cpr_guide",
            // One authored entity covering BOTH pad sites. The app needs them as two
            // separate zones, so this stays a single visual guide until the export is
            // split into a right-clavicle and a left-lateral entity.
            "Human_AED_guide": "human_visual_aed_guide"
        ]
        case .aed: [
            "AED": "aed_visual_model",
            "AED_Defibrilator": "aed_visual_case",
            // Pad sides confirmed by the asset author: blue is the casualty's anatomical
            // LEFT (lower lateral chest), orange the anatomical RIGHT (below the right
            // clavicle). The names encode the side, not the colour, so a future
            // re-colour cannot silently swap two clinically distinct pads.
            "AED_patch_blue": "aed_visual_left_pad",
            "AED_patch_orange": "aed_visual_right_pad",
            "shockbutton_red": "aed_visual_shock_button",
            "startbutton_green": "aed_visual_power_button"
        ]
        }
    }
}

/// Loads and renames the exported Reality Composer Pro models.
enum PracticeVisualModelLoader {
    /// Renames every entity in `root` whose authored name appears in `mapping`.
    ///
    /// Returns the authored names that were NOT recognised, so an exported hierarchy
    /// that has drifted from the mapping reports itself instead of failing silently.
    @discardableResult
    @MainActor
    static func applyNameMapping(
        _ mapping: [String: String],
        to root: Entity
    ) -> [String] {
        var unmapped: [String] = []
        forEachEntity(in: root) { entity in
            guard !entity.name.isEmpty else { return }
            if let semanticName = mapping[entity.name] {
                entity.name = semanticName
            } else if mapping.values.contains(entity.name) == false {
                unmapped.append(entity.name)
            }
        }
        return unmapped
    }

    /// Every non-empty entity name in the hierarchy, depth-first.
    ///
    /// The compiled archive is encrypted, so this is the only way to confirm what a
    /// `.reality` export actually contains.
    @MainActor
    static func entityNames(in root: Entity) -> [String] {
        var names: [String] = []
        forEachEntity(in: root) { entity in
            guard !entity.name.isEmpty else { return }
            names.append(entity.name)
        }
        return names
    }

    @MainActor
    static func url(
        for model: PracticeVisualModel,
        in bundle: Bundle
    ) throws -> URL {
        guard let url = bundle.url(
            forResource: model.resourceName,
            withExtension: PracticeVisualModel.fileExtension,
            subdirectory: PracticeVisualModel.bundleSubdirectory
        ) else {
            throw PracticeVisualModelError.resourceMissing(name: model.resourceName)
        }
        return url
    }

    /// Loads the compiled model and applies its rename map.
    @MainActor
    static func load(
        _ model: PracticeVisualModel,
        from bundle: Bundle = .main
    ) async throws -> Entity {
        let url = try url(for: model, in: bundle)
        let loaded: Entity
        do {
            loaded = try await Entity(contentsOf: url)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw PracticeVisualModelError.loadFailed(
                name: model.resourceName,
                diagnostic: String(describing: error)
            )
        }
        // Take this model's subtree BEFORE the rename map runs — the subtree is found by
        // its authored name, which the mapping is about to rewrite. Detaching drops the
        // rest of a combined export (the other model, the "Selection" wrapper); its
        // authored layout transform is irrelevant because `apply(_:to:)` overwrites the
        // root transform on attach. A root that already carries the authored name resolves
        // to itself, so single-model exports are untouched by this step.
        let entity = firstEntity(named: model.authoredRootEntityName, in: loaded) ?? loaded
        entity.removeFromParent()
        applyNameMapping(model.nameMapping, to: entity)
        makeNonInteractive(entity)
        entity.name = model.semanticRootName
        return entity
    }

    /// Strips input and collision components from an imported model.
    ///
    /// Reality Composer Pro authors these onto entities by default, and once attached
    /// they sit in front of the practice UI and swallow taps — the AED export carries
    /// both, which is enough to make the panel behind it unselectable. These models are
    /// decoration; the authored skeleton owns every interactive entity.
    @MainActor
    static func makeNonInteractive(_ root: Entity) {
        forEachEntity(in: root) { entity in
            entity.components.remove(InputTargetComponent.self)
            entity.components.remove(CollisionComponent.self)
        }
    }

    /// Positions an already-attached model. Safe to call every frame.
    @MainActor
    static func apply(_ placement: PracticeVisualModelPlacement, to entity: Entity) {
        let sanitized = placement.sanitized
        entity.position = sanitized.offsetMetres
        entity.orientation = sanitized.orientation
        entity.scale = SIMD3<Float>(repeating: sanitized.scale)
    }

    /// Shows or hides the placeholder geometry this model replaces.
    @MainActor
    static func applyPlaceholderVisibility(
        for model: PracticeVisualModel,
        isHidden: Bool,
        in scene: Entity
    ) {
        for name in model.replacedPlaceholderEntityNames {
            guard let placeholder = firstEntity(named: name, in: scene) else { continue }
            placeholder.components.set(OpacityComponent(opacity: isHidden ? 0 : 1))
        }
    }

    /// Attaches every model whose host entity exists in `scene`, and returns the ones
    /// attached along with how accurately each landed.
    ///
    /// Scenes are cached and re-added when a room is revisited, so an already-attached
    /// model is repositioned rather than duplicated.
    @discardableResult
    @MainActor
    static func attachModels(
        in scene: Entity,
        placements: PracticeVisualModelPlacementStore,
        reports: PracticeAlignmentReportStore? = nil,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor,
        bundle: Bundle = .main
    ) async -> [PracticeVisualModel] {
        var attached: [PracticeVisualModel] = []
        for model in PracticeVisualModel.allCases {
            guard let host = firstEntity(named: model.hostEntityName, in: scene) else {
                continue
            }
            let placement = placements.placement(for: model)
            if let existing = firstEntity(named: model.semanticRootName, in: host) {
                apply(placement, to: existing)
                applyVisibility(for: model, placement: placement, in: scene)
                applyCrop(
                    for: model,
                    entity: existing,
                    host: host,
                    scene: scene,
                    placement: placement,
                    descriptor: descriptor,
                    reports: reports
                )
                reports?.recordAlignment(
                    measure(model, in: scene, placement: placement, descriptor: descriptor),
                    for: model
                )
                attached.append(model)
                continue
            }
            let hadStoredPlacement = placements.hasStoredPlacement(for: model)
            guard let entity = try? await load(model, from: bundle) else { continue }
            apply(placement, to: entity)
            host.addChild(entity)

            // First attach only. A stored placement is either a solve that already ran or
            // an operator's deliberate adjustment; re-solving over either would throw away
            // in-headset tuning every time the room reloads.
            var effective = placement
            if !hadStoredPlacement {
                // Baseline first: what the shipped default achieves before any solve. This
                // is the "before" half of the accuracy report and has to be sampled while
                // it is still true.
                reports?.recordBaseline(
                    measure(model, in: scene, placement: placement, descriptor: descriptor),
                    for: model
                )
                if model.solvesOnFirstAttach, let solved = solvePlacement(
                    for: model,
                    in: scene,
                    placement: placement,
                    descriptor: descriptor
                ) {
                    effective = solved
                    placements.update(solved, for: model)
                    apply(solved, to: entity)
                }
            }

            applyVisibility(for: model, placement: effective, in: scene)
            applyCrop(
                for: model,
                entity: entity,
                host: host,
                scene: scene,
                placement: effective,
                descriptor: descriptor,
                reports: reports
            )
            reports?.recordAlignment(
                measure(model, in: scene, placement: effective, descriptor: descriptor),
                for: model
            )
            attached.append(model)
        }
        return attached
    }

    /// Registers a body onto the manikin, or sizes a prop against it.
    ///
    /// Falls back to the old placeholder fit when neither applies, so a scene the solver
    /// cannot measure still gets a model at a sensible size rather than at its raw export
    /// scale.
    @MainActor
    static func solvePlacement(
        for model: PracticeVisualModel,
        in scene: Entity,
        placement: PracticeVisualModelPlacement,
        descriptor: PracticeAssetDescriptor = .placeholderDescriptor
    ) -> PracticeVisualModelPlacement? {
        switch model {
        case .human:
            if let solved = PracticeVisualModelAlignment.solvePlacement(
                for: model,
                in: scene,
                currentPlacement: placement,
                descriptor: descriptor
            ) {
                return solved.placement
            }
        case .aed:
            if let sized = PracticeVisualModelAlignment.solvePropPlacement(
                for: model,
                in: scene,
                currentPlacement: fitToPlaceholder(model, in: scene, placement: placement)
                    ?? placement,
                descriptor: descriptor
            ) {
                return sized
            }
        }
        return fitToPlaceholder(model, in: scene, placement: placement)
    }

    @MainActor
    private static func measure(
        _ model: PracticeVisualModel,
        in scene: Entity,
        placement: PracticeVisualModelPlacement,
        descriptor: PracticeAssetDescriptor
    ) -> TorsoAlignmentAccuracy? {
        PracticeVisualModelAlignment.measureAccuracy(
            for: model,
            in: scene,
            placement: placement,
            descriptor: descriptor
        )
    }

    /// Hides the geometry this model stands in for, and the markers it makes redundant.
    @MainActor
    static func applyVisibility(
        for model: PracticeVisualModel,
        placement: PracticeVisualModelPlacement,
        in scene: Entity
    ) {
        applyPlaceholderVisibility(
            for: model,
            isHidden: placement.hidesPlaceholder,
            in: scene
        )
        // Tied to the same switch: showing the placeholder body to check alignment while
        // its pad markers stayed hidden would hide half the thing being checked.
        setOpacity(
            placement.hidesPlaceholder ? 0 : 1,
            onEntitiesNamed: model.supersededLegacyEntityNames,
            in: scene
        )
        setOpacity(
            placement.hidesPlaceholder ? 0 : 1,
            onEntitiesNamed: model.operatorHiddenEntityNames,
            in: scene
        )
        // One-way on purpose: flipping the switch brings the props back to LOOK at,
        // never to touch — see `operatorHiddenEntityNames`.
        for name in model.operatorHiddenEntityNames {
            guard let entity = firstEntity(named: name, in: scene) else { continue }
            makeNonInteractive(entity)
        }
    }

    /// Crops the import to the manikin's physical envelope, or restores it when the
    /// operator switches cropping off.
    @MainActor
    static func applyCrop(
        for model: PracticeVisualModel,
        entity: Entity,
        host: Entity,
        scene: Entity,
        placement: PracticeVisualModelPlacement,
        descriptor: PracticeAssetDescriptor,
        reports: PracticeAlignmentReportStore?
    ) {
        guard model == .human else { return }
        guard placement.cropsToPhysicalEnvelope else {
            PracticeVisualModelCrop.restore(entity)
            reports?.recordCrop(nil, for: model)
            return
        }
        guard let reference = PracticeVisualModelAlignment.bestReference(
            in: scene,
            host: host,
            descriptor: descriptor
        ) else { return }
        let outcome = PracticeVisualModelCrop.apply(
            to: entity,
            envelopeCenter: reference.physicalEnvelopeCenter,
            envelopeExtents: reference.physicalEnvelopeExtents,
            host: host
        )
        reports?.recordCrop(outcome, for: model)
    }

    @MainActor
    private static func setOpacity(
        _ opacity: Float,
        onEntitiesNamed names: [String],
        in scene: Entity
    ) {
        for name in names {
            guard let entity = firstEntity(named: name, in: scene) else { continue }
            entity.components.set(OpacityComponent(opacity: opacity))
        }
    }

    /// Fits the attached model onto the bounding box of the placeholder geometry it
    /// replaces, preserving the model's aspect ratio and its current rotation.
    ///
    /// Imported exports carry their own origin, units and axis convention, so an
    /// identity placement almost never lands correctly. Measuring the old model and
    /// matching it is deterministic where guessing is not. Rotation is applied first and
    /// left untouched: set the body face-up, THEN fit, or the box being measured is the
    /// wrong shape.
    @MainActor
    static func fitToPlaceholder(
        _ model: PracticeVisualModel,
        in scene: Entity,
        placement: PracticeVisualModelPlacement
    ) -> PracticeVisualModelPlacement? {
        guard let host = firstEntity(named: model.hostEntityName, in: scene),
              let entity = firstEntity(named: model.semanticRootName, in: host)
        else { return nil }

        let reference = placeholderBounds(for: model, in: scene, relativeTo: host)
        guard let reference, !reference.isEmpty else { return nil }

        // Measure the model unscaled and unmoved, but with its rotation applied.
        let restore = entity.transform
        entity.position = .zero
        entity.orientation = placement.sanitized.orientation
        entity.scale = .one
        let modelBounds = entity.visualBounds(recursive: true, relativeTo: host)
        entity.transform = restore
        guard !modelBounds.isEmpty else { return nil }

        let referenceExtents = reference.extents
        let modelExtents = modelBounds.extents
        var ratios: [Float] = []
        for axis in 0..<3 where modelExtents[axis] > 1e-5 {
            ratios.append(referenceExtents[axis] / modelExtents[axis])
        }
        guard let fitScale = ratios.min(), fitScale.isFinite, fitScale > 0 else {
            return nil
        }

        var fitted = placement
        fitted.scale = fitScale
        fitted.offsetMetres = reference.center - modelBounds.center * fitScale
        return fitted.sanitized
    }

    /// Union of the placeholder geometry's bounds, in the host's coordinate space.
    @MainActor
    private static func placeholderBounds(
        for model: PracticeVisualModel,
        in scene: Entity,
        relativeTo host: Entity
    ) -> BoundingBox? {
        var union: BoundingBox?
        for name in model.replacedPlaceholderEntityNames {
            guard let placeholder = firstEntity(named: name, in: scene) else { continue }
            let bounds = placeholder.visualBounds(recursive: true, relativeTo: host)
            guard !bounds.isEmpty else { continue }
            union = union.map { $0.union(bounds) } ?? bounds
        }
        return union
    }

    @MainActor
    static func firstEntity(named name: String, in root: Entity) -> Entity? {
        if root.name == name { return root }
        for child in root.children {
            if let match = firstEntity(named: name, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private static func forEachEntity(in root: Entity, _ body: (Entity) -> Void) {
        body(root)
        for child in root.children {
            forEachEntity(in: child, body)
        }
    }
}
