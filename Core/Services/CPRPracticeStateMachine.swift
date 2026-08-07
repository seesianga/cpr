import Foundation

enum CPRPracticeState: String, Codable, CaseIterable, Sendable {
    case positioning
    case landmarkCheck
    case correctiveFeedback
    case compressionCycles
    case restWindow
    case stopped
    case complete
}

enum CPRHandPlacementZone: String, Codable, CaseIterable, Sendable {
    case sternumTarget
    case xiphoidAvoidZone
    case outsideTarget
    case unavailable
}

enum CPRHandStackingHeuristic: String, Codable, CaseIterable, Sendable {
    case likelyStacked
    case separated
    case indeterminate
}

enum CPRStopReason: String, Codable, CaseIterable, Sendable {
    case emergencyTeamTookOver
    case aedAnalysing
    case aedCharging
    case aedShockPrompt
    case casualtyResponsive
    case normalBreathingReturned
}

enum CPRPracticeEvent: Codable, Equatable, Sendable {
    case confirmPositioning
    case classifyHandPlacement(CPRHandPlacementZone)
    case acknowledgeCorrection
    case compressionDetected(
        timestampSeconds: Double,
        placement: CPRHandPlacementZone,
        handStacking: CPRHandStackingHeuristic
    )
    case recordInterruption(durationSeconds: Double)
    case startRest
    case endRest(durationSeconds: Double)
    case stop(CPRStopReason)
    case finish
    case invalidNumericInput(CPRNumericField)
}

enum CPRNumericField: String, Codable, Sendable {
    case timestampSeconds
    case durationSeconds
}

enum CPRPracticeCorrectionCode: String, Codable, Sendable {
    case xiphoidPlacement
    case outsideSternumTarget
    case placementUnavailable
    case restBeforeCycleBoundary
    case prolongedInterruption
    case invalidCadence
}

struct CPRPracticeRemediation: Codable, Equatable, Sendable {
    let code: CPRPracticeCorrectionCode
    let message: String
    let sourceFactIDs: [String]
}

enum CPRPracticeRejectionReason: Codable, Equatable, Sendable {
    case eventNotAllowed(event: String, state: CPRPracticeState)
    case invalidDuration
    case invalidTimestamp
    case restNotYetAvailable(compressionsSinceRest: Int)
}

enum CPRPracticeCriticalFailure: String, Codable, Sendable {
    case compressionOnXiphoid = "project_authored.compression_on_xiphoid"
    case prolongedInterruption = "project_authored.prolonged_compression_interruption"
}

struct CPRPracticePolicy: Codable, Equatable, Sendable {
    let minimumRatePerMinute: Double
    let maximumRatePerMinute: Double
    let practiceTempoPerMinute: Double
    let preferredCompressionsPerCycle: Int
    let maximumRestSeconds: Double

    static let sourceBacked = CPRPracticePolicy(
        minimumRatePerMinute: 100,
        maximumRatePerMinute: 120,
        practiceTempoPerMinute: 110,
        preferredCompressionsPerCycle: 100,
        maximumRestSeconds: 10
    )

    static func validated(
        minimumRatePerMinute: Double,
        maximumRatePerMinute: Double,
        practiceTempoPerMinute: Double,
        preferredCompressionsPerCycle: Int,
        maximumRestSeconds: Double
    ) throws -> CPRPracticePolicy {
        guard minimumRatePerMinute.isFinite,
              maximumRatePerMinute.isFinite,
              practiceTempoPerMinute.isFinite,
              maximumRestSeconds.isFinite,
              minimumRatePerMinute > 0,
              minimumRatePerMinute <= maximumRatePerMinute,
              (minimumRatePerMinute...maximumRatePerMinute).contains(practiceTempoPerMinute),
              preferredCompressionsPerCycle > 0,
              maximumRestSeconds > 0
        else { throw CPRPracticePolicyError.invalidSourceBackedPolicy }
        return CPRPracticePolicy(
            minimumRatePerMinute: minimumRatePerMinute,
            maximumRatePerMinute: maximumRatePerMinute,
            practiceTempoPerMinute: practiceTempoPerMinute,
            preferredCompressionsPerCycle: preferredCompressionsPerCycle,
            maximumRestSeconds: maximumRestSeconds
        )
    }

    func contains(rate: Double) -> Bool {
        minimumRatePerMinute...maximumRatePerMinute ~= rate
    }
}

enum CPRPracticePolicyError: Error, Equatable, Sendable {
    case invalidSourceBackedPolicy
}

enum CPRCadenceBand: String, Codable, Sendable {
    case belowSupportedBand
    case withinSupportedBand
    case aboveSupportedBand
}

struct CPRInterruption: Codable, Equatable, Sendable {
    let afterCompressionCount: Int
    let durationSeconds: Double
    let wasRestWindow: Bool
    let exceededSupportedMaximum: Bool
}

/// CPR practice metrics derived only from interaction events. There are intentionally no
/// depth or force fields: those values belong exclusively to a verified CPRSensorProvider.
struct CPRPracticeMetrics: Codable, Equatable, Sendable {
    var totalCompressions = 0
    var completedCycles = 0
    var compressionsSinceRest = 0
    var cadenceSamplesPerMinute: [Double] = []
    var cadenceBands: [CPRCadenceBand] = []
    var compressionTimestamps: [Double] = []
    var handStackingSamples: [CPRHandStackingHeuristic] = []
    var interruptions: [CPRInterruption] = []
    var latestHandPlacement: CPRHandPlacementZone = .unavailable

    var latestCadencePerMinute: Double? { cadenceSamplesPerMinute.last }

    var averageCadencePerMinute: Double? {
        guard !cadenceSamplesPerMinute.isEmpty else { return nil }
        return cadenceSamplesPerMinute.reduce(0, +) / Double(cadenceSamplesPerMinute.count)
    }

    var longestInterruptionSeconds: Double {
        interruptions.map(\.durationSeconds).max() ?? 0
    }
}

/// Pure-Swift CPR practice reducer. Rate, placement, rest, interruption and supported stop
/// conditions are authoritative here; UI controls only submit typed events.
struct CPRPracticeStateMachine: EventSourcedStateMachine {
    private(set) var state: CPRPracticeState = .positioning
    private(set) var eventLog: [StateMachineEventLogEntry<
        CPRPracticeState,
        CPRPracticeEvent,
        CPRPracticeRejectionReason,
        CPRPracticeRemediation
    >] = []
    private(set) var metrics = CPRPracticeMetrics()
    private(set) var criticalFailures: [CPRPracticeCriticalFailure] = []
    private(set) var lastCorrection: CPRPracticeRemediation?

    let policy: CPRPracticePolicy

    init(policy: CPRPracticePolicy = .sourceBacked) {
        self.policy = policy
    }

    @discardableResult
    mutating func handle(
        _ event: CPRPracticeEvent
    ) -> StateMachineEventLogEntry<
        CPRPracticeState,
        CPRPracticeEvent,
        CPRPracticeRejectionReason,
        CPRPracticeRemediation
    > {
        let stateBefore = state
        let recordedEvent = event.persistableForReplay
        let outcome: StateMachineEventOutcome<
            CPRPracticeState,
            CPRPracticeRejectionReason,
            CPRPracticeRemediation
        >

        switch (state, recordedEvent) {
        case (_, .invalidNumericInput(.timestampSeconds)):
            outcome = .rejected(
                reason: .invalidTimestamp,
                remediation: Self.remediation(.invalidCadence)
            )

        case (_, .invalidNumericInput(.durationSeconds)):
            outcome = .rejected(
                reason: .invalidDuration,
                remediation: Self.remediation(.prolongedInterruption)
            )

        case (.positioning, .confirmPositioning):
            state = .landmarkCheck
            outcome = .accepted(to: state, remediation: nil)

        case let (.landmarkCheck, .classifyHandPlacement(zone)):
            metrics.latestHandPlacement = zone
            switch zone {
            case .sternumTarget:
                lastCorrection = nil
                state = .compressionCycles
                outcome = .accepted(to: state, remediation: nil)
            case .xiphoidAvoidZone:
                let remediation = Self.remediation(.xiphoidPlacement)
                lastCorrection = remediation
                appendFailure(.compressionOnXiphoid)
                state = .correctiveFeedback
                outcome = .accepted(to: state, remediation: remediation)
            case .outsideTarget:
                let remediation = Self.remediation(.outsideSternumTarget)
                lastCorrection = remediation
                state = .correctiveFeedback
                outcome = .accepted(to: state, remediation: remediation)
            case .unavailable:
                let remediation = Self.remediation(.placementUnavailable)
                lastCorrection = remediation
                state = .correctiveFeedback
                outcome = .accepted(to: state, remediation: remediation)
            }

        case (.correctiveFeedback, .acknowledgeCorrection):
            state = .landmarkCheck
            outcome = .accepted(to: state, remediation: nil)

        case let (
            .compressionCycles,
            .compressionDetected(timestamp, placement, handStacking)
        ):
            guard timestamp.isFinite,
                  timestamp >= 0,
                  metrics.compressionTimestamps.last.map({ timestamp > $0 }) ?? true
            else {
                outcome = .rejected(
                    reason: .invalidTimestamp,
                    remediation: Self.remediation(.invalidCadence)
                )
                break
            }
            metrics.latestHandPlacement = placement
            if placement == .xiphoidAvoidZone {
                let remediation = Self.remediation(.xiphoidPlacement)
                lastCorrection = remediation
                appendFailure(.compressionOnXiphoid)
                state = .correctiveFeedback
                outcome = .accepted(to: state, remediation: remediation)
                break
            }
            if placement == .outsideTarget || placement == .unavailable {
                let code: CPRPracticeCorrectionCode = placement == .unavailable
                    ? .placementUnavailable
                    : .outsideSternumTarget
                let remediation = Self.remediation(code)
                lastCorrection = remediation
                state = .correctiveFeedback
                outcome = .accepted(to: state, remediation: remediation)
                break
            }
            metrics.totalCompressions += 1
            metrics.compressionsSinceRest += 1
            if let previousTimestamp = metrics.compressionTimestamps.last {
                let cadence = 60 / (timestamp - previousTimestamp)
                metrics.cadenceSamplesPerMinute.append(cadence)
                let band: CPRCadenceBand
                if cadence < policy.minimumRatePerMinute {
                    band = .belowSupportedBand
                } else if cadence > policy.maximumRatePerMinute {
                    band = .aboveSupportedBand
                } else {
                    band = .withinSupportedBand
                }
                metrics.cadenceBands.append(band)
            }
            metrics.compressionTimestamps.append(timestamp)
            metrics.handStackingSamples.append(handStacking)
            metrics.completedCycles = metrics.totalCompressions / policy.preferredCompressionsPerCycle
            outcome = .accepted(to: state, remediation: nil)

        case let (.compressionCycles, .recordInterruption(duration)):
            guard duration.isFinite, duration >= 0 else {
                outcome = .rejected(
                    reason: .invalidDuration,
                    remediation: Self.remediation(.prolongedInterruption)
                )
                break
            }
            let exceeded = duration > policy.maximumRestSeconds
            recordInterruption(duration: duration, wasRestWindow: false, exceeded: exceeded)
            if exceeded {
                appendFailure(.prolongedInterruption)
                outcome = .accepted(
                    to: state,
                    remediation: Self.remediation(.prolongedInterruption)
                )
            } else {
                outcome = .accepted(to: state, remediation: nil)
            }

        case (.compressionCycles, .startRest):
            guard metrics.compressionsSinceRest >= policy.preferredCompressionsPerCycle else {
                outcome = .rejected(
                    reason: .restNotYetAvailable(
                        compressionsSinceRest: metrics.compressionsSinceRest
                    ),
                    remediation: Self.remediation(.restBeforeCycleBoundary)
                )
                break
            }
            state = .restWindow
            outcome = .accepted(to: state, remediation: nil)

        case let (.restWindow, .endRest(duration)):
            guard duration.isFinite, duration >= 0 else {
                outcome = .rejected(
                    reason: .invalidDuration,
                    remediation: Self.remediation(.prolongedInterruption)
                )
                break
            }
            let exceeded = duration > policy.maximumRestSeconds
            recordInterruption(duration: duration, wasRestWindow: true, exceeded: exceeded)
            metrics.compressionsSinceRest = 0
            state = .compressionCycles
            if exceeded {
                appendFailure(.prolongedInterruption)
                outcome = .accepted(
                    to: state,
                    remediation: Self.remediation(.prolongedInterruption)
                )
            } else {
                outcome = .accepted(to: state, remediation: nil)
            }

        case let (.compressionCycles, .stop(reason)):
            _ = reason // Every enum case is a source-backed stop condition.
            state = .stopped
            outcome = .accepted(to: state, remediation: nil)

        case (.stopped, .finish):
            state = .complete
            outcome = .accepted(to: state, remediation: nil)

        default:
            outcome = .rejected(
                reason: .eventNotAllowed(
                    event: String(describing: recordedEvent),
                    state: state
                ),
                remediation: Self.remediation(for: state)
            )
        }

        let entry = StateMachineEventLogEntry(
            sequence: eventLog.count,
            stateBefore: stateBefore,
            event: recordedEvent,
            outcome: outcome,
            evidence: [
                "totalCompressions": String(metrics.totalCompressions),
                "completedCycles": String(metrics.completedCycles),
                "compressionsSinceRest": String(metrics.compressionsSinceRest),
                "cadenceBands": metrics.cadenceBands.map(\.rawValue).joined(separator: ","),
                "criticalFailures": criticalFailures.map(\.rawValue).joined(separator: ",")
            ]
        )
        eventLog.append(entry)
        return entry
    }

    private mutating func recordInterruption(
        duration: Double,
        wasRestWindow: Bool,
        exceeded: Bool
    ) {
        metrics.interruptions.append(
            CPRInterruption(
                afterCompressionCount: metrics.totalCompressions,
                durationSeconds: duration,
                wasRestWindow: wasRestWindow,
                exceededSupportedMaximum: exceeded
            )
        )
    }

    private mutating func appendFailure(_ failure: CPRPracticeCriticalFailure) {
        if !criticalFailures.contains(failure) {
            criticalFailures.append(failure)
        }
    }

    private static func remediation(for state: CPRPracticeState) -> CPRPracticeRemediation {
        switch state {
        case .positioning:
            CPRPracticeRemediation(
                code: .outsideSternumTarget,
                message: "Confirm a firm, flat, supine practice position before continuing.",
                sourceFactIDs: ["fact.drsabc.positionCasualty"]
            )
        case .landmarkCheck, .correctiveFeedback:
            remediation(.outsideSternumTarget)
        case .compressionCycles, .restWindow:
            remediation(.prolongedInterruption)
        case .stopped, .complete:
            CPRPracticeRemediation(
                code: .outsideSternumTarget,
                message: "This practice sequence has already reached its supported stop state.",
                sourceFactIDs: ["fact.compression.stopCriteria"]
            )
        }
    }

    static func remediation(_ code: CPRPracticeCorrectionCode) -> CPRPracticeRemediation {
        switch code {
        case .xiphoidPlacement:
            CPRPracticeRemediation(
                code: code,
                message: "Move hand placement to the lower half of the sternum and away from the xiphoid area.",
                sourceFactIDs: ["fact.compression.site"]
            )
        case .outsideSternumTarget:
            CPRPracticeRemediation(
                code: code,
                message: "Place the heel of the hand over the lower-half sternum target.",
                sourceFactIDs: ["fact.compression.site"]
            )
        case .placementUnavailable:
            CPRPracticeRemediation(
                code: code,
                message: "Use the accessible placement control to identify the sternum target before continuing.",
                sourceFactIDs: ["fact.compression.site"]
            )
        case .restBeforeCycleBoundary:
            CPRPracticeRemediation(
                code: code,
                message: "Keep compressions continuous; the coached rest window follows about 100 compressions.",
                sourceFactIDs: ["fact.compression.restRule", "fact.compression.minimiseInterruptions"]
            )
        case .prolongedInterruption:
            CPRPracticeRemediation(
                code: code,
                message: "Resume immediately. The supported rest or interruption window is no more than 10 seconds.",
                sourceFactIDs: ["fact.compression.restRule", "fact.compression.minimiseInterruptions"]
            )
        case .invalidCadence:
            CPRPracticeRemediation(
                code: code,
                message: "Use a positive cadence sample; the supported practice band is 100 to 120 per minute.",
                sourceFactIDs: ["fact.compression.rate"]
            )
        }
    }
}

private extension CPRPracticeEvent {
    var persistableForReplay: CPRPracticeEvent {
        switch self {
        case let .compressionDetected(timestamp, _, _) where !timestamp.isFinite:
            .invalidNumericInput(.timestampSeconds)
        case let .recordInterruption(duration) where !duration.isFinite:
            .invalidNumericInput(.durationSeconds)
        case let .endRest(duration) where !duration.isFinite:
            .invalidNumericInput(.durationSeconds)
        default:
            self
        }
    }
}
