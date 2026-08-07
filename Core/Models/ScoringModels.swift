import Foundation

enum ScoringDimension: String, Codable, Sendable, CaseIterable, Hashable {
    case sceneSafety
    case recognitionAndActivation
    case cprSequenceAndRhythm
    case aedPreparationAndPlacement
    case communication
    case time

    var weight: Double {
        switch self {
        case .sceneSafety: 0.20
        case .recognitionAndActivation: 0.20
        case .cprSequenceAndRhythm: 0.25
        case .aedPreparationAndPlacement: 0.20
        case .communication: 0.10
        case .time: 0.05
        }
    }

    var displayName: String {
        switch self {
        case .sceneSafety: "Scene safety"
        case .recognitionAndActivation: "Recognition and activation"
        case .cprSequenceAndRhythm: "CPR sequence and rhythm"
        case .aedPreparationAndPlacement: "AED preparation and placement"
        case .communication: "Communication"
        case .time: "Time"
        }
    }

    var isSafetyCriticalDimension: Bool {
        switch self {
        case .sceneSafety, .recognitionAndActivation,
             .cprSequenceAndRhythm, .aedPreparationAndPlacement:
            true
        case .communication, .time:
            false
        }
    }
}

struct CriticalError: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let code: String
    let remediation: String
}

struct ScenarioScoreInput: Codable, Sendable, Equatable {
    let attemptID: String
    let contentVersion: String
    let dimensionScores: [ScoringDimension: Double]
    let criticalErrors: [CriticalError]
}

struct DimensionScoreContribution: Codable, Sendable, Equatable {
    let dimension: ScoringDimension
    let normalisedScore: Double
    let weight: Double
    let weightedScore: Double
}

struct ScenarioScoreOutcome: Codable, Sendable, Equatable {
    let attemptID: String
    let contentVersion: String
    let normalisedScore: Double
    let percentage: Double
    let passed: Bool
    let hasUnsafeCompletion: Bool
    let requiresMandatoryRemediation: Bool
    let remediationCodes: [String]
    let xpEligible: Bool
    let contributions: [DimensionScoreContribution]
}

enum ScoringError: Error, Sendable, Equatable {
    case missingDimension(ScoringDimension)
    case invalidDimensionScore(ScoringDimension)
    case invalidPassThreshold
    case invalidSafetyFloor
}

struct ScoringPolicy: Codable, Sendable, Equatable {
    let passThreshold: Double
    let safetyDimensionFloor: Double

    static let standard = ScoringPolicy(
        passThreshold: 0.80,
        safetyDimensionFloor: 0.60
    )
}
