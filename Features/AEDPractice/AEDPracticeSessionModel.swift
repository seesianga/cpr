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
    /// Project-authored UI coaching window. This is not a clinical timing threshold;
    /// the source-backed learner instruction remains to resume compressions immediately.
    static let defaultResumeCoachingDelay: Duration = .seconds(4)

    private let resumeCoachingDelay: Duration
    private var audioDirector: any AudioDirector
    private var machine: AEDStateMachine?
    private var content: PracticeMachineContentContract?
    private var rightPadCorrect: Bool?
    private var leftPadCorrect: Bool?
    private var resumeCoachingTask: Task<Void, Never>?

    private(set) var loadState: AEDPracticeSessionLoadState = .idle
    private(set) var latestFeedback: String?
    private(set) var clearZoneActivated = false
    private(set) var bystanderClearStates = [
        "bystander_01": false,
        "bystander_02": false
    ]
    private(set) var isPaused = false
    private(set) var spatialCueRequest: AEDSpatialCueRequest?

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
    var isPreparationComplete: Bool { machine?.preparation.isReadyForPads ?? false }
    var padPlacementInstruction: PracticeContentInstruction? {
        content?.aedPadPlacementInstruction
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
        cancelResumeCoachingTimer()
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

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            cancelResumeCoachingTimer()
        } else if state == .noShockAdvised || state == .simulatedShock {
            startResumeCoachingTimer()
        }
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
        guard bystanderClearStates[entityName] != nil else { return }
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
            startResumeCoachingTimer()
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
            startResumeCoachingTimer()
        }
    }

    func expireResumeWindow() {
        guard canInteract else { return }
        submit(.coachedResumeWindowExpired)
    }

    func resumeCompressions() {
        guard canInteract else { return }
        let entry = submit(.resumeCompressions)
        if entry?.wasAccepted == true {
            cancelResumeCoachingTimer()
        }
    }

    func finish() {
        guard canInteract else { return }
        submit(.finish)
    }

    func stop() {
        cancelResumeCoachingTimer()
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

    private func startResumeCoachingTimer() {
        cancelResumeCoachingTimer()
        let delay = resumeCoachingDelay
        resumeCoachingTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.expireResumeWindow()
        }
    }

    private func cancelResumeCoachingTimer() {
        resumeCoachingTask?.cancel()
        resumeCoachingTask = nil
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
        let safetyState: AEDAudioSafetyState = switch state {
        case .analysing: .analysing
        case .charging: .charging
        case .clearConfirmation: .clearConfirmation
        case .simulatedShock: .simulatedShock
        default: .normal
        }
        let correctionActive: Bool
        switch entry.outcome {
        case let .accepted(_, remediation): correctionActive = remediation != nil
        case .rejected: correctionActive = true
        }
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
