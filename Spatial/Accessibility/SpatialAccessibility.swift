import Foundation
import Observation

/// Deterministic comfort timer for one immersive session. A suggestion is persistent
/// until dismissed and never closes the immersive space automatically.
@MainActor
@Observable
final class ImmersionComfortSession {
    static let standardBreakThreshold: TimeInterval = 12 * 60

    let breakThreshold: TimeInterval
    private(set) var elapsedImmersionTime: TimeInterval = 0
    private(set) var isBreakSuggestionVisible = false
    private(set) var didSuggestBreak = false

    private var activeSince: Date?
    private var accumulatedTime: TimeInterval = 0

    init(breakThreshold: TimeInterval = standardBreakThreshold) {
        self.breakThreshold = max(0, breakThreshold)
    }

    func start(at date: Date = .now) {
        accumulatedTime = 0
        elapsedImmersionTime = 0
        didSuggestBreak = false
        isBreakSuggestionVisible = false
        activeSince = date
    }

    func suspend(at date: Date = .now) {
        guard let activeSince else { return }
        accumulatedTime += max(0, date.timeIntervalSince(activeSince))
        self.activeSince = nil
        update(at: date)
    }

    func resume(at date: Date = .now) {
        guard activeSince == nil else { return }
        activeSince = date
        update(at: date)
    }

    func update(at date: Date = .now) {
        let activeTime = activeSince.map { max(0, date.timeIntervalSince($0)) } ?? 0
        elapsedImmersionTime = accumulatedTime + activeTime
        if !didSuggestBreak && elapsedImmersionTime >= breakThreshold {
            didSuggestBreak = true
            isBreakSuggestionVisible = true
        }
    }

    func dismissSuggestion() {
        isBreakSuggestionVisible = false
    }

    func reset() {
        activeSince = nil
        accumulatedTime = 0
        elapsedImmersionTime = 0
        isBreakSuggestionVisible = false
        didSuggestBreak = false
    }
}

enum SpatialAccessibility {
    static func effectiveReduceMotion(
        systemSetting: Bool,
        appSetting: Bool
    ) -> Bool {
        systemSetting || appSetting
    }
}
