import ARKit
import Foundation
import simd

/// The observable lifecycle of optional detailed hand tracking.
enum HandTrackingState: Codable, Equatable, Sendable {
    case idle
    case requestingPermission
    case running
    case paused
    case permissionDenied
    case unavailable
    case failed(message: String)
}

/// An app-facing boundary around hand-derived CPR practice signals.
///
/// Permission denial, provider failure, and unsupported hardware are normal fallback states.
/// Callers must keep the complete gaze-and-pinch and accessible-control practice path available.
@MainActor
protocol HandTrackingServicing: AnyObject {
    var state: HandTrackingState { get }
    var signals: AsyncStream<HandTrackingDerivedEvent> { get }

    func configure(targets: HandTrackingTargets)
    func start() async
    func pause()
    func stop()
}

/// Owns the real ARKit session used for optional hand-derived CPR guidance.
///
/// Privacy boundary: `HandAnchor`, `HandSkeleton`, and individual joint transforms exist only
/// inside the update loop. Each update is reduced immediately to one transient palm centroid,
/// processed into discrete signals, and discarded. Raw hand-tracking frames are never retained,
/// persisted, audited, or exposed to feature views.
@MainActor
final class HandTrackingService: HandTrackingServicing {
    private let session: ARKitSession
    private let provider: HandTrackingProvider
    private let signalContinuation: AsyncStream<HandTrackingDerivedEvent>.Continuation

    let signals: AsyncStream<HandTrackingDerivedEvent>
    private(set) var state: HandTrackingState = .idle

    private var targets: HandTrackingTargets?
    private var processor: HandSignalProcessor?
    private var anchorReductionTask: Task<Void, Never>?
    private var anchorUpdateTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init(
        session: ARKitSession = ARKitSession(),
        provider: HandTrackingProvider = HandTrackingProvider()
    ) {
        self.session = session
        self.provider = provider
        let stream = AsyncStream.makeStream(
            of: HandTrackingDerivedEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        signals = stream.stream
        signalContinuation = stream.continuation
    }

    func configure(targets: HandTrackingTargets) {
        if state == .running || state == .requestingPermission {
            pause()
        }
        self.targets = targets
    }

    func start() async {
        guard state != .running, state != .requestingPermission else { return }
        guard let targets else {
            transitionToFallback(.failed(message: "The CPR practice targets are unavailable."))
            return
        }
        guard HandTrackingProvider.isSupported else {
            transitionToFallback(.unavailable)
            return
        }

        lifecycleGeneration &+= 1
        let runGeneration = lifecycleGeneration
        beginSessionEventMonitoringIfNeeded()
        state = .requestingPermission
        let authorization = await session.requestAuthorization(for: [.handTracking])
        guard runGeneration == lifecycleGeneration,
              state == .requestingPermission
        else { return }

        switch authorization[.handTracking] {
        case .allowed:
            do {
                let processor = HandSignalProcessor(
                    detector: HandSignalDetector(targets: targets)
                )
                try await session.run([provider])
                guard runGeneration == lifecycleGeneration,
                      state == .requestingPermission
                else {
                    stopSessionUnlessAnotherRunStarted()
                    return
                }
                self.processor = processor
                state = .running
                beginAnchorUpdates(
                    using: processor,
                    runGeneration: runGeneration
                )
            } catch {
                guard runGeneration == lifecycleGeneration else { return }
                transitionToFallback(.failed(message: error.localizedDescription))
            }
        case .denied:
            transitionToFallback(.permissionDenied)
        case .notDetermined, .none:
            transitionToFallback(.unavailable)
        @unknown default:
            transitionToFallback(.unavailable)
        }
    }

    func pause() {
        guard state == .running || state == .requestingPermission else { return }
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        processor = nil
        state = .paused
        session.stop()
    }

    func stop() {
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        sessionEventTask?.cancel()
        sessionEventTask = nil
        processor = nil
        session.stop()
        state = .idle
    }

    private func beginAnchorUpdates(
        using processor: HandSignalProcessor,
        runGeneration: Int
    ) {
        cancelAnchorTasks()
        let provider = provider
        let reducedObservations = AsyncStream.makeStream(
            of: TrackedPalmObservation.self,
            bufferingPolicy: .bufferingNewest(32)
        )

        // This producer performs the privacy reduction synchronously. No raw ARKit anchor,
        // skeleton, joint collection, or update crosses the stream boundary or an actor await.
        anchorReductionTask = Task.detached(priority: .userInitiated) {
            defer { reducedObservations.continuation.finish() }
            for await update in provider.anchorUpdates {
                guard !Task.isCancelled else { return }
                reducedObservations.continuation.yield(
                    ARKitPalmObservationExtractor.observation(from: update)
                )
            }
        }

        let signalContinuation = signalContinuation
        anchorUpdateTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await observation in reducedObservations.stream {
                guard !Task.isCancelled else { return }
                let events = await processor.process(observation)
                guard !Task.isCancelled,
                      await self?.isCurrentRun(runGeneration) == true
                else { return }
                for event in events {
                    signalContinuation.yield(event)
                }
            }
        }
    }

    private func beginSessionEventMonitoringIfNeeded() {
        guard sessionEventTask == nil else { return }
        let session = session
        sessionEventTask = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { return }
                handleSessionEvent(event)
            }
        }
    }

    private func handleSessionEvent(_ event: ARKitSession.Event) {
        switch event {
        case let .authorizationChanged(type, status):
            guard type == .handTracking else { return }
            switch status {
            case .allowed:
                break
            case .denied:
                transitionToFallback(.permissionDenied)
            case .notDetermined:
                transitionToFallback(.unavailable)
            @unknown default:
                transitionToFallback(.unavailable)
            }

        case let .dataProviderStateChanged(dataProviders, newState, error):
            let concernsHandTracking = dataProviders.contains {
                ObjectIdentifier($0) == ObjectIdentifier(provider)
            }
            guard concernsHandTracking else { return }

            switch newState {
            case .running, .initialized:
                break
            case .paused:
                guard state == .running else { return }
                lifecycleGeneration &+= 1
                cancelAnchorTasks()
                processor = nil
                state = .paused
            case .stopped:
                guard state == .running || state == .requestingPermission else { return }
                transitionToFallback(
                    .failed(message: error?.localizedDescription ?? "The hand-tracking provider stopped unexpectedly.")
                )
            @unknown default:
                transitionToFallback(.unavailable)
            }
        @unknown default:
            transitionToFallback(.unavailable)
        }
    }

    private func transitionToFallback(_ fallbackState: HandTrackingState) {
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        processor = nil
        state = fallbackState
        session.stop()
        signalContinuation.yield(.trackingAvailabilityChanged(isAvailable: false))
    }

    private func cancelAnchorTasks() {
        anchorReductionTask?.cancel()
        anchorReductionTask = nil
        anchorUpdateTask?.cancel()
        anchorUpdateTask = nil
    }

    private func isCurrentRun(_ generation: Int) -> Bool {
        generation == lifecycleGeneration && state == .running
    }

    private func stopSessionUnlessAnotherRunStarted() {
        guard state != .requestingPermission, state != .running else { return }
        session.stop()
    }
}

private actor HandSignalProcessor {
    private var detector: HandSignalDetector

    init(detector: HandSignalDetector) {
        self.detector = detector
    }

    func process(_ observation: TrackedPalmObservation) -> [HandTrackingDerivedEvent] {
        detector.process(observation)
    }
}

private enum ARKitPalmObservationExtractor {
    private static let palmJointNames: [HandSkeleton.JointName] = [
        .wrist,
        .indexFingerMetacarpal,
        .middleFingerMetacarpal,
        .ringFingerMetacarpal,
        .littleFingerMetacarpal
    ]
    private static let minimumTrackedJointCount = 3

    static func observation(
        from update: AnchorUpdate<HandAnchor>
    ) -> TrackedPalmObservation {
        let anchor = update.anchor
        let chirality: TrackedHandChirality = switch anchor.chirality {
        case .left: .left
        case .right: .right
        @unknown default: .right
        }

        guard update.event != .removed,
              anchor.isTracked,
              let skeleton = anchor.handSkeleton
        else {
            return TrackedPalmObservation(
                timestampSeconds: update.timestamp,
                chirality: chirality,
                palmCentroidWorld: nil
            )
        }

        let trackedPoints = palmJointNames.compactMap { jointName -> SIMD3<Float>? in
            let joint = skeleton.joint(jointName)
            guard joint.isTracked else { return nil }
            let worldFromJoint = anchor.originFromAnchorTransform *
                joint.anchorFromJointTransform
            let translation = worldFromJoint.columns.3
            return SIMD3<Float>(translation.x, translation.y, translation.z)
        }
        guard trackedPoints.count >= minimumTrackedJointCount else {
            return TrackedPalmObservation(
                timestampSeconds: update.timestamp,
                chirality: chirality,
                palmCentroidWorld: nil
            )
        }

        let centroid = trackedPoints.reduce(SIMD3<Float>.zero, +) /
            Float(trackedPoints.count)
        return TrackedPalmObservation(
            timestampSeconds: update.timestamp,
            chirality: chirality,
            palmCentroidWorld: centroid
        )
    }
}
