import Foundation
import RealityKit

enum HandTrackingTargetExtractionError: Error, Equatable, LocalizedError, Sendable {
    case emptyBounds(entityName: String)
    case invalidTransform(entityName: String)

    var errorDescription: String? {
        switch self {
        case let .emptyBounds(entityName):
            "The practice target \"\(entityName)\" has no usable authored bounds."
        case let .invalidTransform(entityName):
            "The practice target \"\(entityName)\" has an invalid spatial transform."
        }
    }
}

extension AssetRegistry {
    /// Extracts immutable target geometry after the scene has joined the immersive hierarchy.
    /// The returned values contain no retained RealityKit entities.
    ///
    /// When the active asset descriptor's torso can be resolved, detection volumes come
    /// from the scale-invariant torso grid; the authored sternum/xiphoid entities remain
    /// visual affordances. Without a usable torso the authored volumes stay authoritative.
    func handTrackingTargets(
        in root: Entity,
        for scene: SpatialSceneName = .cprPracticeRoom
    ) throws -> HandTrackingTargets {
        if let grid = torsoGridMap(in: root),
           let sternum = grid.worldVolume(for: .sternumCompressionSite),
           let xiphoidAvoidZone = grid.worldVolume(for: .xiphoidAvoidZone) {
            return HandTrackingTargets(
                sternum: sternum,
                xiphoidAvoidZone: xiphoidAvoidZone,
                grid: grid
            )
        }

        let descriptor = practiceAssetDescriptor
        let sternumEntity = try requiredEntity(
            named: descriptor.body.sternumTargetEntityName,
            in: root,
            scene: scene
        )
        let xiphoidEntity = try requiredEntity(
            named: descriptor.body.xiphoidAvoidZoneEntityName,
            in: root,
            scene: scene
        )

        return HandTrackingTargets(
            sternum: try targetVolume(from: sternumEntity),
            xiphoidAvoidZone: try targetVolume(from: xiphoidEntity)
        )
    }

    /// Builds the normalized torso grid from the active descriptor's torso root. Landmark
    /// entities present in the scene override the proportional region defaults.
    func torsoGridMap(in root: Entity) -> TorsoGridMap? {
        let descriptor = practiceAssetDescriptor
        guard let torso = firstEntity(
            named: descriptor.body.torsoRootEntityName,
            in: root
        ) else { return nil }
        let bounds = torso.visualBounds(recursive: true, relativeTo: torso)
        guard !bounds.isEmpty else { return nil }

        var landmarks: [TorsoLandmark: SIMD3<Float>] = [:]
        for landmarkName in descriptor.body.landmarkEntityNames {
            guard let landmark = TorsoLandmark(rawValue: landmarkName),
                  let landmarkEntity = firstEntity(named: landmarkName, in: root)
            else { continue }
            landmarks[landmark] = landmarkEntity.position(relativeTo: nil)
        }

        return TorsoGridMap(
            descriptor: descriptor.gridDescriptor,
            worldFromTorsoTransform: torso.transformMatrix(relativeTo: nil),
            localBoundsCenter: bounds.center,
            localBoundsExtents: bounds.extents,
            landmarkWorldPositions: landmarks
        )
    }

    /// World positions for the descriptor's pinch-grabbable practice items (both pads
    /// and the power button) so the composed gesture pipeline can associate pinches.
    func pinchGrabItems(in root: Entity) -> [PinchGrabItem] {
        let descriptor = practiceAssetDescriptor
        let identifiers = [
            descriptor.patches.rightPadEntityName,
            descriptor.patches.leftPadEntityName,
            descriptor.defibrillator.powerButtonEntityName
        ]
        return identifiers.compactMap { identifier in
            guard let entity = firstEntity(named: identifier, in: root) else { return nil }
            return PinchGrabItem(
                identifier: identifier,
                worldPosition: entity.position(relativeTo: nil)
            )
        }
    }

    private func targetVolume(from entity: Entity) throws -> HandTrackingTargetVolume {
        let bounds = entity.visualBounds(recursive: true, relativeTo: entity)
        guard !bounds.isEmpty else {
            throw HandTrackingTargetExtractionError.emptyBounds(entityName: entity.name)
        }
        guard let volume = HandTrackingTargetVolume(
            worldFromTargetTransform: entity.transformMatrix(relativeTo: nil),
            localCenter: bounds.center,
            localExtents: bounds.extents
        ) else {
            throw HandTrackingTargetExtractionError.invalidTransform(entityName: entity.name)
        }
        return volume
    }
}
