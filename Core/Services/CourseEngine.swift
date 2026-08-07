import Foundation

/// Learner and instructor state supplied when resolving which modules may be presented.
///
/// The content lifecycle is deliberately absent: `CourseEngine` reads the authoritative
/// `ContentVersionState` from its repository before evaluating every module.
struct ModulePresentationRequest: Sendable, Equatable {
    let courseID: String
    let contentVersion: String
    let completedModuleIDs: Set<String>
    let instructorApprovalGranted: Bool

    init(
        courseID: String,
        contentVersion: String,
        completedModuleIDs: Set<String> = [],
        instructorApprovalGranted: Bool = false
    ) {
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.completedModuleIDs = completedModuleIDs
        self.instructorApprovalGranted = instructorApprovalGranted
    }
}

/// Loads, structurally validates, versions, and exposes course content.
actor CourseEngine {
    private let courseRepository: any CourseRepository
    private let versionRepository: any ContentVersionRepository
    private let facts: ClinicalFactCatalogue
    private let structureValidator: CourseStructureValidator
    private let safetyValidator: ClinicalSafetyValidator
    private let moduleAccessEvaluator: ModuleAccessEvaluator

    init(
        courseRepository: any CourseRepository,
        versionRepository: any ContentVersionRepository,
        facts: ClinicalFactCatalogue,
        structureValidator: CourseStructureValidator = CourseStructureValidator(),
        safetyValidator: ClinicalSafetyValidator = ClinicalSafetyValidator(),
        moduleAccessEvaluator: ModuleAccessEvaluator = ModuleAccessEvaluator()
    ) {
        self.courseRepository = courseRepository
        self.versionRepository = versionRepository
        self.facts = facts
        self.structureValidator = structureValidator
        self.safetyValidator = safetyValidator
        self.moduleAccessEvaluator = moduleAccessEvaluator
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

    /// The sole `CourseEngine` module-listing API used by presentation features.
    ///
    /// Every module is evaluated against completion, instructor approval, and the
    /// repository-owned content lifecycle. Callers cannot bypass the lifecycle gate by
    /// supplying their own status or by retrieving an unfiltered `Course` from this actor.
    func presentableModules(for request: ModulePresentationRequest) async throws -> [Module] {
        guard let state = try await versionRepository.versionState(
            courseID: request.courseID,
            contentVersion: request.contentVersion
        ) else {
            throw ClinicalContentError.lifecycleNotFound(
                courseID: request.courseID,
                contentVersion: request.contentVersion
            )
        }
        guard let course = try await courseRepository.course(
            id: request.courseID,
            contentVersion: request.contentVersion
        ) else {
            throw ClinicalContentError.courseNotFound(
                courseID: request.courseID,
                contentVersion: request.contentVersion
            )
        }

        return course.modules
            .filter { module in
                moduleAccessEvaluator.evaluate(
                    module: module,
                    completedModuleIDs: request.completedModuleIDs,
                    instructorApprovalGranted: request.instructorApprovalGranted,
                    contentLifecycle: state.lifecycle
                ).isUnlocked
            }
            .sorted { lhs, rhs in
                if lhs.order == rhs.order { return lhs.id < rhs.id }
                return lhs.order < rhs.order
            }
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
