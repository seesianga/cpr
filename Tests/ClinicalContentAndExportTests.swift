import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class ClinicalContentAndExportTests: XCTestCase {
    func testClinicalSafetyValidatorBlocksAuthoritativeRequiresSMEReviewFact() {
        let reference = makeReference(
            embeddedStatus: "source_checked",
            factID: "fact.flagged"
        )
        let course = makeCourse(reference: reference)
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.flagged", status: .requiresSMEReview)]
        )

        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: catalogue
        )

        XCTAssertFalse(report.permitsActivation)
        XCTAssertEqual(report.excludedAssessmentIDs, ["assessment-1"])
        XCTAssertTrue(report.eligibleAssessmentIDs.isEmpty)
        XCTAssertTrue(
            report.issues.contains {
                $0.factID == "fact.flagged" && $0.reason == .requiresSMEReview
            }
        )
    }

    func testClinicalSafetyValidatorBlocksUnknownFactReference() {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "source_checked",
                factID: "fact.not-in-catalogue"
            )
        )

        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: makeCatalogue(facts: [])
        )

        XCTAssertEqual(report.excludedAssessmentIDs, ["assessment-1"])
        XCTAssertTrue(
            report.issues.contains {
                $0.factID == "fact.not-in-catalogue" &&
                    $0.reason == .unknownFactReference
            }
        )
    }

    func testClinicalSafetyValidatorBlocksMissingFactReference() {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "source_checked",
                factID: nil
            )
        )

        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: makeCatalogue(facts: [])
        )

        XCTAssertFalse(report.permitsActivation)
        XCTAssertTrue(
            report.issues.contains {
                $0.factID == nil && $0.reason == .missingFactReference
            }
        )
    }

    func testClinicalSafetyValidatorBlocksContentVersionMismatch() {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "source_checked",
                contentVersion: "0.9.0",
                factID: "fact.safe"
            )
        )
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.safe", status: .sourceChecked)]
        )

        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: catalogue
        )

        XCTAssertFalse(report.permitsActivation)
        XCTAssertTrue(
            report.issues.contains {
                $0.factID == "fact.safe" && $0.reason == .contentVersionMismatch
            }
        )
    }

    func testClinicalSafetyValidatorBlocksUnknownEmbeddedReviewStatus() {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "pending_unrecognised_review",
                factID: "fact.safe"
            )
        )
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.safe", status: .sourceChecked)]
        )

        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: catalogue
        )

        XCTAssertFalse(report.permitsActivation)
        XCTAssertTrue(report.issues.contains { $0.reason == .unknownReviewStatus })
    }

    func testClinicalSafetyValidatorAllowsSourceCheckedFact() {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "source_checked",
                factID: "fact.safe"
            )
        )
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.safe", status: .sourceChecked)]
        )

        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: catalogue
        )

        XCTAssertTrue(report.permitsActivation)
        XCTAssertEqual(report.eligibleAssessmentIDs, ["assessment-1"])
        XCTAssertTrue(report.excludedAssessmentIDs.isEmpty)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testCourseEngineRejectsDraftAndAllowsClinicallyApprovedSafeContent() async throws {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "source_checked",
                factID: "fact.safe"
            )
        )
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.safe", status: .sourceChecked)]
        )
        let repository = InMemoryCourseRepository(courses: [course])
        let engine = CourseEngine(
            courseRepository: repository,
            versionRepository: repository,
            facts: catalogue
        )

        do {
            _ = try await engine.scoredContent(
                courseID: course.id,
                contentVersion: course.version.contentVersion
            )
            XCTFail("Draft content must not be exposed for scored use")
        } catch let error as ClinicalContentError {
            XCTAssertEqual(
                error,
                .invalidLifecycleTransition(from: .draft, to: .clinicallyApproved)
            )
        }

        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )
        let scored = try await engine.scoredContent(
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )

        XCTAssertEqual(scored.assessments.map(\.id), ["assessment-1"])
        XCTAssertEqual(scored.contentVersion, "1.0.0")
        XCTAssertTrue(scored.safetyReport.permitsActivation)
    }

    func testContentVersionServiceRefusesClinicalApprovalForFlaggedContent() async throws {
        let course = makeCourse(
            reference: makeReference(
                embeddedStatus: "source_checked",
                factID: "fact.flagged"
            )
        )
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.flagged", status: .requiresSMEReview)]
        )
        let repository = InMemoryCourseRepository(courses: [course])
        let auditLog = InMemoryAuditLogService()
        let service = ContentVersionService(
            courses: repository,
            versions: repository,
            auditLog: auditLog,
            facts: catalogue
        )
        try await service.transition(
            courseID: course.id,
            contentVersion: course.version.contentVersion,
            to: .sourceChecked,
            actorID: "reviewer-1"
        )

        do {
            try await service.transition(
                courseID: course.id,
                contentVersion: course.version.contentVersion,
                to: .clinicallyApproved,
                actorID: "reviewer-1"
            )
            XCTFail("Flagged content must not reach clinical approval")
        } catch let error as ClinicalContentError {
            guard case let .scoredContentBlocked(issues) = error else {
                return XCTFail("Expected scoredContentBlocked, received \(error)")
            }
            XCTAssertTrue(issues.contains { $0.reason == .requiresSMEReview })
        }

        let status = try await service.status(
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )
        XCTAssertEqual(status, .sourceChecked)
    }

    func testPublishingSafeNewVersionSupersedesPublishedOldVersion() async throws {
        let referenceV1 = makeReference(
            embeddedStatus: "source_checked",
            contentVersion: "1.0.0",
            factID: "fact.safe"
        )
        let referenceV2 = makeReference(
            embeddedStatus: "source_checked",
            contentVersion: "2.0.0",
            factID: "fact.safe"
        )
        let courseV1 = makeCourse(
            id: "course-lifecycle",
            contentVersion: "1.0.0",
            reference: referenceV1
        )
        let courseV2 = makeCourse(
            id: "course-lifecycle",
            contentVersion: "2.0.0",
            reference: referenceV2
        )
        let catalogue = makeCatalogue(
            facts: [makeFact(id: "fact.safe", status: .sourceChecked)]
        )
        let repository = InMemoryCourseRepository(courses: [courseV1, courseV2])
        let service = ContentVersionService(
            courses: repository,
            versions: repository,
            auditLog: InMemoryAuditLogService(),
            facts: catalogue
        )

        try await approveAndPublish(
            service,
            courseID: courseV1.id,
            contentVersion: "1.0.0"
        )
        try await approveAndPublish(
            service,
            courseID: courseV2.id,
            contentVersion: "2.0.0"
        )

        let versionOneStatus = try await service.status(
            courseID: courseV1.id,
            contentVersion: "1.0.0"
        )
        let versionTwoStatus = try await service.status(
            courseID: courseV2.id,
            contentVersion: "2.0.0"
        )
        let retainedVersionOne = await repository.course(
            id: courseV1.id,
            contentVersion: "1.0.0"
        )
        XCTAssertEqual(versionOneStatus, .superseded)
        XCTAssertEqual(versionTwoStatus, .published)
        XCTAssertNotNil(retainedVersionOne)
    }

    func testXAPIStatementIncludesActorVerbObjectResultAndVersionedContext() throws {
        let activityURL = try XCTUnwrap(
            URL(string: "https://lifesaver.vision/activities/aed-practice")
        )
        let registrationID = UUID(uuidString: "A5B927F8-4BCB-45EB-A045-ECBEEDC40C11")
        let eventID = UUID(uuidString: "4B6CCDF8-6964-4556-B56B-A5BFF85B9D92")
        let event = LearningEventRecord(
            id: try XCTUnwrap(eventID),
            actorAccountID: "learner-42",
            verb: .passed,
            activityID: activityURL,
            activityName: "AED practice assessment",
            result: LearningEventResult(
                scaledScore: 0.9,
                success: true,
                completion: true,
                durationISO8601: "PT4M30S"
            ),
            contentVersion: "2.1.0",
            registrationID: registrationID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let service = XAPIExportService()
        let statement = try service.statement(for: event)

        XCTAssertEqual(statement.actor.objectType, "Agent")
        XCTAssertEqual(statement.actor.account.homePage, XAPIExportService.accountHomePage)
        XCTAssertEqual(statement.actor.account.name, "learner-42")
        XCTAssertEqual(statement.verb.id, LearningVerb.passed.iri)
        XCTAssertEqual(statement.verb.display["en-SG"], "passed")
        XCTAssertEqual(statement.object.objectType, "Activity")
        XCTAssertEqual(statement.object.id, activityURL.absoluteString)
        XCTAssertEqual(
            statement.object.definition.name["en-SG"],
            "AED practice assessment"
        )
        XCTAssertEqual(statement.result?.score?.scaled, 0.9)
        XCTAssertEqual(statement.result?.success, true)
        XCTAssertEqual(statement.result?.completion, true)
        XCTAssertEqual(statement.result?.duration, "PT4M30S")
        XCTAssertEqual(statement.context.registration, registrationID)
        XCTAssertEqual(
            statement.context.extensions[XAPIExportService.contentVersionExtension],
            "2.1.0"
        )

        let verbIRI = try XCTUnwrap(URL(string: statement.verb.id))
        let contextIRI = try XCTUnwrap(
            URL(string: XAPIExportService.contentVersionExtension)
        )
        XCTAssertNotNil(verbIRI.scheme)
        XCTAssertEqual(contextIRI.scheme, "https")

        let encoded = try service.encodedStatement(for: event)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        let extensions = try XCTUnwrap(context["extensions"] as? [String: String])
        XCTAssertEqual(
            extensions[XAPIExportService.contentVersionExtension],
            "2.1.0"
        )
    }

    func testXAPIRejectsOutOfRangeScaledScore() throws {
        let activityURL = try XCTUnwrap(
            URL(string: "https://lifesaver.vision/activities/cpr-practice")
        )
        let event = LearningEventRecord(
            id: UUID(),
            actorAccountID: "learner-42",
            verb: .failed,
            activityID: activityURL,
            activityName: "CPR practice assessment",
            result: LearningEventResult(
                scaledScore: 1.01,
                success: false,
                completion: true,
                durationISO8601: nil
            ),
            contentVersion: "1.0.0",
            registrationID: nil,
            timestamp: .now
        )

        XCTAssertThrowsError(try XAPIExportService().statement(for: event)) { error in
            XCTAssertEqual(error as? XAPIExportError, .invalidScaledScore)
        }
    }

    private func approveAndPublish(
        _ service: ContentVersionService,
        courseID: String,
        contentVersion: String
    ) async throws {
        try await service.transition(
            courseID: courseID,
            contentVersion: contentVersion,
            to: .sourceChecked,
            actorID: "reviewer-1"
        )
        try await service.transition(
            courseID: courseID,
            contentVersion: contentVersion,
            to: .clinicallyApproved,
            actorID: "reviewer-1"
        )
        try await service.publish(
            courseID: courseID,
            contentVersion: contentVersion,
            actorID: "publisher-1"
        )
    }

    private func makeCatalogue(facts: [ClinicalFact]) -> ClinicalFactCatalogue {
        ClinicalFactCatalogue(
            document: ClinicalFactsDocument(
                version: "test-1",
                extractedAt: "2026-08-07",
                citationConvention: "Test citations",
                languageNote: "Test facts",
                facts: facts
            )
        )
    }

    private func makeFact(
        id: String,
        status: ClinicalReviewStatus
    ) -> ClinicalFact {
        ClinicalFact(
            id: id,
            statement: "Test-only clinical statement",
            values: [:],
            sources: [
                ClinicalFactSource(
                    doc: "test-source.pdf",
                    edition: "2026",
                    section: "Test section",
                    page: 1
                )
            ],
            reviewStatus: status,
            supersedes2018: false,
            notes: "Test fixture"
        )
    }

    private func makeReference(
        embeddedStatus: String,
        contentVersion: String = "1.0.0",
        factID: String?
    ) -> SourceReference {
        SourceReference(
            id: "reference-\(UUID().uuidString)",
            document: "test-source.pdf",
            edition: "2026",
            section: "Test section",
            page: "1",
            reviewStatus: embeddedStatus,
            reviewer: nil,
            lastClinicalReviewDate: nil,
            contentVersion: contentVersion,
            clinicalFactID: factID
        )
    }

    private func makeCourse(
        id: String = "course-1",
        contentVersion: String = "1.0.0",
        reference: SourceReference
    ) -> Course {
        let question = Question(
            id: "question-1",
            prompt: "Choose the source-checked test response.",
            choices: [
                QuestionChoice(id: "choice-a", text: "Response A"),
                QuestionChoice(id: "choice-b", text: "Response B")
            ],
            correctChoiceIDs: ["choice-a"],
            explanation: "Test explanation",
            sourceReferences: [reference]
        )
        let assessment = Assessment(
            id: "assessment-1",
            title: "Test assessment",
            passingScore: 0.8,
            questions: [question],
            sourceReferences: []
        )
        let lesson = Lesson(
            id: "lesson-1",
            title: "Test lesson",
            summary: "Test lesson summary",
            order: 1,
            learningObjectives: [],
            contentBlocks: [],
            interactiveActivities: [],
            scenarios: [],
            assessments: [assessment],
            sourceReferences: []
        )
        let module = Module(
            id: "module-1",
            title: "Test module",
            summary: "Test module summary",
            order: 1,
            lessons: [lesson],
            sourceReferences: []
        )
        return Course(
            id: id,
            title: "Test course",
            summary: "Test course summary",
            version: CourseVersion(
                schemaVersion: 1,
                contentVersion: contentVersion,
                locale: "en-SG",
                releasedAt: nil
            ),
            modules: [module],
            instructorRequirement: InstructorRequirement(
                isRequired: true,
                requirementDescription: "Instructor review required",
                recordLabel: "Internal completion record"
            ),
            completionRule: CompletionRule(
                requiredLessonIDs: [lesson.id],
                minimumAssessmentScore: 0.8,
                requiresInstructorSignOff: true
            ),
            sourceReferences: []
        )
    }
}
