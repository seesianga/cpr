import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class CourseContentValidationTests: XCTestCase {
    private let expectedCourseID = "lifesaver-vision-cpr-aed-spatial-academy"
    private let expectedContentVersion = "1.0.0"

    func testBundledCourseDecodesImportsAndExposesOnlySafeScoredContent() async throws {
        let decodedCourse = try CourseContentCodec.loadCourse(named: "course_v1")
        try CourseStructureValidator().validate(decodedCourse)

        let facts = try ClinicalFactCatalogue.loadBundled()
        let repository = InMemoryCourseRepository()
        let engine = CourseEngine(
            courseRepository: repository,
            versionRepository: repository,
            facts: facts
        )

        let importReport = try await engine.importBundledCourses(named: ["course_v1"])
        XCTAssertEqual(importReport.importedCourseIDs, [expectedCourseID])
        XCTAssertEqual(importReport.importedVersionCount, 1)

        let fetchedCourse = await repository.course(
            id: expectedCourseID,
            contentVersion: expectedContentVersion
        )
        let importedCourse = try XCTUnwrap(fetchedCourse)
        XCTAssertEqual(importedCourse, decodedCourse)

        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: expectedCourseID,
            contentVersion: expectedContentVersion
        )
        let scored = try await engine.scoredContent(
            courseID: expectedCourseID,
            contentVersion: expectedContentVersion
        )

        XCTAssertTrue(scored.safetyReport.permitsActivation)
        XCTAssertTrue(scored.safetyReport.issues.isEmpty)
        XCTAssertEqual(scored.assessments.count, 9)
        XCTAssertEqual(
            Set(scored.assessments.map(\.id)),
            Set((1...8).map { "assessment-m\($0)-theory-v1" } + ["assessment-m10-theory-v1"])
        )
        XCTAssertEqual(
            scored.safetyReport.excludedAssessmentIDs,
            ["assessment-m0-diagnostic-v1", "assessment-m9-awareness-v1"]
        )
        XCTAssertEqual(
            Set(scored.scenarios.map(\.id)),
            Set([
                "scenario-a-home",
                "scenario-b-shopping-centre",
                "scenario-c-workplace",
                "scenario-d-community-facility"
            ])
        )
    }

    func testCourseContainsExactlyModulesZeroThroughTenAndRequiredTopics() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")

        XCTAssertEqual(course.id, expectedCourseID)
        XCTAssertEqual(course.title, "Lifesaver Vision: CPR + AED Spatial Academy")
        XCTAssertEqual(course.version.contentVersion, expectedContentVersion)
        XCTAssertEqual(course.version.locale, "en-SG")
        XCTAssertEqual(course.modules.map(\.id), (0...10).map { "M\($0)" })
        XCTAssertEqual(course.modules.map(\.order), Array(0...10))
        XCTAssertEqual(
            course.modules.map(\.title),
            [
                "Orientation & Safety",
                "Cardiac Arrest & the Body",
                "Chain of Survival",
                "DRSABC",
                "Hands-only CPR",
                "AED Preparation",
                "AED Pads & Defibrillation",
                "Special Circumstances",
                "Integrated Scenarios A–D",
                "Child & Infant AED Awareness",
                "Post-incident Handover & Reflection"
            ]
        )
        XCTAssertTrue(course.modules.allSatisfy { $0.lessons.count == 1 })
        XCTAssertTrue(course.modules.flatMap(\.lessons).allSatisfy {
            !$0.learningObjectives.isEmpty && !$0.contentBlocks.isEmpty
        })

        let topicsByModule: [String: [String]] = [
            "M0": [
                "practice academy", "simulation", "never places a telephone call",
                "exit simulation", "not physically assessed", "dominant hand", "input method",
                "accessibility setup", "hand-data handling", "internal completion record",
                "not srfac certification", "instructor assessment", "comfort calibration",
                "pre-course knowledge check"
            ],
            "M1": ["cardiac arrest", "heart attack", "gasping", "2019 registry"],
            "M2": ["seven rings", "what changed since the 2018 manual", "clinical review required"],
            "M3": [
                "drsabc", "simulation", "location", "callback", "incident", "casualty-count",
                "bystander available", "lone rescuer", "aed near or far", "gasping",
                "breathing normally", "unsafe"
            ],
            "M4": [
                "firm, flat", "xiphoid", "100–120", "110", "full recoil", "10 seconds",
                "when to stop compressions", "not physically assessed"
            ],
            "M5": [
                "switch it on", "follow its prompts", "expose the chest", "hair", "jewellery",
                "pacemaker", "medication patches", "wet or sweaty chest"
            ],
            "M6": [
                "steps 1–10", "eleven aed learning states", "stay clear", "nobody may touch",
                "resume after a shock", "resume after no-shock advice"
            ],
            "M8": [
                "home", "shopping centre", "workplace", "community facility",
                "shock–no shock–no shock", "randomisation", "clinical rules"
            ],
            "M9": [
                "locked", "awareness only", "adult pads on a child", "infant",
                "instructor approval", "clinically approved", "does not infer"
            ],
            "M10": [
                "handover essentials", "aed switched on", "emotional decompression",
                "refresher recommendation", "structured after-action review"
            ]
        ]

        for module in course.modules {
            let text = authoredText(in: module).lowercased()
            for topic in topicsByModule[module.id, default: []] {
                XCTAssertTrue(
                    text.contains(topic.lowercased()),
                    "\(module.id) is missing required topic: \(topic)"
                )
            }
        }

        let specialCircumstances = try module("M7", in: course)
        let specialLesson = try XCTUnwrap(specialCircumstances.lessons.first)
        XCTAssertEqual(specialLesson.contentBlocks.count, 10)
        XCTAssertEqual(specialLesson.interactiveActivities.count, 10)
        for drillNumber in 1...10 {
            XCTAssertTrue(
                authoredText(in: specialCircumstances)
                    .localizedCaseInsensitiveContains("Drill \(drillNumber)")
            )
        }

        let integratedLesson = try XCTUnwrap(try module("M8", in: course).lessons.first)
        XCTAssertEqual(integratedLesson.scenarios.count, 4)
        XCTAssertEqual(integratedLesson.interactiveActivities.count, 4)

        let requiredUpdateCards: [String: String] = [
            "M1-B7": "Guideline update",
            "M2-B4": "What changed since the 2018 manual?",
            "M3-B7": "Guideline update",
            "M3-B11": "Guideline update",
            "M6-B9": "Guideline update",
            "M9-B10": "Guideline update",
            "M10-B4": "Guideline update",
            "M10-B5A": "Operational update"
        ]
        let blocksByID = Dictionary(
            uniqueKeysWithValues: course.modules
                .flatMap(\.lessons)
                .flatMap(\.contentBlocks)
                .map { ($0.id, $0) }
        )
        for (blockID, titleFragment) in requiredUpdateCards {
            let block = try XCTUnwrap(blocksByID[blockID], "Missing update card \(blockID)")
            XCTAssertTrue(block.title.localizedCaseInsensitiveContains(titleFragment))
        }
    }

    func testEveryScoredQuestionAndScenarioUsesOnlySafeExistingClinicalFacts() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let facts = try ClinicalFactCatalogue.loadBundled()

        let scoredAssessments = course.modules
            .flatMap(\.lessons)
            .flatMap(\.assessments)
            .filter(\.isScored)
        XCTAssertEqual(scoredAssessments.count, 9)

        for assessment in scoredAssessments {
            if !assessment.sourceReferences.isEmpty {
                assertSafeFactReferences(
                    assessment.sourceReferences,
                    facts: facts,
                    itemID: assessment.id
                )
            }
            XCTAssertFalse(assessment.questions.isEmpty)
            for question in assessment.questions {
                assertSafeFactReferences(
                    question.sourceReferences,
                    facts: facts,
                    itemID: "\(assessment.id)/\(question.id)"
                )
            }
        }

        let scoredScenarios = course.modules.flatMap(\.lessons).flatMap(\.scenarios)
        XCTAssertEqual(scoredScenarios.count, 4)
        for scenario in scoredScenarios {
            assertSafeFactReferences(
                scenario.sourceReferences,
                facts: facts,
                itemID: scenario.id
            )
            XCTAssertFalse(scenario.criticalActions.isEmpty)
            for action in scenario.criticalActions {
                assertSafeFactReferences(
                    action.sourceReferences,
                    facts: facts,
                    itemID: "\(scenario.id)/\(action.id)"
                )
            }
        }

        let safetyReport = ClinicalSafetyValidator().validateScoredContent(
            in: course,
            facts: facts
        )
        XCTAssertTrue(safetyReport.permitsActivation)
        XCTAssertFalse(safetyReport.issues.contains {
            $0.reason == .requiresSMEReview || $0.reason == .embeddedReviewStatusBlocked
        })
    }

    func testQuestionBankHasSixValidFactMappedQuestionsPerModule() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let facts = try ClinicalFactCatalogue.loadBundled()
        let bank = try TheoryQuestionBankCodec.load()

        XCTAssertEqual(bank.schemaVersion, 1)
        XCTAssertEqual(bank.courseID, expectedCourseID)
        XCTAssertEqual(bank.contentVersion, expectedContentVersion)
        XCTAssertEqual(bank.locale, "en-SG")
        XCTAssertEqual(bank.moduleQuestionSets.map(\.moduleID), (0...10).map { "M\($0)" })
        XCTAssertEqual(bank.moduleQuestionSets.count, 11)
        XCTAssertEqual(bank.moduleQuestionSets.flatMap(\.questions).count, 66)

        let unscoredModuleIDs = Set(
            bank.moduleQuestionSets.filter { !$0.isScored }.map(\.moduleID)
        )
        XCTAssertEqual(unscoredModuleIDs, Set(["M0", "M9"]))

        var allQuestionIDs = Set<String>()
        for questionSet in bank.moduleQuestionSets {
            XCTAssertEqual(questionSet.questions.count, 6, questionSet.moduleID)

            let embeddedAssessment = try XCTUnwrap(
                try module(questionSet.moduleID, in: course)
                    .lessons.first?.assessments.first
            )
            XCTAssertEqual(questionSet.assessmentID, embeddedAssessment.id)
            XCTAssertEqual(questionSet.isScored, embeddedAssessment.isScored)
            XCTAssertEqual(questionSet.questions, embeddedAssessment.questions)

            for question in questionSet.questions {
                XCTAssertTrue(allQuestionIDs.insert(question.id).inserted, question.id)
                XCTAssertFalse(question.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertFalse(question.explanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                XCTAssertGreaterThanOrEqual(question.choices.count, 2)

                let choiceIDs = question.choices.map(\.id)
                XCTAssertEqual(Set(choiceIDs).count, choiceIDs.count, question.id)
                XCTAssertFalse(question.correctChoiceIDs.isEmpty, question.id)
                XCTAssertTrue(
                    question.correctChoiceIDs.allSatisfy(Set(choiceIDs).contains),
                    question.id
                )
                if question.type == .ordering {
                    XCTAssertEqual(question.correctChoiceIDs.count, choiceIDs.count, question.id)
                }

                XCTAssertFalse(question.sourceReferences.isEmpty, question.id)
                for reference in question.sourceReferences {
                    let factID = try XCTUnwrap(
                        reference.clinicalFactID,
                        "\(question.id) has no clinicalFactID"
                    )
                    let fact = try XCTUnwrap(
                        facts[factID],
                        "\(question.id) references unknown fact \(factID)"
                    )
                    XCTAssertEqual(reference.typedReviewStatus, fact.reviewStatus, question.id)

                    if questionSet.isScored {
                        XCTAssertFalse(reference.typedReviewStatus.blocksScoredUse, question.id)
                        XCTAssertFalse(fact.reviewStatus.blocksScoredUse, question.id)
                    }
                }
            }
        }
    }

    func testM9IsUnscoredAndLockedUntilAdultCoreInstructorAndClinicalApproval() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let m9 = try module("M9", in: course)
        let adultCore = Set((0...8).map { "M\($0)" })

        XCTAssertEqual(m9.reviewStatus, .clinicalReviewRequired)
        XCTAssertEqual(Set(m9.accessRequirements.requiredCompletedModuleIDs), adultCore)
        XCTAssertTrue(m9.accessRequirements.requiresInstructorApproval)
        XCTAssertTrue(m9.accessRequirements.requiresClinicallyApprovedContent)
        XCTAssertTrue(m9.lessons.flatMap(\.assessments).allSatisfy { !$0.isScored })

        let evaluator = ModuleAccessEvaluator()
        let noRequirements = evaluator.evaluate(
            module: m9,
            completedModuleIDs: [],
            instructorApprovalGranted: false,
            contentLifecycle: .clinicalReviewRequired
        )
        XCTAssertFalse(noRequirements.isUnlocked)
        XCTAssertEqual(Set(noRequirements.missingCompletedModuleIDs), adultCore)
        XCTAssertTrue(noRequirements.isInstructorApprovalMissing)
        XCTAssertTrue(noRequirements.isClinicalApprovalMissing)

        let adultCoreOnly = evaluator.evaluate(
            module: m9,
            completedModuleIDs: adultCore,
            instructorApprovalGranted: false,
            contentLifecycle: .clinicalReviewRequired
        )
        XCTAssertFalse(adultCoreOnly.isUnlocked)
        XCTAssertTrue(adultCoreOnly.isInstructorApprovalMissing)
        XCTAssertTrue(adultCoreOnly.isClinicalApprovalMissing)

        let awaitingClinicalApproval = evaluator.evaluate(
            module: m9,
            completedModuleIDs: adultCore,
            instructorApprovalGranted: true,
            contentLifecycle: .clinicalReviewRequired
        )
        XCTAssertFalse(awaitingClinicalApproval.isUnlocked)
        XCTAssertFalse(awaitingClinicalApproval.isInstructorApprovalMissing)
        XCTAssertTrue(awaitingClinicalApproval.isClinicalApprovalMissing)

        let unlocked = evaluator.evaluate(
            module: m9,
            completedModuleIDs: adultCore,
            instructorApprovalGranted: true,
            contentLifecycle: .clinicallyApproved
        )
        XCTAssertTrue(unlocked.isUnlocked)
    }

    func testScenarioDefinitionsHaveExactStatePatternsSettingsAndInvariantMappings() throws {
        let facts = try ClinicalFactCatalogue.loadBundled()
        let document = try ScenarioDefinitionsCodec.load()

        XCTAssertEqual(document.schemaVersion, 1)
        XCTAssertEqual(document.courseID, expectedCourseID)
        XCTAssertEqual(document.contentVersion, expectedContentVersion)

        let expectedStateIDs = Set([
            "awaitingAED", "powerOn", "prepareChest", "applyRightPad", "applyLeftPad",
            "connectPads", "analyseClear", "chargeClear", "clearCheckAndShock",
            "noShockAdvised", "resumeCPR"
        ])
        XCTAssertEqual(document.aedStateMachine.states.count, 11)
        XCTAssertEqual(Set(document.aedStateMachine.states.map(\.id)), expectedStateIDs)
        XCTAssertTrue(expectedStateIDs.contains(document.aedStateMachine.initialStateID))
        for transition in document.aedStateMachine.transitions {
            XCTAssertTrue(expectedStateIDs.contains(transition.fromStateID), transition.id)
            XCTAssertTrue(expectedStateIDs.contains(transition.toStateID), transition.id)
        }

        let expectedPatterns: [String: [AEDAnalysisOutcome]] = [
            "S-N-N": [.shock, .noShock, .noShock],
            "N-S-N": [.noShock, .shock, .noShock],
            "S-S-N": [.shock, .shock, .noShock],
            "N-N-S": [.noShock, .noShock, .shock],
            "N-N-N": [.noShock, .noShock, .noShock]
        ]
        XCTAssertEqual(document.shockPatterns.count, 5)
        for pattern in document.shockPatterns {
            XCTAssertEqual(pattern.analysisOutcomes, expectedPatterns[pattern.id], pattern.id)
            XCTAssertTrue(pattern.analysisOutcomes.allSatisfy {
                $0 == .shock || $0 == .noShock
            })
        }

        let expectedScenarioIDs = [
            "scenario-a-home",
            "scenario-b-shopping-centre",
            "scenario-c-workplace",
            "scenario-d-community-facility"
        ]
        XCTAssertEqual(document.scenarios.map(\.id), expectedScenarioIDs)
        XCTAssertEqual(
            document.scenarios.map(\.title),
            [
                "Scenario A — Home",
                "Scenario B — Shopping centre",
                "Scenario C — Workplace",
                "Scenario D — Community facility"
            ]
        )

        let patternIDs = Set(expectedPatterns.keys)
        for scenario in document.scenarios {
            XCTAssertTrue(scenario.randomisation.clinicalRulesInvariant, scenario.id)
            XCTAssertEqual(Set(scenario.randomisation.shockPatternIDs), patternIDs, scenario.id)
            XCTAssertFalse(scenario.branchingNodes.isEmpty, scenario.id)
            XCTAssertFalse(scenario.criticalActions.isEmpty, scenario.id)
            XCTAssertFalse(scenario.criticalErrors.isEmpty, scenario.id)

            let actionIDs = Set(scenario.criticalActions.map(\.id))
            let errorIDs = Set(scenario.criticalErrors.map(\.id))
            XCTAssertTrue(actionIDs.isDisjoint(with: errorIDs), scenario.id)

            let conditionallyRequiredActionIDs = Set(
                scenario.branchingNodes
                    .flatMap(\.conditions)
                    .flatMap(\.requiredActionIDs)
            )
            XCTAssertTrue(conditionallyRequiredActionIDs.isSubset(of: actionIDs), scenario.id)
            XCTAssertTrue(scenario.criticalActions.allSatisfy {
                $0.isRequired || conditionallyRequiredActionIDs.contains($0.id)
            }, scenario.id)

            let mappedIDs = scenario.scoringCategoryMapping.map(\.itemID)
            XCTAssertEqual(Set(mappedIDs).count, mappedIDs.count, scenario.id)
            XCTAssertEqual(Set(mappedIDs), actionIDs.union(errorIDs), scenario.id)

            var mappedCategories: [String: ScoringDimension] = [:]
            for mapping in scenario.scoringCategoryMapping {
                mappedCategories[mapping.itemID] = mapping.category
            }
            for action in scenario.criticalActions {
                XCTAssertEqual(mappedCategories[action.id], action.scoringCategory, action.id)
            }
            for error in scenario.criticalErrors {
                XCTAssertEqual(mappedCategories[error.id], error.scoringCategory, error.id)
            }
            XCTAssertEqual(Set(mappedCategories.values), Set(ScoringDimension.allCases), scenario.id)
        }

        for (itemID, references) in allScenarioReferenceGroups(in: document) {
            assertSafeFactReferences(references, facts: facts, itemID: itemID)
        }
    }

    func testReviewRequiredBlocksContainAllBlockedOrMissingClinicalReferences() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let facts = try ClinicalFactCatalogue.loadBundled()
        let blocks = course.modules.flatMap(\.lessons).flatMap(\.contentBlocks)

        let expectedReviewBlockIDs = Set([
            "M2-B1", "M2-B4", "M9-B1", "M9-B4", "M9-B5", "M9-B8",
            "M9-B9", "M9-B10", "M10-B5A", "M10-B6", "M10-B7"
        ])
        XCTAssertEqual(
            Set(blocks.filter { $0.reviewStatus == .clinicalReviewRequired }.map(\.id)),
            expectedReviewBlockIDs
        )

        for block in blocks {
            let blockedOrMissingReferences = block.sourceReferences.filter { reference in
                if reference.typedReviewStatus == .requiresSMEReview {
                    return true
                }
                guard let factID = reference.clinicalFactID else {
                    return false
                }
                return facts[factID]?.reviewStatus.blocksScoredUse ?? true
            }
            if !blockedOrMissingReferences.isEmpty {
                XCTAssertEqual(
                    block.reviewStatus,
                    .clinicalReviewRequired,
                    "\(block.id) contains a blocked or missing clinical reference"
                )
            }
        }

        let modulesRequiringReview = Set(
            course.modules.filter { $0.reviewStatus == .clinicalReviewRequired }.map(\.id)
        )
        XCTAssertEqual(modulesRequiringReview, Set(["M2", "M9", "M10"]))
    }

    private func module(_ id: String, in course: Course) throws -> Module {
        try XCTUnwrap(course.modules.first { $0.id == id }, "Missing module \(id)")
    }

    private func authoredText(in module: Module) -> String {
        var components = [module.title, module.summary]
        for lesson in module.lessons {
            components.append(contentsOf: [lesson.title, lesson.summary])
            components.append(contentsOf: lesson.learningObjectives.map(\.statement))
            for block in lesson.contentBlocks {
                components.append(contentsOf: [block.title, block.body])
            }
            for activity in lesson.interactiveActivities {
                components.append(contentsOf: [activity.title, activity.instructions])
            }
        }
        return components.joined(separator: "\n")
    }

    private func assertSafeFactReferences(
        _ references: [SourceReference],
        facts: ClinicalFactCatalogue,
        itemID: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(references.isEmpty, "\(itemID) has no source reference", file: file, line: line)
        for reference in references {
            XCTAssertFalse(
                reference.typedReviewStatus.blocksScoredUse,
                "\(itemID) embeds blocked status \(reference.reviewStatus)",
                file: file,
                line: line
            )
            guard let factID = reference.clinicalFactID, !factID.isEmpty else {
                XCTFail("\(itemID) has no clinicalFactID", file: file, line: line)
                continue
            }
            guard let fact = facts[factID] else {
                XCTFail("\(itemID) references unknown fact \(factID)", file: file, line: line)
                continue
            }
            XCTAssertFalse(
                fact.reviewStatus.blocksScoredUse,
                "\(itemID) reaches blocked fact \(factID)",
                file: file,
                line: line
            )
        }
    }

    private func allScenarioReferenceGroups(
        in document: ScenarioDefinitionsDocument
    ) -> [(String, [SourceReference])] {
        var groups: [(String, [SourceReference])] = [
            ("aed-state-machine", document.aedStateMachine.sourceReferences)
        ]

        for state in document.aedStateMachine.states {
            groups.append((state.id, state.sourceReferences))
        }
        for transition in document.aedStateMachine.transitions {
            groups.append((transition.id, transition.sourceReferences))
            groups.append(contentsOf: transition.feedbackStatements.map {
                ($0.id, $0.sourceReferences)
            })
        }
        for pattern in document.shockPatterns {
            groups.append((pattern.id, pattern.sourceReferences))
        }
        for scenario in document.scenarios {
            groups.append((scenario.id, scenario.sourceReferences))
            groups.append((scenario.initialState.id, scenario.initialState.sourceReferences))
            groups.append(contentsOf: scenario.feedbackStatements.map {
                ($0.id, $0.sourceReferences)
            })
            for branch in scenario.branchingNodes {
                groups.append((branch.id, branch.sourceReferences))
                groups.append(contentsOf: branch.feedbackStatements.map {
                    ($0.id, $0.sourceReferences)
                })
                for condition in branch.conditions {
                    groups.append((condition.id, condition.sourceReferences))
                    groups.append(contentsOf: condition.feedbackStatements.map {
                        ($0.id, $0.sourceReferences)
                    })
                }
            }
            for action in scenario.criticalActions {
                groups.append((action.id, action.sourceReferences))
                groups.append(contentsOf: action.feedbackStatements.map {
                    ($0.id, $0.sourceReferences)
                })
            }
            for error in scenario.criticalErrors {
                groups.append((error.id, error.sourceReferences))
                groups.append(contentsOf: error.feedbackStatements.map {
                    ($0.id, $0.sourceReferences)
                })
            }
        }
        return groups
    }
}
