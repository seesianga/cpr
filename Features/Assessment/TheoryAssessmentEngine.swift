import Foundation

/// Deterministic, untimed grading for all supported theory-question types.
struct TheoryAssessmentEngine: Sendable {
    func evaluate(
        assessment: Assessment,
        responses: [QuestionResponse],
        configuration: AdminAssessmentConfiguration,
        clinicalEligibility: ClinicalAssessmentEligibility,
        attemptID: String = UUID().uuidString,
        learnerID: String,
        courseID: String,
        contentVersion: String,
        submittedAt: Date = .now
    ) throws -> TheoryAssessmentOutcome {
        if case let .excluded(issues) = clinicalEligibility {
            throw TheoryAssessmentError.clinicallyIneligible(issues)
        }
        guard !assessment.questions.isEmpty else {
            throw TheoryAssessmentError.noQuestions
        }
        guard configuration.passThreshold.isFinite,
              (0...1).contains(configuration.passThreshold)
        else { throw TheoryAssessmentError.invalidPassThreshold }

        var responsesByQuestionID: [String: QuestionResponse] = [:]
        for response in responses {
            guard responsesByQuestionID.updateValue(response, forKey: response.questionID) == nil else {
                throw TheoryAssessmentError.duplicateResponse(response.questionID)
            }
        }

        var reviews: [QuestionReview] = []
        for question in assessment.questions {
            let response = responsesByQuestionID[question.id]
                ?? QuestionResponse(questionID: question.id, selectedChoiceIDs: [])
            let choiceIDs = Set(question.choices.map(\.id))
            if let unknown = response.selectedChoiceIDs.first(where: { !choiceIDs.contains($0) }) {
                throw TheoryAssessmentError.unknownChoice(
                    questionID: question.id,
                    choiceID: unknown
                )
            }
            switch question.type {
            case .singleChoice, .hotspotLite:
                guard response.selectedChoiceIDs.count <= 1 else {
                    throw TheoryAssessmentError.invalidResponseCardinality(questionID: question.id)
                }
            case .multipleChoice:
                guard Set(response.selectedChoiceIDs).count == response.selectedChoiceIDs.count else {
                    throw TheoryAssessmentError.invalidResponseCardinality(questionID: question.id)
                }
            case .ordering:
                guard response.selectedChoiceIDs.isEmpty ||
                        (response.selectedChoiceIDs.count == question.choices.count &&
                         Set(response.selectedChoiceIDs).count == response.selectedChoiceIDs.count)
                else {
                    throw TheoryAssessmentError.invalidResponseCardinality(questionID: question.id)
                }
            }

            let isCorrect: Bool
            switch question.type {
            case .singleChoice, .hotspotLite, .ordering:
                isCorrect = response.selectedChoiceIDs == question.correctChoiceIDs
            case .multipleChoice:
                isCorrect = Set(response.selectedChoiceIDs) == Set(question.correctChoiceIDs)
            }
            reviews.append(
                QuestionReview(
                    questionID: question.id,
                    prompt: question.prompt,
                    selectedChoiceIDs: response.selectedChoiceIDs,
                    correctChoiceIDs: question.correctChoiceIDs,
                    isCorrect: isCorrect,
                    explanation: question.explanation,
                    sourceReferences: question.sourceReferences
                )
            )
        }

        let score = Double(reviews.filter(\.isCorrect).count) / Double(reviews.count)
        return TheoryAssessmentOutcome(
            attemptID: attemptID,
            learnerID: learnerID,
            assessmentID: assessment.id,
            courseID: courseID,
            contentVersion: contentVersion,
            score: score,
            passed: score >= configuration.passThreshold,
            passThreshold: configuration.passThreshold,
            submittedAt: submittedAt,
            reviews: reviews
        )
    }
}

/// Explicit quiz-session state machine with persistent controls and no timers.
struct QuizSession: Sendable, Equatable {
    let assessment: Assessment
    private(set) var phase: QuizSessionPhase = .introduction
    private(set) var responsesByQuestionID: [String: QuestionResponse] = [:]

    mutating func begin() throws {
        guard phase == .introduction, !assessment.questions.isEmpty else {
            throw TheoryAssessmentError.invalidSessionTransition
        }
        for question in assessment.questions where question.type == .ordering {
            responsesByQuestionID[question.id] = QuestionResponse(
                questionID: question.id,
                selectedChoiceIDs: question.choices.map(\.id)
            )
        }
        phase = .answering(0)
    }

    mutating func select(choiceID: String, for questionID: String) throws {
        guard let question = assessment.questions.first(where: { $0.id == questionID }),
              question.choices.contains(where: { $0.id == choiceID })
        else {
            throw TheoryAssessmentError.unknownChoice(
                questionID: questionID,
                choiceID: choiceID
            )
        }
        let current = responsesByQuestionID[questionID]?.selectedChoiceIDs ?? []
        let selected: [String]
        switch question.type {
        case .singleChoice, .hotspotLite:
            selected = [choiceID]
        case .multipleChoice:
            selected = current.contains(choiceID)
                ? current.filter { $0 != choiceID }
                : current + [choiceID]
        case .ordering:
            selected = current.isEmpty ? question.choices.map(\.id) : current
        }
        responsesByQuestionID[questionID] = QuestionResponse(
            questionID: questionID,
            selectedChoiceIDs: selected
        )
    }

    mutating func moveChoice(
        questionID: String,
        choiceID: String,
        offset: Int
    ) throws {
        guard let question = assessment.questions.first(where: { $0.id == questionID }),
              question.type == .ordering
        else { throw TheoryAssessmentError.invalidSessionTransition }
        var order = responsesByQuestionID[questionID]?.selectedChoiceIDs
            ?? question.choices.map(\.id)
        guard let currentIndex = order.firstIndex(of: choiceID) else {
            throw TheoryAssessmentError.unknownChoice(
                questionID: questionID,
                choiceID: choiceID
            )
        }
        let destination = max(0, min(order.count - 1, currentIndex + offset))
        order.swapAt(currentIndex, destination)
        responsesByQuestionID[questionID] = QuestionResponse(
            questionID: questionID,
            selectedChoiceIDs: order
        )
    }

    mutating func showQuestion(at index: Int) throws {
        guard assessment.questions.indices.contains(index),
              phase != .introduction,
              !isSubmitted
        else { throw TheoryAssessmentError.invalidSessionTransition }
        phase = .answering(index)
    }

    mutating func review() throws {
        guard case .answering = phase else {
            throw TheoryAssessmentError.invalidSessionTransition
        }
        phase = .review
    }

    mutating func submit(
        using engine: TheoryAssessmentEngine,
        configuration: AdminAssessmentConfiguration,
        clinicalEligibility: ClinicalAssessmentEligibility,
        learnerID: String,
        courseID: String,
        contentVersion: String,
        submittedAt: Date = .now
    ) throws {
        guard phase == .review else {
            throw TheoryAssessmentError.invalidSessionTransition
        }
        let outcome = try engine.evaluate(
            assessment: assessment,
            responses: Array(responsesByQuestionID.values),
            configuration: configuration,
            clinicalEligibility: clinicalEligibility,
            learnerID: learnerID,
            courseID: courseID,
            contentVersion: contentVersion,
            submittedAt: submittedAt
        )
        phase = .submitted(outcome)
    }

    private var isSubmitted: Bool {
        if case .submitted = phase { return true }
        return false
    }
}
