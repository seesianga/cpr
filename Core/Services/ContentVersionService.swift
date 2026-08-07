import Foundation

/// Audited course lifecycle coordinator. Course and attempt payloads remain immutable.
actor ContentVersionService {
    private let courses: any CourseRepository
    private let versions: any ContentVersionRepository
    private let auditLog: any AuditLogService
    private let facts: ClinicalFactCatalogue
    private let safetyValidator: ClinicalSafetyValidator

    init(
        courses: any CourseRepository,
        versions: any ContentVersionRepository,
        auditLog: any AuditLogService,
        facts: ClinicalFactCatalogue,
        safetyValidator: ClinicalSafetyValidator = ClinicalSafetyValidator()
    ) {
        self.courses = courses
        self.versions = versions
        self.auditLog = auditLog
        self.facts = facts
        self.safetyValidator = safetyValidator
    }

    func status(courseID: String, contentVersion: String) async throws -> ContentLifecycle {
        guard let state = try await versions.versionState(
            courseID: courseID,
            contentVersion: contentVersion
        ) else {
            throw ClinicalContentError.lifecycleNotFound(
                courseID: courseID,
                contentVersion: contentVersion
            )
        }
        return state.lifecycle
    }

    func transition(
        courseID: String,
        contentVersion: String,
        to lifecycle: ContentLifecycle,
        actorID: String?
    ) async throws {
        let current = try await status(
            courseID: courseID,
            contentVersion: contentVersion
        )
        guard Self.allowedTransitions[current, default: []].contains(lifecycle) else {
            throw ClinicalContentError.invalidLifecycleTransition(from: current, to: lifecycle)
        }

        if lifecycle == .clinicallyApproved || lifecycle == .published {
            guard let course = try await courses.course(
                id: courseID,
                contentVersion: contentVersion
            ) else {
                throw ClinicalContentError.courseNotFound(
                    courseID: courseID,
                    contentVersion: contentVersion
                )
            }
            try safetyValidator.assertScoredActivationAllowed(in: course, facts: facts)
        }

        if lifecycle == .published {
            try await versions.publishVersion(
                courseID: courseID,
                contentVersion: contentVersion
            )
        } else {
            try await versions.setLifecycle(
                lifecycle,
                courseID: courseID,
                contentVersion: contentVersion
            )
        }

        try await auditLog.record(
            AuditEvent(
                id: UUID().uuidString,
                actorID: actorID,
                category: "course_content",
                action: "content_lifecycle_changed",
                timestamp: .now,
                metadata: [
                    "courseID": courseID,
                    "contentVersion": contentVersion,
                    "from": current.rawValue,
                    "to": lifecycle.rawValue
                ]
            )
        )
    }

    func publish(
        courseID: String,
        contentVersion: String,
        actorID: String?
    ) async throws {
        try await transition(
            courseID: courseID,
            contentVersion: contentVersion,
            to: .published,
            actorID: actorID
        )
    }

    private static let allowedTransitions: [ContentLifecycle: Set<ContentLifecycle>] = [
        .draft: [.sourceChecked, .clinicalReviewRequired, .retired],
        .sourceChecked: [.draft, .clinicalReviewRequired, .clinicallyApproved, .retired],
        .clinicalReviewRequired: [.sourceChecked, .clinicallyApproved, .retired],
        .clinicallyApproved: [.clinicalReviewRequired, .published, .retired],
        .published: [.superseded, .retired],
        .superseded: [.retired],
        .retired: []
    ]
}
