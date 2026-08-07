import Foundation

enum DRSABCStep: String, Codable, CaseIterable, Sendable {
    case danger
    case response
    case shout
    case simulatedCall995
    case aedDelegation
    case breathingCheck
    case compressions
    case responsiveCasualty
    case monitoringNormalBreathing
    case complete
}

enum DRSABCCorrectionCode: String, Codable, Sendable {
    case unsafeSceneEntry
    case sceneRequiresMitigation
    case helpNotActivated
    case callMustRemainSimulated
    case loneRescuerMustStay
    case gaspingIsNotNormalBreathing
    case breathingCheckTooLong
}

struct DRSABCRemediation: Codable, Equatable, Sendable {
    let code: DRSABCCorrectionCode
    let message: String
    let sourceFactIDs: [String]
}

enum DRSABCState: Codable, Equatable, Sendable {
    case step(DRSABCStep)
    case correctiveFeedback(DRSABCRemediation, retry: DRSABCStep)
}

enum AEDDistance: String, Codable, CaseIterable, Sendable {
    case near
    case far
}

enum DRSABCEvent: Codable, Equatable, Sendable {
    case inspectDanger(sceneUnsafe: Bool, enteredUnsafeScene: Bool)
    case confirmSceneMitigated
    case checkResponse(isUnresponsive: Bool)
    case shoutForHelp(helpActivated: Bool)
    case rehearse995Call(clearlyLabelledSimulation: Bool)
    case delegateAED(
        bystanderAvailable: Bool,
        alone: Bool,
        distance: AEDDistance,
        learnerLeavesCasualty: Bool
    )
    case assessBreathing(
        durationSeconds: Double,
        casualtyGasping: Bool,
        breathingNormal: Bool,
        treatedGaspingAsNormal: Bool
    )
    case acknowledgeCorrection
    case completeStep
    case invalidNumericInput(field: String)
}

enum DRSABCRejectionReason: Codable, Equatable, Sendable {
    case eventNotAllowed(event: String, state: String)
    case inconsistentResponderInputs
    case invalidDuration
}

enum DRSABCCriticalFailure: String, Codable, CaseIterable, Sendable {
    case unsafeSceneEntry = "project_authored.unsafe_scene_not_mitigated"
    case helpNotActivated = "project_authored.emergency_help_not_activated"
    case loneRescuerLeft = "project_authored.lone_rescuer_left_for_aed"
    case gaspingTreatedAsNormal = "project_authored.gasping_treated_as_normal"
    case breathingCheckExceededTenSeconds = "project_authored.breathing_check_too_long"
}

struct DRSABCPolicy: Codable, Equatable, Sendable {
    let maximumBreathingCheckSeconds: Double
    let aedNearWalkingSeconds: Double
    let loneRescuerLeavesCasualty: Bool

    static let sourceBacked = DRSABCPolicy(
        maximumBreathingCheckSeconds: 10,
        aedNearWalkingSeconds: 60,
        loneRescuerLeavesCasualty: false
    )

    static func validated(
        maximumBreathingCheckSeconds: Double,
        aedNearWalkingSeconds: Double,
        loneRescuerLeavesCasualty: Bool
    ) throws -> DRSABCPolicy {
        guard maximumBreathingCheckSeconds.isFinite,
              maximumBreathingCheckSeconds > 0,
              aedNearWalkingSeconds.isFinite,
              aedNearWalkingSeconds > 0,
              !loneRescuerLeavesCasualty
        else { throw DRSABCPolicyError.invalidSourceBackedPolicy }
        return DRSABCPolicy(
            maximumBreathingCheckSeconds: maximumBreathingCheckSeconds,
            aedNearWalkingSeconds: aedNearWalkingSeconds,
            loneRescuerLeavesCasualty: loneRescuerLeavesCasualty
        )
    }
}

enum DRSABCPolicyError: Error, Equatable, Sendable {
    case invalidSourceBackedPolicy
}

/// Pure-Swift DRSABC reducer. Unsafe branch choices enter a corrective state immediately;
/// callers must acknowledge the source-backed feedback before retrying the affected step.
struct DRSABCStateMachine: EventSourcedStateMachine {
    private(set) var state: DRSABCState = .step(.danger)
    private(set) var eventLog: [StateMachineEventLogEntry<
        DRSABCState,
        DRSABCEvent,
        DRSABCRejectionReason,
        DRSABCRemediation
    >] = []
    private(set) var criticalFailures: [DRSABCCriticalFailure] = []
    private(set) var selectedAEDDistance: AEDDistance?
    private(set) var wasBystanderAvailable: Bool?

    let policy: DRSABCPolicy

    init(policy: DRSABCPolicy = .sourceBacked) {
        self.policy = policy
    }

    @discardableResult
    mutating func handle(
        _ event: DRSABCEvent
    ) -> StateMachineEventLogEntry<
        DRSABCState,
        DRSABCEvent,
        DRSABCRejectionReason,
        DRSABCRemediation
    > {
        let stateBefore = state
        let recordedEvent = event.persistableForReplay
        let outcome: StateMachineEventOutcome<
            DRSABCState,
            DRSABCRejectionReason,
            DRSABCRemediation
        >

        switch (state, recordedEvent) {
        case (_, .invalidNumericInput):
            outcome = .rejected(
                reason: .invalidDuration,
                remediation: Self.remediation(.breathingCheckTooLong)
            )

        case let (.step(.danger), .inspectDanger(sceneUnsafe, enteredUnsafeScene)):
            if sceneUnsafe {
                let code: DRSABCCorrectionCode = enteredUnsafeScene
                    ? .unsafeSceneEntry
                    : .sceneRequiresMitigation
                let remediation = Self.remediation(code)
                state = .correctiveFeedback(remediation, retry: .danger)
                if enteredUnsafeScene {
                    appendFailure(.unsafeSceneEntry)
                }
                outcome = .accepted(to: state, remediation: remediation)
            } else {
                state = .step(.response)
                outcome = .accepted(to: state, remediation: nil)
            }

        case (.correctiveFeedback(_, retry: .danger), .confirmSceneMitigated):
            state = .step(.danger)
            outcome = .accepted(to: state, remediation: nil)

        case let (.step(.response), .checkResponse(isUnresponsive)):
            state = .step(isUnresponsive ? .shout : .responsiveCasualty)
            outcome = .accepted(to: state, remediation: nil)

        case let (.step(.shout), .shoutForHelp(helpActivated)):
            if helpActivated {
                state = .step(.simulatedCall995)
                outcome = .accepted(to: state, remediation: nil)
            } else {
                let remediation = Self.remediation(.helpNotActivated)
                state = .correctiveFeedback(remediation, retry: .shout)
                appendFailure(.helpNotActivated)
                outcome = .accepted(to: state, remediation: remediation)
            }

        case let (.step(.simulatedCall995), .rehearse995Call(clearlyLabelledSimulation)):
            if clearlyLabelledSimulation {
                state = .step(.aedDelegation)
                outcome = .accepted(to: state, remediation: nil)
            } else {
                let remediation = Self.remediation(.callMustRemainSimulated)
                state = .correctiveFeedback(remediation, retry: .simulatedCall995)
                outcome = .accepted(to: state, remediation: remediation)
            }

        case let (
            .step(.aedDelegation),
            .delegateAED(bystanderAvailable, alone, distance, learnerLeavesCasualty)
        ):
            guard bystanderAvailable != alone else {
                outcome = .rejected(
                    reason: .inconsistentResponderInputs,
                    remediation: Self.remediation(.loneRescuerMustStay)
                )
                break
            }
            selectedAEDDistance = distance
            wasBystanderAvailable = bystanderAvailable
            if alone && learnerLeavesCasualty {
                let remediation = Self.remediation(.loneRescuerMustStay)
                state = .correctiveFeedback(remediation, retry: .aedDelegation)
                appendFailure(.loneRescuerLeft)
                outcome = .accepted(to: state, remediation: remediation)
            } else {
                state = .step(.breathingCheck)
                outcome = .accepted(to: state, remediation: nil)
            }

        case let (
            .step(.breathingCheck),
            .assessBreathing(duration, gasping, breathingNormal, treatedGaspingAsNormal)
        ):
            guard duration.isFinite, duration >= 0 else {
                outcome = .rejected(
                    reason: .invalidDuration,
                    remediation: Self.remediation(.breathingCheckTooLong)
                )
                break
            }
            if duration > policy.maximumBreathingCheckSeconds {
                let remediation = Self.remediation(.breathingCheckTooLong)
                state = .correctiveFeedback(remediation, retry: .breathingCheck)
                appendFailure(.breathingCheckExceededTenSeconds)
                outcome = .accepted(to: state, remediation: remediation)
            } else if gasping && (breathingNormal || treatedGaspingAsNormal) {
                let remediation = Self.remediation(.gaspingIsNotNormalBreathing)
                state = .correctiveFeedback(remediation, retry: .breathingCheck)
                appendFailure(.gaspingTreatedAsNormal)
                outcome = .accepted(to: state, remediation: remediation)
            } else {
                state = .step(breathingNormal ? .monitoringNormalBreathing : .compressions)
                outcome = .accepted(to: state, remediation: nil)
            }

        case let (.correctiveFeedback(_, retry), .acknowledgeCorrection):
            state = .step(retry)
            outcome = .accepted(to: state, remediation: nil)

        case (.step(.compressions), .completeStep),
             (.step(.responsiveCasualty), .completeStep),
             (.step(.monitoringNormalBreathing), .completeStep):
            state = .step(.complete)
            outcome = .accepted(to: state, remediation: nil)

        default:
            let remediation = Self.remediation(for: state)
            outcome = .rejected(
                reason: .eventNotAllowed(
                    event: String(describing: recordedEvent),
                    state: String(describing: state)
                ),
                remediation: remediation
            )
        }

        let entry = StateMachineEventLogEntry(
            sequence: eventLog.count,
            stateBefore: stateBefore,
            event: recordedEvent,
            outcome: outcome,
            evidence: [
                "criticalFailures": criticalFailures.map(\.rawValue).joined(separator: ","),
                "aedDistance": selectedAEDDistance?.rawValue ?? "unset",
                "bystanderAvailable": wasBystanderAvailable.map(String.init) ?? "unset"
            ]
        )
        eventLog.append(entry)
        return entry
    }

    private mutating func appendFailure(_ failure: DRSABCCriticalFailure) {
        if !criticalFailures.contains(failure) {
            criticalFailures.append(failure)
        }
    }

    private static func remediation(for state: DRSABCState) -> DRSABCRemediation {
        switch state {
        case .step(.danger): remediation(.sceneRequiresMitigation)
        case .step(.shout): remediation(.helpNotActivated)
        case .step(.simulatedCall995): remediation(.callMustRemainSimulated)
        case .step(.aedDelegation): remediation(.loneRescuerMustStay)
        case .step(.breathingCheck): remediation(.gaspingIsNotNormalBreathing)
        case let .correctiveFeedback(remediation, _): remediation
        default:
            DRSABCRemediation(
                code: .sceneRequiresMitigation,
                message: "Complete the current guided step before moving on.",
                sourceFactIDs: ["fact.drsabc.mnemonic"]
            )
        }
    }

    static func remediation(_ code: DRSABCCorrectionCode) -> DRSABCRemediation {
        switch code {
        case .unsafeSceneEntry:
            DRSABCRemediation(
                code: code,
                message: "Do not enter or continue in an unsafe scene. Make the setting safe before approaching.",
                sourceFactIDs: ["fact.drsabc.danger"]
            )
        case .sceneRequiresMitigation:
            DRSABCRemediation(
                code: code,
                message: "Resolve the identified hazard, then repeat the danger check.",
                sourceFactIDs: ["fact.drsabc.danger"]
            )
        case .helpNotActivated:
            DRSABCRemediation(
                code: code,
                message: "Shout for help and activate the simulated emergency-response step before continuing.",
                sourceFactIDs: ["fact.drsabc.call995"]
            )
        case .callMustRemainSimulated:
            DRSABCRemediation(
                code: code,
                message: "Use only the in-app SIMULATION. It never places a real 995 call.",
                sourceFactIDs: ["fact.drsabc.call995"]
            )
        case .loneRescuerMustStay:
            DRSABCRemediation(
                code: code,
                message: "A lone rescuer stays with the casualty and does not leave to search for an AED.",
                sourceFactIDs: ["fact.drsabc.getAed"]
            )
        case .gaspingIsNotNormalBreathing:
            DRSABCRemediation(
                code: code,
                message: "Gasping is not normal breathing. Repeat the check and use the compression branch.",
                sourceFactIDs: ["fact.recognition.gaspingAbnormal", "fact.drsabc.breathingCheck"]
            )
        case .breathingCheckTooLong:
            DRSABCRemediation(
                code: code,
                message: "Look for chest rise and fall for no more than 10 seconds.",
                sourceFactIDs: ["fact.drsabc.breathingCheck"]
            )
        }
    }
}

private extension DRSABCEvent {
    var persistableForReplay: DRSABCEvent {
        switch self {
        case let .assessBreathing(duration, _, _, _) where !duration.isFinite:
            .invalidNumericInput(field: "durationSeconds")
        default:
            self
        }
    }
}
