import Foundation
import SwiftData

/// Local learner identity placeholder. Authentication details remain behind a service boundary.
@Model
final class LearnerProfile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, createdAt: Date = .now) {
        self.id = id
        self.displayName = displayName
        self.createdAt = createdAt
    }
}

/// Local-first course progress placeholder.
@Model
final class ProgressRecord {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID
    var courseID: String
    var completedLessonIDs: [String]
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        learnerID: UUID,
        courseID: String,
        completedLessonIDs: [String] = [],
        updatedAt: Date = .now
    ) {
        self.id = id
        self.learnerID = learnerID
        self.courseID = courseID
        self.completedLessonIDs = completedLessonIDs
        self.updatedAt = updatedAt
    }
}

/// Local assessment or practice attempt placeholder.
@Model
final class AttemptRecord {
    @Attribute(.unique) var id: UUID
    var learnerID: UUID
    var activityID: String
    var startedAt: Date
    var completedAt: Date?
    var resultSummary: String?

    init(
        id: UUID = UUID(),
        learnerID: UUID,
        activityID: String,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        resultSummary: String? = nil
    ) {
        self.id = id
        self.learnerID = learnerID
        self.activityID = activityID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.resultSummary = resultSummary
    }
}

/// Append-oriented audit event placeholder for local development.
@Model
final class AuditLogEntry {
    @Attribute(.unique) var id: UUID
    var category: String
    var action: String
    var timestamp: Date
    var metadataJSON: String

    init(
        id: UUID = UUID(),
        category: String,
        action: String,
        timestamp: Date = .now,
        metadataJSON: String = "{}"
    ) {
        self.id = id
        self.category = category
        self.action = action
        self.timestamp = timestamp
        self.metadataJSON = metadataJSON
    }
}
