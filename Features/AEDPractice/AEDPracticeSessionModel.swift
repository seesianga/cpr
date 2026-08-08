import Foundation
import Observation

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

    private let resumeCoachingDelay: Duration
    private var audioDirector: any AudioDirector
    private var machine: AEDStateMachine?
    private var content: PracticeMachineContentContract?
    private var rightPadCorrect: Bool?
    private var leftPadCorrect: Bool?
    private var resumeCoachingTask: Task<Void, Never>?
    private var resumeCoachingDeadlineUptime: TimeInterval?
    private var pausedResumeCoachingSeconds: TimeInterval?

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

    init(
        resumeCoachingDelay: Duration = defaultResumeCoachingDelay,
        audioDirector: any AudioDirector = NoOpAudioDirector()
    ) {
        self.resumeCoachingDelay = resumeCoachingDelay
        self.audioDirector = audioDirector
    }

    func setAudioDirector(_ audioDirector: any AudioDirector) {
        self.audioDirector = audioDirector
    }

    var state: AEDPracticeState? { machine?.state }
    var eventLogCount: Int { machine?.eventLog.count ?? 0 }
    var criticalFailures: [AEDPracticeCriticalFailure] { machine?.criticalFailures ?? [] }
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
        } else if state == .noShockAdvised || state == .simulatedShock {
            isPaused = false
            startResumeCoachingTimer(resetWindow: false)
        } else {
            isPaused = false
        }
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
        }
    }

    func finish() {
        guard canInteract else { return }
        submit(.finish)
    }

    func stop() {
        clearResumeCoachingTimer()
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
