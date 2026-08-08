import SwiftUI
import SwiftData

/// Shared-space preparation for an integrated attempt. Clinical transitions remain in
/// `ScenarioEngine`; this view only selects equivalent interaction affordances.
struct IntegratedScenarioBriefingView: View {
    let definition: ScenarioDefinition

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @State private var engine: ScenarioEngine?
    @State private var scoringDecision: ScenarioScoringDecision?
    @State private var preparationError: String?
    @State private var isPreparing = false
    @State private var selectedAssignment: ScenarioBystanderAssignment = .getAED
    @State private var selectedMethod: ScenarioInteractionMethod = .gazeAndPinch

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("Environment") {
                LabeledContent("Scenario", value: definition.title)
                LabeledContent(
                    "Immersive scene",
                    value: ScenarioEngine.sceneByScenarioID[definition.id]?.rawValue ?? "Unavailable"
                )
                Text(definition.summary)
                    .foregroundStyle(.secondary)
            }

            Section("Bystander delegation") {
                Picker("Task", selection: $selectedAssignment) {
                    ForEach(ScenarioBystanderAssignment.allCases, id: \.self) { assignment in
                        Text(assignment.displayName).tag(assignment)
                    }
                }
                Picker("Input method", selection: $selectedMethod) {
                    Text("Gaze and pinch").tag(ScenarioInteractionMethod.gazeAndPinch)
                    Text("Accessible labelled control").tag(ScenarioInteractionMethod.accessibleControl)
                }
                Text("Both input methods submit the same action and receive identical scoring. Accessibility support is never treated as a distraction or penalty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Attempt preparation") {
                Button("Prepare approved scenario pattern", systemImage: "checkmark.shield") {
                    Task { await prepareAttempt() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)

                if isPreparing {
                    ProgressView("Verifying clinical scoring eligibility")
                }

                if let engine {
                    Label("Attempt ready", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let explanation = scoringDecision?.practiceOnlyExplanation {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("PRACTICE ONLY — UNSCORED", systemImage: "shield.slash.fill")
                                .font(.headline)
                            Text("\(explanation) No completion record, XP, or badge will be saved.")
                                .font(.footnote)
                        }
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                    }
                    Text("The AED outcome order is selected from the approved pool and intentionally hidden. Clear checks, clinical branches, and CPR resumption rules cannot be randomised.")
                        .foregroundStyle(.secondary)
                    LabeledContent("Scene", value: engine.scene.rawValue)
                    LabeledContent("Simulation call", value: "SIMULATION — no real call is made")

                    Toggle(
                        "I am ready to enter this scenario",
                        isOn: $appModel.hasUserOptedInToImmersion
                    )
                    Button("Start Integrated Scenario", systemImage: "visionpro") {
                        appModel.selectIntegratedScenario(
                            scenarioID: definition.id,
                            patternID: engine.selectedPattern.id,
                            scene: engine.scene
                        )
                        Task { await appModel.openSimulation(using: openImmersiveSpace) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !appModel.hasUserOptedInToImmersion ||
                        appModel.immersionState != .closed
                    )
                    .accessibilityHint("Loads the exact authored scenario room with persistent Pause and Exit controls")
                }

                if let preparationError {
                    Label(preparationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Section("Safety and comfort") {
                Label("Pause and Exit remain visible throughout immersion.", systemImage: "pause.circle")
                Text("Critical errors pause progression, present source-backed correction, replay the recorded offending moment, and require a guided retry.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(definition.title)
    }

    @MainActor
    private func prepareAttempt() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            let document = try ScenarioDefinitionsCodec.load()
            let decision = await ScenarioScoringGate().authorizeBundledLaunch(
                document: document,
                scenarioID: definition.id,
                modelContainer: modelContext.container
            )
            let prepared = try ScenarioEngine(
                document: document,
                scenarioID: definition.id,
                selector: RandomScenarioPatternSelector()
            )
            engine = prepared
            scoringDecision = decision
            preparationError = nil
        } catch {
            engine = nil
            scoringDecision = nil
            preparationError = "This scenario failed its safety or content checks and cannot start."
        }
    }
}
