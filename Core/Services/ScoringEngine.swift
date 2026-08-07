import Foundation

/// Safety-first deterministic scenario scoring. It never accepts depth or force inputs.
struct ScoringEngine: Sendable {
    static let weights: [ScoringDimension: Double] = Dictionary(
        uniqueKeysWithValues: ScoringDimension.allCases.map { ($0, $0.weight) }
    )

    func evaluate(
        _ input: ScenarioScoreInput,
        policy: ScoringPolicy = .standard
    ) throws -> ScenarioScoreOutcome {
        guard policy.passThreshold.isFinite,
              (0...1).contains(policy.passThreshold)
        else { throw ScoringError.invalidPassThreshold }
        guard policy.safetyDimensionFloor.isFinite,
              (0...1).contains(policy.safetyDimensionFloor)
        else { throw ScoringError.invalidSafetyFloor }

        var contributions: [DimensionScoreContribution] = []
        for dimension in ScoringDimension.allCases {
            guard let score = input.dimensionScores[dimension] else {
                throw ScoringError.missingDimension(dimension)
            }
            guard score.isFinite, (0...1).contains(score) else {
                throw ScoringError.invalidDimensionScore(dimension)
            }
            contributions.append(
                DimensionScoreContribution(
                    dimension: dimension,
                    normalisedScore: score,
                    weight: dimension.weight,
                    weightedScore: score * dimension.weight
                )
            )
        }

        let weightedScore = contributions.reduce(0) { $0 + $1.weightedScore }
        let safetyFloorFailures = contributions.filter {
            $0.dimension.isSafetyCriticalDimension &&
            $0.normalisedScore < policy.safetyDimensionFloor
        }
        let unsafe = !input.criticalErrors.isEmpty || !safetyFloorFailures.isEmpty
        let remediationCodes = (
            input.criticalErrors.map(\.code) +
            safetyFloorFailures.map { "safety_floor.\($0.dimension.rawValue)" }
        ).sorted()

        return ScenarioScoreOutcome(
            attemptID: input.attemptID,
            contentVersion: input.contentVersion,
            normalisedScore: weightedScore,
            percentage: weightedScore * 100,
            passed: !unsafe && weightedScore >= policy.passThreshold,
            hasUnsafeCompletion: unsafe,
            requiresMandatoryRemediation: unsafe,
            remediationCodes: remediationCodes,
            xpEligible: !unsafe,
            contributions: contributions
        )
    }
}
