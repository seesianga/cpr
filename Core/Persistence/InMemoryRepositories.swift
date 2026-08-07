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
    private var coursesByID: [String: Course] = [:]

    init(courses: [Course] = []) {
        for course in courses {
            coursesByID[course.id] = course
        }
    }

    func allCourses() -> [Course] {
        coursesByID.values.sorted { $0.id < $1.id }
    }

    func course(id: String) -> Course? {
        coursesByID[id]
    }

    func save(_ course: Course) {
        coursesByID[course.id] = course
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
    private var cohortsByID: [String: Cohort] = [:]

    init(cohorts: [Cohort] = []) {
        for cohort in cohorts {
            cohortsByID[cohort.id] = cohort
        }
    }

    func allCohorts() -> [Cohort] {
        cohortsByID.values.sorted { $0.id < $1.id }
    }

    func cohort(id: String) -> Cohort? {
        cohortsByID[id]
    }

    func save(_ cohort: Cohort) {
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
    func synchronize() -> SyncReport {
        SyncReport(
            completedAt: .now,
            uploadedRecordCount: 0,
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
        storedEvents.append(event)
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
