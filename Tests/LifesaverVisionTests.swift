import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class LifesaverVisionTests: XCTestCase {
    func testSeedCourseJSONDecodesAndRoundTrips() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")

        XCTAssertEqual(course.id, "lifesaver-vision-cpr-aed-spatial-academy")
        XCTAssertEqual(course.title, "Lifesaver Vision: CPR + AED Spatial Academy")
        XCTAssertEqual(course.version.contentVersion, "1.0.0")
        XCTAssertEqual(course.modules.map(\.id), (0...10).map { "M\($0)" })
        XCTAssertEqual(course.modules.flatMap(\.lessons).count, 11)
        XCTAssertTrue(course.sourceReferences.allSatisfy { !$0.reviewStatus.isEmpty })
        XCTAssertEqual(try CourseContentCodec.roundTrip(course), course)
    }

    func testSourceReferenceFieldsRoundTrip() throws {
        let reviewDate = Date(timeIntervalSince1970: 1_700_000_000)
        let source = SourceReference(
            id: "source-test",
            document: "Clinically reviewed source",
            edition: "Test edition",
            section: "Test section",
            page: "42",
            reviewStatus: "reviewed",
            reviewer: "Test Reviewer",
            lastClinicalReviewDate: reviewDate,
            contentVersion: "1.2.3"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(SourceReference.self, from: encoder.encode(source))

        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.document, source.document)
        XCTAssertEqual(decoded.edition, source.edition)
        XCTAssertEqual(decoded.section, source.section)
        XCTAssertEqual(decoded.page, source.page)
        XCTAssertEqual(decoded.reviewStatus, source.reviewStatus)
        XCTAssertEqual(decoded.reviewer, source.reviewer)
        XCTAssertEqual(decoded.lastClinicalReviewDate, source.lastClinicalReviewDate)
        XCTAssertEqual(decoded.contentVersion, source.contentVersion)
    }

    func testInMemoryCourseRepositorySavesAndFetchesCourse() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let repository = InMemoryCourseRepository()

        await repository.save(course)

        let fetched = await repository.course(id: course.id)
        let allCourses = await repository.allCourses()
        XCTAssertEqual(fetched, course)
        XCTAssertEqual(allCourses, [course])
    }

    func testInMemoryProgressRepositorySavesAndFetchesProgress() async throws {
        let repository = InMemoryProgressRepository()
        let progress = LearnerProgress(
            learnerID: "learner-1",
            courseID: "lifesaver-foundations",
            contentVersion: "1.0.0",
            completedLessonIDs: ["lesson-clinical-review-placeholder"],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        await repository.save(progress)

        let fetched = await repository.progress(
            learnerID: progress.learnerID,
            courseID: progress.courseID
        )
        XCTAssertEqual(fetched, progress)
    }

    func testUnverifiedSensorNeverRevealsMeasurement() async throws {
        let provider = InMemoryCPRSensorProvider(
            isVerifiedExternalSensorConnected: false,
            measurement: CPRSensorMeasurement(
                providerIdentifier: "test-sensor",
                capturedAt: .now,
                compressionDepthMetres: nil,
                forceNewtons: nil
            )
        )

        let measurement = await provider.latestMeasurement()

        XCTAssertNil(measurement)
    }
}
