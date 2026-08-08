import Foundation
import RealityKit
import simd

/// Instructor/developer-only visualization of the torso grid and its named regions.
///
/// Off by default. Enable with the `developer.showTorsoGridOverlay` user default in
/// DEBUG builds (`defaults write` on device, or a launch argument in a scheme). The
/// overlay is translucent, non-interactive, and never appears in release builds because
/// its only call site is compiled out.
enum TorsoGridDebugOverlay {
    static let entityName = "torso_grid_debug_overlay"

    private static let regionTints: [TorsoRegionID: SimpleMaterial.Color] = [
        .sternumCompressionSite: .init(red: 0.1, green: 0.45, blue: 0.85, alpha: 1),
        .xiphoidAvoidZone: .init(red: 0.8, green: 0.1, blue: 0.15, alpha: 1),
        .padSiteRightClavicle: .init(red: 0.95, green: 0.7, blue: 0.15, alpha: 1),
        .padSiteLeftLateral: .init(red: 0.95, green: 0.55, blue: 0.1, alpha: 1)
    ]

    @MainActor
    static func make(from grid: TorsoGridMap) -> Entity {
        let overlay = Entity()
        overlay.name = entityName
        overlay.setTransformMatrix(grid.anteriorSurfaceWorldTransform, relativeTo: nil)

        let planeSize = grid.frontalPlaneSizeMetres
        let columns = grid.descriptor.columns
        let rows = grid.descriptor.rows
        let cellWidth = planeSize.x / Float(columns)
        let cellLength = planeSize.y / Float(rows)

        let cellMaterial = SimpleMaterial(
            color: .init(red: 0.85, green: 0.9, blue: 0.95, alpha: 1),
            isMetallic: false
        )
        for column in 0..<columns {
            for row in 0..<rows {
                let tile = ModelEntity(
                    mesh: .generateBox(
                        width: cellWidth * 0.94,
                        height: 0.001,
                        depth: cellLength * 0.94
                    ),
                    materials: [cellMaterial]
                )
                tile.position = SIMD3(
                    (Float(column) + 0.5) / Float(columns) * planeSize.x - planeSize.x / 2,
                    0.002,
                    (Float(row) + 0.5) / Float(rows) * planeSize.y - planeSize.y / 2
                )
                tile.components.set(OpacityComponent(opacity: 0.16))
                overlay.addChild(tile)
            }
        }

        for (regionID, rect) in grid.regions.sorted(by: {
            $0.key.rawValue < $1.key.rawValue
        }) {
            let tint = regionTints[regionID] ?? .white
            let regionTile = ModelEntity(
                mesh: .generateBox(
                    width: Float(rect.width) * planeSize.x,
                    height: 0.002,
                    depth: Float(rect.height) * planeSize.y
                ),
                materials: [SimpleMaterial(color: tint, isMetallic: false)]
            )
            regionTile.name = "\(entityName)_\(regionID.rawValue)"
            regionTile.position = SIMD3(
                Float(rect.centerU) * planeSize.x - planeSize.x / 2,
                0.004,
                Float(rect.centerV) * planeSize.y - planeSize.y / 2
            )
            regionTile.components.set(OpacityComponent(opacity: 0.34))
            overlay.addChild(regionTile)
        }
        return overlay
    }
}
