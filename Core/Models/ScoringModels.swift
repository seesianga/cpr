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

/// Practice-only feedback dimensions. These are deliberately separate from the
/// integrated-scenario dimensions: CPR practice does not fabricate scene-safety,
/// communication, AED, or call-timing evidence that the session did not collect.
enum CPRPracticeScoringDimension: String, Codable, Sendable, CaseIterable, Hashable {
    case handPlacement
    case cadenceBand
    case interruptions
    case postureHeuristic

    var displayName: String {
        switch self {
        case .handPlacement: "Hand placement"
        case .cadenceBand: "Compression cadence"
        case .interruptions: "Compression interruptions"
        case .postureHeuristic: "Two-hand posture heuristic"
        }
    }

    /// Equal weighting avoids presenting a project-authored weighting as clinical guidance.
    /// Unavailable heuristic dimensions are excluded from the assessed-weight denominator.
    var feedbackWeight: Double { 0.25 }
}

struct CPRPracticeScoreInput: Codable, Sendable, Equatable {
    let attemptID: String
    let contentVersion: String
    let metrics: CPRPracticeMetrics
    let criticalFailures: [CPRPracticeCriticalFailure]
}

struct CPRPracticeScoreContribution: Codable, Sendable, Equatable {
    let dimension: CPRPracticeScoringDimension
    /// `nil` means the interaction mode could not assess this dimension. It is not a zero.
    let normalisedScore: Double?
    let configuredWeight: Double
    let evidenceCount: Int

    var weightedScore: Double {
        (normalisedScore ?? 0) * configuredWeight
    }

    var wasAssessed: Bool { normalisedScore != nil }
}

struct CPRPracticeScoreOutcome: Codable, Sendable, Equatable {
    let attemptID: String
    let contentVersion: String
    let normalisedScore: Double
    let percentage: Double
    let passed: Bool
    let hasUnsafeCompletion: Bool
    let requiresMandatoryRemediation: Bool
    let remediationCodes: [String]
    let xpEligible: Bool
    let contributions: [CPRPracticeScoreContribution]
}

enum CPRPracticeScoringError: Error, Codable, Sendable, Equatable {
    case invalidPassThreshold
    case invalidMetrics
}

struct CPRPracticeScoringPolicy: Codable, Sendable, Equatable {
    let passThreshold: Double

    static let standard = CPRPracticeScoringPolicy(passThreshold: 0.80)
}

enum CPRPhysicalMetric: String, Codable, Sendable, CaseIterable {
    case compressionDepth
    case compressionForce

    var displayName: String {
        switch self {
        case .compressionDepth: "Compression depth"
        case .compressionForce: "Compression force"
        }
    }
}

enum CPRPhysicalMeasurementUnit: String, Codable, Sendable {
    case metres
    case newtons
}

enum CPRPhysicalAssessmentStatus: String, Codable, Sendable {
    case notPhysicallyAssessed
    case verifiedExternalSensor

    var displayLabel: String {
        switch self {
        case .notPhysicallyAssessed: "Not physically assessed"
        case .verifiedExternalSensor: "Measured by verified external sensor"
        }
    }
}

/// A physical value can only be created by the scoring summary factory after it has
/// verified the `CPRSensorProvider` connection. Vision-derived values have no path here.
struct CPRPhysicalAssessment: Codable, Sendable, Equatable {
    let metric: CPRPhysicalMetric
    let status: CPRPhysicalAssessmentStatus
    let value: Double?
    let unit: CPRPhysicalMeasurementUnit?
    let providerIdentifier: String?
    let capturedAt: Date?

    var statusLabel: String { status.displayLabel }

    private init(
        metric: CPRPhysicalMetric,
        status: CPRPhysicalAssessmentStatus,
        value: Double?,
        unit: CPRPhysicalMeasurementUnit?,
        providerIdentifier: String?,
        capturedAt: Date?
    ) {
        self.metric = metric
        self.status = status
        self.value = value
        self.unit = unit
        self.providerIdentifier = providerIdentifier
        self.capturedAt = capturedAt
    }

    static func notAssessed(_ metric: CPRPhysicalMetric) -> Self {
        Self(
            metric: metric,
            status: .notPhysicallyAssessed,
            value: nil,
            unit: nil,
            providerIdentifier: nil,
            capturedAt: nil
        )
    }

    static func verified(
        _ metric: CPRPhysicalMetric,
        value: Double,
        unit: CPRPhysicalMeasurementUnit,
        measurement: CPRSensorMeasurement
    ) -> Self {
        Self(
            metric: metric,
            status: .verifiedExternalSensor,
            value: value,
            unit: unit,
            providerIdentifier: measurement.providerIdentifier,
            capturedAt: measurement.capturedAt
        )
    }
}

struct CPRPracticeSessionSummary: Codable, Sendable, Equatable {
    static let internalRecordLabel = "Internal practice completion record"
    static let certificationNotice =
        "This is not SRFAC certification. Practical competency requires instructor sign-off."

    let scoreOutcome: CPRPracticeScoreOutcome
    let totalCompressions: Int
    let completedCycles: Int
    let averageCadencePerMinute: Double?
    let longestInterruptionSeconds: Double
    let depthAssessment: CPRPhysicalAssessment
    let forceAssessment: CPRPhysicalAssessment
    let recordLabel: String
    let certificationNotice: String
}

struct CPRPracticeGamificationEvent: Codable, Sendable, Equatable {
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let sourceAttemptID: String
    let completedAt: Date
    let scoreOutcome: CPRPracticeScoreOutcome
}
