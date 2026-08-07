import Foundation
import SwiftData
import XCTest
@testable import LifesaverVision

@MainActor
final class PrivacyOperationsTests: XCTestCase {
    func testFullDataExportContainsEveryRequiredSectionAndSchemaVersion() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        seedCompleteLearner(
            learnerID: "learner-export",
            prefix: "export",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            into: context
        )
        try context.save()
        let service = PrivacyOperationsService(
            modelContainer: container,
            auditLog: InMemoryAuditLogService()
        )
        let generatedAt = Date(timeIntervalSince1970: 1_710_000_000)

        let data = try await service.exportLearnerData(
            learnerID: "learner-export",
            generatedAt: generatedAt
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let export = try decoder.decode(LearnerDataExport.self, from: data)

        XCTAssertEqual(export.schemaVersion, 1)
        XCTAssertEqual(export.generatedAt, generatedAt)
        XCTAssertEqual(export.learnerProfile.count, 1)
        XCTAssertEqual(export.enrolments.count, 1)
        XCTAssertEqual(export.progress.count, 1)
        XCTAssertEqual(export.attempts.count, 1)
        XCTAssertEqual(export.assessmentResults.count, 1)
        XCTAssertEqual(export.badgeAwards.count, 1)
        XCTAssertEqual(export.instructorFeedback.count, 1)
        XCTAssertEqual(export.practicalSignOffs.count, 1)
        XCTAssertEqual(export.consents.count, 1)
        XCTAssertEqual(export.learningEvents.count, 1)
        XCTAssertEqual(
            export.attempts.first?.fields["contentVersion"],
            .string("1.0.0")
        )

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let requiredKeys: Set<String> = [
            "schemaVersion",
            "generatedAt",
            "learnerProfile",
            "enrolments",
            "progress",
            "attempts",
            "assessmentResults",
            "badgeAwards",
            "instructorFeedback",
            "practicalSignOffs",
            "consents",
            "learningEvents"
        ]
        XCTAssertTrue(requiredKeys.isSubset(of: Set(json.keys)))
    }

    func testAccountDeletionPurgesLinkedLocalDataAndPreservesOtherLearner() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        seedCompleteLearner(
            learnerID: "learner-delete",
            prefix: "delete",
            timestamp: timestamp,
            into: context
        )
        context.insert(
            OfflineQueuedEvent(
                id: "delete-queue",
                aggregateType: "learner",
                aggregateID: "learner-delete",
                eventType: "progress_changed",
                payloadJSON: "{}",
                queuedAt: timestamp,
                localUpdatedAt: timestamp
            )
        )
        context.insert(
            LearnerProfile(
                id: "learner-keep",
                displayName: "Learner Keep",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
        context.insert(
            ProgressRecord(
                id: "keep-progress",
                learnerID: "learner-keep",
                courseID: "course-1",
                contentVersion: "1.0.0",
                completionFraction: 0.25,
                updatedAt: timestamp
            )
        )
        try context.save()
        let auditLog = InMemoryAuditLogService()
        let service = PrivacyOperationsService(
            modelContainer: container,
            auditLog: auditLog
        )
        let requestedAt = Date(timeIntervalSince1970: 1_720_000_000)

        let receipt = try await service.requestAccountDeletion(
            learnerID: "learner-delete",
            requestedAt: requestedAt
        )

        XCTAssertTrue(receipt.localPurgeCompleted)
        XCTAssertEqual(receipt.requestedAt, requestedAt)
        XCTAssertEqual(receipt.purgedLocalRecordCount, 11)

        let verification = ModelContext(container)
        XCTAssertFalse(try verification.fetch(FetchDescriptor<LearnerProfile>())
            .contains { $0.id == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<Enrollment>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<ProgressRecord>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<AttemptRecord>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<AssessmentResult>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<BadgeAward>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<InstructorFeedback>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<PracticalSignOff>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<ConsentRecord>())
            .contains { $0.learnerID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<LearningEventEntity>())
            .contains { $0.actorAccountID == "learner-delete" })
        XCTAssertFalse(try verification.fetch(FetchDescriptor<OfflineQueuedEvent>())
            .contains { $0.aggregateID == "learner-delete" })
        XCTAssertTrue(try verification.fetch(FetchDescriptor<LearnerProfile>())
            .contains { $0.id == "learner-keep" })
        XCTAssertTrue(try verification.fetch(FetchDescriptor<ProgressRecord>())
            .contains { $0.learnerID == "learner-keep" })

        let events = await auditLog.events()
        XCTAssertEqual(events.last?.action, "local_account_deletion_requested")
        XCTAssertNil(events.last?.actorID)
        XCTAssertTrue(events.last?.metadata.isEmpty == true)
    }

    func testRetentionPurgesOnlyRecordsOlderThanCutoff() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let old = try XCTUnwrap(calendar.date(byAdding: .day, value: -31, to: now))
        let boundary = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: now))
        let recent = try XCTUnwrap(calendar.date(byAdding: .day, value: -5, to: now))

        context.insert(
            LearnerProfile(
                id: "learner-retention",
                displayName: "Retention Learner",
                createdAt: old,
                updatedAt: recent
            )
        )
        for (suffix, date) in [("old", old), ("boundary", boundary)] {
            context.insert(
                ProgressRecord(
                    id: "progress-\(suffix)",
                    learnerID: "learner-retention",
                    courseID: "course-1",
                    contentVersion: "1.0.0",
                    completionFraction: 0.5,
                    updatedAt: date
                )
            )
            context.insert(
                AttemptRecord(
                    id: "attempt-\(suffix)",
                    learnerID: "learner-retention",
                    activityID: "assessment-1",
                    assessmentID: "assessment-1",
                    courseID: "course-1",
                    contentVersion: "1.0.0",
                    attemptKind: "assessment",
                    startedAt: date,
                    completedAt: date,
                    score: 0.8,
                    passed: true
                )
            )
            context.insert(
                AssessmentResult(
                    id: "result-\(suffix)",
                    attemptID: "attempt-\(suffix)",
                    learnerID: "learner-retention",
                    assessmentID: "assessment-1",
                    courseID: "course-1",
                    contentVersion: "1.0.0",
                    score: 0.8,
                    passed: true,
                    submittedAt: date
                )
            )
            context.insert(
                InstructorFeedback(
                    id: "feedback-\(suffix)",
                    learnerID: "learner-retention",
                    instructorID: "instructor-1",
                    courseID: "course-1",
                    feedback: "Retention fixture",
                    createdAt: date,
                    updatedAt: date
                )
            )
            context.insert(
                LearningEventEntity(
                    id: "event-\(suffix)",
                    actorAccountID: "learner-retention",
                    verbRawValue: LearningVerb.completed.rawValue,
                    activityID: "https://lifesaver.vision/activities/retention",
                    activityName: "Retention fixture",
                    contentVersion: "1.0.0",
                    timestamp: date
                )
            )
            context.insert(
                OfflineQueuedEvent(
                    id: "queue-\(suffix)",
                    aggregateType: "learner",
                    aggregateID: "learner-retention",
                    eventType: "retention_fixture",
                    payloadJSON: "{}",
                    queuedAt: date,
                    localUpdatedAt: date
                )
            )
            context.insert(
                ConsentRecord(
                    id: "consent-\(suffix)",
                    learnerID: "learner-retention",
                    consentKind: "analytics",
                    policyVersion: "1",
                    isGranted: false,
                    recordedAt: date,
                    revokedAt: date
                )
            )
        }
        context.insert(
            ConsentRecord(
                id: "consent-active-old",
                learnerID: "learner-retention",
                consentKind: "essential",
                policyVersion: "1",
                isGranted: true,
                recordedAt: old,
                revokedAt: nil
            )
        )
        try context.save()
        let auditLog = InMemoryAuditLogService()
        let service = PrivacyOperationsService(
            modelContainer: container,
            auditLog: auditLog
        )
        let configuration = RetentionConfiguration(
            progressDays: 30,
            attemptDays: 30,
            feedbackDays: 30,
            learningEventDays: 30,
            offlineQueueDays: 30,
            revokedConsentDays: 30
        )

        let report = try await service.enforceRetention(configuration, now: now)

        XCTAssertEqual(report.purgedRecordCount, 7)
        XCTAssertEqual(report.countsByRecordType["progress"], 1)
        XCTAssertEqual(report.countsByRecordType["attempts"], 1)
        XCTAssertEqual(report.countsByRecordType["assessmentResults"], 1)
        XCTAssertEqual(report.countsByRecordType["instructorFeedback"], 1)
        XCTAssertEqual(report.countsByRecordType["learningEvents"], 1)
        XCTAssertEqual(report.countsByRecordType["offlineQueue"], 1)
        XCTAssertEqual(report.countsByRecordType["revokedConsents"], 1)

        let verification = ModelContext(container)
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<ProgressRecord>()).map(\.id)),
            ["progress-boundary"]
        )
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<AttemptRecord>()).map(\.id)),
            ["attempt-boundary"]
        )
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<AssessmentResult>()).map(\.id)),
            ["result-boundary"]
        )
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<InstructorFeedback>()).map(\.id)),
            ["feedback-boundary"]
        )
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<LearningEventEntity>()).map(\.id)),
            ["event-boundary"]
        )
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<OfflineQueuedEvent>()).map(\.id)),
            ["queue-boundary"]
        )
        XCTAssertEqual(
            Set(try verification.fetch(FetchDescriptor<ConsentRecord>()).map(\.id)),
            ["consent-active-old", "consent-boundary"]
        )

        let events = await auditLog.events()
        XCTAssertEqual(events.last?.action, "retention_policy_enforced")
        XCTAssertEqual(events.last?.metadata["purgedRecordCount"], "7")
    }

    func testRetentionRejectsNegativeConfiguration() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let service = PrivacyOperationsService(
            modelContainer: container,
            auditLog: InMemoryAuditLogService()
        )
        let invalid = RetentionConfiguration(
            progressDays: -1,
            attemptDays: 30,
            feedbackDays: 30,
            learningEventDays: 30,
            offlineQueueDays: 30,
            revokedConsentDays: 30
        )

        do {
            _ = try await service.enforceRetention(invalid)
            XCTFail("Negative retention values must be rejected")
        } catch let error as PrivacyOperationsError {
            XCTAssertEqual(error, .invalidRetentionConfiguration)
        }
    }

    private func seedCompleteLearner(
        learnerID: String,
        prefix: String,
        timestamp: Date,
        into context: ModelContext
    ) {
        context.insert(
            LearnerProfile(
                id: learnerID,
                displayName: "Test Learner",
                roleRawValue: Role.learner.rawValue,
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
        context.insert(
            Enrollment(
                id: "\(prefix)-enrolment",
                cohortID: "cohort-1",
                learnerID: learnerID,
                courseID: "course-1",
                enrolledAt: timestamp,
                updatedAt: timestamp
            )
        )
        context.insert(
            ProgressRecord(
                id: "\(prefix)-progress",
                learnerID: learnerID,
                courseID: "course-1",
                contentVersion: "1.0.0",
                completedLessonIDs: ["lesson-1"],
                lastLessonID: "lesson-1",
                completionFraction: 1,
                updatedAt: timestamp
            )
        )
        context.insert(
            AttemptRecord(
                id: "\(prefix)-attempt",
                learnerID: learnerID,
                activityID: "assessment-1",
                assessmentID: "assessment-1",
                courseID: "course-1",
                contentVersion: "1.0.0",
                attemptKind: "assessment",
                startedAt: timestamp,
                completedAt: timestamp,
                score: 0.9,
                passed: true,
                responseJSON: "{\"choice\":\"a\"}",
                resultSummary: "Passed"
            )
        )
        context.insert(
            AssessmentResult(
                id: "\(prefix)-result",
                attemptID: "\(prefix)-attempt",
                learnerID: learnerID,
                assessmentID: "assessment-1",
                courseID: "course-1",
                contentVersion: "1.0.0",
                score: 0.9,
                passed: true,
                submittedAt: timestamp,
                responseJSON: "{\"choice\":\"a\"}"
            )
        )
        context.insert(
            BadgeAward(
                id: "\(prefix)-badge",
                learnerID: learnerID,
                badgeID: "rhythm-keeper",
                awardedAt: timestamp,
                contentVersion: "1.0.0",
                sourceAttemptID: "\(prefix)-attempt",
                reason: "Test award"
            )
        )
        context.insert(
            InstructorFeedback(
                id: "\(prefix)-feedback",
                learnerID: learnerID,
                instructorID: "instructor-1",
                courseID: "course-1",
                attemptID: "\(prefix)-attempt",
                feedback: "Test feedback",
                createdAt: timestamp,
                updatedAt: timestamp
            )
        )
        context.insert(
            PracticalSignOff(
                id: "\(prefix)-signoff",
                learnerID: learnerID,
                instructorID: "instructor-1",
                courseID: "course-1",
                contentVersion: "1.0.0",
                statusRawValue: PracticalSignOffStatus.approved.rawValue,
                scheduledAt: timestamp,
                assessedAt: timestamp,
                manikinResultJSON: "{\"depth\":\"Not physically assessed\"}",
                notes: "Test manikin assessment",
                signedAt: timestamp
            )
        )
        context.insert(
            ConsentRecord(
                id: "\(prefix)-consent",
                learnerID: learnerID,
                consentKind: "essential",
                policyVersion: "1",
                isGranted: true,
                recordedAt: timestamp
            )
        )
        context.insert(
            LearningEventEntity(
                id: "\(prefix)-event",
                actorAccountID: learnerID,
                verbRawValue: LearningVerb.passed.rawValue,
                activityID: "https://lifesaver.vision/activities/assessment-1",
                activityName: "Assessment 1",
                resultJSON: "{\"scaledScore\":0.9}",
                contentVersion: "1.0.0",
                registrationID: nil,
                timestamp: timestamp
            )
        )
    }
}
