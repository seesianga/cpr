import Foundation
import simd

struct AEDPadDropZone: Sendable, Equatable {
    let name: String
    let center: SIMD3<Float>
    let extents: SIMD3<Float>
}

/// Classifies an authored pad drop using world-aligned visual bounds.
///
/// The small tolerance is an interaction allowance, not a clinical placement distance.
/// Correctness still comes from the named right/left authored target zones.
enum AEDPadDropZoneClassifier {
    static let defaultInteractionToleranceMetres: Float = 0.015

    static func nearestOverlappingZone(
        padCenter: SIMD3<Float>,
        padExtents: SIMD3<Float>,
        zones: [AEDPadDropZone],
        interactionToleranceMetres: Float = defaultInteractionToleranceMetres
    ) -> String? {
        guard padCenter.allFinite,
              padExtents.allFinite,
              padExtents.allPositive,
              interactionToleranceMetres.isFinite,
              interactionToleranceMetres >= 0
        else { return nil }

        let candidates = zones.compactMap { zone -> (name: String, distance: Float)? in
            guard zone.center.allFinite,
                  zone.extents.allFinite,
                  zone.extents.allPositive
            else { return nil }

            let allowed = (padExtents + zone.extents) * 0.5
            let delta = abs(padCenter - zone.center)
            let separation = max(delta - allowed, SIMD3<Float>.zero)
            let distance = simd_length(separation)
            guard distance <= interactionToleranceMetres else { return nil }
            return (zone.name, distance)
        }

        return candidates.min { lhs, rhs in
            if abs(lhs.distance - rhs.distance) <= Float.ulpOfOne {
                return lhs.name < rhs.name
            }
            return lhs.distance < rhs.distance
        }?.name
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    var allPositive: Bool { x > 0 && y > 0 && z > 0 }
}
