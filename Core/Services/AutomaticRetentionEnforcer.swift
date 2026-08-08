import Foundation
import SwiftUI

protocol AutomaticRetentionScheduleStore: Sendable {
    func lastSuccessfulEnforcement() -> Date?
    func saveSuccessfulEnforcement(at date: Date)
}

/// Persistent timestamp storage keeps the 24-hour cadence across scene transitions and relaunches.
struct UserDefaultsAutomaticRetentionScheduleStore: AutomaticRetentionScheduleStore,
    @unchecked Sendable
{
    static let standardKey = "privacy.retention.lastSuccessfulAutomaticEnforcement"

    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = Self.standardKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func lastSuccessfulEnforcement() -> Date? {
        defaults.object(forKey: key) as? Date
    }

    func saveSuccessfulEnforcement(at date: Date) {
        defaults.set(date, forKey: key)
    }
}

/// Serialises launch and interval checks so multiple lifecycle notifications cannot double-purge.
actor AutomaticRetentionEnforcer {
    static let standardInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 15 * 60

    private let privacyOperations: PrivacyOperationsService
    private let scheduleStore: any AutomaticRetentionScheduleStore
    private let configurationProvider: any RetentionConfigurationProviding
    private let interval: TimeInterval
    private var launchAttempted = false
    private var lastAttemptAt: Date?

    init(
        privacyOperations: PrivacyOperationsService,
        scheduleStore: any AutomaticRetentionScheduleStore =
            UserDefaultsAutomaticRetentionScheduleStore(),
        configurationProvider: any RetentionConfigurationProviding =
            UserDefaultsRetentionConfigurationStore(),
        interval: TimeInterval = AutomaticRetentionEnforcer.standardInterval
    ) {
        self.privacyOperations = privacyOperations
        self.scheduleStore = scheduleStore
        self.configurationProvider = configurationProvider
        self.interval = interval
    }

    /// Runs once for each app process, even when a prior process enforced retention recently.
    @discardableResult
    func enforceOnLaunchIfNeeded(
        now: Date = .now
    ) async throws -> RetentionReport? {
        guard !launchAttempted else { return nil }
        launchAttempted = true
        // A transient failure is retried by the active-scene monitor without treating
        // a later scene activation as a second app launch.
        return try await enforce(now: now)
    }

    /// Enforces only when 24 hours have elapsed since the last successful automatic run.
    @discardableResult
    func enforceIfDue(now: Date = .now) async throws -> RetentionReport? {
        guard isDue(now: now) else { return nil }
        return try await enforce(now: now)
    }

    func secondsUntilNextCheck(now: Date = .now) -> TimeInterval {
        if let lastAttemptAt,
           let successful = scheduleStore.lastSuccessfulEnforcement(),
           lastAttemptAt > successful {
            return Self.remaining(
                since: lastAttemptAt,
                interval: Self.retryInterval,
                now: now
            )
        }
        if let successful = scheduleStore.lastSuccessfulEnforcement() {
            return Self.remaining(since: successful, interval: interval, now: now)
        }
        if let lastAttemptAt {
            return Self.remaining(
                since: lastAttemptAt,
                interval: Self.retryInterval,
                now: now
            )
        }
        return 0
    }

    private func isDue(now: Date) -> Bool {
        guard let successful = scheduleStore.lastSuccessfulEnforcement() else {
            return true
        }
        return now.timeIntervalSince(successful) >= interval
    }

    private func enforce(now: Date) async throws -> RetentionReport {
        lastAttemptAt = now
        let report = try await privacyOperations.enforceRetention(
            configurationProvider.configuration(),
            now: now
        )
        scheduleStore.saveSuccessfulEnforcement(at: now)
        return report
    }

    private static func remaining(
        since date: Date,
        interval: TimeInterval,
        now: Date
    ) -> TimeInterval {
        max(0, interval - max(0, now.timeIntervalSince(date)))
    }
}

private struct AutomaticRetentionEnforcementModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let enforcer: AutomaticRetentionEnforcer

    func body(content: Content) -> some View {
        content.task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }

            _ = try? await enforcer.enforceOnLaunchIfNeeded()
            while !Task.isCancelled {
                let delay = await enforcer.secondsUntilNextCheck()
                do {
                    if delay > 0 {
                        try await ContinuousClock().sleep(for: .seconds(delay))
                    }
                    guard !Task.isCancelled else { return }
                    try await enforcer.enforceIfDue()
                } catch is CancellationError {
                    return
                } catch {
                    // The coordinator records the attempt and applies a bounded retry delay.
                }
            }
        }
    }
}

extension View {
    func automaticRetentionEnforcement(
        using enforcer: AutomaticRetentionEnforcer
    ) -> some View {
        modifier(AutomaticRetentionEnforcementModifier(enforcer: enforcer))
    }
}
