import Foundation

/// The authenticated identity exposed to application features.
struct AuthenticatedUser: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let role: UserRole
}

/// Application roles represented in the shared-space dashboard shell.
enum UserRole: String, Codable, Sendable, CaseIterable {
    case learner
    case instructor
    case administrator
}

/// A learner's local-first progress for one course version.
struct LearnerProgress: Codable, Sendable, Equatable {
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let completedLessonIDs: Set<String>
    let updatedAt: Date
}

/// A persisted assessment attempt summary.
struct AssessmentAttemptSummary: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let learnerID: String
    let assessmentID: String
    let courseID: String
    let contentVersion: String
    let score: Double
    let passed: Bool
    let criticalErrorCodes: [String]
    let submittedAt: Date

    init(
        id: String,
        learnerID: String,
        assessmentID: String,
        courseID: String = "",
        contentVersion: String = "",
        score: Double,
        passed: Bool? = nil,
        criticalErrorCodes: [String] = [],
        submittedAt: Date
    ) {
        self.id = id
        self.learnerID = learnerID
        self.assessmentID = assessmentID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.score = score
        self.passed = passed ?? (score >= 0.8)
        self.criticalErrorCodes = criticalErrorCodes
        self.submittedAt = submittedAt
    }
}

/// A named learner cohort used by instructor tooling.
struct CohortSummary: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let learnerIDs: [String]
    let instructorIDs: [String]
    let assignedCourseIDs: [String]
    let isActive: Bool

    init(
        id: String,
        name: String,
        learnerIDs: [String] = [],
        instructorIDs: [String] = [],
        assignedCourseIDs: [String] = [],
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.learnerIDs = learnerIDs
        self.instructorIDs = instructorIDs
        self.assignedCourseIDs = assignedCourseIDs
        self.isActive = isActive
    }
}

/// An internal learner achievement; it is not an external certification.
struct AchievementRecord: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let learnerID: String
    let achievementID: String
    let awardedAt: Date
}

/// A summary of one local/remote synchronization pass.
struct SyncReport: Codable, Sendable, Equatable {
    let completedAt: Date
    let uploadedRecordCount: Int
    let downloadedRecordCount: Int
    let conflictCount: Int

    init(
        completedAt: Date,
        uploadedRecordCount: Int,
        downloadedRecordCount: Int,
        conflictCount: Int = 0
    ) {
        self.completedAt = completedAt
        self.uploadedRecordCount = uploadedRecordCount
        self.downloadedRecordCount = downloadedRecordCount
        self.conflictCount = conflictCount
    }
}

/// A structured event retained for accountability and troubleshooting.
struct AuditEvent: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let actorID: String?
    let category: String
    let action: String
    let timestamp: Date
    let metadata: [String: String]
    let previousHash: String
    let entryHash: String

    init(
        id: String,
        actorID: String?,
        category: String = "application",
        action: String,
        timestamp: Date,
        metadata: [String: String] = [:],
        previousHash: String = "",
        entryHash: String = ""
    ) {
        self.id = id
        self.actorID = actorID
        self.category = category
        self.action = action
        self.timestamp = timestamp
        self.metadata = metadata
        self.previousHash = previousHash
        self.entryHash = entryHash
    }
}

/// A local mutation represented in a CloudKit-shaped synchronization envelope.
struct QueuedSyncEvent: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let aggregateType: String
    let aggregateID: String
    let eventType: String
    let payloadJSON: String
    let queuedAt: Date
    let localUpdatedAt: Date
    let attemptCount: Int
}

/// A remote record competing with a locally queued mutation.
struct SyncConflict: Codable, Sendable, Equatable {
    let localEventID: String
    let remotePayloadJSON: String
    let remoteUpdatedAt: Date
}

/// Result returned by an optional cloud backend for a pushed batch.
struct CloudPushResult: Codable, Sendable, Equatable {
    let acceptedEventIDs: Set<String>
    let conflicts: [SyncConflict]

    init(acceptedEventIDs: Set<String> = [], conflicts: [SyncConflict] = []) {
        self.acceptedEventIDs = acceptedEventIDs
        self.conflicts = conflicts
    }
}

/// Downloaded remote mutation. Application-specific handlers decide how to apply it.
struct CloudChange: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let aggregateType: String
    let aggregateID: String
    let payloadJSON: String
    let updatedAt: Date
}

/// A sample supplied by a verified external CPR sensor integration.
struct CPRSensorMeasurement: Codable, Sendable, Equatable {
    let providerIdentifier: String
    let capturedAt: Date
    let compressionDepthMetres: Double?
    let forceNewtons: Double?
}

/// Provides the current application authentication state.
protocol AuthenticationService: Sendable {
    func currentUser() async -> AuthenticatedUser?
    func signIn(userID: String) async throws -> AuthenticatedUser
    func signOut() async
}

/// Reads and writes versioned course payloads.
protocol CourseRepository: Sendable {
    func allCourses() async throws -> [Course]
    func course(id: String) async throws -> Course?
    func course(id: String, contentVersion: String) async throws -> Course?
    func versions(courseID: String) async throws -> [Course]
    func save(_ course: Course) async throws
}

/// Stores learner course progress independently of the UI and persistence engine.
protocol ProgressRepository: Sendable {
    func progress(learnerID: String, courseID: String) async throws -> LearnerProgress?
    func save(_ progress: LearnerProgress) async throws
}

/// Stores and retrieves knowledge-assessment attempts.
protocol AssessmentRepository: Sendable {
    func attempts(learnerID: String, assessmentID: String) async throws -> [AssessmentAttemptSummary]
    func save(_ attempt: AssessmentAttemptSummary) async throws
}

/// Manages learner membership for instructor cohorts.
protocol CohortRepository: Sendable {
    func allCohorts() async throws -> [CohortSummary]
    func cohort(id: String) async throws -> CohortSummary?
    func save(_ cohort: CohortSummary) async throws
}

/// Stores internal learner achievements without representing external certification.
protocol AchievementRepository: Sendable {
    func achievements(learnerID: String) async throws -> [AchievementRecord]
    func save(_ achievement: AchievementRecord) async throws
}

/// Provides clinical content and its review traceability metadata.
protocol ClinicalContentRepository: Sendable {
    func sourceReferences(courseID: String) async throws -> [SourceReference]
    func saveSourceReferences(_ references: [SourceReference], courseID: String) async throws
}

/// Synchronizes local-first records through the configured remote abstraction.
protocol SyncService: Sendable {
    func enqueue(_ event: QueuedSyncEvent) async throws
    func pendingEvents() async throws -> [QueuedSyncEvent]
    func synchronize() async throws -> SyncReport
}

/// CloudKit-shaped transport boundary. The simulator uses `NoopCloudBackend`.
protocol CloudBackend: Sendable {
    func push(_ events: [QueuedSyncEvent]) async throws -> CloudPushResult
    func pullChanges(since: Date?) async throws -> [CloudChange]
}

/// Persists structured audit events.
protocol AuditLogService: Sendable {
    func events() async throws -> [AuditEvent]
    func record(_ event: AuditEvent) async throws
    func verifyIntegrity() async throws -> Bool
}

/// Supplies measurements from an explicitly verified external CPR sensor.
///
/// Compression depth and force may only come from verified external sensor data.
/// Implementations must never infer, fabricate, or synthesize depth or force values.
/// A provider without a verified connection must return `nil` measurements.
protocol CPRSensorProvider: Sendable {
    var isVerifiedExternalSensorConnected: Bool { get async }
    func latestMeasurement() async throws -> CPRSensorMeasurement?
}
