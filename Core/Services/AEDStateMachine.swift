import Foundation

enum AEDPadPlacementGuidance {
    // fact.aed.padPlacementAdult
    static let leftPadLocation =
        "the left chest just below and to the left of the left nipple"
    static let correction =
        "Place the right pad on the right chest just below the collarbone and the left pad on \(leftPadLocation); follow the pictures printed on the pads."
    static let accessibleLeftPadHint =
        "Alternative to dragging the left pad on \(leftPadLocation)"
}

/// Runtime safety states requested for Phase 5A. These are intentionally distinct from
/// the Phase 3B JSON's authored teaching-stage labels; `PracticeMachineContentContract` validates
/// and documents that source/runtime boundary.
enum AEDPracticeState: String, Codable, CaseIterable, Sendable {
    case powerOn
    case awaitingPads
    case padsIncorrect
    case padsCorrect
    case analysing
    case shockAdvised
    case noShockAdvised
    case charging
    case clearConfirmation
    case simulatedShock
    case resumeCompressions
    case complete
}

enum AEDChestCondition: String, Codable, CaseIterable, Hashable, Sendable {
    case hairPreventsPadContact
    case jewelleryAtPadSite
    case implantedDeviceNearPadSite
    case medicationPatchAtPadSite
    case wetChest
}

enum AEDPreparationAction: Codable, Equatable, Sendable {
    case shavePadSites
    case moveJewelleryClear
    case confirmImplantedDeviceClearance(fingerBreadths: Int)
    case removeMedicationPatch
    case dryChest
}

struct AEDPreparationChecklist: Codable, Equatable, Sendable {
    let requiredConditions: Set<AEDChestCondition>
    private(set) var completedConditions: Set<AEDChestCondition> = []

    init(requiredConditions: Set<AEDChestCondition> = []) {
        self.requiredConditions = requiredConditions
    }

    var unresolvedConditions: Set<AEDChestCondition> {
        requiredConditions.subtracting(completedConditions)
    }

    var isReadyForPads: Bool { unresolvedConditions.isEmpty }

    @discardableResult
    mutating func perform(_ action: AEDPreparationAction) -> Bool {
        let condition: AEDChestCondition?
        switch action {
        case .shavePadSites:
            condition = .hairPreventsPadContact
        case .moveJewelleryClear:
            condition = .jewelleryAtPadSite
        case let .confirmImplantedDeviceClearance(fingerBreadths):
            condition = fingerBreadths >= 4 ? .implantedDeviceNearPadSite : nil
        case .removeMedicationPatch:
            condition = .medicationPatchAtPadSite
        case .dryChest:
            condition = .wetChest
        }

        guard let condition, requiredConditions.contains(condition) else {
            return false
        }
        completedConditions.insert(condition)
        return true
    }
}

enum AEDPadSide: String, Codable, CaseIterable, Hashable, Sendable {
    case right
    case left

    var expectedRegionID: TorsoRegionID {
        switch self {
        case .right: .padSiteRightClavicle
        case .left: .padSiteLeftLateral
        }
    }
}

/// Immutable evidence from one physical pad release. A nil region/error pair means the
/// learner released outside the configured snap tolerance. The normalized error is
/// scale-independent and is never a distance in metres.
struct AEDPhysicalPadPlacement: Codable, Equatable, Sendable {
    let padSide: AEDPadSide
    let regionID: TorsoRegionID?
    let normalizedPlacementError: Double?

    var isInCorrectRegion: Bool {
        regionID == padSide.expectedRegionID
    }

    var hasValidEvidence: Bool {
        switch (regionID, normalizedPlacementError) {
        case let (.some, .some(error)):
            error.isFinite && error >= 0
        case (nil, nil):
            true
        case (.some, nil), (nil, .some):
            false
        }
    }
}

enum AEDPracticeEvent: Codable, Equatable, Sendable {
    case pressPowerControl
    case performPreparation(AEDPreparationAction)
    case placePads(rightPadCorrect: Bool, leftPadCorrect: Bool)
    /// Additive physical path. Region correctness remains reducer-owned; the feature layer
    /// supplies semantic placement evidence rather than a precomputed correctness Boolean.
    case placePhysicalPad(AEDPhysicalPadPlacement)
    case retryPadPlacement
    case interactiveAnalysisClearCheck(
        clearZoneActivated: Bool,
        bystandersConfirmedClear: Bool,
        anyoneTouching: Bool
    )
    case receiveAnalysisOutcome(AEDAnalysisOutcome, anyoneTouching: Bool)
    case beginCharging(anyoneTouching: Bool)
    case chargingComplete(anyoneTouching: Bool)
    case interactiveClearCheck(
        clearZoneActivated: Bool,
        bystandersConfirmedClear: Bool,
        anyoneTouching: Bool
    )
    /// Invalidates any previously accepted clear sweep when contact resumes.
    case clearCheckInvalidated
    case pressShockControl(anyoneTouching: Bool)
    case coachedResumeWindowExpired
    case resumeCompressions
    case finish
    /// Starts another trainer analysis while the correctly placed pads remain attached.
    /// This is only accepted after the preceding decision has led back to compressions.
    case beginNextAnalysisCycle
}

enum AEDPracticeCorrectionCode: String, Codable, Sendable {
    case preparationIncomplete
    case preparationActionNotApplicable
    case padsIncorrect
    case handsOffRequired
    case clearSweepRequired
    case bystanderStillTouching
    case resumeCompressionsImmediately
    case eventOutOfSequence
}

struct AEDPracticeRemediation: Codable, Equatable, Sendable {
    let code: AEDPracticeCorrectionCode
    let message: String
    let sourceFactIDs: [String]
}

enum AEDPracticeRejectionReason: Codable, Equatable, Sendable {
    case eventNotAllowed(event: String, state: AEDPracticeState)
    case unresolvedPreparation([AEDChestCondition])
    case preparationActionNotApplicable
    case anyoneTouchingDuringAnalysis
    case anyoneTouchingDuringChargeOrShock
    case interactiveClearCheckRequired
    case clearCheckIncomplete
    case unsupportedAnalysisOutcome(String)
    case invalidPhysicalPadPlacement
}

enum AEDPracticeCriticalFailure: String, Codable, CaseIterable, Sendable {
    case contactDuringAnalysis = "unsafe.contact_during_aed_analysis"
    case shockWithoutClearCheck = "project_authored.shock_without_clear_check"
    case contactDuringShock = "project_authored.contact_during_simulated_shock"
    case cprNotResumed = "project_authored.cpr_not_resumed_after_aed_outcome"
}

/// Pure-Swift AED runtime reducer. Contact and interaction provenance are carried in typed
/// events, so a view cannot bypass analysis, clear-sweep, shock, or resume invariants.
struct AEDStateMachine: EventSourcedStateMachine {
    private(set) var state: AEDPracticeState = .powerOn
    private(set) var eventLog: [StateMachineEventLogEntry<
        AEDPracticeState,
        AEDPracticeEvent,
        AEDPracticeRejectionReason,
        AEDPracticeRemediation
    >] = []
    private(set) var preparation: AEDPreparationChecklist
    private(set) var clearCheckCompleted = false
    private(set) var resumeWindowHasExpired = false
    private(set) var criticalFailures: [AEDPracticeCriticalFailure] = []
    private(set) var analysisOutcome: AEDAnalysisOutcome?
    private(set) var physicalPadPlacements: [AEDPadSide: AEDPhysicalPadPlacement] = [:]

    init(requiredChestConditions: Set<AEDChestCondition> = []) {
        preparation = AEDPreparationChecklist(requiredConditions: requiredChestConditions)
    }

    @discardableResult
    mutating func handle(
        _ event: AEDPracticeEvent
    ) -> StateMachineEventLogEntry<
        AEDPracticeState,
        AEDPracticeEvent,
        AEDPracticeRejectionReason,
        AEDPracticeRemediation
    > {
        let stateBefore = state
        let outcome: StateMachineEventOutcome<
            AEDPracticeState,
            AEDPracticeRejectionReason,
            AEDPracticeRemediation
        >

        switch (state, event) {
        case (.powerOn, .pressPowerControl):
            state = .awaitingPads
            outcome = .accepted(to: state, remediation: nil)

        case let (.awaitingPads, .performPreparation(action)):
            if preparation.perform(action) {
                outcome = .accepted(to: state, remediation: nil)
            } else {
                outcome = .rejected(
                    reason: .preparationActionNotApplicable,
                    remediation: Self.remediation(.preparationActionNotApplicable)
                )
            }

        case let (.awaitingPads, .placePads(rightPadCorrect, leftPadCorrect)):
            guard preparation.isReadyForPads else {
                let unresolved = preparation.unresolvedConditions.sorted {
                    $0.rawValue < $1.rawValue
                }
                outcome = .rejected(
                    reason: .unresolvedPreparation(unresolved),
                    remediation: Self.remediation(.preparationIncomplete)
                )
                break
            }
            // Accessible controls carry semantic correctness without claiming a measured
            // physical error. Clear stale physical evidence before taking that path.
            physicalPadPlacements.removeAll(keepingCapacity: false)
            state = rightPadCorrect && leftPadCorrect ? .padsCorrect : .padsIncorrect
            let remediation: AEDPracticeRemediation? = state == .padsIncorrect
                ? Self.remediation(.padsIncorrect)
                : nil
            outcome = .accepted(to: state, remediation: remediation)

        case let (.awaitingPads, .placePhysicalPad(placement)):
            guard preparation.isReadyForPads else {
                let unresolved = preparation.unresolvedConditions.sorted {
                    $0.rawValue < $1.rawValue
                }
                outcome = .rejected(
                    reason: .unresolvedPreparation(unresolved),
                    remediation: Self.remediation(.preparationIncomplete)
                )
                break
            }
            guard placement.hasValidEvidence else {
                outcome = .rejected(
                    reason: .invalidPhysicalPadPlacement,
                    remediation: Self.remediation(.eventOutOfSequence)
                )
                break
            }

            physicalPadPlacements[placement.padSide] = placement
            if !placement.isInCorrectRegion {
                state = .padsIncorrect
                outcome = .accepted(
                    to: state,
                    remediation: Self.remediation(.padsIncorrect)
                )
            } else if AEDPadSide.allCases.allSatisfy({ side in
                physicalPadPlacements[side]?.isInCorrectRegion == true
            }) {
                state = .padsCorrect
                outcome = .accepted(to: state, remediation: nil)
            } else {
                outcome = .accepted(to: state, remediation: nil)
            }

        case (.padsIncorrect, .retryPadPlacement):
            physicalPadPlacements.removeAll(keepingCapacity: false)
            state = .awaitingPads
            outcome = .accepted(to: state, remediation: nil)

        case let (
            .padsCorrect,
            .interactiveAnalysisClearCheck(
                clearZoneActivated,
                bystandersConfirmedClear,
                anyoneTouching
            )
        ):
            if !clearZoneActivated || !bystandersConfirmedClear || anyoneTouching {
                appendFailure(.contactDuringAnalysis)
                outcome = .rejected(
                    reason: anyoneTouching
                        ? .anyoneTouchingDuringAnalysis
                        : .clearCheckIncomplete,
                    remediation: Self.remediation(
                        anyoneTouching || !bystandersConfirmedClear
                            ? .handsOffRequired
                            : .clearSweepRequired
                    )
                )
            } else {
                state = .analysing
                outcome = .accepted(to: state, remediation: nil)
            }

        case let (.analysing, .receiveAnalysisOutcome(selectedOutcome, anyoneTouching)):
            if anyoneTouching {
                appendFailure(.contactDuringAnalysis)
                outcome = .rejected(
                    reason: .anyoneTouchingDuringAnalysis,
                    remediation: Self.remediation(.handsOffRequired)
                )
            } else {
                switch selectedOutcome {
                case .shock:
                    analysisOutcome = selectedOutcome
                    state = .shockAdvised
                    outcome = .accepted(to: state, remediation: nil)
                case .noShock:
                    analysisOutcome = selectedOutcome
                    state = .noShockAdvised
                    outcome = .accepted(to: state, remediation: nil)
                case let .unknown(value):
                    outcome = .rejected(
                        reason: .unsupportedAnalysisOutcome(value),
                        remediation: Self.remediation(.eventOutOfSequence)
                    )
                }
            }

        case let (.shockAdvised, .beginCharging(anyoneTouching)):
            if anyoneTouching {
                appendFailure(.contactDuringShock)
                outcome = .rejected(
                    reason: .anyoneTouchingDuringChargeOrShock,
                    remediation: Self.remediation(.bystanderStillTouching)
                )
            } else {
                state = .charging
                outcome = .accepted(to: state, remediation: nil)
            }

        case let (.charging, .chargingComplete(anyoneTouching)):
            if anyoneTouching {
                appendFailure(.contactDuringShock)
                outcome = .rejected(
                    reason: .anyoneTouchingDuringChargeOrShock,
                    remediation: Self.remediation(.bystanderStillTouching)
                )
            } else {
                clearCheckCompleted = false
                state = .clearConfirmation
                outcome = .accepted(to: state, remediation: nil)
            }

        case let (
            .clearConfirmation,
            .interactiveClearCheck(clearZoneActivated, bystandersConfirmedClear, anyoneTouching)
        ):
            guard clearZoneActivated, bystandersConfirmedClear, !anyoneTouching else {
                clearCheckCompleted = false
                if anyoneTouching {
                    appendFailure(.contactDuringShock)
                }
                outcome = .rejected(
                    reason: .clearCheckIncomplete,
                    remediation: Self.remediation(
                        anyoneTouching || !bystandersConfirmedClear
                            ? .bystanderStillTouching
                            : .clearSweepRequired
                    )
                )
                break
            }
            clearCheckCompleted = true
            outcome = .accepted(to: state, remediation: nil)

        case (.padsCorrect, .clearCheckInvalidated),
             (.analysing, .clearCheckInvalidated),
             (.shockAdvised, .clearCheckInvalidated),
             (.charging, .clearCheckInvalidated),
             (.clearConfirmation, .clearCheckInvalidated):
            clearCheckCompleted = false
            switch state {
            case .analysing:
                appendFailure(.contactDuringAnalysis)
            case .shockAdvised, .charging, .clearConfirmation:
                appendFailure(.contactDuringShock)
            default:
                break
            }
            outcome = .accepted(
                to: state,
                remediation: Self.remediation(.clearSweepRequired)
            )

        case let (.clearConfirmation, .pressShockControl(anyoneTouching)):
            guard clearCheckCompleted else {
                appendFailure(.shockWithoutClearCheck)
                outcome = .rejected(
                    reason: .interactiveClearCheckRequired,
                    remediation: Self.remediation(.clearSweepRequired)
                )
                break
            }
            guard !anyoneTouching else {
                clearCheckCompleted = false
                appendFailure(.contactDuringShock)
                outcome = .rejected(
                    reason: .anyoneTouchingDuringChargeOrShock,
                    remediation: Self.remediation(.bystanderStillTouching)
                )
                break
            }
            state = .simulatedShock
            outcome = .accepted(to: state, remediation: nil)

        case (.simulatedShock, .coachedResumeWindowExpired),
             (.noShockAdvised, .coachedResumeWindowExpired):
            resumeWindowHasExpired = true
            appendFailure(.cprNotResumed)
            outcome = .accepted(
                to: state,
                remediation: Self.remediation(.resumeCompressionsImmediately)
            )

        case (.simulatedShock, .resumeCompressions),
             (.noShockAdvised, .resumeCompressions):
            state = .resumeCompressions
            outcome = .accepted(
                to: state,
                remediation: resumeWindowHasExpired
                    ? Self.remediation(.resumeCompressionsImmediately)
                    : nil
            )

        case (.resumeCompressions, .finish):
            state = .complete
            outcome = .accepted(to: state, remediation: nil)

        case (.complete, .beginNextAnalysisCycle):
            clearCheckCompleted = false
            resumeWindowHasExpired = false
            analysisOutcome = nil
            state = .padsCorrect
            outcome = .accepted(to: state, remediation: nil)

        default:
            outcome = .rejected(
                reason: .eventNotAllowed(
                    event: String(describing: event),
                    state: state
                ),
                remediation: Self.remediation(.eventOutOfSequence)
            )
        }

        let sortedPhysicalPads: [(side: AEDPadSide, placement: AEDPhysicalPadPlacement)] =
            physicalPadPlacements
                .map { (side: $0.key, placement: $0.value) }
                .sorted { $0.side.rawValue < $1.side.rawValue }
        let physicalPadRegions: String = sortedPhysicalPads
            .map { "\($0.side.rawValue):\($0.placement.regionID?.rawValue ?? "outside")" }
            .joined(separator: ",")
        let physicalPadErrors: String = sortedPhysicalPads
            .map { entry -> String in
                let errorText = entry.placement.normalizedPlacementError
                    .map { String($0) } ?? "unavailable"
                return "\(entry.side.rawValue):\(errorText)"
            }
            .joined(separator: ",")

        let entry = StateMachineEventLogEntry(
            sequence: eventLog.count,
            stateBefore: stateBefore,
            event: event,
            outcome: outcome,
            evidence: [
                "clearCheckCompleted": String(clearCheckCompleted),
                "resumeWindowExpired": String(resumeWindowHasExpired),
                "unresolvedPreparation": preparation.unresolvedConditions
                    .map(\.rawValue)
                    .sorted()
                    .joined(separator: ","),
                "physicalPadRegions": physicalPadRegions,
                "physicalPadErrors": physicalPadErrors,
                "criticalFailures": criticalFailures.map(\.rawValue).joined(separator: ",")
            ]
        )
        eventLog.append(entry)
        return entry
    }

    private mutating func appendFailure(_ failure: AEDPracticeCriticalFailure) {
        if !criticalFailures.contains(failure) {
            criticalFailures.append(failure)
        }
    }

    static func remediation(_ code: AEDPracticeCorrectionCode) -> AEDPracticeRemediation {
        switch code {
        case .preparationIncomplete:
            AEDPracticeRemediation(
                code: code,
                message: "Complete every presented chest-preparation check before applying the pads.",
                sourceFactIDs: [
                    "fact.aed.chestPrepHairyChest",
                    "fact.aed.chestPrepJewellery",
                    "fact.aed.chestPrepImplantedDevices",
                    "fact.aed.chestPrepPatches",
                    "fact.aed.chestPrepWet"
                ]
            )
        case .preparationActionNotApplicable:
            AEDPracticeRemediation(
                code: code,
                message: "Choose the preparation action that matches the presented condition.",
                sourceFactIDs: ["fact.aed.applyDuringCpr"]
            )
        case .padsIncorrect:
            // fact.aed.padPlacementAdult
            AEDPracticeRemediation(
                code: code,
                message: AEDPadPlacementGuidance.correction,
                sourceFactIDs: ["fact.aed.padPlacementAdult"]
            )
        case .handsOffRequired:
            AEDPracticeRemediation(
                code: code,
                message: "Stop contact when analysis is announced. Nobody touches the casualty.",
                sourceFactIDs: ["fact.aed.analysisNoTouch"]
            )
        case .clearSweepRequired:
            AEDPracticeRemediation(
                code: code,
                message: "Activate the clear-zone sweep and confirm every bystander is clear before using the simulated shock control.",
                sourceFactIDs: ["fact.aed.shockDelivery"]
            )
        case .bystanderStillTouching:
            AEDPracticeRemediation(
                code: code,
                message: "Do not continue while any person is touching the casualty.",
                sourceFactIDs: ["fact.aed.analysisNoTouch", "fact.aed.shockDelivery"]
            )
        case .resumeCompressionsImmediately:
            AEDPracticeRemediation(
                code: code,
                message: "Restart compressions immediately after either AED outcome.",
                sourceFactIDs: [
                    "fact.aed.resumeAfterShock",
                    "fact.aed.noShockAdvised",
                    "fact.compression.minimiseInterruptions",
                    "fact.compression.restRule"
                ]
            )
        case .eventOutOfSequence:
            AEDPracticeRemediation(
                code: code,
                message: "Complete the current AED prompt before moving to the next action.",
                sourceFactIDs: ["fact.aed.applyDuringCpr"]
            )
        }
    }
}
