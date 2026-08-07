import Foundation
import Observation
import SwiftData

/// The narrow engine surface used by learner-facing module presentation.
///
/// `CourseEngine` remains the sole authority that can mark a module as presentable.
/// The protocol exists so tests can verify that presentation code does not bypass it.
protocol CourseModulePresentationServing: Sendable {
    func importBundledCourses(
        named resourceNames: [String],
        from bundle: Bundle
    ) async throws -> CourseImportReport

    func presentableModules(for request: ModulePresentationRequest) async throws -> [Module]
}

extension CourseEngine: CourseModulePresentationServing {}

/// Explicit module-level instructor approval evidence.
///
/// This is deliberately separate from practical competency sign-off and administrator
/// demonstration permissions. Until a dedicated approval workflow supplies evidence,
/// production presentation uses ``none`` and keeps instructor-gated modules locked.
struct InstructorModuleApproval: Sendable, Equatable {
    let approvedModuleIDs: Set<String>

    static let none = InstructorModuleApproval(approvedModuleIDs: [])

    func grantsEveryInstructorGatedModule(in course: Course) -> Bool {
        let gatedModuleIDs = Set(
            course.modules
                .filter(\.accessRequirements.requiresInstructorApproval)
                .map(\.id)
        )
        return !gatedModuleIDs.isEmpty && gatedModuleIDs.isSubset(of: approvedModuleIDs)
    }
}

enum ModulePresentationLockReason: Sendable, Equatable {
    case incompletePrerequisites([String])
    case instructorApprovalNotRecorded
    case clinicalApprovalRequired
    case unavailable

    var learnerMessage: String {
        switch self {
        case let .incompletePrerequisites(moduleIDs):
            return "Complete \(moduleIDs.joined(separator: ", ")) before opening this module."
        case .instructorApprovalNotRecorded:
            return "Separate instructor approval has not been recorded for this module."
        case .clinicalApprovalRequired:
            return "This course version has not completed the required clinical approval lifecycle."
        case .unavailable:
            return "This module is not available from the authoritative course access gate."
        }
    }
}

struct PresentedCourseModule: Identifiable, Sendable, Equatable {
    let module: Module
    let isPresentable: Bool
    let lockReasons: [ModulePresentationLockReason]

    var id: String { module.id }
}

enum ModulePresentationLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case failed(message: String)
}

/// Main-actor presentation state for the source-backed course catalogue.
///
/// The model imports the bundled immutable course through `CourseEngine`, reads it back
/// through the repository, derives completed modules from persisted lesson progress, and
/// then calls `CourseEngine.presentableModules(for:)`. It never promotes a module based on
/// its own copy of access logic; local evaluation is used only to explain an engine rejection.
@MainActor
@Observable
final class ModulePresentationModel {
    static let bundledCourseResourceName = "course_v1"

    private let engine: any CourseModulePresentationServing
    private let courses: any CourseRepository
    private let progress: any ProgressRepository
    private let versions: any ContentVersionRepository
    private let bundle: Bundle

    private(set) var state: ModulePresentationLoadState = .idle
    private(set) var courseTitle = ""
    private(set) var contentVersion = ""
    private(set) var completedModuleIDs: Set<String> = []
    private(set) var modules: [PresentedCourseModule] = []

    init(
        engine: any CourseModulePresentationServing,
        courses: any CourseRepository,
        progress: any ProgressRepository,
        versions: any ContentVersionRepository,
        bundle: Bundle = .main
    ) {
        self.engine = engine
        self.courses = courses
        self.progress = progress
        self.versions = versions
        self.bundle = bundle
    }

    static func production(
        modelContainer: ModelContainer,
        bundle: Bundle = .main
    ) throws -> ModulePresentationModel {
        let repository = SwiftDataRepositoryStore(modelContainer: modelContainer)
        let engine = CourseEngine(
            courseRepository: repository,
            versionRepository: repository,
            facts: try ClinicalFactCatalogue.loadBundled(from: bundle)
        )
        return ModulePresentationModel(
            engine: engine,
            courses: repository,
            progress: repository,
            versions: repository,
            bundle: bundle
        )
    }

    func load(
        learnerID: String,
        instructorApproval: InstructorModuleApproval = .none
    ) async {
        state = .loading

        do {
            let bundledCourse = try CourseContentCodec.loadCourse(
                named: Self.bundledCourseResourceName,
                from: bundle
            )
            _ = try await engine.importBundledCourses(
                named: [Self.bundledCourseResourceName],
                from: bundle
            )

            guard let course = try await courses.course(
                id: bundledCourse.id,
                contentVersion: bundledCourse.version.contentVersion
            ) else {
                throw ClinicalContentError.courseNotFound(
                    courseID: bundledCourse.id,
                    contentVersion: bundledCourse.version.contentVersion
                )
            }
            guard let lifecycle = try await versions.versionState(
                courseID: course.id,
                contentVersion: course.version.contentVersion
            ) else {
                throw ClinicalContentError.lifecycleNotFound(
                    courseID: course.id,
                    contentVersion: course.version.contentVersion
                )
            }

            let learnerProgress: LearnerProgress?
            if learnerID.isEmpty {
                learnerProgress = nil
            } else {
                learnerProgress = try await progress.progress(
                    learnerID: learnerID,
                    courseID: course.id
                )
            }
            let completedIDs = Self.completedModuleIDs(
                in: course,
                from: learnerProgress
            )
            let approvalGranted = instructorApproval.grantsEveryInstructorGatedModule(
                in: course
            )
            let request = ModulePresentationRequest(
                courseID: course.id,
                contentVersion: course.version.contentVersion,
                completedModuleIDs: completedIDs,
                instructorApprovalGranted: approvalGranted
            )
            let presentableModules = try await engine.presentableModules(for: request)
            let presentableIDs = Set(presentableModules.map(\.id))
            let evaluator = ModuleAccessEvaluator()

            courseTitle = course.title
            contentVersion = course.version.contentVersion
            completedModuleIDs = completedIDs
            modules = course.modules
                .sorted { lhs, rhs in
                    if lhs.order == rhs.order { return lhs.id < rhs.id }
                    return lhs.order < rhs.order
                }
                .map { module in
                    let isPresentable = presentableIDs.contains(module.id)
                    let decision = evaluator.evaluate(
                        module: module,
                        completedModuleIDs: completedIDs,
                        instructorApprovalGranted: approvalGranted,
                        contentLifecycle: lifecycle.lifecycle
                    )
                    return PresentedCourseModule(
                        module: module,
                        isPresentable: isPresentable,
                        lockReasons: isPresentable ? [] : Self.lockReasons(from: decision)
                    )
                }
            state = .loaded
        } catch {
            courseTitle = ""
            contentVersion = ""
            completedModuleIDs = []
            modules = []
            state = .failed(
                message: "The source-backed course catalogue could not be prepared. Please try again."
            )
        }
    }

    /// A module is complete only when progress belongs to the same immutable content
    /// version and contains every lesson in that module. Unknown lesson IDs are ignored.
    static func completedModuleIDs(
        in course: Course,
        from progress: LearnerProgress?
    ) -> Set<String> {
        guard let progress,
              progress.courseID == course.id,
              progress.contentVersion == course.version.contentVersion
        else { return [] }

        return Set(
            course.modules.compactMap { module in
                let requiredLessonIDs = Set(module.lessons.map(\.id))
                guard !requiredLessonIDs.isEmpty,
                      requiredLessonIDs.isSubset(of: progress.completedLessonIDs)
                else { return nil }
                return module.id
            }
        )
    }

    private static func lockReasons(
        from decision: ModuleAccessDecision
    ) -> [ModulePresentationLockReason] {
        var reasons: [ModulePresentationLockReason] = []
        if !decision.missingCompletedModuleIDs.isEmpty {
            reasons.append(.incompletePrerequisites(decision.missingCompletedModuleIDs))
        }
        if decision.isInstructorApprovalMissing {
            reasons.append(.instructorApprovalNotRecorded)
        }
        if decision.isClinicalApprovalMissing {
            reasons.append(.clinicalApprovalRequired)
        }
        if reasons.isEmpty {
            reasons.append(.unavailable)
        }
        return reasons
    }
}
