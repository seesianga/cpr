import ARKit
import simd
import XCTest
@testable import LifesaverVision

@MainActor
final class HandTrackingProviderLifecycleTests: XCTestCase {
    func testResumeAfterPauseCreatesFreshProviderAndReturnsToRunning() async throws {
        var sessions: [ARKitSession] = []
        var providers: [HandTrackingProvider] = []
        var runSessions: [ARKitSession] = []
        var runProviders: [HandTrackingProvider] = []
        var stoppedSessions: [ARKitSession] = []
        let runtime = HandTrackingRuntime(
            observesLiveProviderStreams: false,
            isSupported: { true },
            makeSession: {
                let session = ARKitSession()
                sessions.append(session)
                return session
            },
            makeProvider: {
                let provider = HandTrackingProvider()
                providers.append(provider)
                return provider
            },
            requestAuthorization: { _ in .allowed },
            run: { session, provider in
                runSessions.append(session)
                runProviders.append(provider)
            },
            stop: { stoppedSessions.append($0) }
        )
        let service = HandTrackingService(runtime: runtime)
        defer { service.stop() }
        service.configure(targets: try makeTargets())

        await service.start()
        XCTAssertEqual(service.state, .running)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(runSessions.count, 1)
        XCTAssertEqual(runProviders.count, 1)
        guard sessions.count == 1,
              providers.count == 1,
              runSessions.count == 1,
              runProviders.count == 1
        else { return XCTFail("The initial run must use exactly one fresh session/provider pair") }
        XCTAssertTrue(runSessions[0] === sessions[0])
        XCTAssertTrue(runProviders[0] === providers[0])

        service.pause()
        XCTAssertEqual(service.state, .paused)
        XCTAssertEqual(stoppedSessions.count, 1)
        guard stoppedSessions.count == 1 else {
            return XCTFail("Pause must stop the first session before resume")
        }
        XCTAssertTrue(stoppedSessions[0] === sessions[0])

        await service.start()
        XCTAssertEqual(service.state, .running)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(runSessions.count, 2)
        XCTAssertEqual(runProviders.count, 2)
        guard sessions.count == 2,
              providers.count == 2,
              runSessions.count == 2,
              runProviders.count == 2
        else { return XCTFail("Resume must run exactly the second fresh session/provider pair") }
        XCTAssertFalse(sessions[0] === sessions[1])
        XCTAssertFalse(providers[0] === providers[1])
        XCTAssertTrue(runSessions[1] === sessions[1])
        XCTAssertTrue(runProviders[1] === providers[1])
    }

    func testFailedRunCanRecoverWithFreshProvider() async throws {
        var sessions: [ARKitSession] = []
        var providers: [HandTrackingProvider] = []
        var runSessions: [ARKitSession] = []
        var runProviders: [HandTrackingProvider] = []
        var stoppedSessions: [ARKitSession] = []
        var runAttempt = 0
        let runtime = HandTrackingRuntime(
            observesLiveProviderStreams: false,
            isSupported: { true },
            makeSession: {
                let session = ARKitSession()
                sessions.append(session)
                return session
            },
            makeProvider: {
                let provider = HandTrackingProvider()
                providers.append(provider)
                return provider
            },
            requestAuthorization: { _ in .allowed },
            run: { session, provider in
                runSessions.append(session)
                runProviders.append(provider)
                runAttempt += 1
                if runAttempt == 1 { throw RuntimeFailure.expected }
            },
            stop: { stoppedSessions.append($0) }
        )
        let service = HandTrackingService(runtime: runtime)
        defer { service.stop() }
        service.configure(targets: try makeTargets())

        await service.start()
        guard case .failed = service.state else {
            return XCTFail("The first injected run should enter a recoverable fallback state")
        }
        XCTAssertEqual(stoppedSessions.count, 1)
        guard sessions.count == 1, stoppedSessions.count == 1 else {
            return XCTFail("A failed run must release the session it attempted")
        }
        XCTAssertTrue(stoppedSessions[0] === sessions[0])

        await service.start()
        XCTAssertEqual(service.state, .running)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(runSessions.count, 2)
        XCTAssertEqual(runProviders.count, 2)
        guard sessions.count == 2,
              providers.count == 2,
              runSessions.count == 2,
              runProviders.count == 2
        else { return XCTFail("Recovery must run exactly two fresh session/provider pairs") }
        XCTAssertFalse(providers[0] === providers[1])
        XCTAssertTrue(runSessions[0] === sessions[0])
        XCTAssertTrue(runSessions[1] === sessions[1])
        XCTAssertTrue(runProviders[0] === providers[0])
        XCTAssertTrue(runProviders[1] === providers[1])
    }

    func testUnsupportedStartCanRecoverWhenSupportBecomesAvailable() async throws {
        var isSupported = false
        var providers: [HandTrackingProvider] = []
        var runProviders: [HandTrackingProvider] = []
        let runtime = HandTrackingRuntime(
            observesLiveProviderStreams: false,
            isSupported: { isSupported },
            makeSession: { ARKitSession() },
            makeProvider: {
                let provider = HandTrackingProvider()
                providers.append(provider)
                return provider
            },
            requestAuthorization: { _ in .allowed },
            run: { _, provider in runProviders.append(provider) },
            stop: { _ in }
        )
        let service = HandTrackingService(runtime: runtime)
        defer { service.stop() }
        service.configure(targets: try makeTargets())

        await service.start()
        XCTAssertEqual(service.state, .unavailable)
        XCTAssertTrue(providers.isEmpty)

        isSupported = true
        await service.start()
        XCTAssertEqual(service.state, .running)
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(runProviders.count, 1)
        guard providers.count == 1, runProviders.count == 1 else {
            return XCTFail("The recovered supported run must execute its fresh provider")
        }
        XCTAssertTrue(runProviders[0] === providers[0])
    }

    func testProviderAvailabilityRecoveryReplacesPausedRun() async throws {
        var sessions: [ARKitSession] = []
        var providers: [HandTrackingProvider] = []
        var runProviders: [HandTrackingProvider] = []
        var stoppedSessions: [ARKitSession] = []
        let runtime = HandTrackingRuntime(
            observesLiveProviderStreams: false,
            isSupported: { true },
            makeSession: {
                let session = ARKitSession()
                sessions.append(session)
                return session
            },
            makeProvider: {
                let provider = HandTrackingProvider()
                providers.append(provider)
                return provider
            },
            requestAuthorization: { _ in .allowed },
            run: { _, provider in runProviders.append(provider) },
            stop: { stoppedSessions.append($0) }
        )
        let service = HandTrackingService(runtime: runtime)
        defer { service.stop() }
        service.configure(targets: try makeTargets())

        await service.start()
        service.handleProviderLifecycleChange(.paused)
        XCTAssertEqual(service.state, .paused)
        XCTAssertTrue(stoppedSessions.isEmpty)

        service.handleProviderLifecycleChange(.running)
        try await waitUntil {
            service.state == .running && providers.count == 2
        }

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(runProviders.count, 2)
        XCTAssertEqual(stoppedSessions.count, 1)
        guard sessions.count == 2,
              providers.count == 2,
              runProviders.count == 2,
              stoppedSessions.count == 1
        else { return XCTFail("Provider recovery must stop run one and execute run two") }
        XCTAssertTrue(stoppedSessions[0] === sessions[0])
        XCTAssertFalse(providers[0] === providers[1])
        XCTAssertTrue(runProviders[1] === providers[1])
    }

    func testProviderStopWhilePausedEntersRecoverableFallback() async throws {
        var sessions: [ARKitSession] = []
        var stoppedSessions: [ARKitSession] = []
        let runtime = HandTrackingRuntime(
            observesLiveProviderStreams: false,
            isSupported: { true },
            makeSession: {
                let session = ARKitSession()
                sessions.append(session)
                return session
            },
            makeProvider: { HandTrackingProvider() },
            requestAuthorization: { _ in .allowed },
            run: { _, _ in },
            stop: { stoppedSessions.append($0) }
        )
        let service = HandTrackingService(runtime: runtime)
        defer { service.stop() }
        service.configure(targets: try makeTargets())

        await service.start()
        service.handleProviderLifecycleChange(.paused)
        service.handleProviderLifecycleChange(
            .stopped,
            errorMessage: "Injected provider stop"
        )

        guard case let .failed(message) = service.state else {
            return XCTFail("A stopped paused provider must enter a recoverable fallback")
        }
        XCTAssertTrue(message.contains("Injected provider stop"))
        XCTAssertEqual(stoppedSessions.count, 1)
        guard sessions.count == 1, stoppedSessions.count == 1 else {
            return XCTFail("The stopped provider run must release its original session")
        }
        XCTAssertTrue(stoppedSessions[0] === sessions[0])
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the provider lifecycle transition")
    }
}

@MainActor
final class IntegratedScenarioHandInputTests: XCTestCase {
    func testSyntheticHandCompressionIsInertBeforeScenarioCPRStage() async throws {
        let driver = SyntheticHandTrackingDriver()
        let model = IntegratedScenarioSessionModel(handTracking: driver)
        defer { model.stop() }
        try await prepareScenario(model, handTracking: driver)

        let initialEventCount = model.eventLog.count
        driver.send(compression(at: 0, placement: .sternumTarget))
        driver.send(.trackingAvailabilityChanged(isAvailable: false))
        try await waitUntil {
            model.handTrackingFallbackExplanation?.contains("temporarily") == true
        }

        XCTAssertEqual(model.stage, .sceneSafety)
        XCTAssertEqual(model.cprCompressionCount, 0)
        XCTAssertEqual(model.eventLog.count, initialEventCount)
    }

    func testSyntheticHandCompressionStreamCompletesIntegratedScenarioCPRStage() async throws {
        let driver = SyntheticHandTrackingDriver()
        let model = IntegratedScenarioSessionModel(handTracking: driver)
        defer { model.stop() }
        try await prepareScenario(model, handTracking: driver)

        advanceToCPR(model)
        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        for index in 0..<model.requiredCompressionCount {
            driver.send(compression(
                at: Double(index) * interval,
                placement: .sternumTarget
            ))
            await Task.yield()
        }
        try await waitUntil { model.stage == .aedPreparation }

        XCTAssertEqual(model.cprCompressionCount, model.requiredCompressionCount)
        let acceptedCompressions = model.eventLog.filter { record in
            guard record.wasAccepted,
                  case .cpr(.compressionDetected) = record.event
            else { return false }
            return true
        }
        XCTAssertEqual(acceptedCompressions.count, model.requiredCompressionCount)
    }

    func testSyntheticXiphoidCompressionUsesUnsafeScenarioPath() async throws {
        let driver = SyntheticHandTrackingDriver()
        let model = IntegratedScenarioSessionModel(handTracking: driver)
        defer { model.stop() }
        try await prepareScenario(model, handTracking: driver)
        advanceToCPR(model)

        model.performCPR(unsafeXiphoidPlacement: false, timestampSeconds: 0)
        driver.send(compression(at: 1, placement: .xiphoidAvoidZone))
        try await waitUntil { model.stage == .correction }

        XCTAssertEqual(model.cprCompressionCount, 1)
        XCTAssertTrue(model.correction?.code.contains("xiphoid") == true)
    }

    func testScenarioCPRClockExcludesPausedDuration() async throws {
        let driver = SyntheticHandTrackingDriver()
        let model = IntegratedScenarioSessionModel(handTracking: driver)
        defer { model.stop() }
        try await prepareScenario(model, handTracking: driver)
        advanceToCPR(model)

        let interval = 60 / CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        model.performCPR(
            unsafeXiphoidPlacement: false,
            uptimeSeconds: 100
        )
        await model.setPaused(true, at: 100)
        await model.setPaused(false, at: 110)
        model.performCPR(
            unsafeXiphoidPlacement: false,
            uptimeSeconds: 110 + interval
        )

        let timestamps = model.eventLog.compactMap { record -> Double? in
            guard record.wasAccepted,
                  case let .cpr(.compressionDetected(timestamp, _, _)) = record.event
            else { return nil }
            return timestamp
        }
        XCTAssertEqual(timestamps.count, 2)
        guard timestamps.count == 2 else {
            return XCTFail("Both pre-pause and post-resume compression timestamps are required")
        }
        XCTAssertEqual(timestamps[0], 0, accuracy: 0.000_1)
        XCTAssertEqual(timestamps[1], interval, accuracy: 0.000_1)
    }

    func testUnavailableTrackingMessagesAreHonestFromSessionStart() async throws {
        let scenarioDriver = SyntheticHandTrackingDriver(startState: .unavailable)
        let scenario = IntegratedScenarioSessionModel(handTracking: scenarioDriver)
        defer { scenario.stop() }
        try await prepareScenario(scenario, handTracking: scenarioDriver)

        XCTAssertEqual(scenario.handTrackingState, .unavailable)
        XCTAssertTrue(scenario.handTrackingFallbackExplanation?.contains("unavailable here") == true)
        XCTAssertFalse(scenario.handTrackingFallbackExplanation?.contains("temporarily") == true)

        let cprDriver = SimulatedHandInput(startState: .unavailable)
        let cpr = CPRPracticeSessionModel(handTracking: cprDriver)
        await cpr.prepare()
        cpr.configureHandTracking(targets: try makeTargets())
        await cpr.startHandTracking()

        XCTAssertEqual(cpr.handTrackingState, .unavailable)
        XCTAssertTrue(cpr.handTrackingFallbackExplanation?.contains("unavailable here") == true)
        XCTAssertFalse(cpr.handTrackingFallbackExplanation?.contains("temporarily") == true)

        await cpr.stop()
    }

    func testScenarioResetClearsDebriefAndAllowsFreshPrepare() async throws {
        let driver = SyntheticHandTrackingDriver()
        let model = IntegratedScenarioSessionModel(handTracking: driver)
        defer { model.stop() }
        try await prepareScenario(model, handTracking: driver)

        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: false)
        model.chooseAEDDistance(.far)
        model.assessBreathing(.normal)
        XCTAssertEqual(model.stage, .debrief)
        XCTAssertNotNil(model.debrief)

        await model.reset()

        XCTAssertEqual(model.stage, .sceneSafety)
        XCTAssertNil(model.engine)
        XCTAssertNil(model.debrief)
        XCTAssertNil(model.correction)
        XCTAssertTrue(model.eventLog.isEmpty)
        XCTAssertEqual(model.cprCompressionCount, 0)
        XCTAssertEqual(model.analysisRound, 0)
        XCTAssertFalse(model.callAssigned)
        XCTAssertFalse(model.aedRetrievalAssigned)

        await model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )
        XCTAssertEqual(model.stage, .sceneSafety)
        XCTAssertNotNil(model.engine)
        XCTAssertEqual(model.eventLog.count, 1)
    }

    private func prepareScenario(
        _ model: IntegratedScenarioSessionModel,
        handTracking: SyntheticHandTrackingDriver
    ) async throws {
        await model.prepare(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            audioDirector: NoOpAudioDirector()
        )
        model.configureHandTracking(targets: try makeTargets())
        await model.startHandTracking()
        XCTAssertNotNil(model.engine)
    }

    private func advanceToCPR(_ model: IntegratedScenarioSessionModel) {
        model.assessScene(unsafeEntry: false)
        model.checkResponse()
        model.chooseResponderAvailability(bystanderAvailable: false)
        model.chooseAEDDistance(.far)
        model.assessBreathing(.absentOrAbnormal)
        XCTAssertEqual(model.stage, .cpr)
    }

    private func compression(
        at timestamp: Double,
        placement: CPRHandPlacementZone
    ) -> HandTrackingDerivedEvent {
        .compressionDetected(
            timestampSeconds: timestamp,
            placement: placement,
            handStacking: .likelyStacked
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for the hand-derived scenario transition")
    }
}

@MainActor
final class SimulationNavigationResetTests: XCTestCase {
    func testSuccessfulSimulationDismissalResetsSelectionAndPreservesOptIn() {
        let model = AppModel()
        model.selectIntegratedScenario(
            scenarioID: "scenario-a-home",
            patternID: "S-N-N",
            scene: .home
        )
        model.hasUserOptedInToImmersion = true

        model.simulationDismissalDidComplete()

        XCTAssertEqual(model.selectedPracticeExperience, .cpr)
        XCTAssertEqual(model.selectedSimulationScene, .cprPracticeRoom)
        XCTAssertNil(model.selectedIntegratedScenarioID)
        XCTAssertNil(model.selectedIntegratedScenarioPatternID)
        XCTAssertTrue(model.hasUserOptedInToImmersion)
    }

    func testAEDPlacementCanNavigateBackToPreparationRoom() {
        let model = AppModel()
        model.selectPractice(.aed)
        model.moveAEDPractice(to: .aedPlacementRoom)
        model.simulationRoomDidLoad(.aedPlacementRoom)

        model.moveAEDPractice(to: .aedPreparationRoom)

        XCTAssertEqual(model.selectedSimulationScene, .aedPreparationRoom)
        XCTAssertTrue(model.isSimulationRoomTransitionInFlight)
        model.simulationRoomDidLoad(.aedPreparationRoom)
        XCTAssertFalse(model.isSimulationRoomTransitionInFlight)
    }
}

@MainActor
private final class SyntheticHandTrackingDriver: HandTrackingServicing {
    private let configuredStartState: HandTrackingState
    private let continuation: AsyncStream<HandTrackingDerivedEvent>.Continuation
    private var hasTargets = false

    let signals: AsyncStream<HandTrackingDerivedEvent>
    private(set) var state: HandTrackingState = .idle

    init(startState: HandTrackingState = .running) {
        configuredStartState = startState
        let stream = AsyncStream.makeStream(
            of: HandTrackingDerivedEvent.self,
            bufferingPolicy: .bufferingNewest(256)
        )
        signals = stream.stream
        continuation = stream.continuation
    }

    func configure(targets: HandTrackingTargets) {
        hasTargets = true
        if state == .running { state = .paused }
    }

    func start() async {
        guard hasTargets else {
            state = .failed(message: "Synthetic targets missing")
            continuation.yield(.trackingAvailabilityChanged(isAvailable: false))
            return
        }
        state = configuredStartState
        if state.usesAccessibleFallback {
            continuation.yield(.trackingAvailabilityChanged(isAvailable: false))
        }
    }

    func pause() {
        if state == .running { state = .paused }
    }

    func stop() {
        state = .idle
    }

    func send(_ event: HandTrackingDerivedEvent) {
        continuation.yield(event)
    }
}

private enum RuntimeFailure: Error {
    case expected
}

@MainActor
private func makeTargets() throws -> HandTrackingTargets {
    let sternum = try XCTUnwrap(HandTrackingTargetVolume(
        worldFromTargetTransform: matrix_identity_float4x4,
        localCenter: .zero,
        localExtents: [0.20, 0.02, 0.20]
    ))
    var xiphoidTransform = matrix_identity_float4x4
    xiphoidTransform.columns.3 = [0, 0, 0.30, 1]
    let xiphoid = try XCTUnwrap(HandTrackingTargetVolume(
        worldFromTargetTransform: xiphoidTransform,
        localCenter: .zero,
        localExtents: [0.08, 0.02, 0.08]
    ))
    return HandTrackingTargets(sternum: sternum, xiphoidAvoidZone: xiphoid)
}
