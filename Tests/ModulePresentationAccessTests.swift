import XCTest
@testable import LifesaverVision

@MainActor
final class ModulePresentationAccessTests: XCTestCase {
    private let courseID = "lifesaver-vision-cpr-aed-spatial-academy"
    private let contentVersion = "1.0.0"
    private let adultCoreModuleIDs = Set((0...8).map { "M\($0)" })

    func testM9RemainsLockedWhenAnyPrerequisiteIsIncomplete() async throws {
        let (repository, engine) = try makeSystem()
        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: courseID,
            contentVersion: contentVersion
        )

        var incompleteAdultCore = adultCoreModuleIDs
        incompleteAdultCore.remove("M8")
        let modules = try await engine.presentableModules(
            for: request(
                completedModuleIDs: incompleteAdultCore,
                instructorApprovalGranted: true
            )
        )

        XCTAssertFalse(modules.map(\.id).contains("M9"))
    }

    func testM9RemainsLockedWithoutInstructorApproval() async throws {
        let (repository, engine) = try makeSystem()
        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: courseID,
            contentVersion: contentVersion
        )

        let modules = try await engine.presentableModules(
            for: request(
                completedModuleIDs: adultCoreModuleIDs,
                instructorApprovalGranted: false
            )
        )

        XCTAssertFalse(modules.map(\.id).contains("M9"))
    }

    func testM9UsesAuthoritativeLifecycleAndUnlocksOnlyAfterClinicalApproval() async throws {
        let (repository, engine) = try makeSystem()
        let fullyQualifiedRequest = request(
            completedModuleIDs: adultCoreModuleIDs,
            instructorApprovalGranted: true
        )
        try await repository.setLifecycle(
            .clinicalReviewRequired,
            courseID: courseID,
            contentVersion: contentVersion
        )

        let awaitingApproval = try await engine.presentableModules(for: fullyQualifiedRequest)
        XCTAssertFalse(awaitingApproval.map(\.id).contains("M9"))

        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: courseID,
            contentVersion: contentVersion
        )
        let approved = try await engine.presentableModules(for: fullyQualifiedRequest)

        XCTAssertEqual(approved.map(\.id), (0...10).map { "M\($0)" })
        XCTAssertTrue(approved.map(\.id).contains("M9"))
    }

    private func makeSystem() throws -> (InMemoryCourseRepository, CourseEngine) {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let repository = InMemoryCourseRepository(courses: [course])
        let engine = CourseEngine(
            courseRepository: repository,
            versionRepository: repository,
            facts: try ClinicalFactCatalogue.loadBundled()
        )
        return (repository, engine)
    }

    private func request(
        completedModuleIDs: Set<String>,
        instructorApprovalGranted: Bool
    ) -> ModulePresentationRequest {
        ModulePresentationRequest(
            courseID: courseID,
            contentVersion: contentVersion,
            completedModuleIDs: completedModuleIDs,
            instructorApprovalGranted: instructorApprovalGranted
        )
    }
}
