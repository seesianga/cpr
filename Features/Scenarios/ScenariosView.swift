import SwiftUI

/// Catalogue of integrated emergency-response simulations.
struct ScenariosView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(AppModel.self) private var appModel
    @State private var integratedScenarios: [ScenarioDefinition] = []
    @State private var scenarioLoadError: String?

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("Integrated scenarios A–D") {
                if let scenarioLoadError {
                    Label(scenarioLoadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if integratedScenarios.isEmpty {
                    ProgressView("Loading source-backed scenarios")
                } else {
                    ForEach(integratedScenarios) { scenario in
                        NavigationLink {
                            IntegratedScenarioBriefingView(definition: scenario)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(scenario.title)
                                    .font(.headline)
                                Text(scenario.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                Label(
                                    "\(scenario.randomisation.shockPatternIDs.count) approved AED patterns; clinical rules stay fixed",
                                    systemImage: "shield.checkered"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityHint("Opens the scenario briefing and accessible interaction alternatives")
                    }
                }
            }

            Section("DRSABC guided room") {
                Text("Practise Danger, Response, Shout, a simulated 995 call, AED delegation, breathing assessment and the transition to compressions.")
                Text(DRSABCPracticeSessionModel.simulationBadge)
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            Section("Enter practice") {
                Toggle("I am ready to enter mixed immersion", isOn: $appModel.hasUserOptedInToImmersion)
                Button("Enter DRSABC Practice", systemImage: "visionpro") {
                    appModel.selectPractice(.drsabc)
                    Task { await appModel.openSimulation(using: openImmersiveSpace) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appModel.hasUserOptedInToImmersion ||
                    appModel.immersionState != .closed
                )
                .accessibilityHint("Opens the DRSABC training room; pause and exit controls remain visible")

                if let notice = appModel.immersionNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Scenarios")
        .task {
            guard integratedScenarios.isEmpty, scenarioLoadError == nil else { return }
            do {
                integratedScenarios = try ScenarioDefinitionsCodec.load().scenarios
            } catch {
                scenarioLoadError = "Integrated scenarios are unavailable because their source-backed definitions could not be loaded."
            }
        }
    }
}
