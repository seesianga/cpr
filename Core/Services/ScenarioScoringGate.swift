import Foundation
import SwiftData

struct ScenarioScoringAuthorization: Sendable, Equatable {
    let courseID: String
    let scenarioID: String
    let contentVersion: String
}

enum ScenarioPracticeOnlyReason: String, Sendable, Equatable {
    case notVerified
    case contentUnavailable
    case lifecycleNotApproved
    case runtimeContentMismatch
    case clinicalReviewRequired
    case attemptContentMismatch

    var learnerExplanation: String {
        switch self {
        case .notVerified:
            "Scoring has not been verified for this session."
        case .contentUnavailable:
            "The authoritative course version could not be verified."
        case .lifecycleNotApproved:
            "This course version is not currently approved for scored use."
        case .runtimeContentMismatch:
            "The runtime scenario does not match the authoritative course content."
        case .clinicalReviewRequired:
            "One or more clinical references require review before this scenario can be scored."
        case .attemptContentMismatch:
            "The completed attempt does not match the verified scenario content version."
        }
    }
}

enum ScenarioScoringDecision: Sendable, Equatable {
    case scored(ScenarioScoringAuthorization)
    case practiceOnly(ScenarioPracticeOnlyReason)

    var permitsScoredPersistence: Bool {
        if case .scored = self { return true }
        return false
    }

    var contentVersion: String? {
        guard case let .scored(authorization) = self else { return nil }
        return authorization.contentVersion
    }

    var practiceOnlyExplanation: String? {
        guard case let .practiceOnly(reason) = self else { return nil }
        return reason.learnerExplanation
    }
}

/// Fail-closed runtime gate for integrated-scenario scoring.
///
/// `scenarios_v1.json` is the content executed by `ScenarioEngine`, while `course_v1.json`
/// is the content traversed by `ClinicalSafetyValidator`. This gate validates a course copy
/// containing the exact selected runtime definition and then requires byte-model parity with
/// the authoritative embedded definition. Neither content source can therefore bypass the
/// other by carrying different clinical references.
struct ScenarioScoringGate: Sendable {
    private let validator: ClinicalSafetyValidator

    init(validator: ClinicalSafetyValidator = ClinicalSafetyValidator()) {
        self.validator = validator
    }

    func authorizeLaunch(
        document: ScenarioDefinitionsDocument,
        course: Course,
        facts: ClinicalFactCatalogue,
        lifecycle: ContentLifecycle?,
        scenarioID: String
    ) -> ScenarioScoringDecision {
        guard document.courseID == course.id,
              document.contentVersion == course.version.contentVersion,
              let runtimeScenario = document.scenarios.first(where: { $0.id == scenarioID }),
              let embeddedScenario = course.modules
                .flatMap(\.lessons)
                .flatMap(\.scenarios)
                .first(where: { $0.id == scenarioID })
        else {
            return .practiceOnly(.runtimeContentMismatch)
        }

        guard let runtimeCourse = replacingScenario(
            scenarioID,
            with: runtimeScenario,
            in: course
        ) else {
            return .practiceOnly(.runtimeContentMismatch)
        }
        let report = validator.validateScoredContent(in: runtimeCourse, facts: facts)
        guard report.eligibleScenarioIDs.contains(scenarioID),
              !report.excludedScenarioIDs.contains(scenarioID)
        else {
            return .practiceOnly(.clinicalReviewRequired)
        }

        guard runtimeScenario == embeddedScenario else {
            return .practiceOnly(.runtimeContentMismatch)
        }
        guard let lifecycle, lifecycle.permitsScoredUse else {
            return .practiceOnly(.lifecycleNotApproved)
        }

        return .scored(
            ScenarioScoringAuthorization(
                courseID: document.courseID,
                scenarioID: scenarioID,
                contentVersion: document.contentVersion
            )
        )
    }

    /// The same decision used immediately before SwiftData writes. It additionally binds
    /// the authorization to the immutable session-start event and event-log-derived debrief.
    func authorizePersistence(
        document: ScenarioDefinitionsDocument,
        course: Course,
        facts: ClinicalFactCatalogue,
        lifecycle: ContentLifecycle?,
        debrief: ScenarioDebrief,
        eventLog: [IntegratedScenarioEventRecord]
    ) -> ScenarioScoringDecision {
        let launchDecision = authorizeLaunch(
            document: document,
            course: course,
            facts: facts,
            lifecycle: lifecycle,
            scenarioID: debrief.scenarioID
        )
        guard case let .scored(authorization) = launchDecision,
              authorization.contentVersion == debrief.scoreOutcome.contentVersion,
              let first = eventLog.first,
              first.scenarioID == debrief.scenarioID,
              case let .sessionStarted(scene, patternID, contentVersion, _) = first.event,
              scene == debrief.scene,
              patternID == debrief.selectedPatternID,
              contentVersion == authorization.contentVersion
        else {
            if case .practiceOnly = launchDecision { return launchDecision }
            return .practiceOnly(.attemptContentMismatch)
        }
        return launchDecision
    }

    /// Uses `ContentVersionService` for the authoritative current lifecycle. Any repository,
    /// decoding, or lifecycle failure remains usable only as unscored practice.
    @MainActor
    func authorizeBundledLaunch(
        document: ScenarioDefinitionsDocument,
        scenarioID: String,
        modelContainer: ModelContainer,
        bundle: Bundle = .main
    ) async -> ScenarioScoringDecision {
        do {
            let repository = SwiftDataRepositoryStore(modelContainer: modelContainer)
            let facts = try ClinicalFactCatalogue.loadBundled(from: bundle)
            let service = ContentVersionService(
                courses: repository,
                versions: repository,
                auditLog: repository,
                facts: facts
            )
            let lifecycle = try await service.status(
                courseID: document.courseID,
                contentVersion: document.contentVersion
            )
            guard let course = try await repository.course(
                id: document.courseID,
                contentVersion: document.contentVersion
            ) else {
                return .practiceOnly(.contentUnavailable)
            }
            return authorizeLaunch(
                document: document,
                course: course,
                facts: facts,
                lifecycle: lifecycle,
                scenarioID: scenarioID
            )
        } catch let error as ClinicalContentError {
            switch error {
            case .lifecycleNotFound, .invalidLifecycleTransition:
                return .practiceOnly(.lifecycleNotApproved)
            case .scoredContentBlocked:
                return .practiceOnly(.clinicalReviewRequired)
            case .factCatalogueNotFound, .duplicateFactID, .courseNotFound:
                return .practiceOnly(.contentUnavailable)
            }
        } catch {
            return .practiceOnly(.contentUnavailable)
        }
    }

    @MainActor
    func authorizeBundledPersistence(
        document: ScenarioDefinitionsDocument,
        debrief: ScenarioDebrief,
        eventLog: [IntegratedScenarioEventRecord],
        modelContainer: ModelContainer,
        bundle: Bundle = .main
    ) async -> ScenarioScoringDecision {
        do {
            let repository = SwiftDataRepositoryStore(modelContainer: modelContainer)
            let facts = try ClinicalFactCatalogue.loadBundled(from: bundle)
            let service = ContentVersionService(
                courses: repository,
                versions: repository,
                auditLog: repository,
                facts: facts
            )
            let lifecycle = try await service.status(
                courseID: document.courseID,
                contentVersion: document.contentVersion
            )
            guard let course = try await repository.course(
                id: document.courseID,
                contentVersion: document.contentVersion
            ) else {
                return .practiceOnly(.contentUnavailable)
            }
            return authorizePersistence(
                document: document,
                course: course,
                facts: facts,
                lifecycle: lifecycle,
                debrief: debrief,
                eventLog: eventLog
            )
        } catch let error as ClinicalContentError {
            switch error {
            case .lifecycleNotFound, .invalidLifecycleTransition:
                return .practiceOnly(.lifecycleNotApproved)
            case .scoredContentBlocked:
                return .practiceOnly(.clinicalReviewRequired)
            case .factCatalogueNotFound, .duplicateFactID, .courseNotFound:
                return .practiceOnly(.contentUnavailable)
            }
        } catch {
            return .practiceOnly(.contentUnavailable)
        }
    }

    /// A direct session-model call without repository context is deliberately unscored,
    /// but still validates the exact bundled runtime definition before engine construction.
    func authorizeBundledPracticeOnly(
        document: ScenarioDefinitionsDocument,
        scenarioID: String,
        bundle: Bundle = .main
    ) -> ScenarioScoringDecision {
        do {
            let course = try CourseContentCodec.loadCourse(named: "course_v1", from: bundle)
            let facts = try ClinicalFactCatalogue.loadBundled(from: bundle)
            let decision = authorizeLaunch(
                document: document,
                course: course,
                facts: facts,
                lifecycle: nil,
                scenarioID: scenarioID
            )
            if case .practiceOnly(.lifecycleNotApproved) = decision {
                return .practiceOnly(.notVerified)
            }
            return decision
        } catch {
            return .practiceOnly(.contentUnavailable)
        }
    }

    private func replacingScenario(
        _ scenarioID: String,
        with replacement: ScenarioDefinition,
        in course: Course
    ) -> Course? {
        var didReplace = false
        let modules = course.modules.map { module in
            let lessons = module.lessons.map { lesson in
                let scenarios = lesson.scenarios.map { scenario in
                    guard scenario.id == scenarioID else { return scenario }
                    didReplace = true
                    return replacement
                }
                return Lesson(
                    id: lesson.id,
                    title: lesson.title,
                    summary: lesson.summary,
                    order: lesson.order,
                    learningObjectives: lesson.learningObjectives,
                    contentBlocks: lesson.contentBlocks,
                    interactiveActivities: lesson.interactiveActivities,
                    scenarios: scenarios,
                    assessments: lesson.assessments,
                    sourceReferences: lesson.sourceReferences
                )
            }
            return Module(
                id: module.id,
                title: module.title,
                summary: module.summary,
                order: module.order,
                lessons: lessons,
                sourceReferences: module.sourceReferences,
                reviewStatus: module.reviewStatus,
                accessRequirements: module.accessRequirements
            )
        }
        guard didReplace else { return nil }
        return Course(
            id: course.id,
            title: course.title,
            summary: course.summary,
            version: course.version,
            modules: modules,
            instructorRequirement: course.instructorRequirement,
            completionRule: course.completionRule,
            sourceReferences: course.sourceReferences
        )
    }
}

struct ScenarioPersistenceMetadata: Sendable, Equatable {
    let courseID: String
    let contentVersion: String

    init(debrief: ScenarioDebrief) {
        courseID = "lifesaver-vision-cpr-aed-spatial-academy"
        contentVersion = debrief.scoreOutcome.contentVersion
    }
}
