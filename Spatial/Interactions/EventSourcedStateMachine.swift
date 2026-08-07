import Foundation

/// The result of reducing one typed event against a typed state.
///
/// Rejections are retained alongside accepted transitions. This gives debrief and audit
/// tooling an honest record of attempted unsafe or out-of-order actions without allowing
/// those actions to mutate the authoritative state.
enum StateMachineEventOutcome<State, RejectionReason, Remediation>:
    Codable, Equatable, Sendable
where State: Codable & Equatable & Sendable,
      RejectionReason: Codable & Equatable & Sendable,
      Remediation: Codable & Equatable & Sendable {
    case accepted(to: State, remediation: Remediation?)
    case rejected(reason: RejectionReason, remediation: Remediation)
}

/// One deterministic entry in an event-sourced state-machine log.
///
/// Sequence numbers are logical time. Wall-clock dates deliberately do not participate in
/// reduction or replay, so a stored event stream always produces the same result.
struct StateMachineEventLogEntry<State, Event, RejectionReason, Remediation>:
    Codable, Equatable, Sendable
where State: Codable & Equatable & Sendable,
      Event: Codable & Equatable & Sendable,
      RejectionReason: Codable & Equatable & Sendable,
      Remediation: Codable & Equatable & Sendable {
    let sequence: Int
    let stateBefore: State
    let event: Event
    let outcome: StateMachineEventOutcome<State, RejectionReason, Remediation>
    /// Deterministic reducer-owned evidence (metrics, failures, safety latches) used to
    /// detect replay divergence beyond the visible phase state.
    let evidence: [String: String]

    init(
        sequence: Int,
        stateBefore: State,
        event: Event,
        outcome: StateMachineEventOutcome<State, RejectionReason, Remediation>,
        evidence: [String: String] = [:]
    ) {
        self.sequence = sequence
        self.stateBefore = stateBefore
        self.event = event
        self.outcome = outcome
        self.evidence = evidence
    }

    var wasAccepted: Bool {
        if case .accepted = outcome { return true }
        return false
    }

    var stateAfter: State {
        switch outcome {
        case let .accepted(state, _): state
        case .rejected: stateBefore
        }
    }
}

/// Generic contract for deterministic, typed, event-sourced clinical engines.
///
/// Conforming machines own their domain snapshot and use `handle(_:)` as their only
/// mutation boundary. Views may observe state and submit events, but never encode clinical
/// transition rules themselves.
protocol EventSourcedStateMachine: Sendable {
    associatedtype State: Codable & Equatable & Sendable
    associatedtype Event: Codable & Equatable & Sendable
    associatedtype RejectionReason: Codable & Equatable & Sendable
    associatedtype Remediation: Codable & Equatable & Sendable

    var state: State { get }
    var eventLog: [StateMachineEventLogEntry<State, Event, RejectionReason, Remediation>] { get }

    @discardableResult
    mutating func handle(
        _ event: Event
    ) -> StateMachineEventLogEntry<State, Event, RejectionReason, Remediation>
}

enum StateMachineReplayError: Error, Equatable, Sendable {
    case nonContiguousSequence(expected: Int, actual: Int)
    case divergentEntry(sequence: Int)
}

/// Replays an event log through the same reducer and verifies every recorded outcome.
enum StateMachineReplay {
    static func verified<Machine: EventSourcedStateMachine>(
        _ expectedLog: [StateMachineEventLogEntry<
            Machine.State,
            Machine.Event,
            Machine.RejectionReason,
            Machine.Remediation
        >],
        makeMachine: () -> Machine
    ) throws -> Machine {
        var machine = makeMachine()
        for (expectedSequence, expectedEntry) in expectedLog.enumerated() {
            guard expectedEntry.sequence == expectedSequence else {
                throw StateMachineReplayError.nonContiguousSequence(
                    expected: expectedSequence,
                    actual: expectedEntry.sequence
                )
            }
            let replayedEntry = machine.handle(expectedEntry.event)
            guard replayedEntry == expectedEntry else {
                throw StateMachineReplayError.divergentEntry(sequence: expectedSequence)
            }
        }
        return machine
    }
}
