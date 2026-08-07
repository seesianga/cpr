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

    /// Scores only evidence collected by `CPRPracticeStateMachine`. A missing posture or
    /// placement heuristic is omitted rather than converted into a false failure, keeping
    /// the gaze-pinch/tap fallback path usable when hand tracking is unavailable.
    func evaluate(
        _ input: CPRPracticeScoreInput,
        policy: CPRPracticeScoringPolicy = .standard
    ) throws -> CPRPracticeScoreOutcome {
        guard policy.passThreshold.isFinite,
              (0...1).contains(policy.passThreshold)
        else { throw CPRPracticeScoringError.invalidPassThreshold }
        guard Self.hasValidPracticeMetrics(input.metrics) else {
            throw CPRPracticeScoringError.invalidMetrics
        }

        let contributions = Self.practiceContributions(from: input.metrics)
        let assessedWeight = contributions.reduce(0) { result, contribution in
            result + (contribution.wasAssessed ? contribution.configuredWeight : 0)
        }
        let weightedScore = contributions.reduce(0) { $0 + $1.weightedScore }
        let normalisedScore = assessedWeight > 0 ? weightedScore / assessedWeight : 0

        var remediationCodes = Set(input.criticalFailures.map(\.rawValue))
        if input.metrics.latestHandPlacement == .xiphoidAvoidZone {
            remediationCodes.insert(CPRPracticeCriticalFailure.compressionOnXiphoid.rawValue)
        }
        if input.metrics.interruptions.contains(where: \.exceededSupportedMaximum) {
            remediationCodes.insert(CPRPracticeCriticalFailure.prolongedInterruption.rawValue)
        }
        let sortedRemediationCodes = remediationCodes.sorted()
        let unsafe = !sortedRemediationCodes.isEmpty
        // A completion record and XP require at least one source-backed practice cycle;
        // a single interaction sample is feedback evidence, not a completed practice.
        let hasPracticeEvidence = input.metrics.totalCompressions > 0 &&
            input.metrics.completedCycles > 0

        return CPRPracticeScoreOutcome(
            attemptID: input.attemptID,
            contentVersion: input.contentVersion,
            normalisedScore: normalisedScore,
            percentage: normalisedScore * 100,
            passed: hasPracticeEvidence && !unsafe && normalisedScore >= policy.passThreshold,
            hasUnsafeCompletion: unsafe,
            requiresMandatoryRemediation: unsafe,
            remediationCodes: sortedRemediationCodes,
            // Mirrors scenario scoring: a safe completed attempt may earn the configured
            // completion XP even when its feedback score remains below the pass threshold.
            xpEligible: hasPracticeEvidence && !unsafe,
            contributions: contributions
        )
    }

    /// Produces an internal practice summary. Sensor errors or unverified connections
    /// degrade safely to "Not physically assessed" and never prevent session completion.
    func summarize(
        _ input: CPRPracticeScoreInput,
        policy: CPRPracticeScoringPolicy = .standard,
        sensorProvider: (any CPRSensorProvider)? = nil
    ) async throws -> CPRPracticeSessionSummary {
        let scoreOutcome = try evaluate(input, policy: policy)
        let physicalAssessments = await Self.physicalAssessments(from: sensorProvider)

        return CPRPracticeSessionSummary(
            scoreOutcome: scoreOutcome,
            totalCompressions: input.metrics.totalCompressions,
            completedCycles: input.metrics.completedCycles,
            averageCadencePerMinute: input.metrics.averageCadencePerMinute,
            longestInterruptionSeconds: input.metrics.longestInterruptionSeconds,
            depthAssessment: physicalAssessments.depth,
            forceAssessment: physicalAssessments.force,
            recordLabel: CPRPracticeSessionSummary.internalRecordLabel,
            certificationNotice: CPRPracticeSessionSummary.certificationNotice
        )
    }

    private static func practiceContributions(
        from metrics: CPRPracticeMetrics
    ) -> [CPRPracticeScoreContribution] {
        CPRPracticeScoringDimension.allCases.map { dimension in
            switch dimension {
            case .handPlacement:
                let score: Double?
                switch metrics.latestHandPlacement {
                case .sternumTarget: score = 1
                case .xiphoidAvoidZone, .outsideTarget: score = 0
                case .unavailable: score = nil
                }
                return CPRPracticeScoreContribution(
                    dimension: dimension,
                    normalisedScore: score,
                    configuredWeight: dimension.feedbackWeight,
                    evidenceCount: score == nil ? 0 : 1
                )

            case .cadenceBand:
                let inBandCount = metrics.cadenceBands.reduce(into: 0) { count, band in
                    if band == .withinSupportedBand { count += 1 }
                }
                let score = metrics.cadenceBands.isEmpty
                    ? 0
                    : Double(inBandCount) / Double(metrics.cadenceBands.count)
                return CPRPracticeScoreContribution(
                    dimension: dimension,
                    normalisedScore: score,
                    configuredWeight: dimension.feedbackWeight,
                    evidenceCount: metrics.cadenceBands.count
                )

            case .interruptions:
                let supportedCount = metrics.interruptions.reduce(into: 0) {
                    count,
                    interruption in
                    if !interruption.exceededSupportedMaximum { count += 1 }
                }
                let score = metrics.interruptions.isEmpty
                    ? 1
                    : Double(supportedCount) / Double(metrics.interruptions.count)
                return CPRPracticeScoreContribution(
                    dimension: dimension,
                    normalisedScore: score,
                    configuredWeight: dimension.feedbackWeight,
                    evidenceCount: metrics.interruptions.count
                )

            case .postureHeuristic:
                let assessableSamples = metrics.handStackingSamples.filter {
                    $0 != .indeterminate
                }
                let likelyStackedCount = assessableSamples.reduce(into: 0) { count, sample in
                    if sample == .likelyStacked { count += 1 }
                }
                let score = assessableSamples.isEmpty
                    ? nil
                    : Double(likelyStackedCount) / Double(assessableSamples.count)
                return CPRPracticeScoreContribution(
                    dimension: dimension,
                    normalisedScore: score,
                    configuredWeight: dimension.feedbackWeight,
                    evidenceCount: assessableSamples.count
                )
            }
        }
    }

    private static func hasValidPracticeMetrics(_ metrics: CPRPracticeMetrics) -> Bool {
        guard metrics.totalCompressions >= 0,
              metrics.completedCycles >= 0,
              metrics.compressionsSinceRest >= 0,
              metrics.compressionTimestamps.count == metrics.totalCompressions,
              metrics.handStackingSamples.count == metrics.totalCompressions,
              metrics.cadenceSamplesPerMinute.count == max(0, metrics.totalCompressions - 1),
              metrics.cadenceBands.count == metrics.cadenceSamplesPerMinute.count,
              metrics.cadenceSamplesPerMinute.allSatisfy({ $0.isFinite && $0 > 0 }),
              metrics.compressionTimestamps.allSatisfy({ $0.isFinite && $0 >= 0 }),
              zip(
                  metrics.compressionTimestamps,
                  metrics.compressionTimestamps.dropFirst()
              ).allSatisfy({ $0.0 < $0.1 }),
              metrics.interruptions.allSatisfy({ interruption in
                  interruption.afterCompressionCount >= 0 &&
                  interruption.afterCompressionCount <= metrics.totalCompressions &&
                  interruption.durationSeconds.isFinite &&
                  interruption.durationSeconds >= 0
              })
        else { return false }
        return true
    }

    private static func physicalAssessments(
        from provider: (any CPRSensorProvider)?
    ) async -> (depth: CPRPhysicalAssessment, force: CPRPhysicalAssessment) {
        let notAssessed = (
            depth: CPRPhysicalAssessment.notAssessed(.compressionDepth),
            force: CPRPhysicalAssessment.notAssessed(.compressionForce)
        )
        guard let provider,
              await provider.isVerifiedExternalSensorConnected,
              let measurement = try? await provider.latestMeasurement(),
              !measurement.providerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return notAssessed }

        let depth: CPRPhysicalAssessment
        if let value = measurement.compressionDepthMetres,
           value.isFinite,
           value >= 0 {
            depth = .verified(
                .compressionDepth,
                value: value,
                unit: .metres,
                measurement: measurement
            )
        } else {
            depth = notAssessed.depth
        }

        let force: CPRPhysicalAssessment
        if let value = measurement.forceNewtons,
           value.isFinite,
           value >= 0 {
            force = .verified(
                .compressionForce,
                value: value,
                unit: .newtons,
                measurement: measurement
            )
        } else {
            force = notAssessed.force
        }
        return (depth, force)
    }
}
