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

enum HandTrackingAuthorizationDecision: Sendable, Equatable {
    case allowed
    case denied
    case unavailable
}

enum HandTrackingProviderLifecycleState: Sendable, Equatable {
    case initialized
    case running
    case paused
    case stopped
}

/// Main-actor ARKit operations injected as one runtime so lifecycle behaviour can be
/// verified on the simulator without claiming that simulator hand tracking is available.
struct HandTrackingRuntime {
    let observesLiveProviderStreams: Bool
    let isSupported: @MainActor () -> Bool
    let makeSession: @MainActor () -> ARKitSession
    let makeProvider: @MainActor () -> HandTrackingProvider
    let requestAuthorization: @MainActor (ARKitSession) async -> HandTrackingAuthorizationDecision
    let run: @MainActor (ARKitSession, HandTrackingProvider) async throws -> Void
    let stop: @MainActor (ARKitSession) -> Void

    init(
        observesLiveProviderStreams: Bool = true,
        isSupported: @escaping @MainActor () -> Bool,
        makeSession: @escaping @MainActor () -> ARKitSession,
        makeProvider: @escaping @MainActor () -> HandTrackingProvider,
        requestAuthorization: @escaping @MainActor (ARKitSession) async -> HandTrackingAuthorizationDecision,
        run: @escaping @MainActor (ARKitSession, HandTrackingProvider) async throws -> Void,
        stop: @escaping @MainActor (ARKitSession) -> Void
    ) {
        self.observesLiveProviderStreams = observesLiveProviderStreams
        self.isSupported = isSupported
        self.makeSession = makeSession
        self.makeProvider = makeProvider
        self.requestAuthorization = requestAuthorization
        self.run = run
        self.stop = stop
    }

    @MainActor
    static let live = HandTrackingRuntime(
        observesLiveProviderStreams: true,
        isSupported: { HandTrackingProvider.isSupported },
        makeSession: { ARKitSession() },
        makeProvider: { HandTrackingProvider() },
        requestAuthorization: { session in
            let authorization = await session.requestAuthorization(for: [.handTracking])
            return switch authorization[.handTracking] {
            case .allowed: .allowed
            case .denied: .denied
            case .notDetermined, .none: .unavailable
            @unknown default: .unavailable
            }
        },
        run: { session, provider in
            try await session.run([provider])
        },
        stop: { session in
            session.stop()
        }
    )
}

/// Owns the real ARKit session used for optional hand-derived CPR guidance.
///
/// Privacy boundary: `HandAnchor`, `HandSkeleton`, and individual joint transforms exist only
/// inside the update loop. Each update is reduced immediately to one transient palm centroid,
/// processed into discrete signals, and discarded. Raw hand-tracking frames are never retained,
/// persisted, audited, or exposed to feature views.
@MainActor
final class HandTrackingService: HandTrackingServicing {
    private let runtime: HandTrackingRuntime
    private let signalContinuation: AsyncStream<HandTrackingDerivedEvent>.Continuation

    let signals: AsyncStream<HandTrackingDerivedEvent>
    private(set) var state: HandTrackingState = .idle

    private var targets: HandTrackingTargets?
    private var currentSession: ARKitSession?
    private var currentProvider: HandTrackingProvider?
    private var processor: HandSignalProcessor?
    private var anchorReductionTask: Task<Void, Never>?
    private var anchorUpdateTask: Task<Void, Never>?
    private var sessionEventTask: Task<Void, Never>?
    private var lifecycleGeneration = 0

    init(runtime: HandTrackingRuntime = .live) {
        self.runtime = runtime
        let stream = AsyncStream.makeStream(
            of: HandTrackingDerivedEvent.self,
            bufferingPolicy: .bufferingNewest(128)
        )
        signals = stream.stream
        signalContinuation = stream.continuation
    }

    func configure(targets: HandTrackingTargets) {
        if state == .running || state == .requestingPermission || currentSession != nil {
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
        guard runtime.isSupported() else {
            transitionToFallback(.unavailable)
            return
        }

        // A provider-originated pause keeps its event stream alive so recovery can be
        // observed. An explicit retry supersedes that retained run and must stop it first.
        if currentSession != nil {
            lifecycleGeneration &+= 1
            cancelAnchorTasks()
            processor = nil
            releaseCurrentRunResources()
        }
        lifecycleGeneration &+= 1
        let runGeneration = lifecycleGeneration
        let session = runtime.makeSession()
        let provider = runtime.makeProvider()
        currentSession = session
        currentProvider = provider
        if runtime.observesLiveProviderStreams {
            beginSessionEventMonitoring(
                session: session,
                provider: provider,
                runGeneration: runGeneration
            )
        }
        state = .requestingPermission
        let authorization = await runtime.requestAuthorization(session)
        guard !Task.isCancelled else {
            cancelRunIfCurrent(
                session: session,
                provider: provider,
                generation: runGeneration
            )
            return
        }
        guard isCurrentRunResources(
            session: session,
            provider: provider,
            generation: runGeneration,
            expectedState: .requestingPermission
        )
        else { return }

        switch authorization {
        case .allowed:
            do {
                let processor = HandSignalProcessor(
                    detector: HandSignalDetector(targets: targets)
                )
                try await runtime.run(session, provider)
                guard !Task.isCancelled else {
                    cancelRunIfCurrent(
                        session: session,
                        provider: provider,
                        generation: runGeneration
                    )
                    return
                }
                guard isCurrentRunResources(
                    session: session,
                    provider: provider,
                    generation: runGeneration,
                    expectedState: .requestingPermission
                ) else { return }
                self.processor = processor
                state = .running
                if runtime.observesLiveProviderStreams {
                    beginAnchorUpdates(
                        provider: provider,
                        using: processor,
                        runGeneration: runGeneration
                    )
                }
            } catch {
                if error is CancellationError || Task.isCancelled {
                    cancelRunIfCurrent(
                        session: session,
                        provider: provider,
                        generation: runGeneration
                    )
                    return
                }
                guard runGeneration == lifecycleGeneration else { return }
                transitionToFallback(.failed(message: error.localizedDescription))
            }
        case .denied:
            transitionToFallback(.permissionDenied)
        case .unavailable:
            transitionToFallback(.unavailable)
        }
    }

    func pause() {
        let hasProviderWaitingForRecovery = state == .paused && currentSession != nil
        guard state == .running ||
                state == .requestingPermission ||
                hasProviderWaitingForRecovery
        else { return }
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        processor = nil
        state = .paused
        releaseCurrentRunResources()
    }

    func stop() {
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        processor = nil
        state = .idle
        releaseCurrentRunResources()
    }

    private func beginAnchorUpdates(
        provider: HandTrackingProvider,
        using processor: HandSignalProcessor,
        runGeneration: Int
    ) {
        cancelAnchorTasks()
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

        anchorUpdateTask = Task.detached(priority: .userInitiated) { [weak self] in
            for await observation in reducedObservations.stream {
                guard !Task.isCancelled else { return }
                let events = await processor.process(observation)
                guard !Task.isCancelled else { return }
                await self?.publish(events, for: runGeneration)
            }
        }
    }

    private func beginSessionEventMonitoring(
        session: ARKitSession,
        provider: HandTrackingProvider,
        runGeneration: Int
    ) {
        sessionEventTask?.cancel()
        sessionEventTask = Task { [weak self] in
            for await event in session.events {
                guard let self, !Task.isCancelled else { return }
                guard isCurrentRunResources(
                    session: session,
                    provider: provider,
                    generation: runGeneration
                ) else { return }
                handleSessionEvent(event, provider: provider)
            }
        }
    }

    private func handleSessionEvent(
        _ event: ARKitSession.Event,
        provider: HandTrackingProvider
    ) {
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
            case .initialized:
                handleProviderLifecycleChange(.initialized)
            case .running:
                handleProviderLifecycleChange(.running)
            case .paused:
                handleProviderLifecycleChange(.paused)
            case .stopped:
                handleProviderLifecycleChange(
                    .stopped,
                    errorMessage: error?.localizedDescription
                )
            @unknown default:
                transitionToFallback(.unavailable)
            }
        @unknown default:
            transitionToFallback(.unavailable)
        }
    }

    /// Internal adapter seam shared by live ARKit events and simulator lifecycle tests.
    /// Live callers establish provider identity before forwarding a state change here.
    func handleProviderLifecycleChange(
        _ newState: HandTrackingProviderLifecycleState,
        errorMessage: String? = nil
    ) {
        guard currentSession != nil, currentProvider != nil else { return }
        switch newState {
        case .initialized:
            break
        case .running:
            guard state == .paused else { return }
            restartAfterProviderRecovery()
        case .paused:
            guard state == .running || state == .requestingPermission else { return }
            cancelAnchorTasks()
            processor = nil
            state = .paused
            signalContinuation.yield(.trackingAvailabilityChanged(isAvailable: false))
        case .stopped:
            guard state == .running ||
                    state == .requestingPermission ||
                    state == .paused
            else { return }
            transitionToFallback(
                .failed(
                    message: errorMessage ?? "The hand-tracking provider stopped unexpectedly."
                )
            )
        }
    }

    private func transitionToFallback(_ fallbackState: HandTrackingState) {
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        processor = nil
        state = fallbackState
        releaseCurrentRunResources()
        signalContinuation.yield(.trackingAvailabilityChanged(isAvailable: false))
    }

    private func cancelAnchorTasks() {
        anchorReductionTask?.cancel()
        anchorReductionTask = nil
        anchorUpdateTask?.cancel()
        anchorUpdateTask = nil
    }

    private func publish(
        _ events: [HandTrackingDerivedEvent],
        for generation: Int
    ) {
        guard generation == lifecycleGeneration, state == .running else { return }
        for event in events {
            signalContinuation.yield(event)
        }
    }

    private func isCurrentRunResources(
        session: ARKitSession,
        provider: HandTrackingProvider,
        generation: Int,
        expectedState: HandTrackingState? = nil
    ) -> Bool {
        guard generation == lifecycleGeneration,
              currentSession === session,
              currentProvider === provider
        else { return false }
        return expectedState.map { state == $0 } ?? true
    }

    private func releaseCurrentRunResources() {
        sessionEventTask?.cancel()
        sessionEventTask = nil
        let session = currentSession
        currentSession = nil
        currentProvider = nil
        if let session {
            runtime.stop(session)
        }
    }

    private func cancelRunIfCurrent(
        session: ARKitSession,
        provider: HandTrackingProvider,
        generation: Int
    ) {
        guard isCurrentRunResources(
            session: session,
            provider: provider,
            generation: generation
        ) else { return }
        lifecycleGeneration &+= 1
        cancelAnchorTasks()
        processor = nil
        state = .idle
        releaseCurrentRunResources()
    }

    /// ARKit may pause a provider when observations become unavailable. Keep the event
    /// monitor alive long enough to observe recovery, then replace the stopped run with
    /// a new session/provider pair instead of attempting to reuse ARKit provider state.
    private func restartAfterProviderRecovery() {
        lifecycleGeneration &+= 1
        let recoveryGeneration = lifecycleGeneration
        cancelAnchorTasks()
        processor = nil
        releaseCurrentRunResources()
        Task { [weak self] in
            guard let self,
                  lifecycleGeneration == recoveryGeneration,
                  state == .paused
            else { return }
            await start()
        }
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
