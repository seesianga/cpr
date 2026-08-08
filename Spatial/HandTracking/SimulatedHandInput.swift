import Foundation
import simd

/// One deterministic simulator/test input. Coordinates are transient spatial positions only;
/// this type intentionally has no compression-depth, force, or recoil fields.
struct SimulatedHandFrame: Sendable, Equatable {
    let timestampSeconds: Double
    let leftPalmWorld: SIMD3<Float>?
    let rightPalmWorld: SIMD3<Float>?

    init(
        timestampSeconds: Double,
        leftPalmWorld: SIMD3<Float>? = nil,
        rightPalmWorld: SIMD3<Float>? = nil
    ) {
        self.timestampSeconds = timestampSeconds
        self.leftPalmWorld = leftPalmWorld
        self.rightPalmWorld = rightPalmWorld
    }
}

/// Explicitly injected hand-input driver for the visionOS Simulator and unit tests.
///
/// Production code must not silently substitute this driver for unavailable ARKit tracking.
/// The normal simulator and denied-permission path remains gaze-and-pinch plus accessible
/// controls; automated tests opt in to this driver directly.
@MainActor
final class SimulatedHandInput: HandTrackingServicing {
    private let configuredStartState: HandTrackingState
    private let detectorConfiguration: HandSignalDetectorConfiguration
    private let signalContinuation: AsyncStream<HandTrackingDerivedEvent>.Continuation

    let signals: AsyncStream<HandTrackingDerivedEvent>
    private(set) var state: HandTrackingState = .idle
    private(set) var emittedSignals: [HandTrackingDerivedEvent] = []

    private var targets: HandTrackingTargets?
    private var detector: HandSignalDetector?

    init(
        startState: HandTrackingState = .running,
        detectorConfiguration: HandSignalDetectorConfiguration = .practiceDefault
    ) {
        configuredStartState = startState
        self.detectorConfiguration = detectorConfiguration
        let stream = AsyncStream.makeStream(
            of: HandTrackingDerivedEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        signals = stream.stream
        signalContinuation = stream.continuation
    }

    func configure(targets: HandTrackingTargets) {
        self.targets = targets
        detector = nil
        if state == .running {
            state = .paused
        }
    }

    func start() async {
        guard state != .running else { return }

        switch configuredStartState {
        case .running, .idle, .paused, .requestingPermission:
            guard let targets else {
                state = .failed(message: "The simulated CPR practice targets are unavailable.")
                yield(.trackingAvailabilityChanged(isAvailable: false))
                return
            }
            detector = HandSignalDetector(
                targets: targets,
                configuration: detectorConfiguration
            )
            state = .running
        case .permissionDenied:
            state = .permissionDenied
            yield(.trackingAvailabilityChanged(isAvailable: false))
        case .unavailable:
            state = .unavailable
            yield(.trackingAvailabilityChanged(isAvailable: false))
        case let .failed(message):
            state = .failed(message: message)
            yield(.trackingAvailabilityChanged(isAvailable: false))
        }
    }

    @discardableResult
    func submit(_ frame: SimulatedHandFrame) -> [HandTrackingDerivedEvent] {
        guard state == .running, var detector else { return [] }
        let events = detector.processFrame(
            timestampSeconds: frame.timestampSeconds,
            leftPalmWorld: frame.leftPalmWorld,
            rightPalmWorld: frame.rightPalmWorld
        )
        self.detector = detector
        for event in events {
            yield(event)
        }
        return events
    }

    func pause() {
        guard state == .running else { return }
        detector = nil
        state = .paused
    }

    func stop() {
        detector = nil
        state = .idle
    }

    func resetEmittedSignals() {
        emittedSignals.removeAll(keepingCapacity: false)
    }

    /// Test hook: injects an already-derived event (e.g. a grab interaction) so feature
    /// models can be exercised deterministically. Production code never synthesises
    /// derived events.
    func emit(_ event: HandTrackingDerivedEvent) {
        yield(event)
    }

    private func yield(_ event: HandTrackingDerivedEvent) {
        emittedSignals.append(event)
        signalContinuation.yield(event)
    }
}
