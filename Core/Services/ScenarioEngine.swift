import Foundation

protocol ScenarioPatternSelecting: Sendable {
    func selectPatternID(from approvedPatternIDs: [String], scenarioID: String) -> String?
}

struct RandomScenarioPatternSelector: ScenarioPatternSelecting {
    func selectPatternID(from approvedPatternIDs: [String], scenarioID: String) -> String? {
        approvedPatternIDs.randomElement()
    }
}

struct DeterministicScenarioPatternSelector: ScenarioPatternSelecting {
    let patternID: String

    func selectPatternID(from approvedPatternIDs: [String], scenarioID: String) -> String? {
        patternID
    }
}

/// Orchestrates an authored scenario while retaining the Phase 5A reducers as the only
/// owners of DRSABC, CPR, and AED clinical transitions.
struct ScenarioEngine: Sendable {
    static let sceneByScenarioID: [String: IntegratedScenarioScene] = [
        "scenario-a-home": .home,
        "scenario-b-shopping-centre": .shoppingCentre,
        "scenario-c-workplace": .workplace,
        "scenario-d-community-facility": .communityFacility
    ]

    let definition: ScenarioDefinition
    let contentVersion: String
    let scene: IntegratedScenarioScene
    let selectedPattern: ScenarioShockPattern
    let approvedPatternIDs: [String]

    private var drsabcMachine = DRSABCStateMachine()
    private var cprMachine = CPRPracticeStateMachine()
    private var aedMachine = AEDStateMachine(
        requiredChestConditions: Set(AEDChestCondition.allCases)
    )
    private var records: [IntegratedScenarioEventRecord] = []
    private var completedActionIDs: Set<String> = []
    private var analysisIndex = 0

    private(set) var currentCorrection: ScenarioCriticalCorrection?
    private(set) var currentBranchNodeID: String?

    var eventLog: [IntegratedScenarioEventRecord] { records }
    var drsabcState: DRSABCState { drsabcMachine.state }
    var cprState: CPRPracticeState { cprMachine.state }
    var aedState: AEDPracticeState { aedMachine.state }

    /// Pattern selection never participates in these safety rules.
    var clinicalRulesSignature: String {
        "DRSABC.maxBreathing=10;AED.near=60;CPR.rate=100...120;" +
            "AED.clearBeforeAnalysis=true;AED.clearBeforeShock=true;AED.resumeAfterEither=true"
    }

    init(
        document: ScenarioDefinitionsDocument,
        scenarioID: String,
        selector: any ScenarioPatternSelecting = RandomScenarioPatternSelector()
    ) throws {
        guard let definition = document.scenarios.first(where: { $0.id == scenarioID }) else {
            throw ScenarioEngineError.scenarioNotFound(scenarioID)
        }
        guard let scene = Self.sceneByScenarioID[scenarioID] else {
            throw ScenarioEngineError.sceneMappingMissing(scenarioID)
        }
        guard definition.initialState.values["simulation995Only"] == .boolean(true) else {
            throw ScenarioEngineError.simulationCallInvariantMissing(scenarioID)
        }
        guard definition.randomisation.clinicalRulesInvariant else {
            throw ScenarioEngineError.randomisationMustPreserveClinicalRules(scenarioID)
        }

        let approvedPatternIDs = definition.randomisation.shockPatternIDs
        guard !approvedPatternIDs.isEmpty else {
            throw ScenarioEngineError.emptyApprovedPatternPool(scenarioID)
        }
        guard Set(approvedPatternIDs).count == approvedPatternIDs.count else {
            throw ScenarioEngineError.duplicatePatternID(scenarioID)
        }

        var patternsByID: [String: ScenarioShockPattern] = [:]
        for pattern in document.shockPatterns {
            guard patternsByID.updateValue(pattern, forKey: pattern.id) == nil else {
                throw ScenarioEngineError.duplicatePatternID(pattern.id)
            }
        }
        for patternID in approvedPatternIDs where patternsByID[patternID] == nil {
            throw ScenarioEngineError.unknownPatternID(patternID)
        }
        guard let selectedID = selector.selectPatternID(
            from: approvedPatternIDs,
            scenarioID: scenarioID
        ), approvedPatternIDs.contains(selectedID), let selectedPattern = patternsByID[selectedID]
        else {
            throw ScenarioEngineError.selectorReturnedUnapprovedPattern(scenarioID)
        }
        guard !selectedPattern.analysisOutcomes.isEmpty,
              selectedPattern.analysisOutcomes.allSatisfy({ outcome in
                  outcome == .shock || outcome == .noShock
              })
        else {
            throw ScenarioEngineError.invalidShockPattern(selectedPattern.id)
        }
        let authoredInitialBranchNodeID = "\(scenarioID)-branch-scene-safety"
        guard definition.branchingNodes.contains(where: {
            $0.id == authoredInitialBranchNodeID
        }) else {
            throw ScenarioEngineError.missingInitialBranch(scenarioID)
        }
        let branchNodeIDs = Set(definition.branchingNodes.map(\.id))
        let criticalActionIDs = Set(definition.criticalActions.map(\.id))
        guard branchNodeIDs.count == definition.branchingNodes.count else {
            throw ScenarioEngineError.duplicateBranchID(scenarioID)
        }
        for node in definition.branchingNodes {
            for condition in node.conditions {
                if let nextNodeID = condition.nextNodeID,
                   !branchNodeIDs.contains(nextNodeID) {
                    throw ScenarioEngineError.invalidNextBranch(
                        nodeID: node.id,
                        nextNodeID: nextNodeID
                    )
                }
                if let unknownActionID = condition.requiredActionIDs.first(where: {
                    !criticalActionIDs.contains($0)
                }) {
                    throw ScenarioEngineError.unknownCriticalAction(unknownActionID)
                }
            }
        }
        try Self.validateAEDOutcomeBranches(in: definition)

        self.definition = definition
        self.contentVersion = document.contentVersion
        self.scene = scene
        self.selectedPattern = selectedPattern
        self.approvedPatternIDs = approvedPatternIDs
        self.currentBranchNodeID = authoredInitialBranchNodeID

        let requiredActions = definition.criticalActions.map {
                ScenarioRequiredActionSnapshot(
                    id: $0.id,
                    title: $0.title,
                    dimension: $0.scoringCategory,
                    isAlwaysRequired: $0.isRequired
                )
            }
        append(
            event: .sessionStarted(
                scene: scene,
                patternID: selectedPattern.id,
                contentVersion: document.contentVersion,
                requiredActions: requiredActions
            ),
            stateBefore: "notStarted",
            stateAfter: "active",
            affectsScore: false
        )
    }

    static func loadBundled(
        scenarioID: String,
        selector: any ScenarioPatternSelecting = RandomScenarioPatternSelector(),
        bundle: Bundle = .main
    ) throws -> ScenarioEngine {
        try ScenarioEngine(
            document: ScenarioDefinitionsCodec.load(from: bundle),
            scenarioID: scenarioID,
            selector: selector
        )
    }

    mutating func selectBranch(nodeID: String, conditionID: String) throws {
        guard let expectedNodeID = currentBranchNodeID else {
            throw ScenarioEngineError.branchSequenceComplete
        }
        guard expectedNodeID == nodeID else {
            throw ScenarioEngineError.branchOutOfSequence(
                expectedNodeID: expectedNodeID,
                actualNodeID: nodeID
            )
        }
        guard let node = definition.branchingNodes.first(where: { $0.id == nodeID }) else {
            throw ScenarioEngineError.unknownBranch(nodeID)
        }
        guard let condition = node.conditions.first(where: { $0.id == conditionID }) else {
            throw ScenarioEngineError.unknownBranchCondition(conditionID)
        }
        let requiredActions = condition.requiredActionIDs.compactMap { actionID in
            definition.criticalActions.first(where: { $0.id == actionID }).map {
                ScenarioRequiredActionSnapshot(
                    id: $0.id,
                    title: $0.title,
                    dimension: $0.scoringCategory,
                    isAlwaysRequired: $0.isRequired
                )
            }
        }
        append(
            event: .branchSelected(
                nodeID: nodeID,
                conditionID: condition.id,
                requiredActions: requiredActions
            ),
            stateBefore: nodeID,
            stateAfter: condition.nextNodeID ?? "branchComplete",
            sourceReferences: condition.sourceReferences,
            affectsScore: false
        )
        currentBranchNodeID = condition.nextNodeID
    }

    /// Selects only from the authored node reached by the prior branch. This prevents
    /// callers from searching the graph for a convenient condition and skipping nodes.
    mutating func selectBranch(condition: String) throws {
        guard let nodeID = currentBranchNodeID else {
            throw ScenarioEngineError.branchSequenceComplete
        }
        guard let node = definition.branchingNodes.first(where: { $0.id == nodeID }) else {
            throw ScenarioEngineError.unknownBranch(nodeID)
        }
        guard let selected = node.conditions.first(where: { $0.condition == condition }) else {
            throw ScenarioEngineError.unknownBranchCondition(condition)
        }
        try selectBranch(nodeID: nodeID, conditionID: selected.id)
    }

    mutating func completeAction(
        _ actionID: String,
        method: ScenarioInteractionMethod = .gazeAndPinch
    ) throws {
        guard let action = definition.criticalActions.first(where: { $0.id == actionID }) else {
            throw ScenarioEngineError.unknownCriticalAction(actionID)
        }
        let inserted = completedActionIDs.insert(actionID).inserted
        append(
            event: .requiredActionCompleted(actionID: actionID, method: method),
            wasAccepted: inserted,
            stateBefore: inserted ? "pending" : "alreadyComplete",
            stateAfter: "complete",
            scoringDimension: action.scoringCategory,
            sourceReferences: action.sourceReferences,
            affectsScore: inserted
        )
    }

    mutating func assignBystander(
        _ bystanderID: String,
        assignment: ScenarioBystanderAssignment,
        method: ScenarioInteractionMethod
    ) throws {
        guard !bystanderID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ScenarioEngineError.invalidBystanderID
        }
        append(
            event: .bystanderAssigned(
                bystanderID: bystanderID,
                assignment: assignment,
                method: method
            ),
            stateBefore: "available",
            stateAfter: assignment.rawValue,
            affectsScore: false
        )

        let suffixes: [String] = switch assignment {
        case .callSimulated995: ["action-activate-help", "action-communicate-clearly"]
        case .getAED: ["action-manage-aed-retrieval"]
        }
        for suffix in suffixes {
            let actionID = "\(definition.id)-\(suffix)"
            if definition.criticalActions.contains(where: { $0.id == actionID }) {
                try completeAction(actionID, method: method)
            }
        }
    }

    /// Shopping-centre distractions are context only. Accessibility support never changes score.
    mutating func presentScenarioBDistraction(
        id: String,
        accessibilitySupportUsed: Bool
    ) throws {
        guard definition.id == "scenario-b-shopping-centre" else {
            throw ScenarioEngineError.distractionNotAvailable(definition.id)
        }
        append(
            event: .distractionPresented(
                id: id,
                accessibilitySupportUsed: accessibilitySupportUsed
            ),
            stateBefore: "scenarioActive",
            stateAfter: "scenarioActive",
            affectsScore: false
        )
    }

    mutating func nextAnalysisOutcome() throws -> AEDAnalysisOutcome {
        guard analysisIndex < selectedPattern.analysisOutcomes.count else {
            throw ScenarioEngineError.noRemainingAnalysisOutcome
        }
        let index = analysisIndex
        let outcome = selectedPattern.analysisOutcomes[index]
        analysisIndex += 1
        append(
            event: .analysisOutcome(index: index, outcome: outcome),
            stateBefore: "analysis\(index)",
            stateAfter: outcome.rawValue,
            affectsScore: false
        )
        return outcome
    }

    @discardableResult
    mutating func submit(
        _ event: DRSABCEvent
    ) -> IntegratedScenarioEventRecord {
        let failuresBefore = Set(drsabcMachine.criticalFailures.map(\.rawValue))
        let entry = drsabcMachine.handle(event)
        let remediation = Self.remediation(from: entry.outcome)
        let record = append(
            event: .drsabc(event),
            wasAccepted: entry.wasAccepted,
            stateBefore: String(describing: entry.stateBefore),
            stateAfter: String(describing: entry.stateAfter),
            remediation: remediation?.message,
            sourceReferences: sourceReferences(for: remediation?.sourceFactIDs ?? []),
            replayDomain: .drsabc,
            affectsScore: false
        )
        let failuresAfter = Set(drsabcMachine.criticalFailures.map(\.rawValue))
        let newFailures = failuresAfter.subtracting(failuresBefore)
        registerFailures(
            newFailures,
            fallbackRemediation: remediation?.message,
            fallbackFactIDs: remediation?.sourceFactIDs ?? [],
            anchorRecord: record,
            affectsScore: true
        )
        if newFailures.isEmpty,
           let repeatedCode = Self.criticalCode(for: remediation),
           failuresAfter.contains(repeatedCode) {
            registerFailures(
                [repeatedCode],
                fallbackRemediation: remediation?.message,
                fallbackFactIDs: remediation?.sourceFactIDs ?? [],
                anchorRecord: record,
                affectsScore: false
            )
        }
        return record
    }

    @discardableResult
    mutating func submit(
        _ event: CPRPracticeEvent
    ) -> IntegratedScenarioEventRecord {
        let failuresBefore = Set(cprMachine.criticalFailures.map(\.rawValue))
        let entry = cprMachine.handle(event)
        let remediation = Self.remediation(from: entry.outcome)
        let record = append(
            event: .cpr(event),
            wasAccepted: entry.wasAccepted,
            stateBefore: entry.stateBefore.rawValue,
            stateAfter: entry.stateAfter.rawValue,
            remediation: remediation?.message,
            sourceReferences: sourceReferences(for: remediation?.sourceFactIDs ?? []),
            replayDomain: .cpr,
            affectsScore: false
        )
        let failuresAfter = Set(cprMachine.criticalFailures.map(\.rawValue))
        let newFailures = failuresAfter.subtracting(failuresBefore)
        registerFailures(
            newFailures,
            fallbackRemediation: remediation?.message,
            fallbackFactIDs: remediation?.sourceFactIDs ?? [],
            anchorRecord: record,
            affectsScore: true
        )
        if newFailures.isEmpty,
           let repeatedCode = Self.criticalCode(for: remediation),
           failuresAfter.contains(repeatedCode) {
            registerFailures(
                [repeatedCode],
                fallbackRemediation: remediation?.message,
                fallbackFactIDs: remediation?.sourceFactIDs ?? [],
                anchorRecord: record,
                affectsScore: false
            )
        }
        return record
    }

    @discardableResult
    mutating func submit(
        _ event: AEDPracticeEvent
    ) -> IntegratedScenarioEventRecord {
        let failuresBefore = Set(aedMachine.criticalFailures.map(\.rawValue))
        let entry = aedMachine.handle(event)
        let remediation = Self.remediation(from: entry.outcome)
        let record = append(
            event: .aed(event),
            wasAccepted: entry.wasAccepted,
            stateBefore: entry.stateBefore.rawValue,
            stateAfter: entry.stateAfter.rawValue,
            remediation: remediation?.message,
            sourceReferences: sourceReferences(for: remediation?.sourceFactIDs ?? []),
            replayDomain: .aed,
            affectsScore: false
        )
        let failuresAfter = Set(aedMachine.criticalFailures.map(\.rawValue))
        let newFailures = failuresAfter.subtracting(failuresBefore)
        registerFailures(
            newFailures,
            fallbackRemediation: remediation?.message,
            fallbackFactIDs: remediation?.sourceFactIDs ?? [],
            anchorRecord: record,
            affectsScore: true
        )
        if newFailures.isEmpty,
           let repeatedCode = Self.criticalCode(
               for: remediation,
               stateBefore: entry.stateBefore,
               event: event
           ),
           failuresAfter.contains(repeatedCode) {
            registerFailures(
                [repeatedCode],
                fallbackRemediation: remediation?.message,
                fallbackFactIDs: remediation?.sourceFactIDs ?? [],
                anchorRecord: record,
                affectsScore: false
            )
        }
        return record
    }

    mutating func acknowledgeCorrection() throws {
        guard let correction = currentCorrection else {
            throw ScenarioEngineError.noActiveCorrection
        }
        append(
            event: .correctionAcknowledged(errorID: correction.id),
            stateBefore: "correctiveFeedback",
            stateAfter: "guidedRetry",
            affectsScore: false
        )
        currentCorrection = nil
    }

    mutating func completeSession() {
        append(
            event: .sessionCompleted,
            stateBefore: "active",
            stateAfter: "complete",
            affectsScore: false
        )
        currentBranchNodeID = nil
    }

    private static func validateAEDOutcomeBranches(
        in definition: ScenarioDefinition
    ) throws {
        let analysisConditions = definition.branchingNodes
            .flatMap(\.conditions)
            .filter { $0.condition == "shockOutcome" || $0.condition == "noShockOutcome" }
        for condition in analysisConditions {
            let hasClear = condition.requiredActionIDs.contains { $0.hasSuffix("action-clear-for-aed") }
            let hasResume = condition.requiredActionIDs.contains { $0.hasSuffix("action-resume-cpr") }
            guard hasClear, hasResume else {
                throw ScenarioEngineError.aedOutcomeBranchMissingSafetyAction(
                    scenarioID: definition.id,
                    condition: condition.condition
                )
            }
        }
        guard Set(analysisConditions.map(\.condition)) == Set(["shockOutcome", "noShockOutcome"]) else {
            throw ScenarioEngineError.aedOutcomeBranchMissingSafetyAction(
                scenarioID: definition.id,
                condition: "missingOutcomeBranch"
            )
        }
    }

    @discardableResult
    private mutating func append(
        event: IntegratedScenarioEvent,
        wasAccepted: Bool = true,
        stateBefore: String,
        stateAfter: String,
        scoringDimension: ScoringDimension? = nil,
        remediation: String? = nil,
        sourceReferences: [SourceReference] = [],
        replayDomain: ScenarioMachineDomain? = nil,
        replayAnchor explicitReplayAnchor: ScenarioReplayAnchor? = nil,
        affectsScore: Bool
    ) -> IntegratedScenarioEventRecord {
        let sequence = records.count
        let replayAnchor = explicitReplayAnchor ?? replayDomain.map {
            ScenarioReplayAnchor(
                sequence: sequence,
                domain: $0,
                stateBefore: stateBefore,
                stateAfter: stateAfter,
                eventDescription: String(describing: event)
            )
        }
        let record = IntegratedScenarioEventRecord(
            sequence: sequence,
            scenarioID: definition.id,
            event: event,
            wasAccepted: wasAccepted,
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            scoringDimension: scoringDimension,
            remediation: remediation,
            sourceReferences: sourceReferences,
            replayAnchor: replayAnchor,
            affectsScore: affectsScore
        )
        records.append(record)
        return record
    }

    private mutating func registerFailures(
        _ codes: Set<String>,
        fallbackRemediation: String?,
        fallbackFactIDs: [String],
        anchorRecord: IntegratedScenarioEventRecord,
        affectsScore: Bool
    ) {
        guard let replayAnchor = anchorRecord.replayAnchor else { return }
        for code in codes.sorted() {
            let authored = definition.criticalErrors.first(where: { $0.code == code })
            let dimension = authored?.scoringCategory ?? Self.dimension(forCriticalCode: code)
            let references = authored?.sourceReferences ?? sourceReferences(for: fallbackFactIDs)
            let correction = ScenarioCriticalCorrection(
                id: authored?.id ?? "\(definition.id)-runtime-error-\(code)",
                code: code,
                title: authored?.title ?? "Safety correction",
                remediation: authored?.remediation ?? fallbackRemediation ??
                    "Review the source-backed guidance and retry this step.",
                dimension: dimension,
                systemAudioCueID: Self.systemCueID(scenarioID: definition.id, code: code),
                sourceReferences: references,
                replayAnchor: replayAnchor
            )
            currentCorrection = correction
            append(
                event: .criticalError(
                    errorID: correction.id,
                    code: code,
                    title: correction.title,
                    systemAudioCueID: correction.systemAudioCueID
                ),
                stateBefore: "clinicalEvent",
                stateAfter: "correctiveFeedback",
                scoringDimension: dimension,
                remediation: correction.remediation,
                sourceReferences: references,
                replayAnchor: replayAnchor,
                affectsScore: affectsScore
            )
        }
    }

    private func sourceReferences(for factIDs: [String]) -> [SourceReference] {
        guard !factIDs.isEmpty else { return [] }
        let wanted = Set(factIDs)
        var references = definition.sourceReferences + definition.initialState.sourceReferences
        references += definition.criticalActions.flatMap(\.sourceReferences)
        references += definition.criticalErrors.flatMap(\.sourceReferences)
        references += definition.feedbackStatements.flatMap(\.sourceReferences)
        references += definition.branchingNodes.flatMap { node in
            node.sourceReferences + node.feedbackStatements.flatMap(\.sourceReferences) +
                node.conditions.flatMap { condition in
                    condition.sourceReferences + condition.feedbackStatements.flatMap(\.sourceReferences)
                }
        }
        var seen: Set<String> = []
        return references.filter { reference in
            guard let factID = reference.clinicalFactID, wanted.contains(factID) else {
                return false
            }
            return seen.insert(reference.id).inserted
        }
    }

    static func systemCueID(scenarioID: String, code: String) -> String {
        let suffix: String
        if code.contains("not_resumed") {
            suffix = "resume"
        } else if code.contains("lone_rescuer_left") {
            // The correction is about preserving the response sequence and staying
            // with the casualty, not an AED device-operation error.
            suffix = "sequence"
        } else if code.contains("aed") || code.contains("shock") || code.contains("pad") {
            suffix = "aed-safety"
        } else if code.contains("gasping") || code.contains("normal_breathing") {
            suffix = "normal-breathing"
        } else {
            suffix = "sequence"
        }
        return "sys.\(scenarioID)-feedback-\(suffix)"
    }

    private static func dimension(forCriticalCode code: String) -> ScoringDimension {
        if code.contains("scene") { return .sceneSafety }
        if code.contains("aed") || code.contains("shock") || code.contains("pad") {
            return .aedPreparationAndPlacement
        }
        if code.contains("compression") || code.contains("cpr") || code.contains("xiphoid") {
            return .cprSequenceAndRhythm
        }
        return .recognitionAndActivation
    }

    /// Reducers intentionally de-duplicate their scored failure arrays. A repeated unsafe
    /// action still needs a fresh voice/visual correction and guided retry, so map the
    /// remediation occurrence back to its already-recorded scoring code.
    private static func criticalCode(
        for remediation: DRSABCRemediation?
    ) -> String? {
        switch remediation?.code {
        case .unsafeSceneEntry:
            DRSABCCriticalFailure.unsafeSceneEntry.rawValue
        case .helpNotActivated:
            DRSABCCriticalFailure.helpNotActivated.rawValue
        case .loneRescuerMustStay:
            DRSABCCriticalFailure.loneRescuerLeft.rawValue
        case .gaspingIsNotNormalBreathing:
            DRSABCCriticalFailure.gaspingTreatedAsNormal.rawValue
        case .breathingCheckTooLong:
            DRSABCCriticalFailure.breathingCheckExceededTenSeconds.rawValue
        case .sceneRequiresMitigation, .callMustRemainSimulated, nil:
            nil
        }
    }

    private static func criticalCode(
        for remediation: CPRPracticeRemediation?
    ) -> String? {
        switch remediation?.code {
        case .xiphoidPlacement:
            CPRPracticeCriticalFailure.compressionOnXiphoid.rawValue
        case .prolongedInterruption:
            CPRPracticeCriticalFailure.prolongedInterruption.rawValue
        case .outsideSternumTarget, .placementUnavailable,
             .restBeforeCycleBoundary, .invalidCadence, nil:
            nil
        }
    }

    private static func criticalCode(
        for remediation: AEDPracticeRemediation?,
        stateBefore: AEDPracticeState,
        event: AEDPracticeEvent
    ) -> String? {
        switch remediation?.code {
        case .handsOffRequired:
            AEDPracticeCriticalFailure.contactDuringAnalysis.rawValue
        case .bystanderStillTouching:
            AEDPracticeCriticalFailure.contactDuringShock.rawValue
        case .clearSweepRequired:
            switch (stateBefore, event) {
            case (.padsCorrect, .interactiveAnalysisClearCheck):
                AEDPracticeCriticalFailure.contactDuringAnalysis.rawValue
            case (.clearConfirmation, .pressShockControl):
                AEDPracticeCriticalFailure.shockWithoutClearCheck.rawValue
            default:
                nil
            }
        case .resumeCompressionsImmediately:
            AEDPracticeCriticalFailure.cprNotResumed.rawValue
        case .preparationIncomplete, .preparationActionNotApplicable, .padsIncorrect,
             .eventOutOfSequence, nil:
            nil
        }
    }

    private static func remediation(
        from outcome: StateMachineEventOutcome<
            DRSABCState,
            DRSABCRejectionReason,
            DRSABCRemediation
        >
    ) -> DRSABCRemediation? {
        switch outcome {
        case let .accepted(_, remediation): remediation
        case let .rejected(_, remediation): remediation
        }
    }

    private static func remediation(
        from outcome: StateMachineEventOutcome<
            CPRPracticeState,
            CPRPracticeRejectionReason,
            CPRPracticeRemediation
        >
    ) -> CPRPracticeRemediation? {
        switch outcome {
        case let .accepted(_, remediation): remediation
        case let .rejected(_, remediation): remediation
        }
    }

    private static func remediation(
        from outcome: StateMachineEventOutcome<
            AEDPracticeState,
            AEDPracticeRejectionReason,
            AEDPracticeRemediation
        >
    ) -> AEDPracticeRemediation? {
        switch outcome {
        case let .accepted(_, remediation): remediation
        case let .rejected(_, remediation): remediation
        }
    }
}
