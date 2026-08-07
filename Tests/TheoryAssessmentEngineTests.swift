import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class TheoryAssessmentEngineTests: XCTestCase {
    private let engine = TheoryAssessmentEngine()

    func testAllFourQuestionTypesAreGradedAccordingToTheirAnswerSemantics() throws {
        let assessment = makeAssessment()
        let responses = [
            QuestionResponse(questionID: "single", selectedChoiceIDs: ["single-correct"]),
            QuestionResponse(questionID: "multiple", selectedChoiceIDs: ["multi-b", "multi-a"]),
            QuestionResponse(questionID: "ordering", selectedChoiceIDs: ["order-b", "order-a", "order-c"]),
            QuestionResponse(questionID: "hotspot", selectedChoiceIDs: ["hotspot-correct"])
        ]

        let outcome = try evaluate(assessment: assessment, responses: responses)

        XCTAssertEqual(outcome.score, 1, accuracy: 0.000_001)
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.reviews.count, 4)
        XCTAssertTrue(outcome.reviews.allSatisfy(\.isCorrect))
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: zip(assessment.questions.map(\.id), outcome.reviews.map(\.isCorrect))),
            ["single": true, "multiple": true, "ordering": true, "hotspot": true]
        )
    }

    func testScoreExactlyAtConfiguredThresholdPasses() throws {
        let assessment = makeAssessment()
        let responses = [
            QuestionResponse(questionID: "single", selectedChoiceIDs: ["single-correct"]),
            QuestionResponse(questionID: "multiple", selectedChoiceIDs: ["multi-a", "multi-b"]),
            QuestionResponse(questionID: "ordering", selectedChoiceIDs: ["order-b", "order-a", "order-c"]),
            QuestionResponse(questionID: "hotspot", selectedChoiceIDs: ["hotspot-wrong"])
        ]

        let outcome = try evaluate(
            assessment: assessment,
            responses: responses,
            configuration: AdminAssessmentConfiguration(passThreshold: 0.75)
        )

        XCTAssertEqual(outcome.score, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(outcome.passThreshold, 0.75, accuracy: 0.000_001)
        XCTAssertTrue(outcome.passed)
    }

    func testUnscoredQuestionResponsesDoNotChangeTheScore() throws {
        let reference = sourceReference()
        let scoredQuestion = Question(
            id: "scored",
            prompt: "Scored prompt",
            choices: [
                QuestionChoice(id: "scored-correct", text: "Correct"),
                QuestionChoice(id: "scored-wrong", text: "Incorrect")
            ],
            correctChoiceIDs: ["scored-correct"],
            explanation: "Scored explanation",
            sourceReferences: [reference]
        )
        let awarenessQuestion = Question(
            id: "awareness",
            prompt: "Awareness-only prompt",
            choices: [
                QuestionChoice(id: "awareness-correct", text: "Correct"),
                QuestionChoice(id: "awareness-wrong", text: "Incorrect")
            ],
            correctChoiceIDs: ["awareness-correct"],
            explanation: "Awareness explanation",
            sourceReferences: [reference],
            isScored: false
        )
        let assessment = Assessment(
            id: "mixed-assessment",
            title: "Mixed scored and awareness content",
            passingScore: 1,
            questions: [scoredQuestion, awarenessQuestion],
            sourceReferences: [reference]
        )

        let awarenessCorrect = try evaluate(
            assessment: assessment,
            responses: [
                QuestionResponse(questionID: "scored", selectedChoiceIDs: ["scored-correct"]),
                QuestionResponse(questionID: "awareness", selectedChoiceIDs: ["awareness-correct"])
            ]
        )
        let awarenessIncorrect = try evaluate(
            assessment: assessment,
            responses: [
                QuestionResponse(questionID: "scored", selectedChoiceIDs: ["scored-correct"]),
                QuestionResponse(questionID: "awareness", selectedChoiceIDs: ["awareness-wrong"])
            ]
        )

        XCTAssertEqual(awarenessCorrect.score, 1, accuracy: 0.000_001)
        XCTAssertEqual(awarenessIncorrect.score, awarenessCorrect.score, accuracy: 0.000_001)
        XCTAssertTrue(awarenessCorrect.passed)
        XCTAssertTrue(awarenessIncorrect.passed)
        XCTAssertNotEqual(
            awarenessCorrect.reviews.first { $0.questionID == "awareness" }?.isCorrect,
            awarenessIncorrect.reviews.first { $0.questionID == "awareness" }?.isCorrect
        )
    }

    func testClinicallyExcludedAssessmentFailsClosedEvenWhenEveryAnswerIsCorrect() {
        let issue = ClinicalSafetyIssue(
            id: "assessment-1#requires-review",
            scoredItemID: "assessment-1",
            factID: "fact.requires.review",
            reason: .requiresSMEReview
        )
        let responses = makeAssessment().questions.map {
            QuestionResponse(questionID: $0.id, selectedChoiceIDs: $0.correctChoiceIDs)
        }

        XCTAssertThrowsError(
            try evaluate(
                assessment: makeAssessment(),
                responses: responses,
                clinicalEligibility: .excluded([issue])
            )
        ) { error in
            XCTAssertEqual(error as? TheoryAssessmentError, .clinicallyIneligible([issue]))
        }
    }

    func testQuestionReviewRetainsTraceableSourceReferencesAndContentVersion() throws {
        let assessment = makeAssessment()
        let outcome = try evaluate(
            assessment: assessment,
            responses: [
                QuestionResponse(questionID: "single", selectedChoiceIDs: ["single-correct"])
            ]
        )
        let review = try XCTUnwrap(outcome.reviews.first(where: { $0.questionID == "single" }))

        XCTAssertEqual(review.sourceReferences, assessment.questions[0].sourceReferences)
        XCTAssertEqual(review.sourceReferences.first?.clinicalFactID, "fact.test.source-checked")
        XCTAssertEqual(review.sourceReferences.first?.contentVersion, "1.0.0")
        XCTAssertEqual(outcome.contentVersion, "1.0.0")
    }

    func testQuizSessionRequiresExplicitReviewBeforeExplicitSubmission() throws {
        let assessment = Assessment(
            id: "session-assessment",
            title: "Explicit session flow",
            passingScore: 1,
            questions: [makeAssessment().questions[0]],
            sourceReferences: [sourceReference()]
        )
        var session = QuizSession(assessment: assessment)

        XCTAssertEqual(session.phase, .introduction)
        XCTAssertThrowsError(
            try session.submit(
                using: engine,
                configuration: .standard,
                clinicalEligibility: .eligible,
                learnerID: "learner-1",
                courseID: "course-1",
                contentVersion: "1.0.0"
            )
        ) { error in
            XCTAssertEqual(error as? TheoryAssessmentError, .invalidSessionTransition)
        }

        try session.begin()
        XCTAssertEqual(session.phase, .answering(0))
        try session.select(choiceID: "single-correct", for: "single")
        XCTAssertThrowsError(
            try session.submit(
                using: engine,
                configuration: .standard,
                clinicalEligibility: .eligible,
                learnerID: "learner-1",
                courseID: "course-1",
                contentVersion: "1.0.0"
            )
        ) { error in
            XCTAssertEqual(error as? TheoryAssessmentError, .invalidSessionTransition)
        }

        try session.review()
        XCTAssertEqual(session.phase, .review)
        try session.submit(
            using: engine,
            configuration: .standard,
            clinicalEligibility: .eligible,
            learnerID: "learner-1",
            courseID: "course-1",
            contentVersion: "1.0.0",
            submittedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        guard case let .submitted(outcome) = session.phase else {
            return XCTFail("The session should submit only after entering review.")
        }
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.reviews.map(\.questionID), ["single"])
    }

    private func evaluate(
        assessment: Assessment,
        responses: [QuestionResponse],
        configuration: AdminAssessmentConfiguration = .standard,
        clinicalEligibility: ClinicalAssessmentEligibility = .eligible
    ) throws -> TheoryAssessmentOutcome {
        try engine.evaluate(
            assessment: assessment,
            responses: responses,
            configuration: configuration,
            clinicalEligibility: clinicalEligibility,
            attemptID: "attempt-1",
            learnerID: "learner-1",
            courseID: "course-1",
            contentVersion: "1.0.0",
            submittedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAssessment() -> Assessment {
        let reference = sourceReference()
        return Assessment(
            id: "assessment-1",
            title: "Assessment engine test",
            passingScore: 0.80,
            questions: [
                Question(
                    id: "single",
                    type: .singleChoice,
                    prompt: "Choose one.",
                    choices: [
                        QuestionChoice(id: "single-correct", text: "Correct"),
                        QuestionChoice(id: "single-wrong", text: "Incorrect")
                    ],
                    correctChoiceIDs: ["single-correct"],
                    explanation: "Single-choice explanation.",
                    sourceReferences: [reference]
                ),
                Question(
                    id: "multiple",
                    type: .multipleChoice,
                    prompt: "Choose every applicable option.",
                    choices: [
                        QuestionChoice(id: "multi-a", text: "First correct option"),
                        QuestionChoice(id: "multi-b", text: "Second correct option"),
                        QuestionChoice(id: "multi-wrong", text: "Incorrect option")
                    ],
                    correctChoiceIDs: ["multi-a", "multi-b"],
                    explanation: "Multiple-choice explanation.",
                    sourceReferences: [reference]
                ),
                Question(
                    id: "ordering",
                    type: .ordering,
                    prompt: "Put these placeholder steps in the configured order.",
                    choices: [
                        QuestionChoice(id: "order-a", text: "Placeholder A"),
                        QuestionChoice(id: "order-b", text: "Placeholder B"),
                        QuestionChoice(id: "order-c", text: "Placeholder C")
                    ],
                    correctChoiceIDs: ["order-b", "order-a", "order-c"],
                    explanation: "Ordering explanation.",
                    sourceReferences: [reference]
                ),
                Question(
                    id: "hotspot",
                    type: .hotspotLite,
                    prompt: "Choose the labelled region.",
                    choices: [
                        QuestionChoice(id: "hotspot-correct", text: "Labelled region A"),
                        QuestionChoice(id: "hotspot-wrong", text: "Labelled region B")
                    ],
                    correctChoiceIDs: ["hotspot-correct"],
                    explanation: "Hotspot-lite explanation.",
                    sourceReferences: [reference]
                )
            ],
            sourceReferences: [reference]
        )
    }

    private func sourceReference() -> SourceReference {
        SourceReference(
            id: "source-test-v1",
            document: "Test source",
            edition: "Test edition",
            section: "Test section",
            page: "1",
            reviewStatus: "source_checked",
            reviewer: "Test reviewer",
            lastClinicalReviewDate: Date(timeIntervalSince1970: 1_700_000_000),
            contentVersion: "1.0.0",
            clinicalFactID: "fact.test.source-checked"
        )
    }
}
