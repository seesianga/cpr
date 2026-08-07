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
    let score: Double
    let submittedAt: Date
}

/// A named learner cohort used by instructor tooling.
struct CohortSummary: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let learnerIDs: [String]
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
}

/// A structured event retained for accountability and troubleshooting.
struct AuditEvent: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let actorID: String?
    let action: String
    let timestamp: Date
    let metadata: [String: String]
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
    func synchronize() async throws -> SyncReport
}

/// Persists structured audit events.
protocol AuditLogService: Sendable {
    func events() async throws -> [AuditEvent]
    func record(_ event: AuditEvent) async throws
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
