import Foundation

/// The authored immersive scene used for each integrated scenario definition.
enum IntegratedScenarioScene: String, Codable, CaseIterable, Sendable {
    case home = "Scenario_Home"
    case shoppingCentre = "Scenario_ShoppingCentre"
    case workplace = "Scenario_Workplace"
    case communityFacility = "Scenario_CommunityFacility"
}

enum ScenarioInteractionMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case gazeAndPinch
    case accessibleControl
}

enum ScenarioBystanderAssignment: String, Codable, CaseIterable, Hashable, Sendable {
    case callSimulated995
    case getAED

    var displayName: String {
        switch self {
        case .callSimulated995: "Make the simulated 995 call"
        case .getAED: "Get the AED"
        }
    }
}

enum ScenarioMachineDomain: String, Codable, Sendable {
    case drsabc
    case cpr
    case aed
}

struct ScenarioRequiredActionSnapshot: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let dimension: ScoringDimension
    let isAlwaysRequired: Bool
}

struct ScenarioReplayAnchor: Codable, Sendable, Equatable {
    let sequence: Int
    let domain: ScenarioMachineDomain
    let stateBefore: String
    let stateAfter: String
    let eventDescription: String
}

struct ScenarioCriticalCorrection: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let code: String
    let title: String
    let remediation: String
    let dimension: ScoringDimension
    let systemAudioCueID: String
    let sourceReferences: [SourceReference]
    let replayAnchor: ScenarioReplayAnchor
}

enum IntegratedScenarioEvent: Codable, Sendable, Equatable {
    case sessionStarted(
        scene: IntegratedScenarioScene,
        patternID: String,
        contentVersion: String,
        requiredActions: [ScenarioRequiredActionSnapshot]
    )
    case branchSelected(
        nodeID: String,
        conditionID: String,
        requiredActions: [ScenarioRequiredActionSnapshot]
    )
    case requiredActionCompleted(actionID: String, method: ScenarioInteractionMethod)
    case bystanderAssigned(
        bystanderID: String,
        assignment: ScenarioBystanderAssignment,
        method: ScenarioInteractionMethod
    )
    case distractionPresented(id: String, accessibilitySupportUsed: Bool)
    case analysisOutcome(index: Int, outcome: AEDAnalysisOutcome)
    case drsabc(DRSABCEvent)
    case cpr(CPRPracticeEvent)
    case aed(AEDPracticeEvent)
    case criticalError(
        errorID: String,
        code: String,
        title: String,
        systemAudioCueID: String
    )
    case correctionAcknowledged(errorID: String)
    case sessionCompleted
}

/// A type-erased, immutable record that preserves the evidence needed for replay and debrief.
/// Logical sequence, rather than wall-clock time, keeps replay deterministic.
struct IntegratedScenarioEventRecord: Codable, Identifiable, Sendable, Equatable {
    var id: Int { sequence }

    let sequence: Int
    let scenarioID: String
    let event: IntegratedScenarioEvent
    let wasAccepted: Bool
    let stateBefore: String
    let stateAfter: String
    let scoringDimension: ScoringDimension?
    let remediation: String?
    let sourceReferences: [SourceReference]
    let replayAnchor: ScenarioReplayAnchor?
    let affectsScore: Bool
}

struct ScenarioDebriefFeedback: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let code: String
    let title: String
    let remediation: String
    let dimension: ScoringDimension
    let sourceReferences: [SourceReference]
    let replayAnchor: ScenarioReplayAnchor
}

struct ScenarioDebriefTimelineItem: Codable, Identifiable, Sendable, Equatable {
    var id: Int { sequence }

    let sequence: Int
    let title: String
    let detail: String
    let wasAccepted: Bool
    let isSafetyCritical: Bool
}

struct ScenarioPracticeRecommendation: Codable, Sendable, Equatable {
    let daysUntilNextPractice: Int
    let reason: String
}

struct ScenarioDebrief: Codable, Sendable, Equatable {
    let scenarioID: String
    let scene: IntegratedScenarioScene
    let selectedPatternID: String
    let scoreOutcome: ScenarioScoreOutcome
    let timeline: [ScenarioDebriefTimelineItem]
    let feedback: [ScenarioDebriefFeedback]
    let replayAnchors: [ScenarioReplayAnchor]
    let recommendedXP: Int
    let cprCadenceAccuracy: Double?
    let longestCompressionGapSeconds: Double?
    let practiceRecommendation: ScenarioPracticeRecommendation
}

enum ScenarioEngineError: Error, Sendable, Equatable {
    case scenarioNotFound(String)
    case sceneMappingMissing(String)
    case simulationCallInvariantMissing(String)
    case randomisationMustPreserveClinicalRules(String)
    case emptyApprovedPatternPool(String)
    case duplicatePatternID(String)
    case unknownPatternID(String)
    case selectorReturnedUnapprovedPattern(String)
    case invalidShockPattern(String)
    case aedOutcomeBranchMissingSafetyAction(scenarioID: String, condition: String)
    case missingInitialBranch(String)
    case duplicateBranchID(String)
    case invalidNextBranch(nodeID: String, nextNodeID: String)
    case branchOutOfSequence(expectedNodeID: String?, actualNodeID: String)
    case branchSequenceComplete
    case unknownBranch(String)
    case unknownBranchCondition(String)
    case unknownCriticalAction(String)
    case invalidBystanderID
    case distractionNotAvailable(String)
    case noRemainingAnalysisOutcome
    case noActiveCorrection
    case malformedEventLog(expectedSequence: Int, actualSequence: Int)
    case missingSessionStart
    case inconsistentScenarioID
}
