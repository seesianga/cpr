import Foundation
import Observation
import simd

/// A pad following an active physical pinch. World coordinates come from the derived
/// pinch midpoint (a cursor-like interaction point), never from raw joints.
struct AEDPadGrabPresentation: Sendable, Equatable {
    let itemIdentifier: String
    let padSide: AEDPadSide
    var midpointWorld: SIMD3<Float>
}

/// A released pad's resolved resting place for the immersive view to apply.
struct AEDPadSnapPresentation: Sendable, Equatable {
    let id: UUID
    let itemIdentifier: String
    let worldPosition: SIMD3<Float>
}

struct AEDPreparationPracticeItem: Identifiable, Sendable, Equatable {
    let condition: AEDChestCondition
    let instruction: PracticeContentInstruction
    let isComplete: Bool

    var id: AEDChestCondition { condition }
}

enum AEDPracticeSessionLoadState: Sendable, Equatable {
    case idle
    case ready
    case failed(message: String)
}

struct AEDSpatialCueRequest: Identifiable, Sendable, Equatable {
    let id = UUID()
    let cue: AudioCue
}

/// Coordinates authored AED room interactions while the pure reducer owns every safety gate.
@MainActor
@Observable
final class AEDPracticeSessionModel {
    /// Visible coaching watchdog aligned to the source-backed maximum interruption budget.
    /// `fact.compression.restRule` supplies 10 seconds, while
    /// `fact.compression.minimiseInterruptions`, `fact.aed.resumeAfterShock`, and
    /// `fact.aed.noShockAdvised` still require the learner to resume immediately.
    static let defaultResumeCoachingDelay: Duration = .seconds(10)
    static let resumeCaptionCueText = "Resume compressions now"
    static let resumeCoachingSourceFactIDs = [
        "fact.compression.restRule",
        "fact.compression.minimiseInterruptions",
        "fact.aed.resumeAfterShock",
        "fact.aed.noShockAdvised"
    ]

    private let handTracking: any HandTrackingServicing
    private let resumeCoachingDelay: Duration
    private var audioDirector: any AudioDirector
    private var machine: AEDStateMachine?
    private var content: PracticeMachineContentContract?
    private var rightPadCorrect: Bool?
    private var leftPadCorrect: Bool?
    private var resumeCoachingTask: Task<Void, Never>?
    private var resumeCoachingDeadlineUptime: TimeInterval?
    private var pausedResumeCoachingSeconds: TimeInterval?
    private var signalTask: Task<Void, Never>?
    private var metronomeTask: Task<Void, Never>?
    private var guidedCompressionTimestamps: [Double] = []
    private var guidedTempoBands: [CPRCadenceBand] = []
    private var handTrackingTargets: HandTrackingTargets?
    private var padSidesByItemIdentifier: [String: AEDPadSide] = [:]
    private var powerButtonItemIdentifier: String?
    private var grabItemPositions: [String: SIMD3<Float>] = [:]

    private(set) var loadState: AEDPracticeSessionLoadState = .idle
    private(set) var latestFeedback: String?
    private(set) var clearZoneActivated = false
    private(set) var bystanderClearStates = [
        "bystander_01": false,
        "bystander_02": false
    ]
    private(set) var isPaused = false
    private(set) var hasActiveSafetyCorrection = false
    private(set) var spatialCueRequest: AEDSpatialCueRequest?
    private(set) var resumeCoachingSecondsRemaining: Int?
    private(set) var handTrackingState: HandTrackingState = .idle
    private(set) var guidedCompressionCount = 0
    private(set) var guidedCadencePerMinute: Double?
    private(set) var guidedInterruptionSeconds = 0.0
    private(set) var visualMetronomePulse = false
    /// The pad currently following a physical pinch, for the immersive view to render.
    private(set) var activePadGrab: AEDPadGrabPresentation?
    /// Set when a released pad snapped to a grid region; the view applies the position
    /// and then acknowledges it.
    private(set) var padSnapPresentation: AEDPadSnapPresentation?

    init(
        handTracking: any HandTrackingServicing = HandTrackingService(),
        resumeCoachingDelay: Duration = defaultResumeCoachingDelay,
        audioDirector: any AudioDirector = NoOpAudioDirector()
    ) {
        self.handTracking = handTracking
        self.resumeCoachingDelay = resumeCoachingDelay
        self.audioDirector = audioDirector
    }

    func setAudioDirector(_ audioDirector: any AudioDirector) {
        self.audioDirector = audioDirector
    }

    var state: AEDPracticeState? { machine?.state }
    var eventLogCount: Int { machine?.eventLog.count ?? 0 }
    var criticalFailures: [AEDPracticeCriticalFailure] { machine?.criticalFailures ?? [] }
    var physicalPadPlacements: [AEDPadSide: AEDPhysicalPadPlacement] {
        machine?.physicalPadPlacements ?? [:]
    }
    var contentVersion: String? { content?.contentVersion }
    var isPreparationComplete: Bool { machine?.preparation.isReadyForPads ?? false }
    var powerOnInstruction: PracticeContentInstruction? {
        content?.aedPowerOnInstruction
    }
    var padPlacementInstruction: PracticeContentInstruction? {
        content?.aedPadPlacementInstruction
    }
    var resumeCaptionCue: String? {
        state == .noShockAdvised || state == .simulatedShock
            ? Self.resumeCaptionCueText
            : nil
    }
    var targetRateText: String {
        guard let policy = content?.cprPolicy else { return "100–120/min" }
        return "\(Int(policy.minimumRatePerMinute))–\(Int(policy.maximumRatePerMinute))/min"
    }
    var guidedTempoAccuracy: Double? {
        guard !guidedTempoBands.isEmpty else { return nil }
        let inBand = guidedTempoBands.filter { $0 == .withinSupportedBand }.count
        return Double(inBand) / Double(guidedTempoBands.count)
    }
    var handTrackingFallbackExplanation: String? { handTrackingState.fallbackExplanation }

    var preparationItems: [AEDPreparationPracticeItem] {
        guard let content, let machine else { return [] }
        return AEDChestCondition.allCases.compactMap { condition in
            guard let instruction = content.aedPreparationInstructions[condition] else {
                return nil
            }
            return AEDPreparationPracticeItem(
                condition: condition,
                instruction: instruction,
                isComplete: machine.preparation.completedConditions.contains(condition)
            )
        }
    }

    var allBystandersConfirmedClear: Bool {
        !bystanderClearStates.isEmpty && bystanderClearStates.values.allSatisfy { $0 }
    }

    var guidanceTitle: String {
        switch state {
        case .powerOn: "Switch on the AED trainer"
        case .awaitingPads where !isPreparationComplete: "Prepare the chest"
        case .awaitingPads: "Place both pads"
        case .padsIncorrect: "Correct pad placement"
        case .padsCorrect: "Clear for analysis"
        case .analysing: "Analysing — hands off"
        case .shockAdvised: "Shock advised"
        case .noShockAdvised: "No shock advised"
        case .charging: "Charging — nobody touches"
        case .clearConfirmation: "Perform the interactive clear sweep"
        case .simulatedShock: "Simulated shock complete"
        case .resumeCompressions: "Compressions resumed"
        case .complete: "AED practice complete"
        case nil: "Preparing AED practice"
        }
    }

    var guidanceBody: String {
        if let latestFeedback { return latestFeedback }
        return switch state {
        case .powerOn:
            powerOnInstruction?.body ?? "Switch on the simulated AED and follow its prompts."
        case .awaitingPads where !isPreparationComplete:
            "Complete each source-backed preparation condition presented in the room."
        case .awaitingPads:
            padPlacementInstruction?.body ?? "Follow the pictures on the simulated pads."
        case .padsIncorrect:
            "Retry both pads before analysis."
        case .padsCorrect:
            "Check each bystander and activate the clear-zone ring before analysis."
        case .analysing:
            "Nobody touches the casualty while the simulated AED analyses."
        case .shockAdvised:
            "Keep everyone clear while the simulated AED charges."
        case .noShockAdvised, .simulatedShock:
            "Resume compressions immediately."
        case .charging:
            "Maintain hands-off contact while charging completes."
        case .clearConfirmation:
            "Confirm each bystander is clear, then gaze and pinch the clear-zone ring."
        case .resumeCompressions:
            "Finish this practice only after compressions have resumed."
        case .complete:
            "Internal practice completion only; this is not SRFAC certification."
        case nil:
            "Source-backed AED content is loading."
        }
    }

    func prepare(from bundle: Bundle = .main) {
        clearResumeCoachingTimer()
        stopMetronome()
        resetGuidedCompressionEvidence()
        do {
            let loaded = try PracticeMachineContentContract.loadBundled(from: bundle)
            content = loaded
            machine = AEDStateMachine(
                requiredChestConditions: Set(loaded.aedPreparationInstructions.keys)
            )
            rightPadCorrect = nil
            leftPadCorrect = nil
            resetClearSweep()
            latestFeedback = nil
            hasActiveSafetyCorrection = false
            loadState = .ready
            startSignalConsumerIfNeeded()
            requestSpatialCue("sfx.aed_case_open")
        } catch {
            content = nil
            machine = nil
            loadState = .failed(
                message: "The source-backed AED practice content could not be loaded. Practice is unavailable until the content is corrected."
            )
        }
    }

    /// RealityView room changes can recreate their task while this feature remains in
    /// one continuous AED session. Preserve accepted preparation and pad state in that case.
    func prepareIfNeeded(from bundle: Bundle = .main) {
        guard machine == nil else { return }
        prepare(from: bundle)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        if paused {
            pauseResumeCoachingTimer()
            isPaused = true
            handTracking.pause()
            handTrackingState = handTracking.state
        } else if state == .noShockAdvised || state == .simulatedShock {
            isPaused = false
            startResumeCoachingTimer(resetWindow: false)
            restartHandTrackingAfterPause()
        } else {
            isPaused = false
            restartHandTrackingAfterPause()
        }
    }

    func configureHandTracking(targets: HandTrackingTargets) {
        handTrackingTargets = targets
        handTracking.configure(targets: targets)
        handTrackingState = handTracking.state
    }

    /// Registers the pinch-grabbable practice items resolved through the active asset
    /// descriptor. Identifiers are semantic slot names; the model never sees entities.
    func configurePhysicalInteraction(
        padItems: [AEDPadSide: PinchGrabItem],
        powerButton: PinchGrabItem?
    ) {
        padSidesByItemIdentifier = Dictionary(
            uniqueKeysWithValues: padItems.map { ($0.value.identifier, $0.key) }
        )
        powerButtonItemIdentifier = powerButton?.identifier
        grabItemPositions = Dictionary(
            uniqueKeysWithValues: (padItems.values + (powerButton.map { [$0] } ?? []))
                .map { ($0.identifier, $0.worldPosition) }
        )
        activePadGrab = nil
        padSnapPresentation = nil
        publishGrabbableItems()
    }

    /// The view calls this after applying a snap so stale positions are not re-applied.
    func acknowledgePadSnap(_ snap: AEDPadSnapPresentation) {
        guard padSnapPresentation == snap else { return }
        padSnapPresentation = nil
    }

    private func publishGrabbableItems() {
        handTracking.updateGrabbableItems(
            grabItemPositions.map {
                PinchGrabItem(identifier: $0.key, worldPosition: $0.value)
            }.sorted { $0.identifier < $1.identifier }
        )
    }

    func startHandTracking() async {
        guard !isPaused else { return }
        startSignalConsumerIfNeeded()
        await handTracking.start()
        handTrackingState = handTracking.state
    }

    /// Accessible alternative to pressing the semantic `aed_power_button` entity.
    func pressPowerButton() {
        guard canInteract else { return }
        submit(.pressPowerControl)
    }

    func completePreparation(_ condition: AEDChestCondition) {
        guard canInteract else { return }
        let action: AEDPreparationAction = switch condition {
        case .hairPreventsPadContact: .shavePadSites
        case .jewelleryAtPadSite: .moveJewelleryClear
        case .implantedDeviceNearPadSite: .confirmImplantedDeviceClearance(fingerBreadths: 4)
        case .medicationPatchAtPadSite: .removeMedicationPatch
        case .wetChest: .dryChest
        }
        let wasComplete = isPreparationComplete
        let entry = submit(.performPreparation(action))
        if entry?.wasAccepted == true,
           !wasComplete,
           isPreparationComplete {
            requestSpatialCue("sfx.electrode_packet_open")
        }
    }

    /// Receives the semantic identifiers produced by a pad drag and collision-zone check.
    /// The reducer receives only correctness booleans, so presentation cannot skip preparation.
    func placeDraggedPad(padName: String, destinationZoneName: String?) {
        guard canInteract, state == .awaitingPads else { return }
        switch padName {
        case "aed_right_pad":
            rightPadCorrect = destinationZoneName == "aed_right_pad_zone"
        case "aed_left_pad":
            leftPadCorrect = destinationZoneName == "aed_left_pad_zone"
        default:
            latestFeedback = "Use one of the two simulated electrode pads."
            return
        }
        requestSpatialCue("sfx.pad_backing_peel")
        submitPadPlacementWhenBothAttempted()
    }

    /// Typed physical release path used by the grid/pinch integration. The reducer—not
    /// this feature model—owns the side-to-anatomical-region correctness decision.
    func placePhysicalPad(
        side: AEDPadSide,
        regionID: TorsoRegionID?,
        normalizedPlacementError: Double?
    ) {
        guard canInteract, state == .awaitingPads else { return }
        let entry = submit(
            .placePhysicalPad(
                AEDPhysicalPadPlacement(
                    padSide: side,
                    regionID: regionID,
                    normalizedPlacementError: normalizedPlacementError
                )
            )
        )
        guard entry?.wasAccepted == true else { return }
        requestSpatialCue("sfx.pad_backing_peel")
        if state == .padsCorrect {
            requestSpatialCue("sfx.connector_insert")
        }
    }

    /// Accessible non-drag alternative that still routes through the same placement event.
    func placePadUsingAccessibleControl(rightPad: Bool, inCorrectZone: Bool) {
        guard canInteract, state == .awaitingPads else { return }
        if rightPad {
            rightPadCorrect = inCorrectZone
        } else {
            leftPadCorrect = inCorrectZone
        }
        requestSpatialCue("sfx.pad_backing_peel")
        submitPadPlacementWhenBothAttempted()
    }

    func retryPadPlacement() {
        guard canInteract else { return }
        let entry = submit(.retryPadPlacement)
        if entry?.wasAccepted == true {
            rightPadCorrect = nil
            leftPadCorrect = nil
            resetClearSweep()
        }
    }

    func confirmBystanderClear(_ entityName: String) {
        guard canInteract,
              state == .padsCorrect || state == .analysing ||
                state == .shockAdvised || state == .charging ||
                state == .clearConfirmation
        else { return }
        guard bystanderClearStates[entityName] != nil else { return }
        bystanderClearStates[entityName] = true
        latestFeedback = nil
    }

    func markBystanderTouching(_ entityName: String) {
        guard canInteract else { return }
        guard bystanderClearStates[entityName] == true else { return }
        submit(.clearCheckInvalidated)
        bystanderClearStates[entityName] = false
        clearZoneActivated = false
    }

    /// The ring activation is one part of the interaction. The reducer separately verifies
    /// that all authored bystander entities are in their confirmed-clear state.
    func activateClearZone() {
        guard canInteract else { return }
        clearZoneActivated = true
        let anyoneTouching = !allBystandersConfirmedClear
        let entry: StateMachineEventLogEntry<
            AEDPracticeState,
            AEDPracticeEvent,
            AEDPracticeRejectionReason,
            AEDPracticeRemediation
        >?
        switch state {
        case .padsCorrect:
            entry = submit(
                .interactiveAnalysisClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: allBystandersConfirmedClear,
                    anyoneTouching: anyoneTouching
                )
            )
        case .clearConfirmation:
            entry = submit(
                .interactiveClearCheck(
                    clearZoneActivated: true,
                    bystandersConfirmedClear: allBystandersConfirmedClear,
                    anyoneTouching: anyoneTouching
                )
            )
        default:
            latestFeedback = "Complete the current AED prompt before the clear-zone sweep."
            entry = nil
        }
        if entry?.wasAccepted != true {
            clearZoneActivated = false
        }
    }

    func receiveAnalysisOutcome(_ outcome: AEDAnalysisOutcome) {
        guard canInteract else { return }
        let entry = submit(
            .receiveAnalysisOutcome(
                outcome,
                anyoneTouching: !allBystandersConfirmedClear
            )
        )
        if entry?.wasAccepted == true, state == .noShockAdvised {
            startResumeCoachingTimer(resetWindow: true)
        }
    }

    func beginCharging() {
        guard canInteract else { return }
        submit(.beginCharging(anyoneTouching: !allBystandersConfirmedClear))
    }

    func finishCharging() {
        guard canInteract else { return }
        let entry = submit(
            .chargingComplete(anyoneTouching: !allBystandersConfirmedClear)
        )
        if entry?.wasAccepted == true {
            resetClearSweep()
        }
    }

    func pressSimulatedShockControl() {
        guard canInteract else { return }
        let entry = submit(
            .pressShockControl(anyoneTouching: !allBystandersConfirmedClear)
        )
        if entry?.wasAccepted == true {
            resetClearSweep()
            startResumeCoachingTimer(resetWindow: true)
        }
    }

    func expireResumeWindow() {
        guard canInteract else { return }
        finishResumeCoachingTimerAtExpiry()
        submit(.coachedResumeWindowExpired)
    }

    func resumeCompressions() {
        guard canInteract else { return }
        let entry = submit(.resumeCompressions)
        if entry?.wasAccepted == true {
            clearResumeCoachingTimer()
            startMetronome()
        }
    }

    func finish() {
        guard canInteract else { return }
        let entry = submit(.finish)
        if entry?.wasAccepted == true {
            stopMetronome()
        }
    }

    func stop() {
        clearResumeCoachingTimer()
        stopMetronome()
        signalTask?.cancel()
        signalTask = nil
        activePadGrab = nil
        padSnapPresentation = nil
        handTracking.stop()
        handTrackingState = handTracking.state
    }

    private func submitPadPlacementWhenBothAttempted() {
        guard let rightPadCorrect, let leftPadCorrect else {
            latestFeedback = "Place both simulated pads before checking their positions."
            return
        }
        let entry = submit(
            .placePads(
                rightPadCorrect: rightPadCorrect,
                leftPadCorrect: leftPadCorrect
            )
        )
        if entry?.wasAccepted == true, state == .padsCorrect {
            requestSpatialCue("sfx.connector_insert")
        }
    }

    private func resetClearSweep() {
        clearZoneActivated = false
        bystanderClearStates = [
            "bystander_01": false,
            "bystander_02": false
        ]
    }

    private var canInteract: Bool { !isPaused && machine != nil }

    private func startSignalConsumerIfNeeded() {
        guard signalTask == nil else { return }
        let signals = handTracking.signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard !Task.isCancelled, let self else { return }
                self.consume(signal)
            }
        }
    }

    private func consume(_ signal: HandTrackingDerivedEvent) {
        guard !isPaused else { return }
        switch signal {
        case .trackingAvailabilityChanged:
            handTrackingState = handTracking.state

        case let .compressionDetected(timestamp, placement, _):
            guard handTrackingState == .running,
                  state == .noShockAdvised ||
                    state == .simulatedShock ||
                    state == .resumeCompressions
            else { return }
            switch placement {
            case .sternumTarget:
                if state == .noShockAdvised || state == .simulatedShock {
                    let entry = submit(.resumeCompressions)
                    guard entry?.wasAccepted == true else { return }
                    clearResumeCoachingTimer()
                    startMetronome()
                }
                recordGuidedCompression(at: timestamp)
            case .xiphoidAvoidZone:
                latestFeedback = CPRPracticeStateMachine.remediation(.xiphoidPlacement).message
            case .outsideTarget:
                latestFeedback = CPRPracticeStateMachine.remediation(.outsideSternumTarget).message
            case .unavailable:
                latestFeedback = CPRPracticeStateMachine.remediation(.placementUnavailable).message
            }

        case let .interruptionMeasured(duration):
            guard state == .resumeCompressions, duration.isFinite, duration >= 0 else {
                return
            }
            guidedInterruptionSeconds = duration

        case let .grabInteractionChanged(sample):
            handleGrabInteraction(sample)

        case .placementChanged,
             .placementDwellConfirmed,
             .handStackingChanged,
             .cadenceUpdated:
            break
        }
    }

    private func handleGrabInteraction(_ sample: GrabInteractionSample) {
        guard handTrackingState == .running else { return }
        switch sample.phase {
        case .began:
            if sample.itemIdentifier == powerButtonItemIdentifier {
                pressPowerButton()
                return
            }
            guard state == .awaitingPads,
                  let padSide = padSidesByItemIdentifier[sample.itemIdentifier],
                  let midpoint = sample.midpointWorld
            else { return }
            activePadGrab = AEDPadGrabPresentation(
                itemIdentifier: sample.itemIdentifier,
                padSide: padSide,
                midpointWorld: midpoint
            )

        case .moved:
            guard var grab = activePadGrab,
                  grab.itemIdentifier == sample.itemIdentifier,
                  let midpoint = sample.midpointWorld
            else { return }
            grab.midpointWorld = midpoint
            activePadGrab = grab

        case .released:
            guard let grab = activePadGrab,
                  grab.itemIdentifier == sample.itemIdentifier
            else { return }
            activePadGrab = nil
            resolvePhysicalPadRelease(
                grab: grab,
                releaseWorldPosition: sample.midpointWorld ?? grab.midpointWorld
            )

        case .cancelled:
            if activePadGrab?.itemIdentifier == sample.itemIdentifier {
                activePadGrab = nil
            }
        }
    }

    /// Region correctness stays reducer-owned: this resolves geometry only (snap target
    /// and normalized error) and forwards the typed evidence.
    private func resolvePhysicalPadRelease(
        grab: AEDPadGrabPresentation,
        releaseWorldPosition: SIMD3<Float>
    ) {
        let snap = handTrackingTargets?.grid?.snapResolution(
            forWorld: releaseWorldPosition
        )
        let restingPosition = snap?.worldSnapPosition ?? releaseWorldPosition
        grabItemPositions[grab.itemIdentifier] = restingPosition
        publishGrabbableItems()
        padSnapPresentation = AEDPadSnapPresentation(
            id: UUID(),
            itemIdentifier: grab.itemIdentifier,
            worldPosition: restingPosition
        )
        placePhysicalPad(
            side: grab.padSide,
            regionID: snap?.regionID,
            normalizedPlacementError: snap.map(\.normalizedError)
        )
    }

    private func recordGuidedCompression(at timestamp: Double) {
        guard timestamp.isFinite, timestamp >= 0,
              guidedCompressionTimestamps.last.map({ timestamp > $0 }) ?? true
        else { return }
        if let previous = guidedCompressionTimestamps.last {
            let cadence = 60 / (timestamp - previous)
            guidedCadencePerMinute = cadence
            if let policy = content?.cprPolicy {
                if cadence < policy.minimumRatePerMinute {
                    guidedTempoBands.append(.belowSupportedBand)
                } else if cadence > policy.maximumRatePerMinute {
                    guidedTempoBands.append(.aboveSupportedBand)
                } else {
                    guidedTempoBands.append(.withinSupportedBand)
                }
            }
        }
        guidedCompressionTimestamps.append(timestamp)
        guidedCompressionCount += 1
        guidedInterruptionSeconds = 0
        latestFeedback = nil
    }

    private func startMetronome() {
        guard metronomeTask == nil else { return }
        let tempo = content?.cprPolicy.practiceTempoPerMinute ??
            CPRPracticePolicy.sourceBacked.practiceTempoPerMinute
        let interval = 60 / tempo
        let director = audioDirector
        metronomeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !self.isPaused, self.state == .resumeCompressions else {
                    continue
                }
                self.visualMetronomePulse.toggle()
                _ = await director.play(
                    AudioPlaybackRequest(
                        cue: AudioCue(rawValue: "sfx.metronome"),
                        channel: .soundEffects,
                        context: .immersive,
                        autoplay: true
                    )
                )
            }
        }
    }

    private func stopMetronome() {
        metronomeTask?.cancel()
        metronomeTask = nil
        visualMetronomePulse = false
    }

    private func resetGuidedCompressionEvidence() {
        guidedCompressionTimestamps.removeAll(keepingCapacity: false)
        guidedTempoBands.removeAll(keepingCapacity: false)
        guidedCompressionCount = 0
        guidedCadencePerMinute = nil
        guidedInterruptionSeconds = 0
        visualMetronomePulse = false
    }

    private func restartHandTrackingAfterPause() {
        Task { [weak self] in
            guard let self, !self.isPaused else { return }
            await self.handTracking.start()
            self.handTrackingState = self.handTracking.state
        }
    }

    private func startResumeCoachingTimer(resetWindow: Bool) {
        resumeCoachingTask?.cancel()
        resumeCoachingTask = nil
        let remainingSeconds = resetWindow
            ? Self.seconds(from: resumeCoachingDelay)
            : pausedResumeCoachingSeconds ?? Self.seconds(from: resumeCoachingDelay)
        pausedResumeCoachingSeconds = nil
        guard remainingSeconds > 0 else {
            resumeCoachingSecondsRemaining = 0
            expireResumeWindow()
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + remainingSeconds
        resumeCoachingDeadlineUptime = deadline
        updateResumeCountdown(remainingSeconds: remainingSeconds)
        resumeCoachingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.resumeCoachingDeadlineUptime == deadline
                else { return }
                let remaining = max(
                    0,
                    deadline - ProcessInfo.processInfo.systemUptime
                )
                self.updateResumeCountdown(remainingSeconds: remaining)
                if remaining <= 0 {
                    self.expireResumeWindow()
                    return
                }
                try? await Task.sleep(
                    for: min(.milliseconds(100), .seconds(remaining))
                )
            }
        }
    }

    private func pauseResumeCoachingTimer() {
        if let deadline = resumeCoachingDeadlineUptime {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            pausedResumeCoachingSeconds = remaining
            updateResumeCountdown(remainingSeconds: remaining)
        }
        resumeCoachingDeadlineUptime = nil
        resumeCoachingTask?.cancel()
        resumeCoachingTask = nil
    }

    private func finishResumeCoachingTimerAtExpiry() {
        resumeCoachingTask?.cancel()
        resumeCoachingTask = nil
        resumeCoachingDeadlineUptime = nil
        pausedResumeCoachingSeconds = 0
        resumeCoachingSecondsRemaining = 0
    }

    private func clearResumeCoachingTimer() {
        resumeCoachingTask?.cancel()
        resumeCoachingTask = nil
        resumeCoachingDeadlineUptime = nil
        pausedResumeCoachingSeconds = nil
        resumeCoachingSecondsRemaining = nil
    }

    private func updateResumeCountdown(remainingSeconds: TimeInterval) {
        resumeCoachingSecondsRemaining = max(0, Int(ceil(remainingSeconds)))
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return max(
            0,
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        )
    }

    @discardableResult
    private func submit(
        _ event: AEDPracticeEvent
    ) -> StateMachineEventLogEntry<
        AEDPracticeState,
        AEDPracticeEvent,
        AEDPracticeRejectionReason,
        AEDPracticeRemediation
    >? {
        guard !isPaused, var machine else { return nil }
        let entry = machine.handle(event)
        self.machine = machine
        switch entry.outcome {
        case let .accepted(_, remediation):
            latestFeedback = remediation?.message
        case let .rejected(_, remediation):
            latestFeedback = remediation.message
        }
        updateAudioSafety(for: entry)
        return entry
    }

    private func updateAudioSafety(
        for entry: StateMachineEventLogEntry<
            AEDPracticeState,
            AEDPracticeEvent,
            AEDPracticeRejectionReason,
            AEDPracticeRemediation
        >
    ) {
        let director = audioDirector
        let safetyState = AEDAudioSafetyState.forPracticeState(state)
        let correctionActive: Bool
        switch entry.outcome {
        case let .accepted(_, remediation): correctionActive = remediation != nil
        case .rejected: correctionActive = true
        }
        hasActiveSafetyCorrection = correctionActive
        Task {
            await director.setAEDSafetyState(safetyState)
            await director.setSafetyCriticalCorrectionActive(correctionActive)
            if correctionActive {
                await MainActor.run {
                    self.requestSpatialCue("sfx.safety_warning")
                }
            }
        }
    }

    private func requestSpatialCue(_ id: String) {
        spatialCueRequest = AEDSpatialCueRequest(cue: AudioCue(rawValue: id))
    }
}
