import Foundation

struct PrivacyExportRecord: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let fields: [String: JSONValue]
}

struct LearnerDataExport: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let learnerProfile: [PrivacyExportRecord]
    let enrolments: [PrivacyExportRecord]
    let progress: [PrivacyExportRecord]
    let attempts: [PrivacyExportRecord]
    let assessmentResults: [PrivacyExportRecord]
    let badgeAwards: [PrivacyExportRecord]
    let instructorFeedback: [PrivacyExportRecord]
    let practicalSignOffs: [PrivacyExportRecord]
    let consents: [PrivacyExportRecord]
    let learningEvents: [PrivacyExportRecord]
}

struct DeletionReceipt: Codable, Sendable, Equatable {
    let requestedAt: Date
    let purgedLocalRecordCount: Int
    let localPurgeCompleted: Bool
}

struct RetentionConfiguration: Codable, Sendable, Equatable {
    let progressDays: Int
    let attemptDays: Int
    let feedbackDays: Int
    let learningEventDays: Int
    let offlineQueueDays: Int
    let revokedConsentDays: Int

    static let standard = RetentionConfiguration(
        progressDays: 730,
        attemptDays: 730,
        feedbackDays: 730,
        learningEventDays: 730,
        offlineQueueDays: 30,
        revokedConsentDays: 365
    )
}

enum RetentionPreferenceKeys {
    static let progressDays = "academy.retention.progressDays"
    static let attemptDays = "academy.retention.attemptDays"
    static let feedbackDays = "academy.retention.feedbackDays"
    static let learningEventDays = "academy.retention.learningEventDays"
    static let offlineQueueDays = "academy.retention.offlineQueueDays"
    static let revokedConsentDays = "academy.retention.revokedConsentDays"
}

protocol RetentionConfigurationProviding: Sendable {
    func configuration() -> RetentionConfiguration
}

/// Reads administrator-managed values at enforcement time so automatic purges do not
/// retain a stale configuration. Missing values use the documented standard policy.
struct UserDefaultsRetentionConfigurationStore: RetentionConfigurationProviding,
    @unchecked Sendable
{
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configuration() -> RetentionConfiguration {
        let fallback = RetentionConfiguration.standard
        return RetentionConfiguration(
            progressDays: integer(for: RetentionPreferenceKeys.progressDays)
                ?? fallback.progressDays,
            attemptDays: integer(for: RetentionPreferenceKeys.attemptDays)
                ?? fallback.attemptDays,
            feedbackDays: integer(for: RetentionPreferenceKeys.feedbackDays)
                ?? fallback.feedbackDays,
            learningEventDays: integer(for: RetentionPreferenceKeys.learningEventDays)
                ?? fallback.learningEventDays,
            offlineQueueDays: integer(for: RetentionPreferenceKeys.offlineQueueDays)
                ?? fallback.offlineQueueDays,
            revokedConsentDays: integer(for: RetentionPreferenceKeys.revokedConsentDays)
                ?? fallback.revokedConsentDays
        )
    }

    private func integer(for key: String) -> Int? {
        (defaults.object(forKey: key) as? NSNumber)?.intValue
    }
}

struct RetentionReport: Codable, Sendable, Equatable {
    let completedAt: Date
    let purgedRecordCount: Int
    let countsByRecordType: [String: Int]
}

enum PrivacyOperationsError: Error, Sendable, Equatable {
    case learnerNotFound
    case invalidRetentionConfiguration
}
