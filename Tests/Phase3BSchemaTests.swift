import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class Phase3BSchemaTests: XCTestCase {
    func testPhase3BFieldsDefaultForLegacyPayloadsAndEncodeExplicitly() throws {
        let decoder = JSONDecoder()

        let block = try decoder.decode(
            ContentBlock.self,
            from: Data(
                #"{"id":"block-1","kind":"text","title":"Title","body":"Body","sourceReferences":[]}"#.utf8
            )
        )
        XCTAssertEqual(block.reviewStatus, .sourceChecked)

        let assessment = try decoder.decode(
            Assessment.self,
            from: Data(
                #"{"id":"assessment-1","title":"Check","passingScore":0.8,"questions":[],"sourceReferences":[]}"#.utf8
            )
        )
        XCTAssertTrue(assessment.isScored)

        let module = try decoder.decode(
            Module.self,
            from: Data(
                #"{"id":"M0","title":"Orientation","summary":"Summary","order":0,"lessons":[],"sourceReferences":[]}"#.utf8
            )
        )
        XCTAssertEqual(module.reviewStatus, .sourceChecked)
        XCTAssertEqual(module.accessRequirements, .open)

        let encoder = JSONEncoder()
        let encodedBlock = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(block)) as? [String: Any]
        )
        let encodedAssessment = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(assessment)) as? [String: Any]
        )
        let encodedModule = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(module)) as? [String: Any]
        )

        XCTAssertEqual(encodedBlock["reviewStatus"] as? String, "sourceChecked")
        XCTAssertEqual(encodedAssessment["isScored"] as? Bool, true)
        XCTAssertEqual(encodedModule["reviewStatus"] as? String, "sourceChecked")
        XCTAssertNotNil(encodedModule["accessRequirements"] as? [String: Any])
    }

    func testM9AccessRemainsLockedUntilEveryRequirementIsSatisfied() {
        let prerequisites = (0...8).map { "M\($0)" }
        let requirements = ModuleAccessRequirements(
            requiredCompletedModuleIDs: prerequisites,
            requiresInstructorApproval: true,
            requiresClinicallyApprovedContent: true
        )
        let pendingModule = Module(
            id: "M9",
            title: "Child and infant AED awareness",
            summary: "Awareness only",
            order: 9,
            lessons: [],
            sourceReferences: [],
            reviewStatus: .clinicalReviewRequired,
            accessRequirements: requirements
        )
        let evaluator = ModuleAccessEvaluator()

        let missingEverything = evaluator.evaluate(
            module: pendingModule,
            completedModuleIDs: [],
            instructorApprovalGranted: false,
            contentLifecycle: .clinicalReviewRequired
        )
        XCTAssertFalse(missingEverything.isUnlocked)
        XCTAssertEqual(missingEverything.missingCompletedModuleIDs, prerequisites)
        XCTAssertTrue(missingEverything.isInstructorApprovalMissing)
        XCTAssertTrue(missingEverything.isClinicalApprovalMissing)

        let awaitingClinicalReview = evaluator.evaluate(
            module: pendingModule,
            completedModuleIDs: Set(prerequisites),
            instructorApprovalGranted: true,
            contentLifecycle: .clinicalReviewRequired
        )
        XCTAssertFalse(awaitingClinicalReview.isUnlocked)
        XCTAssertTrue(awaitingClinicalReview.isClinicalApprovalMissing)

        let allRequirementsMet = evaluator.evaluate(
            module: pendingModule,
            completedModuleIDs: Set(prerequisites),
            instructorApprovalGranted: true,
            contentLifecycle: .clinicallyApproved
        )
        XCTAssertTrue(allRequirementsMet.isUnlocked)
    }

    func testAssessmentReferenceCannotMaskMissingQuestionReference() {
        let safeReference = sourceReference(factID: "fact.safe")
        let assessment = Assessment(
            id: "assessment-masked-question",
            title: "Traceability check",
            passingScore: 0.8,
            questions: [
                Question(
                    id: "question-without-reference",
                    prompt: "Choose the answer.",
                    choices: [
                        QuestionChoice(id: "correct", text: "Correct"),
                        QuestionChoice(id: "incorrect", text: "Incorrect")
                    ],
                    correctChoiceIDs: ["correct"],
                    explanation: "Explanation",
                    sourceReferences: []
                )
            ],
            sourceReferences: [safeReference]
        )
        let report = ClinicalSafetyValidator().validateScoredContent(
            in: course(assessments: [assessment]),
            facts: catalogue(facts: [fact(id: "fact.safe", status: .sourceChecked)])
        )

        XCTAssertFalse(report.permitsActivation)
        XCTAssertEqual(report.excludedAssessmentIDs, [assessment.id])
        XCTAssertTrue(
            report.issues.contains {
                $0.scoredItemID == "\(assessment.id)/question-without-reference" &&
                    $0.reason == .missingFactReference
            }
        )
    }

    func testUnscoredAssessmentIsOmittedWithoutBlockingScoredCatalogue() async throws {
        let safeReference = sourceReference(factID: "fact.safe")
        let scored = Assessment(
            id: "assessment-scored",
            title: "Scored knowledge check",
            passingScore: 0.8,
            questions: [question(id: "question-scored", reference: safeReference)],
            sourceReferences: []
        )
        let awarenessOnly = Assessment(
            id: "assessment-awareness",
            title: "Awareness only",
            passingScore: 0,
            questions: [question(id: "question-awareness", reference: nil)],
            sourceReferences: [],
            isScored: false
        )
        let course = course(assessments: [scored, awarenessOnly])
        let facts = catalogue(facts: [fact(id: "fact.safe", status: .sourceChecked)])
        let report = ClinicalSafetyValidator().validateScoredContent(in: course, facts: facts)

        XCTAssertTrue(report.permitsActivation)
        XCTAssertEqual(report.eligibleAssessmentIDs, [scored.id])
        XCTAssertEqual(report.excludedAssessmentIDs, [awarenessOnly.id])

        let repository = InMemoryCourseRepository(courses: [course])
        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )
        let engine = CourseEngine(
            courseRepository: repository,
            versionRepository: repository,
            facts: facts
        )
        let catalogue = try await engine.scoredContent(
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )

        XCTAssertEqual(catalogue.assessments.map(\.id), [scored.id])
    }

    func testExternalTheoryAndScenarioDocumentsRoundTrip() throws {
        let reference = sourceReference(factID: "fact.safe")
        let questionDocument = TheoryQuestionBankDocument(
            schemaVersion: 1,
            courseID: "course-1",
            contentVersion: "1.0.0",
            modules: [
                TheoryQuestionModule(
                    moduleID: "M9",
                    assessmentID: "assessment-m9-awareness",
                    title: "Awareness only",
                    passingScore: 0,
                    isScored: false,
                    questions: [question(id: "question-m9", reference: reference)],
                    sourceReferences: [reference]
                )
            ]
        )
        XCTAssertEqual(
            try TheoryQuestionBankCodec.decode(TheoryQuestionBankCodec.encode(questionDocument)),
            questionDocument
        )
        XCTAssertFalse(questionDocument.modules[0].assessment.isScored)

        let feedback = ScenarioFeedbackStatement(
            id: "feedback-1",
            statement: "Use the source-backed sequence.",
            sourceReferences: [reference]
        )
        let aedStates = (0..<11).map { index in
            AEDStateDefinition(
                id: "aed-state-\(index)",
                title: "AED state \(index)",
                stateDescription: "State-machine test fixture",
                values: [:],
                sourceReferences: [reference]
            )
        }
        let aedTransitions = (0..<10).map { index in
            AEDStateTransition(
                id: "aed-transition-\(index)",
                fromStateID: "aed-state-\(index)",
                toStateID: "aed-state-\(index + 1)",
                trigger: "advance",
                condition: nil,
                feedbackStatements: [feedback],
                sourceReferences: [reference]
            )
        }
        let scenarioDocument = ScenarioDefinitionsDocument(
            schemaVersion: 1,
            courseID: "course-1",
            contentVersion: "1.0.0",
            metadata: ["locale": .string("en-SG")],
            designProvenance: ["source": .string("Phase 3B test fixture")],
            aedStateMachine: AEDStateMachineDefinition(
                initialStateID: "aed-state-0",
                states: aedStates,
                transitions: aedTransitions,
                sourceReferences: [reference]
            ),
            shockPatterns: [
                ScenarioShockPattern(
                    id: "Shock-NoShock-NoShock",
                    analysisOutcomes: [.shock, .noShock, .noShock],
                    sourceReferences: [reference]
                )
            ],
            scenarios: [
                ScenarioDefinition(
                    id: "scenario-a",
                    title: "Home",
                    summary: "Integrated response practice",
                    initialState: ScenarioInitialState(
                        id: "initial",
                        values: ["bystanderAvailable": .boolean(true)],
                        sourceReferences: [reference]
                    ),
                    branchingNodes: [
                        ScenarioBranchNode(
                            id: "branch-bystander",
                            prompt: "A bystander is available.",
                            conditions: [
                                ScenarioBranchCondition(
                                    id: "condition-available",
                                    condition: "bystanderAvailable",
                                    values: ["equals": .boolean(true)],
                                    nextNodeID: "cpr",
                                    requiredActionIDs: ["action-call"],
                                    feedbackStatements: [feedback],
                                    sourceReferences: [reference]
                                )
                            ],
                            feedbackStatements: [feedback],
                            sourceReferences: [reference]
                        )
                    ],
                    criticalActions: [
                        ScenarioCriticalActionDefinition(
                            id: "action-call",
                            title: "Activate help",
                            actionDescription: "Activate the simulated emergency flow.",
                            isRequired: true,
                            scoringCategory: .recognitionAndActivation,
                            feedbackStatements: [feedback],
                            sourceReferences: [reference]
                        )
                    ],
                    criticalErrors: [
                        ScenarioCriticalErrorDefinition(
                            id: "error-unsafe-touch",
                            code: "unsafe_touch",
                            title: "Unsafe contact",
                            errorDescription: "Contact occurred during analysis.",
                            remediation: "Repeat the clear check.",
                            scoringCategory: .aedPreparationAndPlacement,
                            feedbackStatements: [feedback],
                            sourceReferences: [reference]
                        )
                    ],
                    randomisation: ScenarioRandomisationDefinition(
                        shockPatternIDs: ["Shock-NoShock-NoShock"],
                        clinicalRulesInvariant: true
                    ),
                    scoringCategoryMapping: [
                        ScenarioScoringCategoryMapping(
                            itemID: "action-call",
                            category: .recognitionAndActivation
                        )
                    ],
                    feedbackStatements: [feedback],
                    sourceReferences: [reference]
                )
            ]
        )
        XCTAssertEqual(
            try ScenarioDefinitionsCodec.decode(ScenarioDefinitionsCodec.encode(scenarioDocument)),
            scenarioDocument
        )
    }

    func testBundledTheoryQuestionBankDecodesAllModules() throws {
        let document = try TheoryQuestionBankCodec.load()

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.contentVersion, "1.0.0")
        XCTAssertEqual(
            Set(document.moduleQuestionSets.map(\.moduleID)),
            Set((0...10).map { "M\($0)" })
        )
    }

    private func question(id: String, reference: SourceReference?) -> Question {
        Question(
            id: id,
            prompt: "Choose the source-backed answer.",
            choices: [
                QuestionChoice(id: "\(id)-correct", text: "Correct"),
                QuestionChoice(id: "\(id)-incorrect", text: "Incorrect")
            ],
            correctChoiceIDs: ["\(id)-correct"],
            explanation: "Source-backed explanation.",
            sourceReferences: reference.map { [$0] } ?? []
        )
    }

    private func sourceReference(factID: String) -> SourceReference {
        SourceReference(
            id: "source-\(factID)",
            document: "test-source.pdf",
            edition: "2026",
            section: "Test section",
            page: "1",
            reviewStatus: "source_checked",
            reviewer: nil,
            lastClinicalReviewDate: nil,
            contentVersion: "1.0.0",
            clinicalFactID: factID
        )
    }

    private func fact(id: String, status: ClinicalReviewStatus) -> ClinicalFact {
        ClinicalFact(
            id: id,
            statement: "Test-only statement",
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

    private func catalogue(facts: [ClinicalFact]) -> ClinicalFactCatalogue {
        ClinicalFactCatalogue(
            document: ClinicalFactsDocument(
                version: "test-1",
                extractedAt: "2026-08-07",
                citationConvention: "Test",
                languageNote: "Test",
                facts: facts
            )
        )
    }

    private func course(assessments: [Assessment]) -> Course {
        let lesson = Lesson(
            id: "lesson-1",
            title: "Lesson",
            summary: "Summary",
            order: 1,
            learningObjectives: [],
            contentBlocks: [],
            interactiveActivities: [],
            scenarios: [],
            assessments: assessments,
            sourceReferences: []
        )
        return Course(
            id: "course-1",
            title: "Course",
            summary: "Summary",
            version: CourseVersion(
                schemaVersion: 1,
                contentVersion: "1.0.0",
                locale: "en-SG",
                releasedAt: nil
            ),
            modules: [
                Module(
                    id: "M0",
                    title: "Orientation",
                    summary: "Summary",
                    order: 0,
                    lessons: [lesson],
                    sourceReferences: []
                )
            ],
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
