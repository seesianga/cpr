import Foundation

// MARK: - Module access

/// Declarative requirements evaluated before a learner can open a module.
struct ModuleAccessRequirements: Codable, Sendable, Equatable {
    let requiredCompletedModuleIDs: [String]
    let requiresInstructorApproval: Bool
    let requiresClinicallyApprovedContent: Bool

    static let open = ModuleAccessRequirements(
        requiredCompletedModuleIDs: [],
        requiresInstructorApproval: false,
        requiresClinicallyApprovedContent: false
    )

    init(
        requiredCompletedModuleIDs: [String] = [],
        requiresInstructorApproval: Bool = false,
        requiresClinicallyApprovedContent: Bool = false
    ) {
        self.requiredCompletedModuleIDs = requiredCompletedModuleIDs
        self.requiresInstructorApproval = requiresInstructorApproval
        self.requiresClinicallyApprovedContent = requiresClinicallyApprovedContent
    }
}

/// Explains every unmet access requirement without conflating clinical and instructor approval.
struct ModuleAccessDecision: Sendable, Equatable {
    let missingCompletedModuleIDs: [String]
    let isInstructorApprovalMissing: Bool
    let isClinicalApprovalMissing: Bool

    var isUnlocked: Bool {
        missingCompletedModuleIDs.isEmpty &&
            !isInstructorApprovalMissing &&
            !isClinicalApprovalMissing
    }
}

struct ModuleAccessEvaluator: Sendable {
    func evaluate(
        module: Module,
        completedModuleIDs: Set<String>,
        instructorApprovalGranted: Bool,
        contentLifecycle: ContentLifecycle
    ) -> ModuleAccessDecision {
        let requirements = module.accessRequirements
        let missingModules = requirements.requiredCompletedModuleIDs
            .filter { !completedModuleIDs.contains($0) }
            .sorted()
        let clinicallyApproved = contentLifecycle == .clinicallyApproved ||
            contentLifecycle == .published

        return ModuleAccessDecision(
            missingCompletedModuleIDs: missingModules,
            isInstructorApprovalMissing: requirements.requiresInstructorApproval &&
                !instructorApprovalGranted,
            isClinicalApprovalMissing: requirements.requiresClinicallyApprovedContent &&
                !clinicallyApproved
        )
    }
}

// MARK: - External theory-question bank

/// Versioned top-level payload for `Resources/Questions/theory_questions_v1.json`.
struct TheoryQuestionBankDocument: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let courseID: String
    let contentVersion: String
    let locale: String
    let moduleQuestionSets: [TheoryQuestionModule]

    /// Compatibility alias for callers that treat each set as a module-owned bank.
    var modules: [TheoryQuestionModule] { moduleQuestionSets }

    init(
        schemaVersion: Int,
        courseID: String,
        contentVersion: String,
        locale: String = "en-SG",
        moduleQuestionSets: [TheoryQuestionModule]
    ) {
        self.schemaVersion = schemaVersion
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.locale = locale
        self.moduleQuestionSets = moduleQuestionSets
    }

    init(
        schemaVersion: Int,
        courseID: String,
        contentVersion: String,
        locale: String = "en-SG",
        modules: [TheoryQuestionModule]
    ) {
        self.init(
            schemaVersion: schemaVersion,
            courseID: courseID,
            contentVersion: contentVersion,
            locale: locale,
            moduleQuestionSets: modules
        )
    }
}

/// A module-owned question set that converts directly into the LMS `Assessment` model.
struct TheoryQuestionModule: Codable, Identifiable, Sendable, Equatable {
    var id: String { assessmentID }

    let moduleID: String
    let assessmentID: String
    let title: String
    let passingScore: Double
    let isScored: Bool
    let questions: [Question]
    let sourceReferences: [SourceReference]
    let scoredUseWaiver: ScoredUseWaiver?

    init(
        moduleID: String,
        assessmentID: String,
        title: String,
        passingScore: Double,
        isScored: Bool = true,
        questions: [Question],
        sourceReferences: [SourceReference] = [],
        scoredUseWaiver: ScoredUseWaiver? = nil
    ) {
        self.moduleID = moduleID
        self.assessmentID = assessmentID
        self.title = title
        self.passingScore = passingScore
        self.isScored = isScored
        self.questions = questions
        self.sourceReferences = sourceReferences
        self.scoredUseWaiver = scoredUseWaiver
    }

    private enum CodingKeys: String, CodingKey {
        case moduleID, assessmentID, title, passingScore, isScored
        case questions, sourceReferences, scoredUseWaiver
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moduleID = try container.decode(String.self, forKey: .moduleID)
        assessmentID = try container.decode(String.self, forKey: .assessmentID)
        title = try container.decode(String.self, forKey: .title)
        passingScore = try container.decode(Double.self, forKey: .passingScore)
        isScored = try container.decodeIfPresent(Bool.self, forKey: .isScored) ?? true
        questions = try container.decode([Question].self, forKey: .questions)
        sourceReferences = try container.decodeIfPresent(
            [SourceReference].self,
            forKey: .sourceReferences
        ) ?? []
        scoredUseWaiver = try container.decodeIfPresent(
            ScoredUseWaiver.self,
            forKey: .scoredUseWaiver
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(moduleID, forKey: .moduleID)
        try container.encode(assessmentID, forKey: .assessmentID)
        try container.encode(title, forKey: .title)
        try container.encode(passingScore, forKey: .passingScore)
        try container.encode(isScored, forKey: .isScored)
        try container.encode(questions, forKey: .questions)
        if !sourceReferences.isEmpty {
            try container.encode(sourceReferences, forKey: .sourceReferences)
        }
        try container.encodeIfPresent(scoredUseWaiver, forKey: .scoredUseWaiver)
    }

    var assessment: Assessment {
        Assessment(
            id: assessmentID,
            title: title,
            passingScore: passingScore,
            questions: questions,
            sourceReferences: sourceReferences,
            isScored: isScored,
            scoredUseWaiver: scoredUseWaiver
        )
    }
}

enum TheoryQuestionBankCodec {
    static func decode(_ data: Data) throws -> TheoryQuestionBankDocument {
        try Phase3BJSONCodec.decoder.decode(TheoryQuestionBankDocument.self, from: data)
    }

    static func encode(_ document: TheoryQuestionBankDocument) throws -> Data {
        try Phase3BJSONCodec.encoder.encode(document)
    }

    static func load(
        named resourceName: String = "theory_questions_v1",
        from bundle: Bundle = .main
    ) throws -> TheoryQuestionBankDocument {
        let url = Phase3BJSONCodec.resourceURL(
            named: resourceName,
            subdirectory: "Questions",
            bundle: bundle
        )
        guard let url else {
            throw Phase3BContentError.resourceNotFound(resourceName)
        }
        return try decode(Data(contentsOf: url))
    }
}

// MARK: - External integrated-scenario definitions

/// Versioned top-level payload for `Resources/Courses/scenarios_v1.json`.
struct ScenarioDefinitionsDocument: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let courseID: String
    let contentVersion: String
    let metadata: [String: JSONValue]
    let designProvenance: [String: JSONValue]
    let aedStateMachine: AEDStateMachineDefinition
    let shockPatterns: [ScenarioShockPattern]
    let scenarios: [ScenarioDefinition]
}

struct AEDStateMachineDefinition: Codable, Sendable, Equatable {
    let initialStateID: String
    let states: [AEDStateDefinition]
    let transitions: [AEDStateTransition]
    let sourceReferences: [SourceReference]
}

struct AEDStateDefinition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let stateDescription: String
    let values: [String: JSONValue]
    let sourceReferences: [SourceReference]
}

struct AEDStateTransition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let fromStateID: String
    let toStateID: String
    let trigger: String
    let condition: String?
    let feedbackStatements: [ScenarioFeedbackStatement]
    let sourceReferences: [SourceReference]
}

enum AEDAnalysisOutcome: Codable, Sendable, Equatable {
    case shock
    case noShock
    case unknown(String)

    var rawValue: String {
        switch self {
        case .shock: "shock"
        case .noShock: "noShock"
        case let .unknown(value): value
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "shock", "shockAdvised", "shock_advised": self = .shock
        case "noShock", "noShockAdvised", "no_shock_advised": self = .noShock
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ScenarioShockPattern: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let analysisOutcomes: [AEDAnalysisOutcome]
    let sourceReferences: [SourceReference]
}

struct ScenarioDefinition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let summary: String
    let initialState: ScenarioInitialState
    let branchingNodes: [ScenarioBranchNode]
    let criticalActions: [ScenarioCriticalActionDefinition]
    let criticalErrors: [ScenarioCriticalErrorDefinition]
    let randomisation: ScenarioRandomisationDefinition
    let scoringCategoryMapping: [ScenarioScoringCategoryMapping]
    let feedbackStatements: [ScenarioFeedbackStatement]
    let sourceReferences: [SourceReference]
}

/// Scenario-specific state stays data-driven while preserving traceable source metadata.
struct ScenarioInitialState: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let values: [String: JSONValue]
    let sourceReferences: [SourceReference]
}

struct ScenarioBranchNode: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let prompt: String
    let conditions: [ScenarioBranchCondition]
    let feedbackStatements: [ScenarioFeedbackStatement]
    let sourceReferences: [SourceReference]
}

/// `values` permits Boolean, numeric, string, array, or object predicates without code changes.
struct ScenarioBranchCondition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let condition: String
    let values: [String: JSONValue]
    let nextNodeID: String?
    let requiredActionIDs: [String]
    let feedbackStatements: [ScenarioFeedbackStatement]
    let sourceReferences: [SourceReference]
}

struct ScenarioCriticalActionDefinition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let actionDescription: String
    let isRequired: Bool
    let scoringCategory: ScoringDimension
    let feedbackStatements: [ScenarioFeedbackStatement]
    let sourceReferences: [SourceReference]
}

struct ScenarioCriticalErrorDefinition: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let code: String
    let title: String
    let errorDescription: String
    let remediation: String
    let scoringCategory: ScoringDimension
    let feedbackStatements: [ScenarioFeedbackStatement]
    let sourceReferences: [SourceReference]
}

struct ScenarioRandomisationDefinition: Codable, Sendable, Equatable {
    let shockPatternIDs: [String]
    let clinicalRulesInvariant: Bool
}

struct ScenarioScoringCategoryMapping: Codable, Identifiable, Sendable, Equatable {
    var id: String { itemID }

    let itemID: String
    let category: ScoringDimension
}

struct ScenarioFeedbackStatement: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let statement: String
    let sourceReferences: [SourceReference]
}

enum ScenarioDefinitionsCodec {
    static func decode(_ data: Data) throws -> ScenarioDefinitionsDocument {
        let document = try Phase3BJSONCodec.decoder.decode(
            ScenarioDefinitionsDocument.self,
            from: data
        )
        try validate(document)
        return document
    }

    static func encode(_ document: ScenarioDefinitionsDocument) throws -> Data {
        try validate(document)
        return try Phase3BJSONCodec.encoder.encode(document)
    }

    static func load(
        named resourceName: String = "scenarios_v1",
        from bundle: Bundle = .main
    ) throws -> ScenarioDefinitionsDocument {
        let url = Phase3BJSONCodec.resourceURL(
            named: resourceName,
            subdirectory: "Courses",
            bundle: bundle
        )
        guard let url else {
            throw Phase3BContentError.resourceNotFound(resourceName)
        }
        return try decode(Data(contentsOf: url))
    }

    private static func validate(_ document: ScenarioDefinitionsDocument) throws {
        let states = document.aedStateMachine.states
        guard states.count == 11 else {
            throw Phase3BContentError.invalidAEDStateCount(states.count)
        }

        var stateIDs = Set<String>()
        for state in states where !stateIDs.insert(state.id).inserted {
            throw Phase3BContentError.duplicateAEDStateID(state.id)
        }
        guard stateIDs.contains(document.aedStateMachine.initialStateID) else {
            throw Phase3BContentError.unknownAEDStateReference(
                document.aedStateMachine.initialStateID
            )
        }
        for transition in document.aedStateMachine.transitions {
            guard stateIDs.contains(transition.fromStateID) else {
                throw Phase3BContentError.unknownAEDStateReference(transition.fromStateID)
            }
            guard stateIDs.contains(transition.toStateID) else {
                throw Phase3BContentError.unknownAEDStateReference(transition.toStateID)
            }
        }
    }
}

enum Phase3BContentError: Error, Sendable, Equatable {
    case resourceNotFound(String)
    case invalidAEDStateCount(Int)
    case duplicateAEDStateID(String)
    case unknownAEDStateReference(String)
}

private enum Phase3BJSONCodec {
    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func resourceURL(
        named resourceName: String,
        subdirectory: String,
        bundle: Bundle
    ) -> URL? {
        bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: subdirectory
        ) ?? bundle.url(forResource: resourceName, withExtension: "json")
    }
}
