import Foundation

struct QuestionResponse: Codable, Sendable, Equatable {
    let questionID: String
    let selectedChoiceIDs: [String]
}

enum ClinicalAssessmentEligibility: Sendable, Equatable {
    case eligible
    case excluded([ClinicalSafetyIssue])
}

struct AdminAssessmentConfiguration: Codable, Sendable, Equatable {
    let passThreshold: Double

    static let standard = AdminAssessmentConfiguration(passThreshold: 0.80)
}

struct QuestionReview: Codable, Identifiable, Sendable, Equatable {
    var id: String { questionID }
    let questionID: String
    let prompt: String
    let selectedChoiceIDs: [String]
    let correctChoiceIDs: [String]
    let isCorrect: Bool
    let explanation: String
    let sourceReferences: [SourceReference]
}

struct TheoryAssessmentOutcome: Codable, Sendable, Equatable {
    let attemptID: String
    let learnerID: String
    let assessmentID: String
    let courseID: String
    let contentVersion: String
    let score: Double
    let passed: Bool
    let passThreshold: Double
    let submittedAt: Date
    let reviews: [QuestionReview]

    var attemptSummary: AssessmentAttemptSummary {
        AssessmentAttemptSummary(
            id: attemptID,
            learnerID: learnerID,
            assessmentID: assessmentID,
            courseID: courseID,
            contentVersion: contentVersion,
            score: score,
            passed: passed,
            submittedAt: submittedAt
        )
    }
}

enum TheoryAssessmentError: Error, Sendable, Equatable {
    case clinicallyIneligible([ClinicalSafetyIssue])
    case noQuestions
    case invalidPassThreshold
    case duplicateResponse(String)
    case unknownChoice(questionID: String, choiceID: String)
    case invalidResponseCardinality(questionID: String)
    case invalidSessionTransition
}

enum QuizSessionPhase: Sendable, Equatable {
    case introduction
    case answering(Int)
    case review
    case submitted(TheoryAssessmentOutcome)
}
