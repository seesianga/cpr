import Foundation

/// Fail-closed clinical traceability validator for every scored assessment and scenario.
struct ClinicalSafetyValidator: Sendable {
    func validateScoredContent(
        in course: Course,
        facts: ClinicalFactCatalogue
    ) -> ClinicalSafetyReport {
        var eligibleAssessmentIDs: [String] = []
        var excludedAssessmentIDs: [String] = []
        var eligibleScenarioIDs: [String] = []
        var excludedScenarioIDs: [String] = []
        var allIssues: [ClinicalSafetyIssue] = []

        for module in course.modules {
            for lesson in module.lessons {
                for assessment in lesson.assessments {
                    guard assessment.isScored else {
                        // Awareness-only assessments remain available to learning views but
                        // can never enter the scored-content catalogue.
                        excludedAssessmentIDs.append(assessment.id)
                        continue
                    }

                    var assessmentIssues: [ClinicalSafetyIssue] = []
                    let scoredQuestions = assessment.questions.filter(\.isScored)
                    if scoredQuestions.isEmpty {
                        assessmentIssues.append(
                            ClinicalSafetyIssue(
                                id: "\(assessment.id)#no-scored-questions",
                                scoredItemID: assessment.id,
                                factID: nil,
                                reason: .noScoredQuestions
                            )
                        )
                    }
                    if !assessment.sourceReferences.isEmpty {
                        assessmentIssues.append(
                            contentsOf: issues(
                                for: assessment.sourceReferences,
                                scoredItemID: assessment.id,
                                contentVersion: course.version.contentVersion,
                                facts: facts
                            )
                        )
                    }
                    for question in scoredQuestions {
                        assessmentIssues.append(
                            contentsOf: issues(
                                for: question.sourceReferences,
                                scoredItemID: "\(assessment.id)/\(question.id)",
                                contentVersion: course.version.contentVersion,
                                facts: facts
                            )
                        )
                    }

                    let requiredWaiverCoverage = Set(
                        (module.reviewStatus == .clinicalReviewRequired ? [module.id] : []) +
                            lesson.contentBlocks
                            .filter { $0.reviewStatus == .clinicalReviewRequired }
                            .map(\.id)
                    )
                    if !requiredWaiverCoverage.isEmpty {
                        if let waiver = assessment.scoredUseWaiver {
                            let waiverCoverage = Set(waiver.coveredContentIDs)
                            if waiver.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                waiver.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                waiverCoverage != requiredWaiverCoverage ||
                                waiverCoverage.count != waiver.coveredContentIDs.count
                            {
                                assessmentIssues.append(
                                    ClinicalSafetyIssue(
                                        id: "\(assessment.id)#container-waiver-invalid",
                                        scoredItemID: assessment.id,
                                        factID: nil,
                                        reason: .reviewRequiredContainerWaiverInvalid
                                    )
                                )
                            }
                        } else {
                            assessmentIssues.append(
                                ClinicalSafetyIssue(
                                    id: "\(assessment.id)#container-waiver-missing",
                                    scoredItemID: assessment.id,
                                    factID: nil,
                                    reason: .reviewRequiredContainerWaiverMissing
                                )
                            )
                        }
                    }

                    if assessmentIssues.isEmpty {
                        eligibleAssessmentIDs.append(assessment.id)
                    } else {
                        excludedAssessmentIDs.append(assessment.id)
                        allIssues.append(contentsOf: assessmentIssues)
                    }
                }
            }
        }

        for scenario in course.modules.flatMap(\.lessons).flatMap(\.scenarios) {
            var scenarioIssues: [ClinicalSafetyIssue] = []
            func validate(_ itemID: String, _ references: [SourceReference]) {
                scenarioIssues.append(
                    contentsOf: issues(
                        for: references,
                        scoredItemID: itemID,
                        contentVersion: course.version.contentVersion,
                        facts: facts
                    )
                )
            }

            validate(scenario.id, scenario.sourceReferences)
            validate(scenario.initialState.id, scenario.initialState.sourceReferences)
            for feedback in scenario.feedbackStatements {
                validate(feedback.id, feedback.sourceReferences)
            }
            for branch in scenario.branchingNodes {
                validate(branch.id, branch.sourceReferences)
                for feedback in branch.feedbackStatements {
                    validate(feedback.id, feedback.sourceReferences)
                }
                for condition in branch.conditions {
                    validate(condition.id, condition.sourceReferences)
                    for feedback in condition.feedbackStatements {
                        validate(feedback.id, feedback.sourceReferences)
                    }
                }
            }
            for action in scenario.criticalActions {
                validate(action.id, action.sourceReferences)
                for feedback in action.feedbackStatements {
                    validate(feedback.id, feedback.sourceReferences)
                }
            }
            for error in scenario.criticalErrors {
                validate(error.id, error.sourceReferences)
                for feedback in error.feedbackStatements {
                    validate(feedback.id, feedback.sourceReferences)
                }
            }

            if scenarioIssues.isEmpty {
                eligibleScenarioIDs.append(scenario.id)
            } else {
                excludedScenarioIDs.append(scenario.id)
                allIssues.append(contentsOf: scenarioIssues)
            }
        }

        return ClinicalSafetyReport(
            eligibleAssessmentIDs: eligibleAssessmentIDs.sorted(),
            excludedAssessmentIDs: excludedAssessmentIDs.sorted(),
            eligibleScenarioIDs: eligibleScenarioIDs.sorted(),
            excludedScenarioIDs: excludedScenarioIDs.sorted(),
            issues: allIssues
        )
    }

    func assertScoredActivationAllowed(
        in course: Course,
        facts: ClinicalFactCatalogue
    ) throws {
        let report = validateScoredContent(in: course, facts: facts)
        guard report.permitsActivation else {
            throw ClinicalContentError.scoredContentBlocked(report.issues)
        }
    }

    private func issues(
        for references: [SourceReference],
        scoredItemID: String,
        contentVersion: String,
        facts: ClinicalFactCatalogue
    ) -> [ClinicalSafetyIssue] {
        guard !references.isEmpty else {
            return [
                ClinicalSafetyIssue(
                    id: "\(scoredItemID)#missing-reference",
                    scoredItemID: scoredItemID,
                    factID: nil,
                    reason: .missingFactReference
                )
            ]
        }

        var result: [ClinicalSafetyIssue] = []
        for (index, reference) in references.enumerated() {
            if reference.contentVersion != contentVersion {
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: reference.clinicalFactID,
                        reason: .contentVersionMismatch,
                        index: index
                    )
                )
            }

            switch reference.typedReviewStatus {
            case .requiresSMEReview:
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: reference.clinicalFactID,
                        reason: .embeddedReviewStatusBlocked,
                        index: index
                    )
                )
            case .unknown:
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: reference.clinicalFactID,
                        reason: .unknownReviewStatus,
                        index: index
                    )
                )
            case .sourceChecked, .clinicallyApproved:
                break
            }

            guard let factID = reference.clinicalFactID, !factID.isEmpty else {
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: nil,
                        reason: .missingFactReference,
                        index: index
                    )
                )
                continue
            }
            guard let fact = facts[factID] else {
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: factID,
                        reason: .unknownFactReference,
                        index: index
                    )
                )
                continue
            }
            switch fact.reviewStatus {
            case .requiresSMEReview:
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: factID,
                        reason: .requiresSMEReview,
                        index: index
                    )
                )
            case .unknown:
                result.append(
                    issue(
                        itemID: scoredItemID,
                        factID: factID,
                        reason: .unknownReviewStatus,
                        index: index
                    )
                )
            case .sourceChecked, .clinicallyApproved:
                break
            }
        }
        return result
    }

    private func issue(
        itemID: String,
        factID: String?,
        reason: ClinicalSafetyReason,
        index: Int
    ) -> ClinicalSafetyIssue {
        ClinicalSafetyIssue(
            id: "\(itemID)#\(index)#\(reason.rawValue)",
            scoredItemID: itemID,
            factID: factID,
            reason: reason
        )
    }
}

enum CourseValidationError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case emptyRequiredField(String)
    case duplicateIdentifier(String)
    case duplicateOrder(scope: String, order: Int)
    case invalidPassingScore(assessmentID: String)
    case invalidCorrectChoice(assessmentID: String, questionID: String)
    case sourceVersionMismatch(referenceID: String)
}

/// Structural validation independent of clinical approval.
struct CourseStructureValidator: Sendable {
    func validate(_ course: Course) throws {
        guard course.version.schemaVersion == 1 else {
            throw CourseValidationError.unsupportedSchemaVersion(course.version.schemaVersion)
        }
        guard !course.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CourseValidationError.emptyRequiredField("course.id")
        }
        guard !course.version.contentVersion.isEmpty else {
            throw CourseValidationError.emptyRequiredField("course.version.contentVersion")
        }

        var identifiers = Set<String>()
        try requireUnique(course.id, in: &identifiers)
        try requireUniqueOrders(course.modules.map(\.order), scope: "modules")
        try validateReferences(course.sourceReferences, course: course)

        for module in course.modules {
            try requireUnique(module.id, in: &identifiers)
            try requireUniqueOrders(module.lessons.map(\.order), scope: module.id)
            try validateReferences(module.sourceReferences, course: course)
            for lesson in module.lessons {
                try requireUnique(lesson.id, in: &identifiers)
                try validateReferences(lesson.sourceReferences, course: course)
                for objective in lesson.learningObjectives {
                    try requireUnique(objective.id, in: &identifiers)
                    try validateReferences(objective.sourceReferences, course: course)
                }
                for block in lesson.contentBlocks {
                    try requireUnique(block.id, in: &identifiers)
                    try validateReferences(block.sourceReferences, course: course)
                }
                for activity in lesson.interactiveActivities {
                    try requireUnique(activity.id, in: &identifiers)
                    try validateReferences(activity.sourceReferences, course: course)
                }
                for scenario in lesson.scenarios {
                    try requireUnique(scenario.id, in: &identifiers)
                    try validateReferences(scenario.sourceReferences, course: course)
                    try requireUnique(scenario.initialState.id, in: &identifiers)
                    try validateReferences(scenario.initialState.sourceReferences, course: course)
                    for feedback in scenario.feedbackStatements {
                        try requireUnique(feedback.id, in: &identifiers)
                        try validateReferences(feedback.sourceReferences, course: course)
                    }
                    for branch in scenario.branchingNodes {
                        try requireUnique(branch.id, in: &identifiers)
                        try validateReferences(branch.sourceReferences, course: course)
                        for feedback in branch.feedbackStatements {
                            try requireUnique(feedback.id, in: &identifiers)
                            try validateReferences(feedback.sourceReferences, course: course)
                        }
                        for condition in branch.conditions {
                            try requireUnique(condition.id, in: &identifiers)
                            try validateReferences(condition.sourceReferences, course: course)
                            for feedback in condition.feedbackStatements {
                                try requireUnique(feedback.id, in: &identifiers)
                                try validateReferences(feedback.sourceReferences, course: course)
                            }
                        }
                    }
                    for action in scenario.criticalActions {
                        try requireUnique(action.id, in: &identifiers)
                        try validateReferences(action.sourceReferences, course: course)
                        for feedback in action.feedbackStatements {
                            try requireUnique(feedback.id, in: &identifiers)
                            try validateReferences(feedback.sourceReferences, course: course)
                        }
                    }
                    for error in scenario.criticalErrors {
                        try requireUnique(error.id, in: &identifiers)
                        try validateReferences(error.sourceReferences, course: course)
                        for feedback in error.feedbackStatements {
                            try requireUnique(feedback.id, in: &identifiers)
                            try validateReferences(feedback.sourceReferences, course: course)
                        }
                    }
                }
                for assessment in lesson.assessments {
                    try requireUnique(assessment.id, in: &identifiers)
                    guard assessment.passingScore.isFinite,
                          (0...1).contains(assessment.passingScore)
                    else {
                        throw CourseValidationError.invalidPassingScore(
                            assessmentID: assessment.id
                        )
                    }
                    try validateReferences(assessment.sourceReferences, course: course)
                    for question in assessment.questions {
                        try requireUnique(question.id, in: &identifiers)
                        let choiceIDs = Set(question.choices.map(\.id))
                        let correctIDs = question.correctChoiceIDs
                        let validCardinality: Bool
                        switch question.type {
                        case .singleChoice, .hotspotLite:
                            validCardinality = correctIDs.count == 1
                        case .multipleChoice:
                            validCardinality = !correctIDs.isEmpty
                        case .ordering:
                            validCardinality = correctIDs.count == question.choices.count
                        }
                        guard Set(correctIDs).count == correctIDs.count,
                              Set(question.choices.map(\.id)).count == question.choices.count,
                              correctIDs.allSatisfy(choiceIDs.contains),
                              validCardinality
                        else {
                            throw CourseValidationError.invalidCorrectChoice(
                                assessmentID: assessment.id,
                                questionID: question.id
                            )
                        }
                        try validateReferences(question.sourceReferences, course: course)
                    }
                }
            }
        }
    }

    private func requireUnique(_ id: String, in identifiers: inout Set<String>) throws {
        guard identifiers.insert(id).inserted else {
            throw CourseValidationError.duplicateIdentifier(id)
        }
    }

    private func requireUniqueOrders(_ orders: [Int], scope: String) throws {
        var seen = Set<Int>()
        for order in orders where !seen.insert(order).inserted {
            throw CourseValidationError.duplicateOrder(scope: scope, order: order)
        }
    }

    private func validateReferences(_ references: [SourceReference], course: Course) throws {
        for reference in references where reference.contentVersion != course.version.contentVersion {
            throw CourseValidationError.sourceVersionMismatch(referenceID: reference.id)
        }
    }
}
