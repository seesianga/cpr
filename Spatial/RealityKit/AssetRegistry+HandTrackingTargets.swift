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
    func handTrackingTargets(
        in root: Entity,
        for scene: SpatialSceneName = .cprPracticeRoom
    ) throws -> HandTrackingTargets {
        let sternumEntity = try requiredEntity(
            named: "sternum_target",
            in: root,
            scene: scene
        )
        let xiphoidEntity = try requiredEntity(
            named: "xiphoid_avoid_zone",
            in: root,
            scene: scene
        )

        return HandTrackingTargets(
            sternum: try targetVolume(from: sternumEntity),
            xiphoidAvoidZone: try targetVolume(from: xiphoidEntity)
        )
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
