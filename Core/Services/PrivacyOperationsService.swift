import Foundation
import SwiftData

/// Local privacy operations. It never writes learner identifiers or payloads to `os_log`.
actor PrivacyOperationsService {
    private let modelContainer: ModelContainer
    private let auditLog: any AuditLogService

    init(modelContainer: ModelContainer, auditLog: any AuditLogService) {
        self.modelContainer = modelContainer
        self.auditLog = auditLog
    }

    func recordLearningEvent(_ event: LearningEventRecord) throws {
        let context = ModelContext(modelContainer)
        let resultJSON: String?
        if let result = event.result {
            let data = try JSONEncoder().encode(result)
            resultJSON = String(data: data, encoding: .utf8)
        } else {
            resultJSON = nil
        }
        context.insert(
            LearningEventEntity(
                id: event.id.uuidString,
                actorAccountID: event.actorAccountID,
                verbRawValue: event.verb.rawValue,
                activityID: event.activityID.absoluteString,
                activityName: event.activityName,
                resultJSON: resultJSON,
                contentVersion: event.contentVersion,
                registrationID: event.registrationID?.uuidString,
                timestamp: event.timestamp
            )
        )
        try context.save()
    }

    func exportLearnerData(
        learnerID: String,
        generatedAt: Date = .now
    ) throws -> Data {
        let context = ModelContext(modelContainer)
        let profile = try context.fetch(FetchDescriptor<LearnerProfile>())
            .filter { $0.id == learnerID }
            .map {
                PrivacyExportRecord(
                    id: $0.id,
                    fields: [
                        "displayName": .string($0.displayName),
                        "role": .string($0.roleRawValue),
                        "isActive": .boolean($0.isActive),
                        "createdAt": Self.date($0.createdAt),
                        "updatedAt": Self.date($0.updatedAt)
                    ]
                )
            }
        guard !profile.isEmpty else { throw PrivacyOperationsError.learnerNotFound }

        let export = LearnerDataExport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            learnerProfile: profile,
            enrolments: try context.fetch(FetchDescriptor<Enrollment>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "cohortID": .string($0.cohortID),
                        "courseID": .string($0.courseID),
                        "enrolledAt": Self.date($0.enrolledAt),
                        "isActive": .boolean($0.isActive)
                    ])
                },
            progress: try context.fetch(FetchDescriptor<ProgressRecord>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "courseID": .string($0.courseID),
                        "contentVersion": .string($0.contentVersion),
                        "completedLessonIDs": .array($0.completedLessonIDs.sorted().map(JSONValue.string)),
                        "completionFraction": .number($0.completionFraction),
                        "updatedAt": Self.date($0.updatedAt)
                    ])
                },
            attempts: try context.fetch(FetchDescriptor<AttemptRecord>())
                .filter { $0.learnerID == learnerID }
                .map {
                    var fields: [String: JSONValue] = [
                        "activityID": .string($0.activityID),
                        "contentVersion": .string($0.contentVersion),
                        "attemptKind": .string($0.attemptKind),
                        "startedAt": Self.date($0.startedAt),
                        "criticalErrorCodes": .array($0.criticalErrorCodes.sorted().map(JSONValue.string)),
                        "responseJSON": .string($0.responseJSON)
                    ]
                    if let score = $0.score { fields["score"] = .number(score) }
                    if let passed = $0.passed { fields["passed"] = .boolean(passed) }
                    return Self.record($0.id, fields)
                },
            assessmentResults: try context.fetch(FetchDescriptor<AssessmentResult>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "attemptID": .string($0.attemptID),
                        "assessmentID": .string($0.assessmentID),
                        "courseID": .string($0.courseID),
                        "contentVersion": .string($0.contentVersion),
                        "score": .number($0.score),
                        "passed": .boolean($0.passed),
                        "submittedAt": Self.date($0.submittedAt)
                    ])
                },
            badgeAwards: try context.fetch(FetchDescriptor<BadgeAward>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "badgeID": .string($0.badgeID),
                        "awardedAt": Self.date($0.awardedAt),
                        "reason": .string($0.reason)
                    ])
                },
            instructorFeedback: try context.fetch(FetchDescriptor<InstructorFeedback>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "instructorID": .string($0.instructorID),
                        "courseID": .string($0.courseID),
                        "feedback": .string($0.feedback),
                        "createdAt": Self.date($0.createdAt),
                        "updatedAt": Self.date($0.updatedAt)
                    ])
                },
            practicalSignOffs: try context.fetch(FetchDescriptor<PracticalSignOff>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "courseID": .string($0.courseID),
                        "contentVersion": .string($0.contentVersion),
                        "status": .string($0.statusRawValue),
                        "manikinResultJSON": .string($0.manikinResultJSON),
                        "notes": .string($0.notes)
                    ])
                },
            consents: try context.fetch(FetchDescriptor<ConsentRecord>())
                .filter { $0.learnerID == learnerID }
                .map {
                    Self.record($0.id, [
                        "consentKind": .string($0.consentKind),
                        "policyVersion": .string($0.policyVersion),
                        "isGranted": .boolean($0.isGranted),
                        "recordedAt": Self.date($0.recordedAt)
                    ])
                },
            learningEvents: try context.fetch(FetchDescriptor<LearningEventEntity>())
                .filter { $0.actorAccountID == learnerID }
                .map {
                    Self.record($0.id, [
                        "verb": .string($0.verbRawValue),
                        "activityID": .string($0.activityID),
                        "activityName": .string($0.activityName),
                        "contentVersion": .string($0.contentVersion),
                        "timestamp": Self.date($0.timestamp)
                    ])
                }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Self.sorted(export))
    }

    func requestAccountDeletion(
        learnerID: String,
        requestedAt: Date = .now
    ) async throws -> DeletionReceipt {
        let markingContext = ModelContext(modelContainer)
        guard let profile = try markingContext.fetch(FetchDescriptor<LearnerProfile>())
            .first(where: { $0.id == learnerID })
        else { throw PrivacyOperationsError.learnerNotFound }
        profile.isActive = false
        profile.deletionRequestedAt = requestedAt
        profile.updatedAt = requestedAt
        try markingContext.save()

        try await auditLog.record(
            AuditEvent(
                id: UUID().uuidString,
                actorID: nil,
                category: "privacy",
                action: "local_account_deletion_requested",
                timestamp: requestedAt,
                metadata: [:]
            )
        )

        let context = ModelContext(modelContainer)
        var count = 0
        count += try delete(context, FetchDescriptor<LearnerProfile>()) { $0.id == learnerID }
        count += try delete(context, FetchDescriptor<Enrollment>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<ProgressRecord>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<AttemptRecord>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<AssessmentResult>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<BadgeAward>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<InstructorFeedback>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<PracticalSignOff>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<ConsentRecord>()) { $0.learnerID == learnerID }
        count += try delete(context, FetchDescriptor<LearningEventEntity>()) { $0.actorAccountID == learnerID }
        count += try delete(context, FetchDescriptor<OfflineQueuedEvent>()) { $0.aggregateID == learnerID }
        try context.save()
        return DeletionReceipt(
            requestedAt: requestedAt,
            purgedLocalRecordCount: count,
            localPurgeCompleted: true
        )
    }

    func enforceRetention(
        _ configuration: RetentionConfiguration,
        now: Date = .now
    ) async throws -> RetentionReport {
        let values = [
            configuration.progressDays,
            configuration.attemptDays,
            configuration.feedbackDays,
            configuration.learningEventDays,
            configuration.offlineQueueDays,
            configuration.revokedConsentDays
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw PrivacyOperationsError.invalidRetentionConfiguration
        }
        let calendar = Calendar(identifier: .gregorian)
        let context = ModelContext(modelContainer)
        var counts: [String: Int] = [:]

        let progressCutoff = calendar.date(byAdding: .day, value: -configuration.progressDays, to: now) ?? now
        counts["progress"] = try delete(context, FetchDescriptor<ProgressRecord>()) {
            $0.updatedAt < progressCutoff
        }
        let attemptCutoff = calendar.date(byAdding: .day, value: -configuration.attemptDays, to: now) ?? now
        counts["attempts"] = try delete(context, FetchDescriptor<AttemptRecord>()) {
            ($0.completedAt ?? $0.startedAt) < attemptCutoff
        }
        counts["assessmentResults"] = try delete(context, FetchDescriptor<AssessmentResult>()) {
            $0.submittedAt < attemptCutoff
        }
        let feedbackCutoff = calendar.date(byAdding: .day, value: -configuration.feedbackDays, to: now) ?? now
        counts["instructorFeedback"] = try delete(context, FetchDescriptor<InstructorFeedback>()) {
            $0.updatedAt < feedbackCutoff
        }
        let eventCutoff = calendar.date(byAdding: .day, value: -configuration.learningEventDays, to: now) ?? now
        counts["learningEvents"] = try delete(context, FetchDescriptor<LearningEventEntity>()) {
            $0.timestamp < eventCutoff
        }
        let queueCutoff = calendar.date(byAdding: .day, value: -configuration.offlineQueueDays, to: now) ?? now
        counts["offlineQueue"] = try delete(context, FetchDescriptor<OfflineQueuedEvent>()) {
            $0.queuedAt < queueCutoff
        }
        let consentCutoff = calendar.date(byAdding: .day, value: -configuration.revokedConsentDays, to: now) ?? now
        counts["revokedConsents"] = try delete(context, FetchDescriptor<ConsentRecord>()) {
            guard let revokedAt = $0.revokedAt else { return false }
            return revokedAt < consentCutoff
        }
        try context.save()

        let total = counts.values.reduce(0, +)
        try await auditLog.record(
            AuditEvent(
                id: UUID().uuidString,
                actorID: nil,
                category: "privacy",
                action: "retention_policy_enforced",
                timestamp: now,
                metadata: ["purgedRecordCount": String(total)]
            )
        )
        return RetentionReport(
            completedAt: now,
            purgedRecordCount: total,
            countsByRecordType: counts
        )
    }

    private func delete<Model: PersistentModel>(
        _ context: ModelContext,
        _ descriptor: FetchDescriptor<Model>,
        where predicate: (Model) -> Bool
    ) throws -> Int {
        let records = try context.fetch(descriptor).filter(predicate)
        for record in records { context.delete(record) }
        return records.count
    }

    private static func record(
        _ id: String,
        _ fields: [String: JSONValue]
    ) -> PrivacyExportRecord {
        PrivacyExportRecord(id: id, fields: fields)
    }

    private static func date(_ value: Date) -> JSONValue {
        .string(String(value.timeIntervalSince1970))
    }

    private static func sorted(_ export: LearnerDataExport) -> LearnerDataExport {
        func records(_ values: [PrivacyExportRecord]) -> [PrivacyExportRecord] {
            values.sorted { $0.id < $1.id }
        }
        return LearnerDataExport(
            schemaVersion: export.schemaVersion,
            generatedAt: export.generatedAt,
            learnerProfile: records(export.learnerProfile),
            enrolments: records(export.enrolments),
            progress: records(export.progress),
            attempts: records(export.attempts),
            assessmentResults: records(export.assessmentResults),
            badgeAwards: records(export.badgeAwards),
            instructorFeedback: records(export.instructorFeedback),
            practicalSignOffs: records(export.practicalSignOffs),
            consents: records(export.consents),
            learningEvents: records(export.learningEvents)
        )
    }
}
