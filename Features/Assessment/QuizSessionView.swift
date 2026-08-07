import Observation
import SwiftUI

@MainActor
@Observable
final class QuizSessionViewModel {
    private(set) var session: QuizSession
    private(set) var errorMessage: String?
    let configuration: AdminAssessmentConfiguration
    let clinicalEligibility: ClinicalAssessmentEligibility
    let learnerID: String
    let courseID: String
    let contentVersion: String

    init(
        assessment: Assessment,
        configuration: AdminAssessmentConfiguration,
        clinicalEligibility: ClinicalAssessmentEligibility,
        learnerID: String,
        courseID: String,
        contentVersion: String
    ) {
        session = QuizSession(assessment: assessment)
        self.configuration = configuration
        self.clinicalEligibility = clinicalEligibility
        self.learnerID = learnerID
        self.courseID = courseID
        self.contentVersion = contentVersion
    }

    var currentQuestion: Question? {
        guard case let .answering(index) = session.phase,
              session.assessment.questions.indices.contains(index)
        else { return nil }
        return session.assessment.questions[index]
    }

    var currentQuestionIndex: Int? {
        guard case let .answering(index) = session.phase else { return nil }
        return index
    }

    func begin() { perform { try session.begin() } }

    func select(_ choiceID: String, questionID: String) {
        perform { try session.select(choiceID: choiceID, for: questionID) }
    }

    func isSelected(_ choiceID: String, questionID: String) -> Bool {
        session.responsesByQuestionID[questionID]?.selectedChoiceIDs.contains(choiceID) == true
    }

    func orderedChoices(for question: Question) -> [QuestionChoice] {
        let order = session.responsesByQuestionID[question.id]?.selectedChoiceIDs
            ?? question.choices.map(\.id)
        let byID = Dictionary(uniqueKeysWithValues: question.choices.map { ($0.id, $0) })
        return order.compactMap { byID[$0] }
    }

    func move(_ choiceID: String, questionID: String, offset: Int) {
        perform {
            try session.moveChoice(
                questionID: questionID,
                choiceID: choiceID,
                offset: offset
            )
        }
    }

    func previous() {
        guard let index = currentQuestionIndex, index > 0 else { return }
        perform { try session.showQuestion(at: index - 1) }
    }

    func next() {
        guard let index = currentQuestionIndex else { return }
        if session.assessment.questions.indices.contains(index + 1) {
            perform { try session.showQuestion(at: index + 1) }
        } else {
            review()
        }
    }

    func review() { perform { try session.review() } }

    func returnToQuestion(_ index: Int) {
        perform { try session.showQuestion(at: index) }
    }

    func submit() {
        perform {
            try session.submit(
                using: TheoryAssessmentEngine(),
                configuration: configuration,
                clinicalEligibility: clinicalEligibility,
                learnerID: learnerID,
                courseID: courseID,
                contentVersion: contentVersion
            )
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = "This assessment action could not be completed."
        }
    }
}

struct QuizSessionView: View {
    let model: QuizSessionViewModel

    var body: some View {
        @Bindable var model = model

        Group {
            switch model.session.phase {
            case .introduction:
                VStack(spacing: 20) {
                    Text(model.session.assessment.title)
                        .font(.largeTitle.bold())
                    Text("This knowledge check is untimed. You can move backwards and forwards before submitting.")
                        .foregroundStyle(.secondary)
                    Button("Begin Knowledge Check", systemImage: "play.fill") {
                        model.begin()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .answering:
                questionContent
            case .review:
                submissionReview
            case let .submitted(outcome):
                AssessmentReviewView(outcome: outcome, assessment: model.session.assessment)
            }
        }
        .padding(32)
        .glassBackgroundEffect()
        .overlay(alignment: .bottom) {
            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .padding()
                    .accessibilityLabel("Assessment error: \(error)")
            }
        }
    }

    @ViewBuilder
    private var questionContent: some View {
        if let question = model.currentQuestion,
           let questionIndex = model.currentQuestionIndex {
            VStack(alignment: .leading, spacing: 20) {
                Text("Question \(questionIndex + 1) of \(model.session.assessment.questions.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(question.prompt)
                    .font(.title2.bold())

                if question.type == .ordering {
                    ForEach(Array(model.orderedChoices(for: question).enumerated()), id: \.element.id) {
                        index,
                        choice in
                        HStack {
                            Text("\(index + 1). \(choice.text)")
                            Spacer()
                            Button("Move Up", systemImage: "arrow.up") {
                                model.move(choice.id, questionID: question.id, offset: -1)
                            }
                            .disabled(index == 0)
                            Button("Move Down", systemImage: "arrow.down") {
                                model.move(choice.id, questionID: question.id, offset: 1)
                            }
                            .disabled(index == question.choices.count - 1)
                        }
                        .padding()
                        .background(.thinMaterial, in: .rect(cornerRadius: 12))
                    }
                } else {
                    ForEach(question.choices) { choice in
                        Button {
                            model.select(choice.id, questionID: question.id)
                        } label: {
                            HStack {
                                Image(
                                    systemName: model.isSelected(choice.id, questionID: question.id)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                Text(choice.text)
                                Spacer()
                            }
                            .padding()
                        }
                        .buttonStyle(.plain)
                        .background(.thinMaterial, in: .rect(cornerRadius: 12))
                        .accessibilityValue(
                            model.isSelected(choice.id, questionID: question.id)
                                ? "Selected"
                                : "Not selected"
                        )
                    }
                }

                HStack {
                    Button("Previous", systemImage: "chevron.left") { model.previous() }
                        .disabled(questionIndex == 0)
                    Spacer()
                    Button(
                        questionIndex == model.session.assessment.questions.count - 1
                            ? "Review Answers"
                            : "Next",
                        systemImage: "chevron.right"
                    ) { model.next() }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var submissionReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Your Answers")
                .font(.largeTitle.bold())
            Text("Nothing is submitted until you choose Submit Knowledge Check.")
                .foregroundStyle(.secondary)
            ForEach(Array(model.session.assessment.questions.enumerated()), id: \.element.id) {
                index,
                question in
                Button("Question \(index + 1): \(question.prompt)") {
                    model.returnToQuestion(index)
                }
                .buttonStyle(.bordered)
            }
            Button("Submit Knowledge Check", systemImage: "checkmark.seal") {
                model.submit()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct AssessmentReviewView: View {
    let outcome: TheoryAssessmentOutcome
    let assessment: Assessment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(outcome.passed ? "Knowledge Check Passed" : "Review Recommended")
                    .font(.largeTitle.bold())
                Text(outcome.score, format: .percent.precision(.fractionLength(0)))
                    .font(.title)
                    .accessibilityLabel("Score \(Int(outcome.score * 100)) per cent")
                Text("Content version \(outcome.contentVersion)")
                    .foregroundStyle(.secondary)

                ForEach(outcome.reviews) { review in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            review.prompt,
                            systemImage: review.isCorrect ? "checkmark.circle.fill" : "arrow.clockwise.circle"
                        )
                        .font(.headline)
                        Text(review.explanation)
                        DisclosureGroup("Source references") {
                            ForEach(review.sourceReferences) { source in
                                Text("\(source.document), \(source.edition), \(source.section), page \(source.page)")
                                    .font(.footnote)
                            }
                        }
                    }
                    .padding()
                    .background(.thinMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
    }
}
