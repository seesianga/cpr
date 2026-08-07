import CryptoKit
import Foundation
import SwiftData

enum PersistenceRepositoryError: Error, Sendable, Equatable {
    case invalidUTF8
    case contentVersionNotFound(courseID: String)
    case duplicateEventID(String)
    case invalidLifecycle(String)
}

/// Actor-isolated SwiftData implementations for all LMS repositories.
///
/// Only value-type domain records cross this actor boundary; SwiftData models remain
/// confined to the model actor's context.
@ModelActor
actor SwiftDataRepositoryStore:
    CourseRepository,
    ProgressRepository,
    AssessmentRepository,
    CohortRepository,
    AchievementRepository,
    ClinicalContentRepository,
    ContentVersionRepository,
    AuditLogService
{
    // MARK: CourseRepository

    func allCourses() throws -> [Course] {
        let descriptor = FetchDescriptor<ContentVersionRecord>(
            sortBy: [
                SortDescriptor(\.courseID),
                SortDescriptor(\.contentVersion)
            ]
        )
        return try modelContext.fetch(descriptor).map(Self.decodeCourse)
    }

    func course(id: String) throws -> Course? {
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.courseID == id },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(Self.decodeCourse)
    }

    func course(id: String, contentVersion: String) throws -> Course? {
        let recordID = Self.contentRecordID(courseID: id, contentVersion: contentVersion)
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(Self.decodeCourse)
    }

    func versions(courseID: String) throws -> [Course] {
        let descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.courseID == courseID },
            sortBy: [SortDescriptor(\.contentVersion)]
        )
        return try modelContext.fetch(descriptor).map(Self.decodeCourse)
    }

    func save(_ course: Course) throws {
        let recordID = Self.contentRecordID(
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )
        let courseJSON = try Self.string(from: CourseContentCodec.encode(course))
        let sourceJSON = try Self.encodeSourceReferences(course.sourceReferences)
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1

        if let stored = try modelContext.fetch(descriptor).first {
            stored.courseJSON = courseJSON
            stored.sourceReferencesJSON = sourceJSON
            stored.schemaVersion = course.version.schemaVersion
            stored.updatedAt = .now
        } else {
            modelContext.insert(
                ContentVersionRecord(
                    id: recordID,
                    courseID: course.id,
                    contentVersion: course.version.contentVersion,
                    schemaVersion: course.version.schemaVersion,
                    courseJSON: courseJSON,
                    sourceReferencesJSON: sourceJSON
                )
            )
        }
        try modelContext.save()
    }

    // MARK: ContentVersionRepository

    func versionState(
        courseID: String,
        contentVersion: String
    ) throws -> ContentVersionState? {
        let recordID = Self.contentRecordID(
            courseID: courseID,
            contentVersion: contentVersion
        )
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map(Self.contentVersionState)
    }

    func versionStates(courseID: String) throws -> [ContentVersionState] {
        let descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.courseID == courseID },
            sortBy: [SortDescriptor(\.contentVersion)]
        )
        return try modelContext.fetch(descriptor).map(Self.contentVersionState)
    }

    func setLifecycle(
        _ lifecycle: ContentLifecycle,
        courseID: String,
        contentVersion: String
    ) throws {
        let recordID = Self.contentRecordID(
            courseID: courseID,
            contentVersion: contentVersion
        )
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            throw ClinicalContentError.lifecycleNotFound(
                courseID: courseID,
                contentVersion: contentVersion
            )
        }
        record.lifecycleRawValue = lifecycle.rawValue
        record.updatedAt = .now
        if lifecycle == .retired {
            record.retiredAt = .now
        } else {
            record.retiredAt = nil
        }
        try modelContext.save()
    }

    func publishVersion(courseID: String, contentVersion: String) throws {
        let targetID = Self.contentRecordID(
            courseID: courseID,
            contentVersion: contentVersion
        )
        let descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.courseID == courseID }
        )
        let records = try modelContext.fetch(descriptor)
        guard let target = records.first(where: { $0.id == targetID }) else {
            throw ClinicalContentError.lifecycleNotFound(
                courseID: courseID,
                contentVersion: contentVersion
            )
        }
        let now = Date.now
        for record in records where record.id != targetID && record.lifecycleRawValue == ContentLifecycle.published.rawValue {
            record.lifecycleRawValue = ContentLifecycle.superseded.rawValue
            record.updatedAt = now
        }
        target.lifecycleRawValue = ContentLifecycle.published.rawValue
        target.publishedAt = now
        target.retiredAt = nil
        target.updatedAt = now
        try modelContext.save()
    }

    // MARK: ProgressRepository

    func progress(learnerID: String, courseID: String) throws -> LearnerProgress? {
        var descriptor = FetchDescriptor<ProgressRecord>(
            predicate: #Predicate {
                $0.learnerID == learnerID && $0.courseID == courseID
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map {
            LearnerProgress(
                learnerID: $0.learnerID,
                courseID: $0.courseID,
                contentVersion: $0.contentVersion,
                completedLessonIDs: Set($0.completedLessonIDs),
                updatedAt: $0.updatedAt
            )
        }
    }

    func save(_ progress: LearnerProgress) throws {
        let recordID = Self.progressRecordID(
            learnerID: progress.learnerID,
            courseID: progress.courseID,
            contentVersion: progress.contentVersion
        )
        var descriptor = FetchDescriptor<ProgressRecord>(
            predicate: #Predicate { $0.id == recordID }
        )
        descriptor.fetchLimit = 1
        let completed = progress.completedLessonIDs.sorted()

        if let stored = try modelContext.fetch(descriptor).first {
            stored.completedLessonIDs = completed
            stored.updatedAt = progress.updatedAt
        } else {
            modelContext.insert(
                ProgressRecord(
                    id: recordID,
                    learnerID: progress.learnerID,
                    courseID: progress.courseID,
                    contentVersion: progress.contentVersion,
                    completedLessonIDs: completed,
                    updatedAt: progress.updatedAt
                )
            )
        }
        try modelContext.save()
    }

    // MARK: AssessmentRepository

    func attempts(
        learnerID: String,
        assessmentID: String
    ) throws -> [AssessmentAttemptSummary] {
        let descriptor = FetchDescriptor<AssessmentResult>(
            predicate: #Predicate {
                $0.learnerID == learnerID && $0.assessmentID == assessmentID
            },
            sortBy: [SortDescriptor(\.submittedAt)]
        )
        return try modelContext.fetch(descriptor).map {
            AssessmentAttemptSummary(
                id: $0.id,
                learnerID: $0.learnerID,
                assessmentID: $0.assessmentID,
                courseID: $0.courseID,
                contentVersion: $0.contentVersion,
                score: $0.score,
                passed: $0.passed,
                criticalErrorCodes: $0.criticalErrorCodes,
                submittedAt: $0.submittedAt
            )
        }
    }

    func save(_ attempt: AssessmentAttemptSummary) throws {
        var descriptor = FetchDescriptor<AssessmentResult>(
            predicate: #Predicate { $0.id == attempt.id }
        )
        descriptor.fetchLimit = 1
        if let stored = try modelContext.fetch(descriptor).first {
            stored.score = attempt.score
            stored.passed = attempt.passed
            stored.criticalErrorCodes = attempt.criticalErrorCodes
            stored.submittedAt = attempt.submittedAt
        } else {
            modelContext.insert(
                AssessmentResult(
                    id: attempt.id,
                    attemptID: attempt.id,
                    learnerID: attempt.learnerID,
                    assessmentID: attempt.assessmentID,
                    courseID: attempt.courseID,
                    contentVersion: attempt.contentVersion,
                    score: attempt.score,
                    passed: attempt.passed,
                    criticalErrorCodes: attempt.criticalErrorCodes,
                    submittedAt: attempt.submittedAt
                )
            )
        }
        try modelContext.save()
    }

    // MARK: CohortRepository

    func allCohorts() throws -> [CohortSummary] {
        let descriptor = FetchDescriptor<Cohort>(sortBy: [SortDescriptor(\.name)])
        return try modelContext.fetch(descriptor).map { try cohortSummary(from: $0) }
    }

    func cohort(id: String) throws -> CohortSummary? {
        var descriptor = FetchDescriptor<Cohort>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first.map { try cohortSummary(from: $0) }
    }

    func save(_ cohort: CohortSummary) throws {
        let cohortID = cohort.id
        var descriptor = FetchDescriptor<Cohort>(predicate: #Predicate { $0.id == cohortID })
        descriptor.fetchLimit = 1
        if let stored = try modelContext.fetch(descriptor).first {
            stored.name = cohort.name
            stored.instructorIDs = cohort.instructorIDs
            stored.assignedCourseIDs = cohort.assignedCourseIDs
            stored.isActive = cohort.isActive
            stored.updatedAt = .now
        } else {
            modelContext.insert(
                Cohort(
                    id: cohort.id,
                    name: cohort.name,
                    instructorIDs: cohort.instructorIDs,
                    assignedCourseIDs: cohort.assignedCourseIDs,
                    isActive: cohort.isActive
                )
            )
        }

        let enrollmentDescriptor = FetchDescriptor<Enrollment>(
            predicate: #Predicate { $0.cohortID == cohortID }
        )
        let current = try modelContext.fetch(enrollmentDescriptor)
        let requestedLearners = Set(cohort.learnerIDs)
        for enrollment in current where !requestedLearners.contains(enrollment.learnerID) {
            enrollment.isActive = false
            enrollment.updatedAt = .now
        }
        let existingLearners = Set(current.map(\.learnerID))
        for learnerID in requestedLearners.subtracting(existingLearners) {
            modelContext.insert(
                Enrollment(
                    id: "\(cohortID)#\(learnerID)",
                    cohortID: cohortID,
                    learnerID: learnerID,
                    courseID: cohort.assignedCourseIDs.first ?? ""
                )
            )
        }
        for enrollment in current where requestedLearners.contains(enrollment.learnerID) {
            enrollment.isActive = true
            enrollment.updatedAt = .now
        }
        try modelContext.save()
    }

    // MARK: AchievementRepository

    func achievements(learnerID: String) throws -> [AchievementRecord] {
        let descriptor = FetchDescriptor<BadgeAward>(
            predicate: #Predicate { $0.learnerID == learnerID },
            sortBy: [SortDescriptor(\.awardedAt)]
        )
        return try modelContext.fetch(descriptor).map {
            AchievementRecord(
                id: $0.id,
                learnerID: $0.learnerID,
                achievementID: $0.badgeID,
                awardedAt: $0.awardedAt
            )
        }
    }

    func save(_ achievement: AchievementRecord) throws {
        var descriptor = FetchDescriptor<BadgeAward>(
            predicate: #Predicate { $0.id == achievement.id }
        )
        descriptor.fetchLimit = 1
        if let stored = try modelContext.fetch(descriptor).first {
            stored.badgeID = achievement.achievementID
            stored.awardedAt = achievement.awardedAt
        } else {
            modelContext.insert(
                BadgeAward(
                    id: achievement.id,
                    learnerID: achievement.learnerID,
                    badgeID: achievement.achievementID,
                    awardedAt: achievement.awardedAt
                )
            )
        }
        try modelContext.save()
    }

    // MARK: ClinicalContentRepository

    func sourceReferences(courseID: String) throws -> [SourceReference] {
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.courseID == courseID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else { return [] }
        return try Self.decodeSourceReferences(record.sourceReferencesJSON)
    }

    func saveSourceReferences(_ references: [SourceReference], courseID: String) throws {
        var descriptor = FetchDescriptor<ContentVersionRecord>(
            predicate: #Predicate { $0.courseID == courseID },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let record = try modelContext.fetch(descriptor).first else {
            throw PersistenceRepositoryError.contentVersionNotFound(courseID: courseID)
        }
        record.sourceReferencesJSON = try Self.encodeSourceReferences(references)
        record.updatedAt = .now
        try modelContext.save()
    }

    // MARK: AuditLogService

    func events() throws -> [AuditEvent] {
        try auditEntries().map(Self.auditEvent)
    }

    func record(_ event: AuditEvent) throws {
        var duplicateDescriptor = FetchDescriptor<AuditLogEntry>(
            predicate: #Predicate { $0.id == event.id }
        )
        duplicateDescriptor.fetchLimit = 1
        guard try modelContext.fetch(duplicateDescriptor).isEmpty else {
            throw PersistenceRepositoryError.duplicateEventID(event.id)
        }

        let existing = try auditEntries()
        let previousHash = existing.last?.entryHash ?? ""
        let sequence = (existing.last?.sequenceNumber ?? 0) + 1
        let metadataJSON = try Self.canonicalMetadataJSON(event.metadata)
        let hash = Self.auditHash(
            id: event.id,
            actorID: event.actorID,
            category: event.category,
            action: event.action,
            timestamp: event.timestamp,
            metadataJSON: metadataJSON,
            previousHash: previousHash,
            sequenceNumber: sequence
        )
        modelContext.insert(
            AuditLogEntry(
                id: event.id,
                actorID: event.actorID,
                category: event.category,
                action: event.action,
                timestamp: event.timestamp,
                sequenceNumber: sequence,
                metadataJSON: metadataJSON,
                previousHash: previousHash,
                entryHash: hash
            )
        )
        try modelContext.save()
    }

    func verifyIntegrity() throws -> Bool {
        var previousHash = ""
        for entry in try auditEntries() {
            guard entry.previousHash == previousHash else { return false }
            let expected = Self.auditHash(
                id: entry.id,
                actorID: entry.actorID,
                category: entry.category,
                action: entry.action,
                timestamp: entry.timestamp,
                metadataJSON: entry.metadataJSON,
                previousHash: entry.previousHash,
                sequenceNumber: entry.sequenceNumber
            )
            guard entry.entryHash == expected else { return false }
            previousHash = entry.entryHash
        }
        return true
    }

    // MARK: Helpers

    private func cohortSummary(from cohort: Cohort) throws -> CohortSummary {
        let cohortID = cohort.id
        let descriptor = FetchDescriptor<Enrollment>(
            predicate: #Predicate { $0.cohortID == cohortID && $0.isActive }
        )
        return CohortSummary(
            id: cohort.id,
            name: cohort.name,
            learnerIDs: try modelContext.fetch(descriptor).map(\.learnerID).sorted(),
            instructorIDs: cohort.instructorIDs,
            assignedCourseIDs: cohort.assignedCourseIDs,
            isActive: cohort.isActive
        )
    }

    private func auditEntries() throws -> [AuditLogEntry] {
        try modelContext.fetch(
            FetchDescriptor<AuditLogEntry>(sortBy: [SortDescriptor(\.sequenceNumber)])
        )
    }

    private static func decodeCourse(_ record: ContentVersionRecord) throws -> Course {
        guard let data = record.courseJSON.data(using: .utf8) else {
            throw PersistenceRepositoryError.invalidUTF8
        }
        return try CourseContentCodec.decode(data)
    }

    private static func contentVersionState(
        _ record: ContentVersionRecord
    ) throws -> ContentVersionState {
        guard let lifecycle = ContentLifecycle(rawValue: record.lifecycleRawValue) else {
            throw PersistenceRepositoryError.invalidLifecycle(record.lifecycleRawValue)
        }
        return ContentVersionState(
            courseID: record.courseID,
            contentVersion: record.contentVersion,
            lifecycle: lifecycle,
            updatedAt: record.updatedAt
        )
    }

    private static func encodeSourceReferences(_ references: [SourceReference]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try string(from: encoder.encode(references))
    }

    private static func decodeSourceReferences(_ json: String) throws -> [SourceReference] {
        guard let data = json.data(using: .utf8) else {
            throw PersistenceRepositoryError.invalidUTF8
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SourceReference].self, from: data)
    }

    private static func string(from data: Data) throws -> String {
        guard let string = String(data: data, encoding: .utf8) else {
            throw PersistenceRepositoryError.invalidUTF8
        }
        return string
    }

    private static func contentRecordID(courseID: String, contentVersion: String) -> String {
        "\(courseID)#\(contentVersion)"
    }

    private static func progressRecordID(
        learnerID: String,
        courseID: String,
        contentVersion: String
    ) -> String {
        "\(learnerID)#\(courseID)#\(contentVersion)"
    }

    private static func canonicalMetadataJSON(_ metadata: [String: String]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        return try string(from: data)
    }

    private static func decodeMetadata(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dictionary
    }

    private static func auditEvent(_ entry: AuditLogEntry) -> AuditEvent {
        AuditEvent(
            id: entry.id,
            actorID: entry.actorID,
            category: entry.category,
            action: entry.action,
            timestamp: entry.timestamp,
            metadata: decodeMetadata(entry.metadataJSON),
            previousHash: entry.previousHash,
            entryHash: entry.entryHash
        )
    }

    private static func auditHash(
        id: String,
        actorID: String?,
        category: String,
        action: String,
        timestamp: Date,
        metadataJSON: String,
        previousHash: String,
        sequenceNumber: Int
    ) -> String {
        let canonical = [
            String(sequenceNumber),
            previousHash,
            id,
            actorID ?? "",
            category,
            action,
            String(timestamp.timeIntervalSince1970),
            metadataJSON
        ].joined(separator: "|")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
