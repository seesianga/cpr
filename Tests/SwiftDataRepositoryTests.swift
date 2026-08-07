import Foundation
import SwiftData
import XCTest
@testable import LifesaverVision

@MainActor
final class SwiftDataRepositoryTests: XCTestCase {
    func testCourseRepositoryPreservesVersionsAndSupersedesPublishedVersion() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let repository = SwiftDataRepositoryStore(modelContainer: container)
        let versionOne = try CourseContentCodec.loadCourse(named: "course_v1")
        let versionTwo = course(versionOne, contentVersion: "2.0.0")

        try await repository.save(versionOne)
        try await repository.save(versionTwo)

        let storedVersions = try await repository.versions(courseID: versionOne.id)
        XCTAssertEqual(storedVersions.map(\.version.contentVersion), ["1.0.0", "2.0.0"])
        let fetchedVersionOne = try await repository.course(
            id: versionOne.id,
            contentVersion: "1.0.0"
        )
        let fetchedVersionTwo = try await repository.course(
            id: versionOne.id,
            contentVersion: "2.0.0"
        )
        XCTAssertEqual(fetchedVersionOne, versionOne)
        XCTAssertEqual(fetchedVersionTwo, versionTwo)

        try await repository.publishVersion(
            courseID: versionOne.id,
            contentVersion: versionOne.version.contentVersion
        )
        try await repository.publishVersion(
            courseID: versionTwo.id,
            contentVersion: versionTwo.version.contentVersion
        )

        let states = try await repository.versionStates(courseID: versionOne.id)
        let lifecycleByVersion = Dictionary(
            uniqueKeysWithValues: states.map { ($0.contentVersion, $0.lifecycle) }
        )
        XCTAssertEqual(lifecycleByVersion["1.0.0"], .superseded)
        XCTAssertEqual(lifecycleByVersion["2.0.0"], .published)
        let allCourses = try await repository.allCourses()
        XCTAssertEqual(allCourses.count, 2)
    }

    func testProgressRepositoryKeepsContentVersionsAndReturnsMostRecentProgress() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let repository = SwiftDataRepositoryStore(modelContainer: container)
        let first = LearnerProgress(
            learnerID: "learner-1",
            courseID: "course-1",
            contentVersion: "1.0.0",
            completedLessonIDs: ["lesson-a"],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let second = LearnerProgress(
            learnerID: "learner-1",
            courseID: "course-1",
            contentVersion: "2.0.0",
            completedLessonIDs: ["lesson-a", "lesson-b"],
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        try await repository.save(first)
        try await repository.save(second)

        let fetched = try await repository.progress(
            learnerID: "learner-1",
            courseID: "course-1"
        )
        XCTAssertEqual(fetched, second)

        let context = ModelContext(container)
        let records = try context.fetch(FetchDescriptor<ProgressRecord>())
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.contentVersion)), ["1.0.0", "2.0.0"])
    }

    func testAssessmentRepositoryRetainsAttemptContentVersionAndCriticalErrors() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let repository = SwiftDataRepositoryStore(modelContainer: container)
        let first = AssessmentAttemptSummary(
            id: "attempt-1",
            learnerID: "learner-1",
            assessmentID: "assessment-1",
            courseID: "course-1",
            contentVersion: "1.0.0",
            score: 0.75,
            passed: false,
            criticalErrorCodes: ["unsafe-clear-zone"],
            submittedAt: Date(timeIntervalSince1970: 100)
        )
        let second = AssessmentAttemptSummary(
            id: "attempt-2",
            learnerID: "learner-1",
            assessmentID: "assessment-1",
            courseID: "course-1",
            contentVersion: "2.0.0",
            score: 0.9,
            passed: true,
            submittedAt: Date(timeIntervalSince1970: 200)
        )

        try await repository.save(first)
        try await repository.save(second)

        let attempts = try await repository.attempts(
            learnerID: "learner-1",
            assessmentID: "assessment-1"
        )
        XCTAssertEqual(attempts, [first, second])
        XCTAssertEqual(attempts.first?.contentVersion, "1.0.0")
        XCTAssertEqual(attempts.first?.criticalErrorCodes, ["unsafe-clear-zone"])
    }

    func testCohortRepositoryUpdatesMembershipWithoutDiscardingEnrollmentHistory() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let repository = SwiftDataRepositoryStore(modelContainer: container)
        let original = CohortSummary(
            id: "cohort-1",
            name: "Saturday Practice",
            learnerIDs: ["learner-1", "learner-2"],
            instructorIDs: ["instructor-1"],
            assignedCourseIDs: ["course-1"]
        )

        try await repository.save(original)
        let fetchedOriginal = try await repository.cohort(id: original.id)
        XCTAssertEqual(fetchedOriginal, original)

        let updated = CohortSummary(
            id: original.id,
            name: "Saturday Practice",
            learnerIDs: ["learner-2", "learner-3"],
            instructorIDs: ["instructor-1", "instructor-2"],
            assignedCourseIDs: ["course-1", "course-2"]
        )
        try await repository.save(updated)

        let fetchedUpdated = try await repository.cohort(id: original.id)
        let allCohorts = try await repository.allCohorts()
        XCTAssertEqual(fetchedUpdated, updated)
        XCTAssertEqual(allCohorts, [updated])

        let context = ModelContext(container)
        let enrolments = try context.fetch(FetchDescriptor<Enrollment>())
        XCTAssertEqual(enrolments.count, 3)
        XCTAssertEqual(enrolments.filter(\.isActive).map(\.learnerID).sorted(), ["learner-2", "learner-3"])
        XCTAssertEqual(
            enrolments.first(where: { $0.learnerID == "learner-1" })?.isActive,
            false
        )
    }

    func testAchievementAndClinicalContentRepositoriesRoundTripDomainValues() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let repository = SwiftDataRepositoryStore(modelContainer: container)
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        try await repository.save(course)

        let achievement = AchievementRecord(
            id: "award-1",
            learnerID: "learner-1",
            achievementID: "rhythm-keeper",
            awardedAt: Date(timeIntervalSince1970: 300)
        )
        try await repository.save(achievement)
        let achievements = try await repository.achievements(learnerID: "learner-1")
        XCTAssertEqual(achievements, [achievement])

        let reference = SourceReference(
            id: "reviewed-source-1",
            document: "Current clinical guidance",
            edition: "Test edition",
            section: "Test section",
            page: "12",
            reviewStatus: ClinicalReviewStatus.clinicallyApproved.rawValue,
            reviewer: "Clinical Reviewer",
            lastClinicalReviewDate: Date(timeIntervalSince1970: 400),
            contentVersion: course.version.contentVersion,
            clinicalFactID: "fact-1"
        )
        try await repository.saveSourceReferences([reference], courseID: course.id)
        let references = try await repository.sourceReferences(courseID: course.id)
        XCTAssertEqual(references, [reference])
    }

    private func course(_ source: Course, contentVersion: String) -> Course {
        Course(
            id: source.id,
            title: source.title,
            summary: source.summary,
            version: CourseVersion(
                schemaVersion: source.version.schemaVersion,
                contentVersion: contentVersion,
                locale: source.version.locale,
                releasedAt: nil
            ),
            modules: source.modules,
            instructorRequirement: source.instructorRequirement,
            completionRule: source.completionRule,
            sourceReferences: source.sourceReferences
        )
    }
}
