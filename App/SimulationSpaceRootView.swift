import RealityKit
import SwiftUI

/// Mixed-immersion simulation placeholder with an always-visible exit control.
struct SimulationSpaceRootView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel

    var body: some View {
        RealityView { content, attachments in
            // Scenario entities and state machines are intentionally deferred.
            if let controls = attachments.entity(for: "simulation-controls") {
                controls.position = [0, 1.35, -1.2]
                content.add(controls)
            }
        } attachments: {
            Attachment(id: "simulation-controls") {
                VStack(spacing: 14) {
                    Text("SIMULATION")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.red)
                    Text("CPR + AED Practice")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Scenario content will be added in a later phase.")
                        .foregroundStyle(.secondary)

                    Button("Exit Simulation", systemImage: "xmark.circle.fill") {
                        Task {
                            await appModel.dismissSimulation(using: dismissImmersiveSpace)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Returns to the shared-space dashboard")
                }
                .padding(24)
                .glassBackgroundEffect()
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
        }
        .onDisappear {
            appModel.simulationSpaceDidDisappear()
        }
    }
}
