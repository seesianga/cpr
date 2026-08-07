import Foundation

/// Loads, structurally validates, versions, and exposes course content.
actor CourseEngine {
    private let courseRepository: any CourseRepository
    private let versionRepository: any ContentVersionRepository
    private let facts: ClinicalFactCatalogue
    private let structureValidator: CourseStructureValidator
    private let safetyValidator: ClinicalSafetyValidator

    init(
        courseRepository: any CourseRepository,
        versionRepository: any ContentVersionRepository,
        facts: ClinicalFactCatalogue,
        structureValidator: CourseStructureValidator = CourseStructureValidator(),
        safetyValidator: ClinicalSafetyValidator = ClinicalSafetyValidator()
    ) {
        self.courseRepository = courseRepository
        self.versionRepository = versionRepository
        self.facts = facts
        self.structureValidator = structureValidator
        self.safetyValidator = safetyValidator
    }

    /// Imports named JSON resources from `Resources/Courses` idempotently by version.
    func importBundledCourses(
        named resourceNames: [String],
        from bundle: Bundle = .main
    ) async throws -> CourseImportReport {
        var imported: [Course] = []
        for resourceName in resourceNames {
            let course = try CourseContentCodec.loadCourse(named: resourceName, from: bundle)
            try structureValidator.validate(course)
            try await courseRepository.save(course)
            imported.append(course)
        }
        return CourseImportReport(
            importedCourseIDs: Array(Set(imported.map(\.id))).sorted(),
            importedVersionCount: imported.count
        )
    }

    func course(id: String, contentVersion: String) async throws -> Course? {
        try await courseRepository.course(id: id, contentVersion: contentVersion)
    }

    func activeCourse(id: String) async throws -> Course? {
        let states = try await versionRepository.versionStates(courseID: id)
        let eligible = states
            .filter { $0.lifecycle == .published || $0.lifecycle == .clinicallyApproved }
            .sorted { lhs, rhs in
                if lhs.lifecycle == rhs.lifecycle { return lhs.updatedAt > rhs.updatedAt }
                return lhs.lifecycle == .published
            }
        guard let state = eligible.first else { return nil }
        return try await courseRepository.course(
            id: id,
            contentVersion: state.contentVersion
        )
    }

    func scoredContent(
        courseID: String,
        contentVersion: String
    ) async throws -> ScoredContentCatalogue {
        guard let state = try await versionRepository.versionState(
            courseID: courseID,
            contentVersion: contentVersion
        ) else {
            throw ClinicalContentError.lifecycleNotFound(
                courseID: courseID,
                contentVersion: contentVersion
            )
        }
        guard state.lifecycle.permitsScoredUse else {
            throw ClinicalContentError.invalidLifecycleTransition(
                from: state.lifecycle,
                to: .clinicallyApproved
            )
        }
        guard let course = try await courseRepository.course(
            id: courseID,
            contentVersion: contentVersion
        ) else {
            throw ClinicalContentError.courseNotFound(
                courseID: courseID,
                contentVersion: contentVersion
            )
        }

        let report = safetyValidator.validateScoredContent(in: course, facts: facts)
        guard report.permitsActivation else {
            throw ClinicalContentError.scoredContentBlocked(report.issues)
        }
        let assessmentIDs = Set(report.eligibleAssessmentIDs)
        let scenarioIDs = Set(report.eligibleScenarioIDs)
        return ScoredContentCatalogue(
            courseID: courseID,
            contentVersion: contentVersion,
            assessments: course.modules
                .flatMap(\.lessons)
                .flatMap(\.assessments)
                .filter { assessmentIDs.contains($0.id) },
            scenarios: course.modules
                .flatMap(\.lessons)
                .flatMap(\.scenarios)
                .filter { scenarioIDs.contains($0.id) },
            safetyReport: report
        )
    }
}
