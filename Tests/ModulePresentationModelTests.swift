import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class ModulePresentationModelTests: XCTestCase {
    private let learnerID = "learner-presentation-model"

    func testModelUsesAuthoritativeEngineResultAndSendsDerivedModuleIDs() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let courseRepository = InMemoryCourseRepository(courses: [course])
        try await courseRepository.setLifecycle(
            .clinicallyApproved,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )
        let completedLessonIDs = Set(["M0-L1", "M1-L1", "unknown-lesson"])
        let progressRepository = InMemoryProgressRepository(
            progress: [progress(for: course, completedLessonIDs: completedLessonIDs)]
        )
        let engine = RecordingModulePresentationEngine(
            modulesToReturn: course.modules.filter { $0.id == "M0" }
        )
        let model = ModulePresentationModel(
            engine: engine,
            courses: courseRepository,
            progress: progressRepository,
            versions: courseRepository
        )

        await model.load(learnerID: learnerID)

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.completedModuleIDs, Set(["M0", "M1"]))
        XCTAssertEqual(
            Set(model.modules.filter(\.isPresentable).map(\.id)),
            Set(["M0"]),
            "The presentation model must not unlock modules omitted by the engine"
        )
        XCTAssertEqual(
            model.modules.first(where: { $0.id == "M1" })?.lockReasons,
            [.unavailable]
        )

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.importedResourceNames, [["course_v1"]])
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertEqual(snapshot.requests.first?.courseID, course.id)
        XCTAssertEqual(snapshot.requests.first?.contentVersion, course.version.contentVersion)
        XCTAssertEqual(snapshot.requests.first?.completedModuleIDs, Set(["M0", "M1"]))
        XCTAssertEqual(snapshot.requests.first?.instructorApprovalGranted, false)
    }

    func testM9StaysLockedWhenDistinctInstructorApprovalIsNotRecorded() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let (repository, model) = try makeModel(
            course: course,
            completedLessonIDs: adultCoreLessonIDs(in: course)
        )
        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )

        await model.load(
            learnerID: learnerID,
            instructorApproval: .none
        )

        let m9 = try XCTUnwrap(model.modules.first { $0.id == "M9" })
        XCTAssertEqual(m9.module.title, "Child & Infant AED Awareness")
        XCTAssertFalse(m9.isPresentable)
        XCTAssertEqual(m9.lockReasons, [.instructorApprovalNotRecorded])
    }

    func testM9StaysLockedWhenLifecycleIsNotClinicallyApproved() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let (repository, model) = try makeModel(
            course: course,
            completedLessonIDs: adultCoreLessonIDs(in: course)
        )
        try await repository.setLifecycle(
            .clinicalReviewRequired,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )

        await model.load(
            learnerID: learnerID,
            instructorApproval: InstructorModuleApproval(approvedModuleIDs: ["M9"])
        )

        let m9 = try XCTUnwrap(model.modules.first { $0.id == "M9" })
        XCTAssertFalse(m9.isPresentable)
        XCTAssertEqual(m9.lockReasons, [.clinicalApprovalRequired])
    }

    func testM9BecomesPresentableOnlyWithPrerequisitesApprovalAndLifecycle() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let (repository, model) = try makeModel(
            course: course,
            completedLessonIDs: adultCoreLessonIDs(in: course)
        )
        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )

        await model.load(
            learnerID: learnerID,
            instructorApproval: InstructorModuleApproval(approvedModuleIDs: ["M9"])
        )

        let m9 = try XCTUnwrap(model.modules.first { $0.id == "M9" })
        XCTAssertTrue(m9.isPresentable)
        XCTAssertTrue(m9.lockReasons.isEmpty)
    }

    func testModuleCompletionRequiresEveryLessonAndMatchingContentVersion() throws {
        let original = try CourseContentCodec.loadCourse(named: "course_v1")
        let firstModule = try XCTUnwrap(original.modules.first)
        let extraLesson = Lesson(
            id: "M0-L2-test",
            title: "Second required lesson",
            summary: "Test-only completion boundary.",
            order: 2,
            learningObjectives: [],
            contentBlocks: [],
            interactiveActivities: [],
            scenarios: [],
            assessments: [],
            sourceReferences: []
        )
        let expandedFirstModule = Module(
            id: firstModule.id,
            title: firstModule.title,
            summary: firstModule.summary,
            order: firstModule.order,
            lessons: firstModule.lessons + [extraLesson],
            sourceReferences: firstModule.sourceReferences,
            reviewStatus: firstModule.reviewStatus,
            accessRequirements: firstModule.accessRequirements
        )
        let course = Course(
            id: original.id,
            title: original.title,
            summary: original.summary,
            version: original.version,
            modules: [expandedFirstModule] + original.modules.dropFirst(),
            instructorRequirement: original.instructorRequirement,
            completionRule: original.completionRule,
            sourceReferences: original.sourceReferences
        )
        let firstLessonID = try XCTUnwrap(firstModule.lessons.first?.id)
        let partial = progress(for: course, completedLessonIDs: [firstLessonID])
        let complete = progress(
            for: course,
            completedLessonIDs: [firstLessonID, extraLesson.id]
        )
        let stale = LearnerProgress(
            learnerID: learnerID,
            courseID: course.id,
            contentVersion: "stale-version",
            completedLessonIDs: [firstLessonID, extraLesson.id],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertFalse(
            ModulePresentationModel.completedModuleIDs(in: course, from: partial)
                .contains(firstModule.id)
        )
        XCTAssertTrue(
            ModulePresentationModel.completedModuleIDs(in: course, from: complete)
                .contains(firstModule.id)
        )
        XCTAssertTrue(
            ModulePresentationModel.completedModuleIDs(in: course, from: stale).isEmpty
        )
    }

    private func makeModel(
        course: Course,
        completedLessonIDs: Set<String>
    ) throws -> (InMemoryCourseRepository, ModulePresentationModel) {
        let courseRepository = InMemoryCourseRepository(courses: [course])
        let progressRepository = InMemoryProgressRepository(
            progress: [progress(for: course, completedLessonIDs: completedLessonIDs)]
        )
        let engine = CourseEngine(
            courseRepository: courseRepository,
            versionRepository: courseRepository,
            facts: try ClinicalFactCatalogue.loadBundled()
        )
        let model = ModulePresentationModel(
            engine: engine,
            courses: courseRepository,
            progress: progressRepository,
            versions: courseRepository
        )
        return (courseRepository, model)
    }

    private func progress(
        for course: Course,
        completedLessonIDs: Set<String>
    ) -> LearnerProgress {
        LearnerProgress(
            learnerID: learnerID,
            courseID: course.id,
            contentVersion: course.version.contentVersion,
            completedLessonIDs: completedLessonIDs,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func adultCoreLessonIDs(in course: Course) -> Set<String> {
        let adultCoreIDs = Set((0...8).map { "M\($0)" })
        return Set(
            course.modules
                .filter { adultCoreIDs.contains($0.id) }
                .flatMap(\.lessons)
                .map(\.id)
        )
    }
}

private actor RecordingModulePresentationEngine: CourseModulePresentationServing {
    struct Snapshot: Sendable {
        let importedResourceNames: [[String]]
        let requests: [ModulePresentationRequest]
    }

    private let modulesToReturn: [Module]
    private var importedResourceNames: [[String]] = []
    private var requests: [ModulePresentationRequest] = []

    init(modulesToReturn: [Module]) {
        self.modulesToReturn = modulesToReturn
    }

    func importBundledCourses(
        named resourceNames: [String],
        from bundle: Bundle
    ) -> CourseImportReport {
        importedResourceNames.append(resourceNames)
        return CourseImportReport(
            importedCourseIDs: ["lifesaver-vision-cpr-aed-spatial-academy"],
            importedVersionCount: 1
        )
    }

    func presentableModules(for request: ModulePresentationRequest) -> [Module] {
        requests.append(request)
        return modulesToReturn
    }

    func snapshot() -> Snapshot {
        Snapshot(
            importedResourceNames: importedResourceNames,
            requests: requests
        )
    }
}
