import Foundation
import Observation

enum DRSABCPracticeLoadState: Sendable, Equatable {
    case idle
    case ready
    case failed(message: String)
}

/// Main-actor bridge between immersive controls and the pure DRSABC reducer.
@MainActor
@Observable
final class DRSABCPracticeSessionModel {
    static let simulationBadge = "SIMULATION — no real call is made"

    private var machine: DRSABCStateMachine?
    private var content: PracticeMachineContentContract?

    private(set) var loadState: DRSABCPracticeLoadState = .idle
    private(set) var latestFeedback: String?
    private(set) var isPaused = false

    var state: DRSABCState? { machine?.state }
    var eventLogCount: Int { machine?.eventLog.count ?? 0 }
    var criticalFailures: [DRSABCCriticalFailure] { machine?.criticalFailures ?? [] }
    var contentVersion: String? { content?.contentVersion }
    var simulatedCallTitle: String {
        content?.simulatedCallTitle ?? "SIMULATION — 995 call rehearsal"
    }
    var simulatedCallBody: String {
        content?.simulatedCallBody ?? "SIMULATION — no real call is made"
    }
    var dispatcherReminder: String { content?.dispatcherReminder.body ?? "" }
    var dispatcherSourceReferences: [SourceReference] {
        content?.dispatcherReminder.sourceReferences ?? []
    }
    var aedDelegationSourceReferences: [SourceReference] {
        content?.aedDelegationInstruction.sourceReferences ?? []
    }
    var aedDelegationGuidance: String {
        guard let content else {
            return "A lone rescuer stays with the casualty and does not leave to search for an AED."
        }
        return "\(content.aedDelegationInstruction.body) If the AED is farther away, continue the response; \(content.dispatcherReminder.body)"
    }
    var callSourceReferences: [SourceReference] {
        content?.simulatedCallSourceReferences ?? []
    }

    var currentStep: DRSABCStep? {
        switch state {
        case let .step(step): step
        case let .correctiveFeedback(_, retry): retry
        case nil: nil
        }
    }

    var activeCorrection: DRSABCRemediation? {
        if case let .correctiveFeedback(remediation, _) = state {
            return remediation
        }
        return nil
    }

    var activeCorrectionSourceCitations: [PracticeSourceCitation] {
        guard let activeCorrection, let content else { return [] }
        return activeCorrection.sourceFactIDs.flatMap {
            content.remediationCitationsByFactID[$0] ?? []
        }
    }

    var guidanceTitle: String {
        if activeCorrection != nil { return "Corrective feedback" }
        return switch currentStep {
        case .danger: "Danger"
        case .response: "Response"
        case .shout: "Shout for help"
        case .simulatedCall995: "Simulated 995 call"
        case .aedDelegation: "Get an AED"
        case .breathingCheck: "Breathing check"
        case .compressions: "Start compressions"
        case .responsiveCasualty: "Responsive casualty"
        case .monitoringNormalBreathing: "Normal breathing branch"
        case .complete: "DRSABC practice complete"
        case nil: "Preparing DRSABC practice"
        }
    }

    var guidanceBody: String {
        if let activeCorrection { return activeCorrection.message }
        if let latestFeedback { return latestFeedback }
        return switch currentStep {
        case .danger:
            "Look for hazards before approaching. Do not enter an unsafe scene."
        case .response:
            content?.responseInstruction.body ?? "Tap the shoulders firmly and ask loudly whether the casualty is okay. Do not shake violently."
        case .shout:
            "Shout for help and activate the simulated emergency response."
        case .simulatedCall995:
            simulatedCallBody
        case .aedDelegation:
            aedDelegationGuidance
        case .breathingCheck:
            content?.breathingBranchInstruction.body ?? "Look for chest rise and fall for no more than 10 seconds. If breathing is absent, abnormal, or you are unsure, begin CPR."
        case .compressions:
            "Move immediately to the guided compression practice."
        case .responsiveCasualty:
            "Continue the appropriate responsive-casualty branch in the guided lesson."
        case .monitoringNormalBreathing:
            content?.breathingBranchInstruction.body ?? "Do not compress when breathing is normal; keep monitoring while waiting for EMS."
        case .complete:
            "Internal practice completion only; this is not SRFAC certification."
        case nil:
            "Source-backed DRSABC content is loading."
        }
    }

    func prepare(from bundle: Bundle = .main) {
        do {
            let loaded = try PracticeMachineContentContract.loadBundled(from: bundle)
            content = loaded
            machine = DRSABCStateMachine(policy: loaded.drsabcPolicy)
            latestFeedback = nil
            loadState = .ready
        } catch {
            content = nil
            machine = nil
            loadState = .failed(
                message: "The source-backed DRSABC practice policy could not be loaded. Practice is unavailable until the content is corrected."
            )
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    func inspectDanger(sceneUnsafe: Bool, enteredUnsafeScene: Bool) {
        submit(
            .inspectDanger(
                sceneUnsafe: sceneUnsafe,
                enteredUnsafeScene: enteredUnsafeScene
            )
        )
    }

    func confirmSceneMitigated() {
        submit(.confirmSceneMitigated)
    }

    func checkResponse(isUnresponsive: Bool) {
        submit(.checkResponse(isUnresponsive: isUnresponsive))
    }

    func shoutForHelp(helpActivated: Bool) {
        submit(.shoutForHelp(helpActivated: helpActivated))
    }

    func rehearseSimulatedCall() {
        submit(.rehearse995Call(clearlyLabelledSimulation: true))
    }

    func delegateAED(
        bystanderAvailable: Bool,
        aedNear: Bool,
        learnerLeavesCasualty: Bool
    ) {
        submit(
            .delegateAED(
                bystanderAvailable: bystanderAvailable,
                alone: !bystanderAvailable,
                distance: aedNear ? .near : .far,
                learnerLeavesCasualty: learnerLeavesCasualty
            )
        )
    }

    func assessBreathing(
        durationSeconds: Double,
        casualtyGasping: Bool,
        breathingNormal: Bool,
        treatedGaspingAsNormal: Bool
    ) {
        submit(
            .assessBreathing(
                durationSeconds: durationSeconds,
                casualtyGasping: casualtyGasping,
                breathingNormal: breathingNormal,
                treatedGaspingAsNormal: treatedGaspingAsNormal
            )
        )
    }

    func acknowledgeCorrection() {
        submit(.acknowledgeCorrection)
    }

    func completeTerminalStep() {
        submit(.completeStep)
    }

    @discardableResult
    private func submit(
        _ event: DRSABCEvent
    ) -> StateMachineEventLogEntry<
        DRSABCState,
        DRSABCEvent,
        DRSABCRejectionReason,
        DRSABCRemediation
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
        return entry
    }
}
