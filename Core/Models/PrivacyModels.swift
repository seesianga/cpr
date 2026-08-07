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

struct RetentionReport: Codable, Sendable, Equatable {
    let completedAt: Date
    let purgedRecordCount: Int
    let countsByRecordType: [String: Int]
}

enum PrivacyOperationsError: Error, Sendable, Equatable {
    case learnerNotFound
    case invalidRetentionConfiguration
}
