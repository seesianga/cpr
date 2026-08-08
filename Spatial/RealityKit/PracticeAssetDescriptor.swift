import Foundation

/// Declares how a practice asset set maps semantic slots to authored entity names.
///
/// This is the single seam for swapping in a new manikin, defibrillator, or patch
/// asset: ship the USDZ plus a descriptor JSON and the torso grid rescales from the
/// new body bounds automatically. The current procedural assets are described by
/// `placeholderDescriptor`, which is the only place their entity-name literals live.
struct PracticeAssetDescriptor: Codable, Equatable, Sendable {
    struct BodySlot: Codable, Equatable, Sendable {
        /// Root used for grid derivation — the torso, not the whole figure, so limbs
        /// and props cannot skew the grid bounds.
        let torsoRootEntityName: String
        /// The whole-figure entity used for interaction affordances.
        let figureEntityName: String
        /// Visual affordances that remain authored entities; detection comes from the grid.
        let sternumTargetEntityName: String
        let xiphoidAvoidZoneEntityName: String
        /// Optional authored landmark entity names checked at load; present landmarks
        /// override the proportional grid defaults.
        let landmarkEntityNames: [String]
    }

    struct DefibrillatorSlot: Codable, Equatable, Sendable {
        let unitEntityName: String
        let powerButtonEntityName: String
        let shockButtonEntityName: String
        let connectorEntityName: String
        let statusLightEntityName: String
    }

    struct PatchesSlot: Codable, Equatable, Sendable {
        let rightPadEntityName: String
        let leftPadEntityName: String
        let rightPadZoneEntityName: String
        let leftPadZoneEntityName: String
    }

    let body: BodySlot
    let defibrillator: DefibrillatorSlot
    let patches: PatchesSlot
    /// Overrides the built-in grid descriptor for assets with a different axis
    /// convention or region layout. Nil uses `BodyGridDescriptor.placeholderDefault`.
    let gridDescriptorOverride: BodyGridDescriptor?

    var gridDescriptor: BodyGridDescriptor {
        gridDescriptorOverride ?? .placeholderDefault
    }

    /// The current procedural/USDA assets. Behaviour is unchanged while this is active.
    static let placeholderDescriptor = PracticeAssetDescriptor(
        body: BodySlot(
            torsoRootEntityName: "torso_shell",
            figureEntityName: "training_manikin",
            sternumTargetEntityName: "sternum_target",
            xiphoidAvoidZoneEntityName: "xiphoid_avoid_zone",
            landmarkEntityNames: TorsoLandmark.allCases.map(\.rawValue)
        ),
        defibrillator: DefibrillatorSlot(
            unitEntityName: "aed_unit",
            powerButtonEntityName: "aed_power_button",
            shockButtonEntityName: "aed_shock_button",
            connectorEntityName: "aed_connector",
            statusLightEntityName: "aed_status_light"
        ),
        patches: PatchesSlot(
            rightPadEntityName: "aed_right_pad",
            leftPadEntityName: "aed_left_pad",
            rightPadZoneEntityName: "aed_right_pad_zone",
            leftPadZoneEntityName: "aed_left_pad_zone"
        ),
        gridDescriptorOverride: nil
    )

    /// Decodes a descriptor JSON shipped beside a swapped-in asset.
    static func decode(from data: Data) throws -> PracticeAssetDescriptor {
        try JSONDecoder().decode(PracticeAssetDescriptor.self, from: data)
    }
}
