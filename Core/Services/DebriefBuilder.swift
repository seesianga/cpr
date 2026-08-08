import Foundation

/// Builds the complete after-action review from the immutable unified event log only.
/// It has no access to a live `ScenarioEngine`, selected definition, or mutable machine state.
enum DebriefBuilder {
    static func build(
        from eventLog: [IntegratedScenarioEventRecord]
    ) throws -> ScenarioDebrief {
        for (expected, record) in eventLog.enumerated() where record.sequence != expected {
            throw ScenarioEngineError.malformedEventLog(
                expectedSequence: expected,
                actualSequence: record.sequence
            )
        }
        guard let first = eventLog.first,
              case let .sessionStarted(scene, patternID, contentVersion, requiredActions) = first.event
        else {
            throw ScenarioEngineError.missingSessionStart
        }
        guard eventLog.allSatisfy({ $0.scenarioID == first.scenarioID }) else {
            throw ScenarioEngineError.inconsistentScenarioID
        }

        let completedActionIDs = Set(eventLog.compactMap { record -> String? in
            guard record.wasAccepted, record.affectsScore,
                  case let .requiredActionCompleted(actionID, _) = record.event
            else { return nil }
            return actionID
        })

        let branchRequiredActions = eventLog.flatMap { record -> [ScenarioRequiredActionSnapshot] in
            guard case let .branchSelected(_, _, actions) = record.event else { return [] }
            return actions
        }
        let applicableActions = (requiredActions.filter(\.isAlwaysRequired) + branchRequiredActions)
            .reduce(into: [String: ScenarioRequiredActionSnapshot]()) { result, action in
                result[action.id] = action
            }
            .values

        var dimensionScores: [ScoringDimension: Double] = [:]
        for dimension in ScoringDimension.allCases {
            let dimensionActions = applicableActions.filter { $0.dimension == dimension }
            if dimensionActions.isEmpty {
                // No authored evidence in a category is neutral, never a fabricated failure.
                dimensionScores[dimension] = 1
            } else {
                let completed = dimensionActions.filter {
                    completedActionIDs.contains($0.id)
                }.count
                dimensionScores[dimension] = Double(completed) /
                    Double(dimensionActions.count)
            }
        }

        let cprEvidence = Self.cprEvidence(from: eventLog)
        if let cadenceAccuracy = cprEvidence.cadenceAccuracy,
           dimensionScores[.cprSequenceAndRhythm] != nil {
            dimensionScores[.cprSequenceAndRhythm] = min(
                dimensionScores[.cprSequenceAndRhythm] ?? 0,
                cadenceAccuracy
            )
        }

        let scoringEngine = ScoringEngine()
        let physicalPerformance = try Self.physicalEvidence(from: eventLog).flatMap {
            try scoringEngine.physicalPerformanceBreakdown(from: $0)
        }
        if let physicalPerformance {
            let cprPhysicalScores = [
                physicalPerformance.cprLocationAccuracyPercentage,
                physicalPerformance.tempoAccuracyPercentage
            ].compactMap { $0 }.map { $0 / 100 }
            if !cprPhysicalScores.isEmpty {
                let cprPhysicalScore = cprPhysicalScores.reduce(0, +) /
                    Double(cprPhysicalScores.count)
                dimensionScores[.cprSequenceAndRhythm] = min(
                    dimensionScores[.cprSequenceAndRhythm] ?? 1,
                    cprPhysicalScore
                )
            }
            if let padScore = physicalPerformance.padPlacementAccuracyPercentage {
                dimensionScores[.aedPreparationAndPlacement] = min(
                    dimensionScores[.aedPreparationAndPlacement] ?? 1,
                    padScore / 100
                )
            }
        }

        var debriefFeedback: [ScenarioDebriefFeedback] = []
        var criticalErrors: [CriticalError] = []
        var seenErrorIDs: Set<String> = []
        for record in eventLog {
            guard case let .criticalError(errorID, code, title, _) = record.event,
                  let dimension = record.scoringDimension,
                  let remediation = record.remediation,
                  let replayAnchor = record.replayAnchor
            else { continue }
            if seenErrorIDs.insert(errorID).inserted {
                criticalErrors.append(
                    CriticalError(id: errorID, code: code, remediation: remediation)
                )
            }
            debriefFeedback.append(
                ScenarioDebriefFeedback(
                    id: "\(errorID)-\(record.sequence)",
                    code: code,
                    title: title,
                    remediation: remediation,
                    dimension: dimension,
                    sourceReferences: record.sourceReferences,
                    replayAnchor: replayAnchor
                )
            )
        }

        let scoreOutcome = try scoringEngine.evaluate(
            ScenarioScoreInput(
                attemptID: "\(first.scenarioID)-event-log",
                contentVersion: contentVersion,
                dimensionScores: dimensionScores,
                criticalErrors: criticalErrors
            )
        )
        let timeline = eventLog.map(Self.timelineItem)
        let replayAnchors = debriefFeedback
            .map(\.replayAnchor)
            .reduce(into: [ScenarioReplayAnchor]()) { result, anchor in
                guard !result.contains(where: { $0.sequence == anchor.sequence }) else { return }
                result.append(anchor)
            }
        // Scenario attempts use the same fixed safe-attempt award surfaced by
        // GamificationEngine and the dashboard; percentages remain score feedback.
        let recommendedXP = scoreOutcome.xpEligible ? 100 : 0

        return ScenarioDebrief(
            scenarioID: first.scenarioID,
            scene: scene,
            selectedPatternID: patternID,
            scoreOutcome: scoreOutcome,
            timeline: timeline,
            feedback: debriefFeedback,
            replayAnchors: replayAnchors,
            recommendedXP: recommendedXP,
            cprCadenceAccuracy: cprEvidence.cadenceAccuracy,
            longestCompressionGapSeconds: cprEvidence.longestGap,
            physicalPerformance: physicalPerformance,
            practiceRecommendation: recommendation(
                score: scoreOutcome,
                feedback: debriefFeedback
            )
        )
    }

    private static func timelineItem(
        _ record: IntegratedScenarioEventRecord
    ) -> ScenarioDebriefTimelineItem {
        let title: String
        let detail: String
        let safetyCritical: Bool
        switch record.event {
        case let .sessionStarted(scene, patternID, _, _):
            title = "Scenario started"
            detail = "\(scene.rawValue), approved pattern \(patternID)"
            safetyCritical = false
        case let .branchSelected(nodeID, conditionID, requiredActions):
            title = "Branch selected"
            detail = "\(nodeID): \(conditionID); \(requiredActions.count) authored actions apply"
            safetyCritical = false
        case let .requiredActionCompleted(actionID, method):
            title = record.wasAccepted ? "Required action completed" : "Action already recorded"
            detail = "\(actionID) using \(method.rawValue)"
            safetyCritical = false
        case let .bystanderAssigned(bystanderID, assignment, method):
            title = "Bystander task assigned"
            detail = "\(bystanderID): \(assignment.displayName) using \(method.rawValue)"
            safetyCritical = false
        case let .distractionPresented(id, accessibilitySupportUsed):
            title = "Contextual distraction"
            detail = accessibilitySupportUsed
                ? "\(id); accessibility support used without penalty"
                : id
            safetyCritical = false
        case let .analysisOutcome(index, outcome):
            title = "AED analysis \(index + 1)"
            detail = outcome.rawValue
            safetyCritical = true
        case .drsabc:
            title = "DRSABC event"
            detail = "\(record.stateBefore) → \(record.stateAfter)"
            safetyCritical = record.remediation != nil
        case .cpr:
            title = "CPR event"
            detail = "\(record.stateBefore) → \(record.stateAfter)"
            safetyCritical = record.remediation != nil
        case .aed:
            title = "AED event"
            detail = "\(record.stateBefore) → \(record.stateAfter)"
            safetyCritical = record.remediation != nil
        case let .criticalError(_, code, titleValue, _):
            title = titleValue
            detail = record.remediation ?? code
            safetyCritical = true
        case .correctionAcknowledged:
            title = "Guided retry started"
            detail = "The source-backed correction remains in the event record."
            safetyCritical = true
        case .sessionCompleted:
            title = "Scenario completed"
            detail = "After-action review is available."
            safetyCritical = false
        }
        return ScenarioDebriefTimelineItem(
            sequence: record.sequence,
            title: title,
            detail: detail,
            wasAccepted: record.wasAccepted,
            isSafetyCritical: safetyCritical
        )
    }

    private static func cprEvidence(
        from eventLog: [IntegratedScenarioEventRecord]
    ) -> (cadenceAccuracy: Double?, longestGap: Double?) {
        let timestamps = eventLog.compactMap { record -> TimeInterval? in
            guard record.wasAccepted,
                  case let .cpr(.compressionDetected(timestamp, placement, _)) = record.event,
                  placement == .sternumTarget
            else { return nil }
            return timestamp
        }
        guard timestamps.count >= 2 else { return (nil, nil) }
        let gaps = zip(timestamps.dropFirst(), timestamps).compactMap { current, previous in
            let gap = current - previous
            return gap.isFinite && gap > 0 ? gap : nil
        }
        guard !gaps.isEmpty else { return (nil, nil) }
        let inBand = gaps.filter { gap in
            let cadence = 60 / gap
            return CPRPracticePolicy.sourceBacked.contains(rate: cadence)
        }.count
        return (
            Double(inBand) / Double(gaps.count),
            gaps.max()
        )
    }

    /// Physical performance is opt-in: the typed physical-pad event is the provenance
    /// marker. An all-accessible attempt therefore retains its existing category score and
    /// never receives a fabricated physical zero.
    private static func physicalEvidence(
        from eventLog: [IntegratedScenarioEventRecord]
    ) -> PhysicalPerformanceEvidence? {
        let padPlacements = eventLog.compactMap { record -> AEDPhysicalPadPlacement? in
            guard record.wasAccepted,
                  case let .aed(.placePhysicalPad(placement)) = record.event
            else { return nil }
            return placement
        }
        guard !padPlacements.isEmpty else { return nil }

        let compressions = eventLog.compactMap {
            record -> (timestamp: Double, placement: CPRHandPlacementZone)? in
            guard record.wasAccepted,
                  case let .cpr(.compressionDetected(timestamp, placement, _)) = record.event
            else { return nil }
            return (timestamp, placement)
        }
        return PhysicalPerformanceEvidence(
            compressionPlacements: compressions.map(\.placement),
            compressionTimestamps: compressions.map(\.timestamp),
            padPlacements: padPlacements
        )
    }

    private static func recommendation(
        score: ScenarioScoreOutcome,
        feedback: [ScenarioDebriefFeedback]
    ) -> ScenarioPracticeRecommendation {
        if let firstSafetyError = feedback.first {
            return ScenarioPracticeRecommendation(
                daysUntilNextPractice: 1,
                reason: "Revisit \(firstSafetyError.dimension.displayName.lowercased()) with the guided correction."
            )
        }
        if !score.passed {
            return ScenarioPracticeRecommendation(
                daysUntilNextPractice: 3,
                reason: "Repeat the integrated sequence while the source-backed steps are fresh."
            )
        }
        if score.percentage < 90 {
            return ScenarioPracticeRecommendation(
                daysUntilNextPractice: 7,
                reason: "A one-week review will reinforce the least-complete category."
            )
        }
        return ScenarioPracticeRecommendation(
            daysUntilNextPractice: 14,
            reason: "Maintain mastery with a calm two-week refresher."
        )
    }
}
