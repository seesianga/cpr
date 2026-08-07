import Foundation

/// In-memory authentication boundary for previews and tests.
actor InMemoryAuthenticationService: AuthenticationService {
    private var user: AuthenticatedUser?

    init(currentUser: AuthenticatedUser? = nil) {
        user = currentUser
    }

    func currentUser() -> AuthenticatedUser? {
        user
    }

    func signIn(userID: String) -> AuthenticatedUser {
        let signedInUser = AuthenticatedUser(
            id: userID,
            displayName: "Preview Learner",
            role: .learner
        )
        user = signedInUser
        return signedInUser
    }

    func signOut() {
        user = nil
    }
}

/// In-memory course repository for previews and deterministic unit tests.
actor InMemoryCourseRepository: CourseRepository {
    private struct Key: Hashable, Sendable {
        let courseID: String
        let contentVersion: String
    }

    private var coursesByKey: [Key: Course] = [:]

    init(courses: [Course] = []) {
        for course in courses {
            coursesByKey[Key(courseID: course.id, contentVersion: course.version.contentVersion)] = course
        }
    }

    func allCourses() -> [Course] {
        coursesByKey.values.sorted {
            ($0.id, $0.version.contentVersion) < ($1.id, $1.version.contentVersion)
        }
    }

    func course(id: String) -> Course? {
        coursesByKey.values
            .filter { $0.id == id }
            .sorted { $0.version.contentVersion > $1.version.contentVersion }
            .first
    }

    func course(id: String, contentVersion: String) -> Course? {
        coursesByKey[Key(courseID: id, contentVersion: contentVersion)]
    }

    func versions(courseID: String) -> [Course] {
        coursesByKey.values
            .filter { $0.id == courseID }
            .sorted { $0.version.contentVersion < $1.version.contentVersion }
    }

    func save(_ course: Course) {
        coursesByKey[Key(courseID: course.id, contentVersion: course.version.contentVersion)] = course
    }
}

/// In-memory learner-progress repository for previews and deterministic unit tests.
actor InMemoryProgressRepository: ProgressRepository {
    private struct Key: Hashable, Sendable {
        let learnerID: String
        let courseID: String
    }

    private var progressByKey: [Key: LearnerProgress] = [:]

    init(progress: [LearnerProgress] = []) {
        for record in progress {
            progressByKey[Key(learnerID: record.learnerID, courseID: record.courseID)] = record
        }
    }

    func progress(learnerID: String, courseID: String) -> LearnerProgress? {
        progressByKey[Key(learnerID: learnerID, courseID: courseID)]
    }

    func save(_ progress: LearnerProgress) {
        progressByKey[Key(learnerID: progress.learnerID, courseID: progress.courseID)] = progress
    }
}

/// In-memory assessment-attempt repository.
actor InMemoryAssessmentRepository: AssessmentRepository {
    private var attemptsByID: [String: AssessmentAttemptSummary] = [:]

    init(attempts: [AssessmentAttemptSummary] = []) {
        for attempt in attempts {
            attemptsByID[attempt.id] = attempt
        }
    }

    func attempts(learnerID: String, assessmentID: String) -> [AssessmentAttemptSummary] {
        attemptsByID.values
            .filter { $0.learnerID == learnerID && $0.assessmentID == assessmentID }
            .sorted { $0.submittedAt < $1.submittedAt }
    }

    func save(_ attempt: AssessmentAttemptSummary) {
        attemptsByID[attempt.id] = attempt
    }
}

/// In-memory cohort repository.
actor InMemoryCohortRepository: CohortRepository {
    private var cohortsByID: [String: CohortSummary] = [:]

    init(cohorts: [CohortSummary] = []) {
        for cohort in cohorts {
            cohortsByID[cohort.id] = cohort
        }
    }

    func allCohorts() -> [CohortSummary] {
        cohortsByID.values.sorted { $0.id < $1.id }
    }

    func cohort(id: String) -> CohortSummary? {
        cohortsByID[id]
    }

    func save(_ cohort: CohortSummary) {
        cohortsByID[cohort.id] = cohort
    }
}

/// In-memory internal-achievement repository.
actor InMemoryAchievementRepository: AchievementRepository {
    private var achievementsByID: [String: AchievementRecord] = [:]

    init(achievements: [AchievementRecord] = []) {
        for achievement in achievements {
            achievementsByID[achievement.id] = achievement
        }
    }

    func achievements(learnerID: String) -> [AchievementRecord] {
        achievementsByID.values
            .filter { $0.learnerID == learnerID }
            .sorted { $0.awardedAt < $1.awardedAt }
    }

    func save(_ achievement: AchievementRecord) {
        achievementsByID[achievement.id] = achievement
    }
}

/// In-memory clinical traceability repository.
actor InMemoryClinicalContentRepository: ClinicalContentRepository {
    private var referencesByCourseID: [String: [SourceReference]]

    init(referencesByCourseID: [String: [SourceReference]] = [:]) {
        self.referencesByCourseID = referencesByCourseID
    }

    func sourceReferences(courseID: String) -> [SourceReference] {
        referencesByCourseID[courseID, default: []]
    }

    func saveSourceReferences(_ references: [SourceReference], courseID: String) {
        referencesByCourseID[courseID] = references
    }
}

/// Deterministic no-network synchronization boundary for previews and tests.
actor InMemorySyncService: SyncService {
    private var queuedEvents: [QueuedSyncEvent] = []

    func enqueue(_ event: QueuedSyncEvent) {
        queuedEvents.removeAll { $0.id == event.id }
        queuedEvents.append(event)
    }

    func pendingEvents() -> [QueuedSyncEvent] {
        queuedEvents.sorted { $0.queuedAt < $1.queuedAt }
    }

    func synchronize() -> SyncReport {
        let uploadedCount = queuedEvents.count
        queuedEvents.removeAll()
        return SyncReport(
            completedAt: .now,
            uploadedRecordCount: uploadedCount,
            downloadedRecordCount: 0
        )
    }
}

/// In-memory append-only audit log.
actor InMemoryAuditLogService: AuditLogService {
    private var storedEvents: [AuditEvent]

    init(events: [AuditEvent] = []) {
        storedEvents = events
    }

    func events() -> [AuditEvent] {
        storedEvents.sorted { $0.timestamp < $1.timestamp }
    }

    func record(_ event: AuditEvent) {
        let previousHash = storedEvents.last?.entryHash ?? ""
        storedEvents.append(
            AuditEvent(
                id: event.id,
                actorID: event.actorID,
                category: event.category,
                action: event.action,
                timestamp: event.timestamp,
                metadata: event.metadata,
                previousHash: previousHash,
                entryHash: event.entryHash
            )
        )
    }

    func verifyIntegrity() -> Bool {
        for (index, event) in storedEvents.enumerated() {
            let expectedPrevious = index == 0 ? "" : storedEvents[index - 1].entryHash
            guard event.previousHash == expectedPrevious else { return false }
        }
        return true
    }
}

/// Test double that reveals samples only while a verified external sensor is connected.
actor InMemoryCPRSensorProvider: CPRSensorProvider {
    private(set) var isVerifiedExternalSensorConnected: Bool
    private var measurement: CPRSensorMeasurement?

    init(
        isVerifiedExternalSensorConnected: Bool = false,
        measurement: CPRSensorMeasurement? = nil
    ) {
        self.isVerifiedExternalSensorConnected = isVerifiedExternalSensorConnected
        self.measurement = measurement
    }

    func latestMeasurement() -> CPRSensorMeasurement? {
        guard isVerifiedExternalSensorConnected else { return nil }
        return measurement
    }

    func updateConnection(isVerified: Bool, measurement: CPRSensorMeasurement? = nil) {
        isVerifiedExternalSensorConnected = isVerified
        self.measurement = isVerified ? measurement : nil
    }
}
