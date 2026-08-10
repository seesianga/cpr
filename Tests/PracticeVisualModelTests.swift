import RealityKit
import simd
import XCTest
@testable import LifesaverVision

/// Coverage for the compiled Reality Composer Pro models exported as `.reality`.
///
/// The archives are encrypted, so their names cannot be checked statically. These tests
/// pin the rename contract instead: what the mapping renames, what it reports as
/// unrecognised, and — most importantly — that no visual name is allowed to collide
/// with a clinically meaningful detection target.
@MainActor
final class PracticeVisualModelTests: XCTestCase {

    func testNameMappingRenamesAuthoredEntitiesAndReportsUnknownOnes() {
        let root = makeEntity("AED", children: [
            makeEntity("AED_Defibrilator", children: [
                makeEntity("shockbutton_red"),
                makeEntity("startbutton_green"),
                makeEntity("Shape 1")
            ]),
            makeEntity("AED_patch_blue"),
            makeEntity("AED_patch_orange")
        ])

        let unmapped = PracticeVisualModelLoader.applyNameMapping(
            PracticeVisualModel.aed.nameMapping,
            to: root
        )

        XCTAssertEqual(
            PracticeVisualModelLoader.entityNames(in: root),
            [
                "aed_visual_model",
                "aed_visual_case",
                "aed_visual_shock_button",
                "aed_visual_power_button",
                "Shape 1",
                "aed_visual_left_pad",
                "aed_visual_right_pad"
            ]
        )
        XCTAssertEqual(
            unmapped,
            ["Shape 1"],
            "Entities absent from the mapping must be reported, not silently kept"
        )
    }

    func testHumanMappingRenamesTheClothingHierarchy() {
        let root = makeEntity("Human", children: [
            makeEntity("Human_body"),
            makeEntity("Human_clothe", children: [
                makeEntity("Tshirts"),
                makeEntity("Pants")
            ]),
            makeEntity("Human_CPR_guide"),
            makeEntity("Human_AED_guide"),
            makeEntity("Human_detection_area")
        ])

        PracticeVisualModelLoader.applyNameMapping(
            PracticeVisualModel.human.nameMapping,
            to: root
        )

        XCTAssertEqual(
            PracticeVisualModelLoader.entityNames(in: root),
            [
                "human_visual_model",
                "human_visual_body",
                "human_visual_clothing",
                "human_visual_clothing_top",
                "human_visual_clothing_bottom",
                "human_visual_cpr_guide",
                "human_visual_aed_guide",
                "human_visual_sternum_site"
            ]
        )
    }

    /// The imported meshes are decoration. Every detection target stays owned by the
    /// authored USDA skeleton, so no rename may ever produce one of those names.
    func testVisualNamesNeverCollideWithDetectionTargets() {
        let descriptor = PracticeAssetDescriptor.placeholderDescriptor
        var reserved: Set<String> = [
            descriptor.body.torsoRootEntityName,
            descriptor.body.figureEntityName,
            descriptor.body.sternumTargetEntityName,
            descriptor.body.xiphoidAvoidZoneEntityName,
            descriptor.defibrillator.unitEntityName,
            descriptor.defibrillator.powerButtonEntityName,
            descriptor.defibrillator.shockButtonEntityName,
            descriptor.defibrillator.connectorEntityName,
            descriptor.defibrillator.statusLightEntityName,
            descriptor.patches.rightPadEntityName,
            descriptor.patches.leftPadEntityName,
            descriptor.patches.rightPadZoneEntityName,
            descriptor.patches.leftPadZoneEntityName
        ]
        reserved.formUnion(descriptor.body.landmarkEntityNames)

        for model in PracticeVisualModel.allCases {
            for semanticName in model.nameMapping.values {
                XCTAssertFalse(
                    reserved.contains(semanticName),
                    "\(model.rawValue) maps onto the reserved detection target \(semanticName)"
                )
            }
            XCTAssertFalse(reserved.contains(model.semanticRootName))
            XCTAssertTrue(
                reserved.contains(model.hostEntityName),
                "A visual model must hang beneath an authored skeleton entity"
            )
        }
    }

    // MARK: - Bundled export contracts (runtime loads)

    /// The AED ships inside a combined "export selection" file that also carries the
    /// human. Loading the AED must yield the AED subtree ONLY: the wrapper and the
    /// neighbouring body may never ride along, or a second casualty hangs off the AED
    /// mount. The archive is encrypted, so an actual load is the only place this can be
    /// checked.
    func testBundledAEDExportLoadsAsTheAEDSubtreeOnly() async throws {
        let root = try await PracticeVisualModelLoader.load(.aed)
        XCTAssertEqual(root.name, PracticeVisualModel.aed.semanticRootName)

        for required in [
            "aed_visual_case",
            "aed_visual_left_pad",
            "aed_visual_right_pad",
            "aed_visual_shock_button",
            "aed_visual_power_button"
        ] {
            XCTAssertNotNil(
                PracticeVisualModelLoader.firstEntity(named: required, in: root),
                "Bundled AED export is missing the mapped entity \(required)"
            )
        }

        let names = PracticeVisualModelLoader.entityNames(in: root)
        XCTAssertFalse(
            names.contains { $0.hasPrefix("Human") || $0.hasPrefix("human_visual") },
            "The combined export's human subtree leaked into the AED model: \(names)"
        )
        // Structural proof the SUBTREE was selected, not the wrapper: the case is a
        // direct child of the returned root. In the wrapper-attached failure mode the
        // case sits a level deeper (wrapper → AED → case), so this fails there. A
        // names.contains("Selection") check would be vacuous instead — load() renames
        // whichever root it picked, so that name never survives to be observed.
        XCTAssertTrue(
            root.children.contains { $0.name == "aed_visual_case" },
            "aed_visual_case must be a direct child of the selected AED subtree"
        )
    }

    /// The AED is sized as a fraction of chest width, which only works if the export is
    /// authored in metres. The OLD export was not — its root carried a 0.01 scale with
    /// ×100 children, the neutralized measurement came out ~67 m, and the fraction solve
    /// silently nil'd out to the placeholder fit. This pins the new contract: measured at
    /// neutral root transform, the AED must be metric and the proportional solve must
    /// actually engage. A future export in mm or cm units fails here instead of silently
    /// changing sizing behavior class.
    func testBundledAEDExportIsMetricAndProportionalSizingEngages() async throws {
        let root = try await PracticeVisualModelLoader.load(.aed)
        root.transform = Transform()
        let staging = Entity()
        staging.addChild(root)

        let bounds = root.visualBounds(recursive: true, relativeTo: staging)
        let maxExtent = bounds.extents.max()
        XCTAssertTrue(
            (0.2...2.0).contains(maxExtent),
            "AED export must be metric; neutralized max extent was \(maxExtent) m"
        )

        // 0.46 m is the authored manikin chest width the fraction is taken against.
        XCTAssertNotNil(
            ProportionalPropSizing.scale(
                chestWidthMetres: 0.46,
                measuredPropWidthMetres: maxExtent
            ),
            "The proportional sizing path must engage for the bundled export"
        )
    }

    /// The human still loads from its own single-model export; this pins that its
    /// authored names keep resolving through the rename map after any asset swap.
    func testBundledHumanExportLoadsWithSemanticNames() async throws {
        let root = try await PracticeVisualModelLoader.load(.human)
        XCTAssertEqual(root.name, PracticeVisualModel.human.semanticRootName)

        for required in [
            "human_visual_body",
            "human_visual_clothing",
            "human_visual_sternum_site",
            "human_visual_cpr_guide",
            "human_visual_aed_guide"
        ] {
            XCTAssertNotNil(
                PracticeVisualModelLoader.firstEntity(named: required, in: root),
                "Bundled human export is missing the mapped entity \(required)"
            )
        }

        let names = PracticeVisualModelLoader.entityNames(in: root)
        XCTAssertFalse(
            names.contains { $0.hasPrefix("AED") || $0.hasPrefix("aed_visual") },
            "An AED subtree leaked into the human model: \(names)"
        )
    }

    func testMissingBundledResourceThrowsInsteadOfCrashing() {
        XCTAssertThrowsError(
            try PracticeVisualModelLoader.url(for: .human, in: Bundle(for: Self.self))
        ) { error in
            XCTAssertEqual(
                error as? PracticeVisualModelError,
                .resourceMissing(name: "Human"),
                "The unit-test bundle has no copy-files phase, so this must throw"
            )
        }
    }

    /// `torso_shell` is the torso grid's bounds source AND the geometry the imported body
    /// replaces. Hiding it must not collapse its bounds, or every detection region goes
    /// with it.
    func testHidingPlaceholderKeepsItsVisualBoundsIntact() {
        let placeholder = ModelEntity(mesh: .generateBox(size: [0.46, 0.18, 0.72]))
        placeholder.name = "torso_shell"
        let before = placeholder.visualBounds(recursive: true, relativeTo: placeholder)
        XCTAssertFalse(before.isEmpty)

        placeholder.components.set(OpacityComponent(opacity: 0))

        let after = placeholder.visualBounds(recursive: true, relativeTo: placeholder)
        XCTAssertFalse(
            after.isEmpty,
            "Opacity hiding must preserve bounds; disabling the entity would not"
        )
        XCTAssertEqual(after.extents.x, before.extents.x, accuracy: 0.0001)
        XCTAssertEqual(after.extents.y, before.extents.y, accuracy: 0.0001)
        XCTAssertEqual(after.extents.z, before.extents.z, accuracy: 0.0001)
    }

    /// Reality Composer Pro authors input and collision components by default. Left in
    /// place they sit in front of the practice UI and swallow taps, which is what made
    /// the AED panel unselectable.
    func testImportedModelsAreStrippedOfInteractionComponents() {
        let child = makeEntity("AED_Defibrilator")
        child.components.set(InputTargetComponent())
        let root = makeEntity("AED", children: [child])
        root.components.set(InputTargetComponent())
        root.components.set(
            CollisionComponent(shapes: [.generateBox(size: SIMD3<Float>(repeating: 0.2))])
        )

        PracticeVisualModelLoader.makeNonInteractive(root)

        XCTAssertNil(root.components[InputTargetComponent.self])
        XCTAssertNil(root.components[CollisionComponent.self])
        XCTAssertNil(
            child.components[InputTargetComponent.self],
            "Stripping must reach every descendant, not just the root"
        )
    }

    func testRollFlipsAFaceDownBodyFaceUp() {
        var placement = PracticeVisualModelPlacement.identity
        placement.rollDegrees = 180

        // Roll turns about the head-to-feet axis, so the body's "up" inverts.
        let up = placement.orientation.act(SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(up.y, -1, accuracy: 0.0001)
        XCTAssertEqual(up.x, 0, accuracy: 0.0001)
    }

    /// Fitting must scale the import down onto the placeholder's box and centre it,
    /// preserving aspect ratio — that is what "align to the old model" means.
    func testFitScalesAndCentresTheModelOntoThePlaceholder() throws {
        let host = Entity()
        host.name = "training_manikin"

        let placeholder = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.46, 0.18, 0.72))
        )
        placeholder.name = "torso_shell"
        placeholder.position = SIMD3<Float>(0, 0.12, 0)
        host.addChild(placeholder)

        let imported = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(repeating: 2)))
        imported.name = "human_visual_model"
        host.addChild(imported)

        let fitted = try XCTUnwrap(
            PracticeVisualModelLoader.fitToPlaceholder(
                .human,
                in: host,
                placement: .identity
            )
        )

        // Tightest axis wins so the import fits inside: 0.18 / 2 = 0.09.
        XCTAssertEqual(fitted.scale, 0.09, accuracy: 0.001)
        // A 2 m cube centred on its origin, scaled, must land on the placeholder centre.
        XCTAssertEqual(fitted.offsetMetres.y, 0.12, accuracy: 0.001)
        XCTAssertEqual(fitted.offsetMetres.x, 0, accuracy: 0.001)
        XCTAssertEqual(fitted.offsetMetres.z, 0, accuracy: 0.001)
    }

    func testHumanDefaultPlacementStartsFaceUp() {
        XCTAssertEqual(PracticeVisualModel.human.defaultPlacement.rollDegrees, 180)
        XCTAssertEqual(PracticeVisualModel.aed.defaultPlacement.rollDegrees, 0)
    }

    /// Pins the shipped human placement to the values tuned by eye against the physical
    /// torso trainer (2026-08-10). These are configuration, not derivation — a change here
    /// must be a deliberate re-tune on the demo unit, never a refactoring accident.
    func testHumanDefaultPlacementIsThePhysicallyTunedConfiguration() {
        let placement = PracticeVisualModel.human.defaultPlacement
        XCTAssertEqual(placement.offsetMetres.x, 0.00, accuracy: 0.0001)
        XCTAssertEqual(placement.offsetMetres.y, 0.19, accuracy: 0.0001)
        XCTAssertEqual(placement.offsetMetres.z, 0.80, accuracy: 0.0001)
        XCTAssertEqual(placement.rollDegrees, 180)
        XCTAssertEqual(placement.pitchDegrees, 0)
        XCTAssertEqual(placement.yawDegrees, 180)
        XCTAssertEqual(placement.scale, 0.43, accuracy: 0.0001)
        XCTAssertTrue(placement.hidesPlaceholder)
        XCTAssertFalse(
            placement.cropsToPhysicalEnvelope,
            "Crop ships OFF: the tuned placement reads correctly whole on the demo unit"
        )
        XCTAssertEqual(
            placement,
            placement.sanitized,
            "The shipped default must survive sanitization untouched"
        )
    }

    /// The human's default is the working registration, so the first attach must not
    /// solve over it; the AED is sized off the measured chest, so it must keep solving.
    func testFirstAttachSolvePolicyPreservesTheTunedHumanDefault() {
        XCTAssertFalse(PracticeVisualModel.human.solvesOnFirstAttach)
        XCTAssertTrue(PracticeVisualModel.aed.solvesOnFirstAttach)
    }

    // MARK: - Placement tuning

    func testPlacementSanitizationClampsAndRejectsNonFiniteValues() {
        var extreme = PracticeVisualModelPlacement.identity
        extreme.scale = 1_000
        extreme.offsetMetres = [99, -99, 0.2]

        let sanitized = extreme.sanitized
        XCTAssertEqual(sanitized.scale, PracticeVisualModelPlacement.maximumScale)
        XCTAssertEqual(sanitized.offsetMetres.x, PracticeVisualModelPlacement.maximumOffsetMetres)
        XCTAssertEqual(sanitized.offsetMetres.y, -PracticeVisualModelPlacement.maximumOffsetMetres)
        XCTAssertEqual(sanitized.offsetMetres.z, 0.2, accuracy: 0.0001)

        var broken = PracticeVisualModelPlacement.identity
        broken.scale = .nan
        XCTAssertEqual(
            broken.sanitized,
            .identity,
            "A non-finite placement must fall back to identity, never reach RealityKit"
        )
    }

    func testPlacementStorePersistsPerModelAndResets() throws {
        let suiteName = "PracticeVisualModelTests.placement"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = PracticeVisualModelPlacementStore(defaults: defaults)
        var placement = PracticeVisualModelPlacement.identity
        placement.offsetMetres = [0.1, 0.2, 0.3]
        placement.yawDegrees = 15
        store.update(placement, for: .human)

        let reloaded = PracticeVisualModelPlacementStore(defaults: defaults)
        XCTAssertEqual(reloaded.placement(for: .human).offsetMetres, [0.1, 0.2, 0.3])
        XCTAssertEqual(reloaded.placement(for: .human).yawDegrees, 15)
        XCTAssertEqual(
            reloaded.placement(for: .aed),
            .identity,
            "A tuned placement must not leak onto the other model"
        )

        store.reset(.human)
        let afterReset = PracticeVisualModelPlacementStore(defaults: defaults)
        XCTAssertEqual(
            afterReset.placement(for: .human),
            PracticeVisualModel.human.defaultPlacement,
            "Reset restores the model's starting placement, not a bare identity"
        )
        XCTAssertFalse(
            afterReset.hasStoredPlacement(for: .human),
            "Clearing the stored value lets the next attach auto-fit again"
        )
    }

    /// The AED's storage key went v3 → v4 when its export changed unit convention
    /// (2026-08-10): a v3 scale renders the new asset ~100× wrong. A device that stored a
    /// v3 AED placement must come up on the defaults and re-solve, not apply the stale
    /// number — while the human's v3 key stays honoured, because its export did not
    /// change and it carries the operator's hand-tuned registration.
    func testStaleV3AEDPlacementIsDiscardedButHumanV3Survives() throws {
        let suiteName = "PracticeVisualModelTests.migration"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var stale = PracticeVisualModelPlacement.identity
        stale.scale = 0.05
        stale.offsetMetres = [-0.247, 0.047, -0.072]
        let data = try JSONEncoder().encode(stale)
        // Written under the RETIRED key, the way a pre-swap install left it.
        defaults.set(data, forKey: "developer.visualModelPlacement.v3.AED")

        var tunedHuman = PracticeVisualModel.human.defaultPlacement
        tunedHuman.yawDegrees = 195
        defaults.set(
            try JSONEncoder().encode(tunedHuman),
            forKey: "developer.visualModelPlacement.v3.Human"
        )

        let store = PracticeVisualModelPlacementStore(defaults: defaults)
        XCTAssertFalse(
            store.hasStoredPlacement(for: .aed),
            "A v3 AED value must not be visible through the v4 key"
        )
        XCTAssertEqual(
            store.placement(for: .aed),
            PracticeVisualModel.aed.defaultPlacement,
            "The stale AED placement must be discarded in favour of the defaults"
        )
        XCTAssertEqual(
            store.placement(for: .human).yawDegrees,
            195,
            "The human's v3 placement must survive the AED's key bump"
        )
    }

    // MARK: - Authored torso-grid landmarks

    /// The four `landmark_*` markers authored into `TrainingManikin.usda` must resolve to
    /// exactly the region centres the grid already derives proportionally. This pins the
    /// derivation so a future edit to either side cannot silently move a clinical zone.
    func testAuthoredLandmarksReproduceTheProportionalGridRegions() throws {
        let descriptor = BodyGridDescriptor.placeholderDefault
        // torso_shell: centre (0, 0.12, 0), extents 0.46 x 0.18 x 0.72 in manikin space.
        let authoredLandmarks: [TorsoLandmark: SIMD3<Float>] = [
            .sternum: [0, 0.225, 0.095],
            .xiphoid: [0, 0.225, 0.2664],
            .rightClavicle: [-0.1449, 0.225, -0.2455],
            .leftLowerRibs: [0.1886, 0.225, 0.1296]
        ]

        let grid = try XCTUnwrap(
            TorsoGridMap(
                descriptor: descriptor,
                worldFromTorsoTransform: matrix_identity_float4x4,
                localBoundsCenter: [0, 0.12, 0],
                localBoundsExtents: [0.46, 0.18, 0.72],
                landmarkWorldPositions: authoredLandmarks
            )
        )

        for region in TorsoRegionID.allCases {
            let expected = try XCTUnwrap(descriptor.regions[region])
            let resolved = try XCTUnwrap(grid.regions[region])
            XCTAssertEqual(
                resolved.centerU,
                expected.centerU,
                accuracy: 0.002,
                "\(region) lateral centre drifted from the proportional default"
            )
            XCTAssertEqual(
                resolved.centerV,
                expected.centerV,
                accuracy: 0.002,
                "\(region) longitudinal centre drifted from the proportional default"
            )
        }
    }

    // MARK: - Helpers

    private func makeEntity(_ name: String, children: [Entity] = []) -> Entity {
        let entity = Entity()
        entity.name = name
        for child in children {
            entity.addChild(child)
        }
        return entity
    }
}
