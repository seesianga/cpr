import Foundation
import simd

/// Interaction thresholds for pinch-grabbing practice items. These are input-filter
/// values with begin/release hysteresis so the gesture does not flap; they carry no
/// clinical meaning.
struct PinchGrabConfiguration: Sendable, Equatable {
    /// Thumb-tip-to-index-tip gap at or below which a pinch begins.
    let grabDistanceMetres: Float
    /// Gap at or above which an active pinch releases (must exceed the grab distance).
    let releaseDistanceMetres: Float
    /// Furthest a pinch midpoint may start from an item and still grab it.
    let maximumItemGrabRadiusMetres: Float
    let maximumSampleAgeSeconds: Double

    init(
        grabDistanceMetres: Float,
        releaseDistanceMetres: Float,
        maximumItemGrabRadiusMetres: Float,
        maximumSampleAgeSeconds: Double
    ) {
        self.grabDistanceMetres = grabDistanceMetres
        self.releaseDistanceMetres = releaseDistanceMetres
        self.maximumItemGrabRadiusMetres = maximumItemGrabRadiusMetres
        self.maximumSampleAgeSeconds = maximumSampleAgeSeconds
    }

    static let practiceDefault = PinchGrabConfiguration(
        grabDistanceMetres: 0.022,
        releaseDistanceMetres: 0.045,
        maximumItemGrabRadiusMetres: 0.12,
        maximumSampleAgeSeconds: 0.25
    )
}

/// A named, grabbable practice item at a world position. Identifiers come from the
/// active asset descriptor; this type never holds an entity reference.
struct PinchGrabItem: Sendable, Equatable {
    let identifier: String
    let worldPosition: SIMD3<Float>

    init(identifier: String, worldPosition: SIMD3<Float>) {
        self.identifier = identifier
        self.worldPosition = worldPosition
    }
}

/// Pure value-type pinch-grab state machine over reduced finger nodes.
///
/// One grab is active at a time. A pinch begins when the thumb-index gap closes below
/// the grab threshold near a registered item; the item follows the pinch midpoint until
/// the gap opens past the release threshold. Hand loss mid-drag cancels the grab.
struct PinchGrabTracker: Sendable {
    private struct HandSample: Sendable {
        let timestampSeconds: Double
        let nodes: TrackedHandNodes
    }

    private struct ActiveGrab: Sendable {
        let itemIdentifier: String
        let chirality: TrackedHandChirality
        var lastMidpointWorld: SIMD3<Float>
    }

    private let configuration: PinchGrabConfiguration
    private var items: [PinchGrabItem] = []
    private var hands: [TrackedHandChirality: HandSample] = [:]
    private var pinchedHands: Set<TrackedHandChirality> = []
    private var activeGrab: ActiveGrab?

    init(configuration: PinchGrabConfiguration = .practiceDefault) {
        self.configuration = configuration
    }

    mutating func updateItems(_ items: [PinchGrabItem]) {
        self.items = items.filter { $0.worldPosition.allFinite }
    }

    mutating func process(
        _ observation: TrackedHandNodesObservation
    ) -> [GrabInteractionSample] {
        guard observation.timestampSeconds.isFinite,
              observation.timestampSeconds >= 0
        else { return [] }
        if let existing = hands[observation.chirality],
           observation.timestampSeconds < existing.timestampSeconds {
            return []
        }

        if let nodes = observation.nodes,
           nodes.thumbTip.allFinite,
           nodes.indexTip.allFinite {
            hands[observation.chirality] = HandSample(
                timestampSeconds: observation.timestampSeconds,
                nodes: nodes
            )
        } else {
            hands.removeValue(forKey: observation.chirality)
            pinchedHands.remove(observation.chirality)
        }
        return evaluate(at: observation.timestampSeconds)
    }

    /// Cancels any active grab, e.g. when tracking stops.
    mutating func reset(at timestampSeconds: Double = 0) -> [GrabInteractionSample] {
        hands.removeAll(keepingCapacity: false)
        pinchedHands.removeAll(keepingCapacity: false)
        guard let grab = activeGrab else { return [] }
        activeGrab = nil
        return [
            GrabInteractionSample(
                phase: .cancelled,
                itemIdentifier: grab.itemIdentifier,
                timestampSeconds: timestampSeconds,
                midpointWorld: nil
            )
        ]
    }

    private mutating func evaluate(at timestampSeconds: Double) -> [GrabInteractionSample] {
        let staleHands = hands.filter {
            timestampSeconds - $0.value.timestampSeconds >
                configuration.maximumSampleAgeSeconds
        }
        for chirality in staleHands.keys {
            hands.removeValue(forKey: chirality)
            pinchedHands.remove(chirality)
        }

        var outputs: [GrabInteractionSample] = []

        if let grab = activeGrab {
            guard let sample = hands[grab.chirality] else {
                activeGrab = nil
                outputs.append(
                    GrabInteractionSample(
                        phase: .cancelled,
                        itemIdentifier: grab.itemIdentifier,
                        timestampSeconds: timestampSeconds,
                        midpointWorld: nil
                    )
                )
                return outputs
            }

            let midpoint = sample.nodes.pinchMidpointWorld
            if sample.nodes.pinchGapMetres >= configuration.releaseDistanceMetres {
                pinchedHands.remove(grab.chirality)
                activeGrab = nil
                outputs.append(
                    GrabInteractionSample(
                        phase: .released,
                        itemIdentifier: grab.itemIdentifier,
                        timestampSeconds: timestampSeconds,
                        midpointWorld: midpoint
                    )
                )
            } else {
                activeGrab?.lastMidpointWorld = midpoint
                outputs.append(
                    GrabInteractionSample(
                        phase: .moved,
                        itemIdentifier: grab.itemIdentifier,
                        timestampSeconds: timestampSeconds,
                        midpointWorld: midpoint
                    )
                )
            }
            return outputs
        }

        // No active grab: look for a fresh pinch near a registered item. A hand stays
        // "pinched" until it opens past the release threshold, so holding a closed
        // pinch cannot begin a second grab on the same closure.
        for chirality in [TrackedHandChirality.left, .right] {
            guard let sample = hands[chirality] else { continue }
            let gap = sample.nodes.pinchGapMetres
            if pinchedHands.contains(chirality) {
                if gap >= configuration.releaseDistanceMetres {
                    pinchedHands.remove(chirality)
                }
                continue
            }
            guard gap <= configuration.grabDistanceMetres else { continue }
            pinchedHands.insert(chirality)

            let midpoint = sample.nodes.pinchMidpointWorld
            var candidates: [(item: PinchGrabItem, distance: Float)] = items.map { item in
                (item: item, distance: simd_distance(item.worldPosition, midpoint))
            }
            candidates = candidates.filter { candidate in
                candidate.distance <= configuration.maximumItemGrabRadiusMetres
            }
            candidates.sort { lhs, rhs in
                lhs.distance == rhs.distance
                    ? lhs.item.identifier < rhs.item.identifier
                    : lhs.distance < rhs.distance
            }
            guard let nearest = candidates.first else { continue }

            activeGrab = ActiveGrab(
                itemIdentifier: nearest.item.identifier,
                chirality: chirality,
                lastMidpointWorld: midpoint
            )
            outputs.append(
                GrabInteractionSample(
                    phase: .began,
                    itemIdentifier: nearest.item.identifier,
                    timestampSeconds: timestampSeconds,
                    midpointWorld: midpoint
                )
            )
            break
        }
        return outputs
    }
}

private extension SIMD3 where Scalar == Float {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
