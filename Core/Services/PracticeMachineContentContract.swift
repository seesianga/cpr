import Foundation

enum PracticeMachineContentError: Error, Equatable, Sendable {
    case missingScenarioBranches([String])
    case missingAuthoredAEDStates([String])
    case invalidAEDStateCount(Int)
    case missingCourseModule(String)
    case missingCourseBlock(String)
    case missingClinicalFact(String)
    case blockedClinicalFact(String)
    case missingClinicalFactValue(factID: String, key: String)
    case invalidClinicalFactValue(factID: String, key: String)
    case unsupportedClinicalPolicy(String)
    case contentIdentityMismatch
}

/// A traceable learner-facing instruction copied from the immutable bundled course.
struct PracticeContentInstruction: Sendable, Equatable {
    let id: String
    let title: String
    let body: String
    let sourceReferences: [SourceReference]
}

/// Validated bridge from audited Phase 3B content to the Phase 5A runtime reducers.
///
/// The JSON describes learner-facing teaching stages; runtime state adds safety-only states
/// such as incorrect pads, interactive clear confirmation, simulated shock, and completion.
struct PracticeMachineContentContract: Sendable, Equatable {
    let courseID: String
    let contentVersion: String
    let drsabcPolicy: DRSABCPolicy
    let cprPolicy: CPRPracticePolicy
    let authoredAEDStateIDs: Set<String>
    let runtimeAEDStateIDs: Set<String>
    let simulatedCallTitle: String
    let simulatedCallBody: String
    let simulatedCallSourceReferences: [SourceReference]
    let dispatcherReminder: PracticeContentInstruction
    let aedPreparationInstructions: [AEDChestCondition: PracticeContentInstruction]
    let aedPadPlacementInstruction: PracticeContentInstruction

    static func loadBundled(from bundle: Bundle = .main) throws -> PracticeMachineContentContract {
        try make(
            course: CourseContentCodec.loadCourse(named: "course_v1", from: bundle),
            scenarios: ScenarioDefinitionsCodec.load(from: bundle),
            facts: ClinicalFactCatalogue.loadBundled(from: bundle)
        )
    }

    static func make(
        course: Course,
        scenarios: ScenarioDefinitionsDocument,
        facts: ClinicalFactCatalogue
    ) throws -> PracticeMachineContentContract {
        guard course.id == scenarios.courseID,
              course.version.contentVersion == scenarios.contentVersion
        else {
            throw PracticeMachineContentError.contentIdentityMismatch
        }
        let requiredBranches = Set([
            "sceneSafe", "sceneUnsafe", "bystanderAvailable", "rescuerAlone",
            "aedNear", "aedFar", "gaspingObserved",
            "breathingAbsentAbnormalOrUncertain", "normalBreathingObserved",
            "shockOutcome", "noShockOutcome"
        ])
        let missingBranches = scenarios.scenarios.flatMap { scenario in
            let available = Set(
                scenario.branchingNodes
                    .flatMap(\.conditions)
                    .map(\.condition)
            )
            return requiredBranches.subtracting(available).sorted().map {
                "\(scenario.id):\($0)"
            }
        }
        guard missingBranches.isEmpty else {
            throw PracticeMachineContentError.missingScenarioBranches(missingBranches)
        }

        let authoredIDs = Set(scenarios.aedStateMachine.states.map(\.id))
        guard authoredIDs.count == 11 else {
            throw PracticeMachineContentError.invalidAEDStateCount(authoredIDs.count)
        }
        let expectedAuthoredIDs = Set([
            "awaitingAED", "powerOn", "prepareChest", "applyRightPad", "applyLeftPad",
            "connectPads", "analyseClear", "chargeClear", "clearCheckAndShock",
            "noShockAdvised", "resumeCPR"
        ])
        let missingAuthored = expectedAuthoredIDs.subtracting(authoredIDs).sorted()
        guard missingAuthored.isEmpty else {
            throw PracticeMachineContentError.missingAuthoredAEDStates(missingAuthored)
        }

        guard let module3 = course.modules.first(where: { $0.id == "M3" }) else {
            throw PracticeMachineContentError.missingCourseModule("M3")
        }
        guard let callBlock = module3.lessons
            .flatMap(\.contentBlocks)
            .first(where: { $0.id == "M3-B4" })
        else {
            throw PracticeMachineContentError.missingCourseBlock("M3-B4")
        }
        guard let dispatcherBlock = module3.lessons
            .flatMap(\.contentBlocks)
            .first(where: { $0.id == "M3-B5" })
        else {
            throw PracticeMachineContentError.missingCourseBlock("M3-B5")
        }
        guard let module4 = course.modules.first(where: { $0.id == "M4" }) else {
            throw PracticeMachineContentError.missingCourseModule("M4")
        }
        guard let tempoBlock = module4.lessons
            .flatMap(\.contentBlocks)
            .first(where: { $0.id == "M4-B4" }),
              tempoBlock.body.contains("110")
        else {
            throw PracticeMachineContentError.missingCourseBlock("M4-B4")
        }
        guard let module5 = course.modules.first(where: { $0.id == "M5" }) else {
            throw PracticeMachineContentError.missingCourseModule("M5")
        }
        let module5Blocks = Dictionary(
            uniqueKeysWithValues: module5.lessons.flatMap(\.contentBlocks).map { ($0.id, $0) }
        )
        let preparationBlockIDs: [(AEDChestCondition, String)] = [
            (.hairPreventsPadContact, "M5-B6"),
            (.jewelleryAtPadSite, "M5-B7"),
            (.implantedDeviceNearPadSite, "M5-B8"),
            (.medicationPatchAtPadSite, "M5-B9"),
            (.wetChest, "M5-B10")
        ]
        var preparationInstructions: [AEDChestCondition: PracticeContentInstruction] = [:]
        for (condition, blockID) in preparationBlockIDs {
            guard let block = module5Blocks[blockID] else {
                throw PracticeMachineContentError.missingCourseBlock(blockID)
            }
            preparationInstructions[condition] = PracticeContentInstruction(block: block)
        }
        guard let padPlacementBlock = module5Blocks["M5-B3"] else {
            throw PracticeMachineContentError.missingCourseBlock("M5-B3")
        }

        let breathingMaximum = try requiredNumber(
            facts: facts,
            factID: "fact.drsabc.breathingCheck",
            key: "maxCheckSeconds"
        )
        let aedDistance = try requiredNumber(
            facts: facts,
            factID: "fact.drsabc.getAed",
            key: "aedFetchWalkingDistanceSeconds"
        )
        let loneRescuerLeaves = try requiredBoolean(
            facts: facts,
            factID: "fact.drsabc.getAed",
            key: "loneRescuerLeaves"
        )
        let minimumRate = try requiredNumber(
            facts: facts,
            factID: "fact.compression.rate",
            key: "minPerMinute"
        )
        let maximumRate = try requiredNumber(
            facts: facts,
            factID: "fact.compression.rate",
            key: "maxPerMinute"
        )
        let countTarget = try requiredNumber(
            facts: facts,
            factID: "fact.compression.counting",
            key: "countTarget"
        )
        let maxRest = try requiredNumber(
            facts: facts,
            factID: "fact.compression.restRule",
            key: "maxRestSeconds"
        )
        guard breathingMaximum > 0 else {
            throw PracticeMachineContentError.unsupportedClinicalPolicy(
                "maximumBreathingCheckSeconds"
            )
        }
        guard aedDistance > 0 else {
            throw PracticeMachineContentError.unsupportedClinicalPolicy(
                "aedNearWalkingSeconds"
            )
        }
        guard loneRescuerLeaves == false else {
            throw PracticeMachineContentError.unsupportedClinicalPolicy(
                "loneRescuerLeavesCasualty"
            )
        }
        guard minimumRate > 0, minimumRate <= maximumRate else {
            throw PracticeMachineContentError.unsupportedClinicalPolicy(
                "compressionRateRange"
            )
        }
        guard countTarget > 0,
              countTarget.rounded(.towardZero) == countTarget,
              countTarget <= Double(Int.max)
        else {
            throw PracticeMachineContentError.unsupportedClinicalPolicy(
                "preferredCompressionsPerCycle"
            )
        }
        guard maxRest > 0 else {
            throw PracticeMachineContentError.unsupportedClinicalPolicy(
                "maximumRestSeconds"
            )
        }

        return PracticeMachineContentContract(
            courseID: course.id,
            contentVersion: course.version.contentVersion,
            drsabcPolicy: try DRSABCPolicy.validated(
                maximumBreathingCheckSeconds: breathingMaximum,
                aedNearWalkingSeconds: aedDistance,
                loneRescuerLeavesCasualty: loneRescuerLeaves
            ),
            cprPolicy: try CPRPracticePolicy.validated(
                minimumRatePerMinute: minimumRate,
                maximumRatePerMinute: maximumRate,
                practiceTempoPerMinute: 110,
                preferredCompressionsPerCycle: Int(countTarget),
                maximumRestSeconds: maxRest
            ),
            authoredAEDStateIDs: authoredIDs,
            runtimeAEDStateIDs: Set(AEDPracticeState.allCases.map(\.rawValue)),
            simulatedCallTitle: callBlock.title,
            simulatedCallBody: callBlock.body,
            simulatedCallSourceReferences: callBlock.sourceReferences,
            dispatcherReminder: PracticeContentInstruction(block: dispatcherBlock),
            aedPreparationInstructions: preparationInstructions,
            aedPadPlacementInstruction: PracticeContentInstruction(block: padPlacementBlock)
        )
    }

    private static func requiredNumber(
        facts: ClinicalFactCatalogue,
        factID: String,
        key: String
    ) throws -> Double {
        guard let fact = facts[factID] else {
            throw PracticeMachineContentError.missingClinicalFact(factID)
        }
        guard !fact.reviewStatus.blocksScoredUse else {
            throw PracticeMachineContentError.blockedClinicalFact(factID)
        }
        guard let value = fact.values[key] else {
            throw PracticeMachineContentError.missingClinicalFactValue(
                factID: factID,
                key: key
            )
        }
        guard let number = value.numberValue, number.isFinite else {
            throw PracticeMachineContentError.invalidClinicalFactValue(
                factID: factID,
                key: key
            )
        }
        return number
    }

    private static func requiredBoolean(
        facts: ClinicalFactCatalogue,
        factID: String,
        key: String
    ) throws -> Bool {
        guard let fact = facts[factID] else {
            throw PracticeMachineContentError.missingClinicalFact(factID)
        }
        guard !fact.reviewStatus.blocksScoredUse else {
            throw PracticeMachineContentError.blockedClinicalFact(factID)
        }
        guard let value = fact.values[key] else {
            throw PracticeMachineContentError.missingClinicalFactValue(
                factID: factID,
                key: key
            )
        }
        guard let boolean = value.booleanValue else {
            throw PracticeMachineContentError.invalidClinicalFactValue(
                factID: factID,
                key: key
            )
        }
        return boolean
    }
}

private extension PracticeContentInstruction {
    init(block: ContentBlock) {
        id = block.id
        title = block.title
        body = block.body
        sourceReferences = block.sourceReferences
    }
}

private extension JSONValue {
    var numberValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var booleanValue: Bool? {
        if case let .boolean(value) = self { return value }
        return nil
    }
}
