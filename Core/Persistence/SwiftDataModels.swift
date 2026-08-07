import Foundation
import SwiftData

/// Local learner identity. Authentication credentials are never stored in SwiftData.
@Model
final class LearnerProfile {
    @Attribute(.unique) var id: String
    var displayName: String
    var roleRawValue: String
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletionRequestedAt: Date?

    init(
        id: String = UUID().uuidString,
        displayName: String,
        roleRawValue: String = "learner",
        isActive: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        deletionRequestedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.roleRawValue = roleRawValue
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletionRequestedAt = deletionRequestedAt
    }
}

/// Local-first progress for one learner and one immutable course content version.
@Model
final class ProgressRecord {
    @Attribute(.unique) var id: String
    var learnerID: String
    var courseID: String
    var contentVersion: String
    var completedLessonIDs: [String]
    var lastLessonID: String?
    var completionFraction: Double
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        learnerID: String,
        courseID: String,
        contentVersion: String,
        completedLessonIDs: [String] = [],
        lastLessonID: String? = nil,
        completionFraction: Double = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.learnerID = learnerID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.completedLessonIDs = completedLessonIDs
        self.lastLessonID = lastLessonID
        self.completionFraction = completionFraction
        self.updatedAt = updatedAt
    }
}

/// A durable assessment or practice attempt. The content version is never rewritten.
@Model
final class AttemptRecord {
    @Attribute(.unique) var id: String
    var learnerID: String
    var activityID: String
    var assessmentID: String?
    var courseID: String?
    var contentVersion: String
    var attemptKind: String
    var startedAt: Date
    var completedAt: Date?
    var score: Double?
    var passed: Bool?
    var criticalErrorCodes: [String]
    var responseJSON: String
    var resultSummary: String?

    init(
        id: String = UUID().uuidString,
        learnerID: String,
        activityID: String,
        assessmentID: String? = nil,
        courseID: String? = nil,
        contentVersion: String,
        attemptKind: String = "practice",
        startedAt: Date = .now,
        completedAt: Date? = nil,
        score: Double? = nil,
        passed: Bool? = nil,
        criticalErrorCodes: [String] = [],
        responseJSON: String = "{}",
        resultSummary: String? = nil
    ) {
        self.id = id
        self.learnerID = learnerID
        self.activityID = activityID
        self.assessmentID = assessmentID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.attemptKind = attemptKind
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.score = score
        self.passed = passed
        self.criticalErrorCodes = criticalErrorCodes
        self.responseJSON = responseJSON
        self.resultSummary = resultSummary
    }
}

/// One immutable link in the local append-only audit chain.
@Model
final class AuditLogEntry {
    @Attribute(.unique) var id: String
    var actorID: String?
    var category: String
    var action: String
    var timestamp: Date
    var metadataJSON: String
    var previousHash: String
    var entryHash: String

    init(
        id: String = UUID().uuidString,
        actorID: String? = nil,
        category: String,
        action: String,
        timestamp: Date = .now,
        metadataJSON: String = "{}",
        previousHash: String = "",
        entryHash: String = ""
    ) {
        self.id = id
        self.actorID = actorID
        self.category = category
        self.action = action
        self.timestamp = timestamp
        self.metadataJSON = metadataJSON
        self.previousHash = previousHash
        self.entryHash = entryHash
    }
}

/// Instructor-managed learner group. Membership is also represented by `Enrollment`.
@Model
final class Cohort {
    @Attribute(.unique) var id: String
    var name: String
    var instructorIDs: [String]
    var assignedCourseIDs: [String]
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        instructorIDs: [String] = [],
        assignedCourseIDs: [String] = [],
        isActive: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.instructorIDs = instructorIDs
        self.assignedCourseIDs = assignedCourseIDs
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Learner membership and course assignment within a cohort.
@Model
final class Enrollment {
    @Attribute(.unique) var id: String
    var cohortID: String
    var learnerID: String
    var courseID: String
    var enrolledAt: Date
    var isActive: Bool
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        cohortID: String,
        learnerID: String,
        courseID: String,
        enrolledAt: Date = .now,
        isActive: Bool = true,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.cohortID = cohortID
        self.learnerID = learnerID
        self.courseID = courseID
        self.enrolledAt = enrolledAt
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

/// Scored knowledge-assessment result linked back to its immutable attempt.
@Model
final class AssessmentResult {
    @Attribute(.unique) var id: String
    var attemptID: String
    var learnerID: String
    var assessmentID: String
    var courseID: String
    var contentVersion: String
    var score: Double
    var passed: Bool
    var criticalErrorCodes: [String]
    var submittedAt: Date
    var responseJSON: String

    init(
        id: String = UUID().uuidString,
        attemptID: String,
        learnerID: String,
        assessmentID: String,
        courseID: String,
        contentVersion: String,
        score: Double,
        passed: Bool,
        criticalErrorCodes: [String] = [],
        submittedAt: Date = .now,
        responseJSON: String = "{}"
    ) {
        self.id = id
        self.attemptID = attemptID
        self.learnerID = learnerID
        self.assessmentID = assessmentID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.score = score
        self.passed = passed
        self.criticalErrorCodes = criticalErrorCodes
        self.submittedAt = submittedAt
        self.responseJSON = responseJSON
    }
}

/// Data-driven internal badge award; never an external certification.
@Model
final class BadgeAward {
    @Attribute(.unique) var id: String
    var learnerID: String
    var badgeID: String
    var awardedAt: Date
    var contentVersion: String?
    var sourceAttemptID: String?
    var reason: String

    init(
        id: String = UUID().uuidString,
        learnerID: String,
        badgeID: String,
        awardedAt: Date = .now,
        contentVersion: String? = nil,
        sourceAttemptID: String? = nil,
        reason: String = ""
    ) {
        self.id = id
        self.learnerID = learnerID
        self.badgeID = badgeID
        self.awardedAt = awardedAt
        self.contentVersion = contentVersion
        self.sourceAttemptID = sourceAttemptID
        self.reason = reason
    }
}

/// Written instructor guidance attached to a learner, course, or attempt.
@Model
final class InstructorFeedback {
    @Attribute(.unique) var id: String
    var learnerID: String
    var instructorID: String
    var courseID: String
    var attemptID: String?
    var feedback: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        learnerID: String,
        instructorID: String,
        courseID: String,
        attemptID: String? = nil,
        feedback: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.learnerID = learnerID
        self.instructorID = instructorID
        self.courseID = courseID
        self.attemptID = attemptID
        self.feedback = feedback
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Instructor-recorded practical outcome using an approved training manikin.
@Model
final class PracticalSignOff {
    @Attribute(.unique) var id: String
    var learnerID: String
    var instructorID: String?
    var courseID: String
    var contentVersion: String
    var statusRawValue: String
    var scheduledAt: Date?
    var assessedAt: Date?
    var manikinResultJSON: String
    var notes: String
    var remediation: String?
    var signedAt: Date?

    init(
        id: String = UUID().uuidString,
        learnerID: String,
        instructorID: String? = nil,
        courseID: String,
        contentVersion: String,
        statusRawValue: String = "scheduled",
        scheduledAt: Date? = nil,
        assessedAt: Date? = nil,
        manikinResultJSON: String = "{}",
        notes: String = "",
        remediation: String? = nil,
        signedAt: Date? = nil
    ) {
        self.id = id
        self.learnerID = learnerID
        self.instructorID = instructorID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.statusRawValue = statusRawValue
        self.scheduledAt = scheduledAt
        self.assessedAt = assessedAt
        self.manikinResultJSON = manikinResultJSON
        self.notes = notes
        self.remediation = remediation
        self.signedAt = signedAt
    }
}

/// Persisted immutable course payload and its lifecycle state.
@Model
final class ContentVersionRecord {
    @Attribute(.unique) var id: String
    var courseID: String
    var contentVersion: String
    var schemaVersion: Int
    var lifecycleRawValue: String
    var courseJSON: String
    var sourceReferencesJSON: String
    var createdAt: Date
    var updatedAt: Date
    var publishedAt: Date?
    var retiredAt: Date?

    init(
        id: String,
        courseID: String,
        contentVersion: String,
        schemaVersion: Int,
        lifecycleRawValue: String = "draft",
        courseJSON: String,
        sourceReferencesJSON: String = "[]",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        publishedAt: Date? = nil,
        retiredAt: Date? = nil
    ) {
        self.id = id
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.schemaVersion = schemaVersion
        self.lifecycleRawValue = lifecycleRawValue
        self.courseJSON = courseJSON
        self.sourceReferencesJSON = sourceReferencesJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.retiredAt = retiredAt
    }
}

/// Durable event waiting for an optional remote backend.
@Model
final class OfflineQueuedEvent {
    @Attribute(.unique) var id: String
    var aggregateType: String
    var aggregateID: String
    var eventType: String
    var payloadJSON: String
    var queuedAt: Date
    var localUpdatedAt: Date
    var remoteUpdatedAt: Date?
    var attemptCount: Int
    var stateRawValue: String
    var conflictPolicyRawValue: String
    var lastErrorDescription: String?

    init(
        id: String = UUID().uuidString,
        aggregateType: String,
        aggregateID: String,
        eventType: String,
        payloadJSON: String,
        queuedAt: Date = .now,
        localUpdatedAt: Date = .now,
        remoteUpdatedAt: Date? = nil,
        attemptCount: Int = 0,
        stateRawValue: String = "pending",
        conflictPolicyRawValue: String = "last_writer_wins_with_audit",
        lastErrorDescription: String? = nil
    ) {
        self.id = id
        self.aggregateType = aggregateType
        self.aggregateID = aggregateID
        self.eventType = eventType
        self.payloadJSON = payloadJSON
        self.queuedAt = queuedAt
        self.localUpdatedAt = localUpdatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.attemptCount = attemptCount
        self.stateRawValue = stateRawValue
        self.conflictPolicyRawValue = conflictPolicyRawValue
        self.lastErrorDescription = lastErrorDescription
    }
}

/// Versioned consent choice recorded locally for privacy operations.
@Model
final class ConsentRecord {
    @Attribute(.unique) var id: String
    var learnerID: String
    var consentKind: String
    var policyVersion: String
    var isGranted: Bool
    var recordedAt: Date
    var revokedAt: Date?

    init(
        id: String = UUID().uuidString,
        learnerID: String,
        consentKind: String,
        policyVersion: String,
        isGranted: Bool,
        recordedAt: Date = .now,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.learnerID = learnerID
        self.consentKind = consentKind
        self.policyVersion = policyVersion
        self.isGranted = isGranted
        self.recordedAt = recordedAt
        self.revokedAt = revokedAt
    }
}
