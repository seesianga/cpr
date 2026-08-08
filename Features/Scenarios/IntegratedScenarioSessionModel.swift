import Foundation
import Observation
import SwiftData
import SwiftUI

private enum IntegratedScenarioSessionError: Error {
    case rejectedClinicalTransition
}

enum IntegratedScenarioStage: String, Sendable, Equatable {
    case sceneSafety
    case response
    case distraction
    case responderContext
    case delegation
    case aedDistance
    case breathing
    case cpr
    case aedPreparation
    case aedAnalysisClear
    case aedAnalysingDecision
    case aedCharging
    case aedClearConfirmation
    case aedSimulatedShock
    case aedResume
    case correction
    case debrief
}

extension IntegratedScenarioScene {
    var spatialSceneName: SpatialSceneName {
        switch self {
        case .home: .scenarioHome
        case .shoppingCentre: .scenarioShoppingCentre
        case .workplace: .scenarioWorkplace
        case .communityFacility: .scenarioCommunityFacility
        }
    }
}

/// Learner-facing orchestration over the pure ScenarioEngine. Every clinical transition
/// is submitted to a Phase 5A reducer; view controls never mutate clinical state directly.
@MainActor
@Observable
final class IntegratedScenarioSessionModel {
    private let handTracking: any HandTrackingServicing
    private(set) var engine: ScenarioEngine?
    private(set) var stage: IntegratedScenarioStage = .sceneSafety
    private(set) var correction: ScenarioCriticalCorrection?
    private(set) var debrief: ScenarioDebrief?
    private(set) var lastAnalysisOutcome: AEDAnalysisOutcome?
    private(set) var analysisRound = 0
    private(set) var errorMessage: String?
    private(set) var callAssigned = false
    private(set) var aedRetrievalAssigned = false
    private(set) var isPaused = false
    private(set) var isLoneRescuer = false
    private(set) var cprCompressionCount = 0
    private(set) var handTrackingState: HandTrackingState = .idle
    private(set) var scoringDecision: ScenarioScoringDecision = .practiceOnly(.notVerified)
    let requiredCompressionCount = CPRPracticePolicy.sourceBacked.preferredCompressionsPerCycle
    var selectedBystanderAssignment: ScenarioBystanderAssignment = .getAED

    private var stageBeforeCorrection: IntegratedScenarioStage = .sceneSafety
    private var cprPositioningComplete = false
    private var cprLandmarkConfirmed = false
    private var cprStartedAtUptime: TimeInterval?
    private var handTimestampOffset: TimeInterval?
    private var accumulatedPausedSeconds = 0.0
    private var pauseStartedAt: TimeInterval?
    private var isAEDCycleReadyForAnalysis = false
    private var isHandTrackingSceneActive = false
    private var handObservationFallbackExplanation: String?
    private var signalTask: Task<Void, Never>?
    private var audioDirector: (any AudioDirector)?
    private var audioCommandTask: Task<Void, Never>?

    init(handTracking: any HandTrackingServicing = HandTrackingService()) {
        self.handTracking = handTracking
    }

    var eventLog: [IntegratedScenarioEventRecord] { engine?.eventLog ?? [] }
    var scenarioTitle: String { engine?.definition.title ?? "Integrated scenario" }
    var aedState: AEDPracticeState? { engine?.aedState }
    var selectedPatternID: String? { engine?.selectedPattern.id }
    var totalAnalysisRounds: Int { engine?.selectedPattern.analysisOutcomes.count ?? 0 }
    var scenarioScene: IntegratedScenarioScene? { engine?.scene ?? debrief?.scene }
    var handTrackingFallbackExplanation: String? {
        handTrackingState.fallbackExplanation ?? handObservationFallbackExplanation
    }

    func prepare(
        scenarioID: String,
        patternID: String,
        audioDirector: any AudioDirector,
        modelContainer: ModelContainer? = nil,
        bundle: Bundle = .main
    ) async {
        guard !Task.isCancelled else { return }
        audioCommandTask?.cancel()
        audioCommandTask = nil
        clearAttemptState()
        self.audioDirector = audioDirector
        startSignalConsumerIfNeeded()
        do {
            let document = try ScenarioDefinitionsCodec.load(from: bundle)
            let gate = ScenarioScoringGate()
            let decision: ScenarioScoringDecision
            if let modelContainer {
                decision = await gate.authorizeBundledLaunch(
                    document: document,
                    scenarioID: scenarioID,
                    modelContainer: modelContainer,
                    bundle: bundle
                )
            } else {
                decision = gate.authorizeBundledPracticeOnly(
                    document: document,
                    scenarioID: scenarioID,
                    bundle: bundle
                )
            }

            guard !Task.isCancelled else {
                stop()
                return
            }

            engine = try ScenarioEngine(
                document: document,
                scenarioID: scenarioID,
                selector: DeterministicScenarioPatternSelector(patternID: patternID)
            )
            scoringDecision = decision
            enqueueAudioCommand { director in
                _ = await director.play(
                    AudioPlaybackRequest(
                        cue: AudioCue(rawValue: "music.scenario_bed"),
                        context: .immersive,
                        autoplay: true
                    )
                )
            }
        } catch {
            engine = nil
            scoringDecision = .practiceOnly(.contentUnavailable)
            errorMessage = "The approved scenario definition could not be prepared."
        }
    }

    /// Clears all attempt evidence and returns the coordinator to its launch stage.
    /// The caller can immediately invoke `prepare` to begin a fresh in-session attempt.
    func reset() async {
        audioCommandTask?.cancel()
        audioCommandTask = nil
        let director = audioDirector
        clearAttemptState()
        if let director {
            await director.setAEDSafetyState(.normal)
            await director.setSafetyCriticalCorrectionActive(false)
        }
    }

    func configureHandTracking(targets: HandTrackingTargets) {
        isHandTrackingSceneActive = true
        handTimestampOffset = nil
        handObservationFallbackExplanation = nil
        handTracking.configure(targets: targets)
        handTrackingState = handTracking.state
    }

    func startHandTracking() async {
        guard isHandTrackingSceneActive, !isPaused else { return }
        startSignalConsumerIfNeeded()
        await handTracking.start()
        handTrackingState = handTracking.state
    }

    /// Stops only the current provider run. The stable signal consumer remains ready for
    /// an in-session restart after the debrief room returns to the authored scenario room.
    func stopHandTracking() {
        isHandTrackingSceneActive = false
        handTimestampOffset = nil
        handTracking.stop()
        handTrackingState = handTracking.state
        handObservationFallbackExplanation = nil
    }

    func stop() {
        stopHandTracking()
        signalTask?.cancel()
        signalTask = nil
        audioCommandTask?.cancel()
        audioCommandTask = nil
    }

    func assessScene(unsafeEntry: Bool) {
        guard !isPaused, stage == .sceneSafety else { return }
        guard var engine else { return }
        do {
            if unsafeEntry {
                // A critical unsafe entry must be remediated before the authored branch
                // cursor advances, otherwise the guided retry could skip scene safety.
                try requireAccepted(
                    engine.submit(.inspectDanger(sceneUnsafe: true, enteredUnsafeScene: true))
                )
            } else {
                try requireAccepted(
                    engine.submit(.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false))
                )
                try selectBranch(condition: "sceneSafe", in: &engine)
                try completeAction(suffix: "action-assess-scene", in: &engine)
                stage = .response
            }
            self.engine = engine
            detectCorrection(returningTo: .sceneSafety)
        } catch {
            failAction()
        }
    }

    func checkResponse() {
        guard !isPaused, stage == .response else { return }
        guard var engine else { return }
        do {
            try requireAccepted(engine.submit(.checkResponse(isUnresponsive: true)))
            try completeAction(suffix: "action-check-responsiveness", in: &engine)
            self.engine = engine
            stage = engine.definition.id == "scenario-b-shopping-centre"
                ? .distraction
                : .responderContext
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    /// Scenario B's environmental beat is context only. The two controls intentionally
    /// produce the same non-scoring continuation, so accessibility support cannot be penalised.
    func continuePastDistraction(accessibilitySupportUsed: Bool) {
        guard !isPaused, stage == .distraction, var engine else { return }
        do {
            try engine.presentScenarioBDistraction(
                id: "shopping-centre-announcement",
                accessibilitySupportUsed: accessibilitySupportUsed
            )
            self.engine = engine
            stage = .responderContext
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func chooseResponderAvailability(bystanderAvailable: Bool) {
        guard !isPaused, stage == .responderContext, var engine else { return }
        do {
            try selectBranch(
                condition: bystanderAvailable ? "bystanderAvailable" : "rescuerAlone",
                in: &engine
            )
            if bystanderAvailable {
                stage = .delegation
            } else {
                try requireAccepted(engine.submit(.shoutForHelp(helpActivated: true)))
                try completeAction(suffix: "action-activate-help", in: &engine)
                try requireAccepted(
                    engine.submit(.rehearse995Call(clearlyLabelledSimulation: true))
                )
                try completeAction(suffix: "action-communicate-clearly", in: &engine)
                callAssigned = true
                stage = .aedDistance
            }
            isLoneRescuer = !bystanderAvailable
            self.engine = engine
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func assignSelectedTask(
        to bystanderID: String,
        method: ScenarioInteractionMethod
    ) {
        guard !isPaused, stage == .delegation else { return }
        guard var engine else { return }
        do {
            switch selectedBystanderAssignment {
            case .callSimulated995:
                if !callAssigned {
                    try requireAccepted(engine.submit(.shoutForHelp(helpActivated: true)))
                    try requireAccepted(
                        engine.submit(.rehearse995Call(clearlyLabelledSimulation: true))
                    )
                    try engine.assignBystander(
                        bystanderID,
                        assignment: .callSimulated995,
                        method: method
                    )
                    callAssigned = true
                }
            case .getAED:
                try engine.assignBystander(
                    bystanderID,
                    assignment: .getAED,
                    method: method
                )
                aedRetrievalAssigned = true
            }

            if callAssigned && aedRetrievalAssigned {
                stage = .aedDistance
            }
            self.engine = engine
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func chooseAEDDistance(_ distance: AEDDistance) {
        guard !isPaused, stage == .aedDistance, var engine else { return }
        do {
            try selectBranch(
                condition: distance == .near ? "aedNear" : "aedFar",
                in: &engine
            )
            try requireAccepted(
                engine.submit(
                    .delegateAED(
                        bystanderAvailable: !isLoneRescuer,
                        alone: isLoneRescuer,
                        distance: distance,
                        learnerLeavesCasualty: false
                    )
                )
            )
            if isLoneRescuer {
                try completeAction(suffix: "action-manage-aed-retrieval", in: &engine)
                aedRetrievalAssigned = true
            }
            if distance == .far {
                // The far branch's authored delay-minimisation evidence is earned only
                // after the reducer accepts the responder/delegation choice. This does
                // not alter the near/far clinical policy or allow a lone rescuer to leave.
                try completeAction(suffix: "action-minimise-delay", in: &engine)
            }
            self.engine = engine
            stage = .breathing
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func assessBreathing(_ presentation: BreathingPresentation) {
        guard !isPaused, stage == .breathing else { return }
        guard var engine else { return }
        do {
            switch presentation {
            case .absentOrAbnormal:
                try requireAccepted(
                    engine.submit(
                        .assessBreathing(
                            durationSeconds: 8,
                            casualtyGasping: false,
                            breathingNormal: false,
                            treatedGaspingAsNormal: false
                        )
                    )
                )
                try selectBranch(
                    condition: "breathingAbsentAbnormalOrUncertain",
                    in: &engine
                )
                try completeAction(suffix: "action-check-breathing", in: &engine)
                stage = .cpr

            case .gaspingTreatedCorrectly:
                try requireAccepted(
                    engine.submit(
                        .assessBreathing(
                            durationSeconds: 8,
                            casualtyGasping: true,
                            breathingNormal: false,
                            treatedGaspingAsNormal: false
                        )
                    )
                )
                try selectBranch(condition: "gaspingObserved", in: &engine)
                try completeAction(suffix: "action-check-breathing", in: &engine)
                stage = .cpr

            case .normal:
                try requireAccepted(
                    engine.submit(
                        .assessBreathing(
                            durationSeconds: 8,
                            casualtyGasping: false,
                            breathingNormal: true,
                            treatedGaspingAsNormal: false
                        )
                    )
                )
                try selectBranch(condition: "normalBreathingObserved", in: &engine)
                try completeAction(suffix: "action-check-breathing", in: &engine)
                if let monitor = actionID(suffix: "action-monitor-normal-breathing", in: engine) {
                    try engine.completeAction(monitor)
                }
                try finishScenario(in: &engine)
                return

            case .gaspingTreatedAsNormal:
                try requireAccepted(
                    engine.submit(
                        .assessBreathing(
                            durationSeconds: 8,
                            casualtyGasping: true,
                            breathingNormal: true,
                            treatedGaspingAsNormal: true
                        )
                    )
                )
            }
            self.engine = engine
            detectCorrection(returningTo: .breathing)
        } catch {
            failAction()
        }
    }

    func performCPR(
        unsafeXiphoidPlacement: Bool,
        timestampSeconds: TimeInterval? = nil,
        handStacking: CPRHandStackingHeuristic = .likelyStacked,
        uptimeSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard !isPaused, stage == .cpr else { return }
        guard var engine else { return }
        if !cprPositioningComplete {
            let positioning = engine.submit(CPRPracticeEvent.confirmPositioning)
            self.engine = engine
            guard positioning.wasAccepted else {
                failAction()
                return
            }
            cprPositioningComplete = true
        }
        if unsafeXiphoidPlacement {
            let placement: IntegratedScenarioEventRecord
            if cprLandmarkConfirmed {
                let now = activeClock(at: uptimeSeconds)
                if cprStartedAtUptime == nil { cprStartedAtUptime = now }
                let elapsed = timestampSeconds ?? max(
                    0,
                    now - (cprStartedAtUptime ?? now)
                )
                placement = engine.submit(
                    CPRPracticeEvent.compressionDetected(
                        timestampSeconds: elapsed,
                        placement: .xiphoidAvoidZone,
                        handStacking: handStacking
                    )
                )
            } else {
                placement = engine.submit(
                    CPRPracticeEvent.classifyHandPlacement(.xiphoidAvoidZone)
                )
            }
            self.engine = engine
            guard placement.wasAccepted else {
                detectCorrection(returningTo: .cpr)
                if correction == nil { failAction() }
                return
            }
            detectCorrection(returningTo: .cpr)
            return
        }

        if !cprLandmarkConfirmed {
            let placement = engine.submit(
                CPRPracticeEvent.classifyHandPlacement(.sternumTarget)
            )
            self.engine = engine
            guard placement.wasAccepted else {
                failAction()
                return
            }
            cprLandmarkConfirmed = true
        }
        let now = activeClock(at: uptimeSeconds)
        if cprStartedAtUptime == nil { cprStartedAtUptime = now }
        let elapsed = timestampSeconds ?? max(0, now - (cprStartedAtUptime ?? now))
        let compression = engine.submit(
            CPRPracticeEvent.compressionDetected(
                timestampSeconds: elapsed,
                placement: .sternumTarget,
                handStacking: handStacking
            )
        )
        guard compression.wasAccepted else {
            self.engine = engine
            detectCorrection(returningTo: .cpr)
            if correction == nil { failAction() }
            return
        }
        cprCompressionCount += 1
        self.engine = engine
        guard cprCompressionCount >= requiredCompressionCount else { return }

        do {
            if let position = actionID(suffix: "action-position-for-cpr", in: engine) {
                try engine.completeAction(position)
            }
            if let compressions = actionID(suffix: "action-perform-compressions", in: engine) {
                try engine.completeAction(compressions)
            }
            self.engine = engine
            stage = .aedPreparation
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func prepareAndApplyAED() {
        guard !isPaused, stage == .aedPreparation else { return }
        guard var engine else { return }
        let preparation: [AEDPreparationAction] = [
            .shavePadSites,
            .moveJewelleryClear,
            .confirmImplantedDeviceClearance(fingerBreadths: 4),
            .removeMedicationPatch,
            .dryChest
        ]
        do {
            try requireAccepted(
                engine.submit(AEDPracticeEvent.pressPowerControl)
            )
            for action in preparation {
                try requireAccepted(
                    engine.submit(AEDPracticeEvent.performPreparation(action))
                )
            }
            try requireAccepted(
                engine.submit(
                    AEDPracticeEvent.placePads(
                        rightPadCorrect: true,
                        leftPadCorrect: true
                    )
                )
            )
            if let applyAED = actionID(suffix: "action-apply-aed", in: engine) {
                try engine.completeAction(applyAED)
            }
            self.engine = engine
            isAEDCycleReadyForAnalysis = true
            stage = .aedAnalysisClear
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    /// Begins either the first or a repeated analysis cycle. Repeated cycles use the
    /// reducer's explicit reset and preserve only the prepared chest and attached pads.
    func confirmClearForAEDAnalysis(anyoneTouching: Bool) {
        guard !isPaused, stage == .aedAnalysisClear else { return }
        guard var engine, analysisRound < totalAnalysisRounds else { return }
        do {
            if !isAEDCycleReadyForAnalysis {
                try requireAccepted(engine.submit(AEDPracticeEvent.beginNextAnalysisCycle))
                isAEDCycleReadyForAnalysis = true
            }
            let analysisClear = engine.submit(
                AEDPracticeEvent.interactiveAnalysisClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: !anyoneTouching,
                    anyoneTouching: anyoneTouching
                )
            )
            self.engine = engine
            detectCorrection(returningTo: .aedAnalysisClear)
            guard correction == nil else { return }
            try requireAccepted(analysisClear)
            setAudioSafetyState(.analysing)
            stage = .aedAnalysingDecision
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    /// Reveals exactly the next approved trainer decision. A shock decision enters and
    /// persists in the reducer's charging state; a no-shock decision waits for CPR resume.
    func receiveAEDAnalysisDecision() {
        guard !isPaused, stage == .aedAnalysingDecision else { return }
        guard var engine else { return }
        do {
            let outcome = try engine.nextAnalysisOutcome()
            try selectBranch(
                condition: outcome == .shock ? "shockOutcome" : "noShockOutcome",
                in: &engine
            )
            try requireAccepted(
                engine.submit(
                    AEDPracticeEvent.receiveAnalysisOutcome(
                        outcome,
                        anyoneTouching: false
                    )
                )
            )
            lastAnalysisOutcome = outcome
            if outcome == .shock {
                try requireAccepted(
                    engine.submit(AEDPracticeEvent.beginCharging(anyoneTouching: false))
                )
                setAudioSafetyState(.charging)
                stage = .aedCharging
            } else {
                setAudioSafetyState(.normal)
                stage = .aedResume
            }
            self.engine = engine
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func completeAEDCharging(anyoneTouching: Bool) {
        guard !isPaused, stage == .aedCharging else { return }
        guard var engine else { return }
        let chargingComplete = engine.submit(
            AEDPracticeEvent.chargingComplete(anyoneTouching: anyoneTouching)
        )
        self.engine = engine
        detectCorrection(returningTo: .aedCharging)
        guard correction == nil else { return }
        do {
            try requireAccepted(chargingComplete)
            setAudioSafetyState(.clearConfirmation)
            stage = .aedClearConfirmation
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func confirmClearBeforeSimulatedShock(anyoneTouching: Bool) {
        guard !isPaused, stage == .aedClearConfirmation else { return }
        guard var engine else { return }
        let clearCheck = engine.submit(
            AEDPracticeEvent.interactiveClearCheck(
                clearZoneActivated: true,
                bystandersConfirmedClear: !anyoneTouching,
                anyoneTouching: anyoneTouching
            )
        )
        self.engine = engine
        detectCorrection(returningTo: .aedClearConfirmation)
        guard correction == nil else { return }
        do {
            try requireAccepted(clearCheck)
            setAudioSafetyState(.simulatedShock)
            stage = .aedSimulatedShock
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func deliverSimulatedShock(anyoneTouching: Bool) {
        guard !isPaused, stage == .aedSimulatedShock else { return }
        guard var engine else { return }
        let shock = engine.submit(
            AEDPracticeEvent.pressShockControl(anyoneTouching: anyoneTouching)
        )
        self.engine = engine
        // Contact invalidates the preceding clear check, so the guided retry returns
        // to clear confirmation rather than allowing another immediate shock attempt.
        detectCorrection(returningTo: .aedClearConfirmation)
        guard correction == nil else { return }
        do {
            try requireAccepted(shock)
            stage = .aedResume
            errorMessage = nil
        } catch {
            failAction()
        }
    }

    func resumeCPRAfterAEDDecision() {
        guard !isPaused, stage == .aedResume else { return }
        guard var engine else { return }
        do {
            try requireAccepted(engine.submit(AEDPracticeEvent.resumeCompressions))
            try requireAccepted(engine.submit(AEDPracticeEvent.finish))
            try completeAEDCycleActions(in: &engine)
            let completedRound = analysisRound + 1
            isAEDCycleReadyForAnalysis = false
            setAudioSafetyState(.normal)
            if completedRound < totalAnalysisRounds {
                analysisRound = completedRound
                self.engine = engine
                stage = .aedAnalysisClear
                errorMessage = nil
            } else {
                try finishScenario(in: &engine)
                analysisRound = completedRound
            }
        } catch {
            failAction()
        }
    }

    func acknowledgeCorrection() {
        guard !isPaused, stage == .correction else { return }
        guard var engine, let correction else { return }
        do {
            switch correction.replayAnchor.domain {
            case .drsabc:
                try requireAccepted(engine.submit(DRSABCEvent.acknowledgeCorrection))
            case .cpr:
                try requireAccepted(engine.submit(CPRPracticeEvent.acknowledgeCorrection))
                cprLandmarkConfirmed = false
                handTimestampOffset = nil
            case .aed:
                break
            }
            try engine.acknowledgeCorrection()
            self.engine = engine
            self.correction = nil
            stage = stageBeforeCorrection
            enqueueAudioCommand { director in
                await director.setSafetyCriticalCorrectionActive(false)
            }
        } catch {
            failAction()
        }
    }

    private func finishScenario(in engine: inout ScenarioEngine) throws {
        if engine.drsabcState == .step(.compressions) ||
            engine.drsabcState == .step(.monitoringNormalBreathing) {
            try requireAccepted(engine.submit(DRSABCEvent.completeStep))
        }
        if engine.cprState == .compressionCycles {
            try requireAccepted(
                engine.submit(CPRPracticeEvent.stop(.emergencyTeamTookOver))
            )
            try requireAccepted(engine.submit(CPRPracticeEvent.finish))
        }
        engine.completeSession()
        let debrief = try DebriefBuilder.build(from: engine.eventLog)
        self.engine = engine
        self.debrief = debrief
        stage = .debrief
        enqueueAudioCommand { director in
            await director.setAEDSafetyState(.normal)
            await director.setSafetyCriticalCorrectionActive(false)
            _ = await director.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: "sfx.debrief_transition"),
                    context: .immersive,
                    autoplay: true
                )
            )
            _ = await director.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: "music.completion_sting"),
                    context: .immersive,
                    autoplay: true
                )
            )
        }
    }

    private func detectCorrection(returningTo stage: IntegratedScenarioStage) {
        guard let correction = engine?.currentCorrection else { return }
        self.correction = correction
        stageBeforeCorrection = stage
        self.stage = .correction
        enqueueAudioCommand { director in
            await director.setSafetyCriticalCorrectionActive(true)
            _ = await director.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: correction.systemAudioCueID),
                    channel: .dialogue,
                    context: .immersive,
                    autoplay: true
                )
            )
        }
    }

    private func completeAEDCycleActions(in engine: inout ScenarioEngine) throws {
        if let clear = actionID(suffix: "action-clear-for-aed", in: engine) {
            try engine.completeAction(clear)
        }
        if let resume = actionID(suffix: "action-resume-cpr", in: engine) {
            try engine.completeAction(resume)
        }
    }

    private func completeAction(
        suffix: String,
        in engine: inout ScenarioEngine
    ) throws {
        guard let id = actionID(suffix: suffix, in: engine) else {
            throw ScenarioEngineError.unknownCriticalAction(suffix)
        }
        try engine.completeAction(id)
    }

    private func actionID(suffix: String, in engine: ScenarioEngine) -> String? {
        engine.definition.criticalActions.first { $0.id.hasSuffix(suffix) }?.id
    }

    private func selectBranch(condition: String, in engine: inout ScenarioEngine) throws {
        try engine.selectBranch(condition: condition)
    }

    private func setAudioSafetyState(_ state: AEDAudioSafetyState) {
        enqueueAudioCommand { director in
            await director.setAEDSafetyState(state)
        }
    }

    private func requireAccepted(_ record: IntegratedScenarioEventRecord) throws {
        guard record.wasAccepted else {
            throw IntegratedScenarioSessionError.rejectedClinicalTransition
        }
    }

    private func enqueueAudioCommand(
        _ operation: @escaping @Sendable (any AudioDirector) async -> Void
    ) {
        guard let director = audioDirector else { return }
        let previous = audioCommandTask
        audioCommandTask = Task { @MainActor in
            if let previous { await previous.value }
            guard !Task.isCancelled else { return }
            await operation(director)
        }
    }

    private func failAction() {
        errorMessage = "This action could not be accepted by the source-backed scenario engine."
    }

    func setPaused(
        _ paused: Bool,
        at timestampSeconds: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) async {
        guard isPaused != paused else { return }
        if paused {
            isPaused = true
            pauseStartedAt = timestampSeconds
            handTimestampOffset = nil
        } else {
            if let pauseStartedAt {
                accumulatedPausedSeconds += max(0, timestampSeconds - pauseStartedAt)
            }
            self.pauseStartedAt = nil
            isPaused = false
            handTimestampOffset = nil
        }
        guard isHandTrackingSceneActive else { return }
        if paused {
            handTracking.pause()
        } else {
            await handTracking.start()
        }
        handTrackingState = handTracking.state
    }

    private func startSignalConsumerIfNeeded() {
        guard signalTask == nil else { return }
        let signals = handTracking.signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard !Task.isCancelled, let self else { return }
                consume(signal)
            }
        }
    }

    private func consume(_ signal: HandTrackingDerivedEvent) {
        switch signal {
        case let .trackingAvailabilityChanged(isAvailable):
            handTrackingState = handTracking.state
            guard isHandTrackingSceneActive, handTrackingState != .idle else {
                handObservationFallbackExplanation = nil
                return
            }
            if isAvailable {
                handObservationFallbackExplanation = nil
            } else if handTrackingState.fallbackExplanation != nil {
                handObservationFallbackExplanation = nil
            } else {
                handObservationFallbackExplanation = "Hand observations are temporarily unavailable. Continue with the accessible compression control."
            }

        case let .compressionDetected(timestamp, placement, stacking):
            guard !isPaused,
                  isHandTrackingSceneActive,
                  handTrackingState == .running,
                  stage == .cpr
            else { return }
            switch placement {
            case .sternumTarget:
                performCPR(
                    unsafeXiphoidPlacement: false,
                    timestampSeconds: normalizedHandTimestamp(timestamp),
                    handStacking: stacking
                )
            case .xiphoidAvoidZone:
                performCPR(
                    unsafeXiphoidPlacement: true,
                    timestampSeconds: normalizedHandTimestamp(timestamp),
                    handStacking: stacking
                )
            case .outsideTarget, .unavailable:
                break
            }

        case .placementChanged,
             .placementDwellConfirmed,
             .handStackingChanged,
             .interruptionMeasured,
             .cadenceUpdated,
             .grabInteractionChanged:
            break
        }
    }

    private func normalizedHandTimestamp(_ sourceTimestamp: TimeInterval) -> TimeInterval {
        let now = activeClock(at: ProcessInfo.processInfo.systemUptime)
        if cprStartedAtUptime == nil {
            cprStartedAtUptime = now
        }
        let currentElapsed = max(0, now - (cprStartedAtUptime ?? now))
        if handTimestampOffset == nil {
            handTimestampOffset = currentElapsed - sourceTimestamp
        }
        return max(0, sourceTimestamp + (handTimestampOffset ?? 0))
    }

    private func activeClock(at timestampSeconds: TimeInterval) -> TimeInterval {
        let currentPause = pauseStartedAt.map {
            max(0, timestampSeconds - $0)
        } ?? 0
        return max(0, timestampSeconds - accumulatedPausedSeconds - currentPause)
    }

    private func clearAttemptState() {
        engine = nil
        stage = .sceneSafety
        stageBeforeCorrection = .sceneSafety
        correction = nil
        debrief = nil
        lastAnalysisOutcome = nil
        analysisRound = 0
        errorMessage = nil
        callAssigned = false
        aedRetrievalAssigned = false
        isPaused = false
        isLoneRescuer = false
        cprCompressionCount = 0
        scoringDecision = .practiceOnly(.notVerified)
        selectedBystanderAssignment = .getAED
        cprPositioningComplete = false
        cprLandmarkConfirmed = false
        cprStartedAtUptime = nil
        handTimestampOffset = nil
        accumulatedPausedSeconds = 0
        pauseStartedAt = nil
        isAEDCycleReadyForAnalysis = false
        handTrackingState = handTracking.state
    }
}

enum BreathingPresentation: String, Sendable, CaseIterable, Identifiable {
    case absentOrAbnormal
    case gaspingTreatedCorrectly
    case normal
    case gaspingTreatedAsNormal

    var id: String { rawValue }
}

struct IntegratedScenarioImmersivePanel: View {
    let model: IntegratedScenarioSessionModel
    let awardState: DebriefAwardPersistenceState
    let onRestart: () -> Void
    let onReturnToDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("INTEGRATED SCENARIO · SIMULATION", systemImage: "person.2.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(model.scenarioTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)

            if let explanation = model.scoringDecision.practiceOnlyExplanation {
                VStack(alignment: .leading, spacing: 4) {
                    Label("PRACTICE ONLY — UNSCORED", systemImage: "shield.slash.fill")
                        .font(.headline)
                    Text("\(explanation) No completion record, XP, or badge will be saved.")
                        .font(.footnote)
                }
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "Practice only, unscored. \(explanation) No completion record, experience points, or badge will be saved."
                )
            }

            if let errorMessage = model.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if model.isPaused {
                Label("Scenario paused", systemImage: "pause.circle.fill")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }

            if let explanation = model.handTrackingFallbackExplanation {
                Label(explanation, systemImage: "hand.raised.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            stageContent

            if model.stage != .debrief {
                Divider()
                Button("Restart scenario", systemImage: "arrow.counterclockwise") {
                    onRestart()
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Clears this attempt and restarts the same scenario")
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .padding(24)
        .glassBackgroundEffect()
        .disabled(model.isPaused)
    }

    @ViewBuilder
    private var stageContent: some View {
        switch model.stage {
        case .sceneSafety:
            Text("Check the scene before approaching.").foregroundStyle(.secondary)
            buttonGrid([
                ("Scene is safe", "checkmark.shield", { model.assessScene(unsafeEntry: false) }),
                ("Enter an unsafe scene", "xmark.shield", { model.assessScene(unsafeEntry: true) })
            ])

        case .response:
            Text("Check responsiveness using the guided manikin interaction.")
            Button("Casualty is unresponsive", systemImage: "person.fill.questionmark") {
                model.checkResponse()
            }
            .buttonStyle(.borderedProminent)

        case .distraction:
            Label("Shopping-centre announcement", systemImage: "speaker.wave.2.fill")
                .font(.headline)
            Text("This environmental beat does not affect scoring. Focus and accessibility support are always allowed.")
                .foregroundStyle(.secondary)
            buttonGrid([
                ("Continue", "arrow.right.circle", { model.continuePastDistraction(accessibilitySupportUsed: false) }),
                ("Use focus support and continue", "ear.badge.checkmark", { model.continuePastDistraction(accessibilitySupportUsed: true) })
            ])

        case .responderContext:
            Text("Use the responder availability presented in this scenario branch.")
            buttonGrid([
                ("Two bystanders are available", "person.2.fill", { model.chooseResponderAvailability(bystanderAvailable: true) }),
                ("I am the lone rescuer", "person.fill", { model.chooseResponderAvailability(bystanderAvailable: false) })
            ])

        case .delegation:
            @Bindable var model = model
            Text("Assign both tasks. Gaze-and-pinch a bystander or use the labelled alternative below; both submit the same event.")
                .foregroundStyle(.secondary)
            Picker("Task to assign", selection: $model.selectedBystanderAssignment) {
                ForEach(ScenarioBystanderAssignment.allCases, id: \.self) { assignment in
                    Text(assignment.displayName).tag(assignment)
                }
            }
            HStack {
                Button("Assign to bystander one") {
                    model.assignSelectedTask(
                        to: "bystander_01",
                        method: .accessibleControl
                    )
                }
                Button("Assign to bystander two") {
                    model.assignSelectedTask(
                        to: "bystander_02",
                        method: .accessibleControl
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            Label(
                model.callAssigned ? "Simulated call assigned" : "Simulated call still required",
                systemImage: model.callAssigned ? "checkmark.circle.fill" : "circle.dashed"
            )
            Label(
                model.aedRetrievalAssigned ? "AED retrieval assigned" : "AED retrieval still required",
                systemImage: model.aedRetrievalAssigned ? "checkmark.circle.fill" : "circle.dashed"
            )

        case .aedDistance:
            Text(model.isLoneRescuer
                 ? "Choose the authored AED-distance branch. As the lone rescuer, remain with the casualty."
                 : "Choose the AED-distance branch reported by the bystander.")
                .foregroundStyle(.secondary)
            buttonGrid([
                ("AED is near (within 60 seconds)", "figure.walk", { model.chooseAEDDistance(.near) }),
                ("AED is farther away", "figure.walk.motion", { model.chooseAEDDistance(.far) })
            ])

        case .breathing:
            Text("Assess normal breathing within the supported check.")
            buttonGrid([
                ("Absent, abnormal, or unsure", "lungs", { model.assessBreathing(.absentOrAbnormal) }),
                ("Gasping — treat as not normal", "waveform.path", { model.assessBreathing(.gaspingTreatedCorrectly) }),
                ("Normal breathing observed", "lungs.fill", { model.assessBreathing(.normal) }),
                ("Mistake gasping as normal", "exclamationmark.triangle", { model.assessBreathing(.gaspingTreatedAsNormal) })
            ])

        case .cpr:
            Text("Confirm the source-backed hand-placement zone and begin hands-only CPR. Depth and force are Not physically assessed.")
            if model.handTrackingState != .running {
                Button("Record a sternum compression beat", systemImage: "heart.fill") {
                    model.performCPR(unsafeXiphoidPlacement: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Visible alternative when automatic hand observations are unavailable")
            }
            Label(
                "Recorded compressions: \(model.cprCompressionCount) of \(model.requiredCompressionCount)",
                systemImage: model.cprCompressionCount >= model.requiredCompressionCount
                    ? "checkmark.circle.fill"
                    : "metronome"
            )
            if model.handTrackingState == .running {
                buttonGrid([
                    ("Record a sternum compression beat", "heart.fill", { model.performCPR(unsafeXiphoidPlacement: false) }),
                    ("Use xiphoid avoid zone", "exclamationmark.triangle", { model.performCPR(unsafeXiphoidPlacement: true) })
                ])
            } else {
                Button("Use xiphoid avoid zone", systemImage: "exclamationmark.triangle") {
                    model.performCPR(unsafeXiphoidPlacement: true)
                }
                .buttonStyle(.bordered)
            }

        case .aedPreparation:
            Text("Switch on the simulated AED first, complete the presented preparation checks, apply both simulated pads, and follow the trainer prompts.")
            Button("Switch on, prepare and apply simulated AED", systemImage: "waveform.path.ecg") {
                model.prepareAndApplyAED()
            }
            .buttonStyle(.borderedProminent)

        case .aedAnalysisClear:
            Label(
                "Analysis \(model.analysisRound + 1) of \(model.totalAnalysisRounds): clear everyone before analysis",
                systemImage: "hand.raised.fill"
            )
                .font(.headline)
            buttonGrid([
                ("Clear confirmed — begin analysis", "checkmark.shield", { model.confirmClearForAEDAnalysis(anyoneTouching: false) }),
                ("Begin while someone is touching", "person.fill.xmark", { model.confirmClearForAEDAnalysis(anyoneTouching: true) })
            ])

        case .aedAnalysingDecision:
            Label("AED analysing — nobody touches the casualty", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text("The approved pattern determines only the trainer decision. It never changes the clear or CPR-resume rules.")
                .foregroundStyle(.secondary)
            Button("Receive trainer decision", systemImage: "waveform.badge.magnifyingglass") {
                model.receiveAEDAnalysisDecision()
            }
            .buttonStyle(.borderedProminent)

        case .aedCharging:
            Label("Shock advised — AED charging", systemImage: "bolt.heart.fill")
                .font(.headline)
            Text("Keep everyone clear while the simulated AED charges.")
                .foregroundStyle(.secondary)
            buttonGrid([
                ("Charging complete — continue", "battery.100percent.bolt", { model.completeAEDCharging(anyoneTouching: false) }),
                ("Someone is touching during charge", "person.fill.xmark", { model.completeAEDCharging(anyoneTouching: true) })
            ])

        case .aedClearConfirmation:
            Label("Clear prompt — stand clear", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Visually sweep the area and confirm that nobody is touching the casualty.")
                .foregroundStyle(.secondary)
            buttonGrid([
                ("Clear confirmed", "checkmark.shield.fill", { model.confirmClearBeforeSimulatedShock(anyoneTouching: false) }),
                ("Continue while someone is touching", "person.fill.xmark", { model.confirmClearBeforeSimulatedShock(anyoneTouching: true) })
            ])

        case .aedSimulatedShock:
            Label("Clear confirmed — simulated shock ready", systemImage: "bolt.shield.fill")
                .font(.headline)
            buttonGrid([
                ("Deliver simulated shock", "bolt.fill", { model.deliverSimulatedShock(anyoneTouching: false) }),
                ("Shock while someone is touching", "person.fill.xmark", { model.deliverSimulatedShock(anyoneTouching: true) })
            ])

        case .aedResume:
            if let outcome = model.lastAnalysisOutcome {
                Label(
                    outcome == .shock
                        ? "Simulated shock delivered"
                        : "No shock advised",
                    systemImage: outcome == .shock ? "bolt.heart.fill" : "heart.fill"
                )
                .font(.headline)
            }
            Text("Resume chest compressions immediately after either AED decision.")
                .foregroundStyle(.secondary)
            Button("Resume CPR", systemImage: "hands.and.sparkles.fill") {
                model.resumeCPRAfterAEDDecision()
            }
            .buttonStyle(.borderedProminent)

        case .correction:
            if let correction = model.correction {
                VStack(alignment: .leading, spacing: 9) {
                    Label(correction.title, systemImage: "exclamationmark.shield.fill")
                        .font(.headline)
                    Text(correction.remediation)
                    Text("Visual replay of recorded event \(correction.replayAnchor.sequence + 1): \(correction.replayAnchor.stateBefore) → \(correction.replayAnchor.stateAfter)")
                        .font(.footnote.monospaced())
                    DisclosureGroup("Source references") {
                        ForEach(correction.sourceReferences) { source in
                            Text("\(source.document), \(source.edition), \(source.section), page \(source.page)")
                                .font(.footnote)
                        }
                    }
                    Button("Review and retry", systemImage: "arrow.counterclockwise") {
                        model.acknowledgeCorrection()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
                .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
            }

        case .debrief:
            if let debrief = model.debrief {
                VStack(alignment: .leading, spacing: 12) {
                    DebriefView(debrief: debrief, awardState: awardState)
                        .frame(maxHeight: 480)
                    HStack {
                        Button("Restart scenario", systemImage: "arrow.counterclockwise") {
                            onRestart()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isAwardPersistenceInFlight)
                        Button("Return to dashboard", systemImage: "rectangle.portrait.and.arrow.right") {
                            onReturnToDashboard()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var isAwardPersistenceInFlight: Bool {
        switch awardState {
        case .pending, .saving: true
        case .saved, .practiceOnly, .failed: false
        }
    }

    private func buttonGrid(
        _ values: [(String, String, () -> Void)]
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Button(value.0, systemImage: value.1, action: value.2)
                    .buttonStyle(.bordered)
            }
        }
    }
}
