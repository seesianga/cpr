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

        for assessment in course.modules.flatMap(\.lessons).flatMap(\.assessments) {
            let references = assessment.sourceReferences + assessment.questions.flatMap(\.sourceReferences)
            let issues = issues(
                for: references,
                scoredItemID: assessment.id,
                contentVersion: course.version.contentVersion,
                facts: facts
            )
            if issues.isEmpty {
                eligibleAssessmentIDs.append(assessment.id)
            } else {
                excludedAssessmentIDs.append(assessment.id)
                allIssues.append(contentsOf: issues)
            }
        }

        for scenario in course.modules.flatMap(\.lessons).flatMap(\.scenarios) {
            let references = scenario.sourceReferences + scenario.criticalActions.flatMap(\.sourceReferences)
            let issues = issues(
                for: references,
                scoredItemID: scenario.id,
                contentVersion: course.version.contentVersion,
                facts: facts
            )
            if issues.isEmpty {
                eligibleScenarioIDs.append(scenario.id)
            } else {
                excludedScenarioIDs.append(scenario.id)
                allIssues.append(contentsOf: issues)
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
                    for action in scenario.criticalActions {
                        try requireUnique(action.id, in: &identifiers)
                        try validateReferences(action.sourceReferences, course: course)
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
                        guard question.choices.indices.contains(question.correctChoiceIndex) else {
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
