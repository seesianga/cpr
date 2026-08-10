import Foundation
import Observation
import simd

/// Offset, yaw and uniform scale applied to an imported visual model after it is
/// attached to the authored skeleton.
///
/// Imported meshes rarely land in the authored coordinate frame first time, so placement
/// is tuned in the headset and persisted rather than guessed in source. It moves visuals
/// only: detection targets stay owned by the authored USDA skeleton.
struct PracticeVisualModelPlacement: Codable, Equatable, Sendable {
    var offsetMetres: SIMD3<Float>
    /// Rotation about the head-to-feet axis. This is the one that flips a body between
    /// face-up and face-down.
    var rollDegrees: Float = 0
    /// Rotation about the across-the-body axis: head-up versus head-down tilt.
    var pitchDegrees: Float = 0
    var yawDegrees: Float
    var scale: Float
    /// Whether the authored placeholder geometry this model replaces is hidden. Turn it
    /// back on while aligning: seeing both bodies at once is what makes the offset
    /// obvious.
    var hidesPlaceholder: Bool = true
    /// Whether geometry outside the manikin's physical envelope is hidden.
    ///
    /// The manikin is a torso trainer, so a full-body import can render legs that hang in
    /// mid-air with nothing physical underneath them. Switchable in the headset, because
    /// an import whose bind pose defeats the crop is better shown whole than shown wrong.
    /// The human's shipped default leaves it OFF — see
    /// `PracticeVisualModel.defaultPlacement`, which carries the placement tuned on the
    /// physical demo unit — so this struct-level value only reaches entities whose
    /// default placement does not say otherwise.
    var cropsToPhysicalEnvelope: Bool = true

    static let identity = PracticeVisualModelPlacement(
        offsetMetres: .zero,
        yawDegrees: 0,
        scale: 1,
        hidesPlaceholder: true
    )

    /// Clamped so a stray control value can never make the model non-renderable.
    static let minimumScale: Float = 0.05
    static let maximumScale: Float = 20
    static let maximumOffsetMetres: Float = 3

    var isFinite: Bool {
        offsetMetres.x.isFinite && offsetMetres.y.isFinite && offsetMetres.z.isFinite &&
            yawDegrees.isFinite && pitchDegrees.isFinite && rollDegrees.isFinite &&
            scale.isFinite
    }

    var sanitized: PracticeVisualModelPlacement {
        guard isFinite else {
            var fallback = PracticeVisualModelPlacement.identity
            fallback.hidesPlaceholder = hidesPlaceholder
            return fallback
        }
        let limit = Self.maximumOffsetMetres
        return PracticeVisualModelPlacement(
            offsetMetres: SIMD3<Float>(
                min(max(offsetMetres.x, -limit), limit),
                min(max(offsetMetres.y, -limit), limit),
                min(max(offsetMetres.z, -limit), limit)
            ),
            rollDegrees: rollDegrees.truncatingRemainder(dividingBy: 360),
            pitchDegrees: pitchDegrees.truncatingRemainder(dividingBy: 360),
            yawDegrees: yawDegrees.truncatingRemainder(dividingBy: 360),
            scale: min(max(scale, Self.minimumScale), Self.maximumScale),
            hidesPlaceholder: hidesPlaceholder,
            cropsToPhysicalEnvelope: cropsToPhysicalEnvelope
        )
    }

    /// Rewrites yaw/pitch/roll so `orientation` reproduces `rotation`.
    ///
    /// The solver works in matrices, but the persisted placement and the in-headset
    /// steppers are Euler angles, and keeping both in sync by hand is how a tuned
    /// placement silently stops matching what is on screen. Decomposing instead means the
    /// operator can still nudge a solved orientation by 15° and have it persist.
    mutating func setOrientation(_ rotation: simd_float3x3) {
        let angles = Self.yawPitchRollDegrees(from: rotation)
        yawDegrees = angles.yaw
        pitchDegrees = angles.pitch
        rollDegrees = angles.roll
    }

    /// Inverse of `orientation`: extracts the Y→X→Z Euler triple from a rotation matrix.
    ///
    /// Every rotation has such a decomposition, so this never fails; the gimbal-locked
    /// case (chest pointing straight along the head-to-feet axis) folds the redundant
    /// degree of freedom into yaw and leaves roll at zero.
    static func yawPitchRollDegrees(
        from rotation: simd_float3x3
    ) -> (yaw: Float, pitch: Float, roll: Float) {
        // simd is column-major: element(row, column) is columns.column[row].
        func element(_ row: Int, _ column: Int) -> Float {
            rotation[column][row]
        }
        let degrees = 180 / Float.pi
        let sinPitch = min(max(-element(1, 2), -1), 1)
        let pitch = asin(sinPitch)
        let cosPitch = (1 - sinPitch * sinPitch).squareRoot()
        guard cosPitch > 1e-5 else {
            return (
                yaw: atan2(-element(2, 0), element(0, 0)) * degrees,
                pitch: pitch * degrees,
                roll: 0
            )
        }
        // For R = Ry·Rx·Rz: R[0][2] = sin(yaw)·cos(pitch) and R[2][2] = cos(yaw)·cos(pitch),
        // and `pitch` comes from asin so cos(pitch) is never negative — the ratio is yaw
        // outright.
        return (
            yaw: atan2(element(0, 2), element(2, 2)) * degrees,
            pitch: pitch * degrees,
            roll: atan2(element(1, 0), element(1, 1)) * degrees
        )
    }

    /// Yaw, then pitch, then roll. Roll last so "flip the body face-up" stays a single
    /// control that behaves the same whatever the other two are set to.
    var orientation: simd_quatf {
        let radians = Float.pi / 180
        let yaw = simd_quatf(angle: yawDegrees * radians, axis: SIMD3<Float>(0, 1, 0))
        let pitch = simd_quatf(angle: pitchDegrees * radians, axis: SIMD3<Float>(1, 0, 0))
        let roll = simd_quatf(angle: rollDegrees * radians, axis: SIMD3<Float>(0, 0, 1))
        return yaw * pitch * roll
    }

    /// Paste-ready literal, so a placement tuned in the headset can be baked into source
    /// once it is right.
    var sourceLiteral: String {
        String(
            format: "offset (%.3f, %.3f, %.3f)  roll %.0f°  pitch %.0f°  yaw %.0f°  scale %.3f",
            offsetMetres.x,
            offsetMetres.y,
            offsetMetres.z,
            rollDegrees,
            pitchDegrees,
            yawDegrees,
            scale
        )
    }
}

/// Stores per-model placements so an adjustment survives leaving and re-entering the
/// immersive space.
@MainActor
@Observable
final class PracticeVisualModelPlacementStore {
    private let defaults: UserDefaults
    private var placements: [PracticeVisualModel: PracticeVisualModelPlacement] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for model in PracticeVisualModel.allCases {
            placements[model] = Self.load(model, from: defaults) ?? model.defaultPlacement
        }
    }

    func placement(for model: PracticeVisualModel) -> PracticeVisualModelPlacement {
        placements[model] ?? .identity
    }

    func update(
        _ placement: PracticeVisualModelPlacement,
        for model: PracticeVisualModel
    ) {
        let sanitized = placement.sanitized
        placements[model] = sanitized
        if let data = try? JSONEncoder().encode(sanitized) {
            defaults.set(data, forKey: Self.storageKey(for: model))
        }
    }

    /// Restores the model's starting placement and clears the stored value, so the next
    /// attach auto-fits again.
    func reset(_ model: PracticeVisualModel) {
        placements[model] = model.defaultPlacement
        defaults.removeObject(forKey: Self.storageKey(for: model))
    }

    /// Whether this model has a placement the operator tuned or a fit already stored.
    ///
    /// Used to auto-fit exactly once, on first attach, without overwriting later manual
    /// adjustments.
    func hasStoredPlacement(for model: PracticeVisualModel) -> Bool {
        defaults.data(forKey: Self.storageKey(for: model)) != nil
    }

    /// Versioned, and bumped whenever the meaning of a stored placement changes rather
    /// than only its schema. v2 placements were tuned against the old whole-figure fit,
    /// which measured the manikin's head and arms as well as its torso and then shrank the
    /// import to the tightest axis — a placement tuned to compensate for that is wrong
    /// under anatomical registration. Bumping the key discards them so the next attach
    /// starts from the shipped defaults; a stale key would silently keep the old
    /// misalignment.
    ///
    /// Versioned PER MODEL, because the assets revise independently. The AED went to v4
    /// when its export changed unit convention (2026-08-10): the old file's root carried
    /// an authored 0.01 scale with ×100 compensating children, the new file bakes both to
    /// 1 — so the same stored scale number renders the two assets ~100× apart in world
    /// size, and every v3 AED value was derived against the old convention. The human
    /// stays on v3: its export did not change, and a shared bump would discard the
    /// operator's hand-tuned placement for no reason.
    private static func storageVersion(for model: PracticeVisualModel) -> Int {
        switch model {
        case .human: 3
        case .aed: 4
        }
    }

    private static func storageKey(for model: PracticeVisualModel) -> String {
        "developer.visualModelPlacement.v\(storageVersion(for: model)).\(model.rawValue)"
    }

    private static func load(
        _ model: PracticeVisualModel,
        from defaults: UserDefaults
    ) -> PracticeVisualModelPlacement? {
        guard let data = defaults.data(forKey: storageKey(for: model)),
              let decoded = try? JSONDecoder().decode(
                  PracticeVisualModelPlacement.self,
                  from: data
              )
        else { return nil }
        return decoded.sanitized
    }
}
