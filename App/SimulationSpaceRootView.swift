import RealityKit
import SwiftUI

/// Mixed-immersion simulation with head-anchored pause and exit controls.
struct SimulationSpaceRootView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var loadedScene: SpatialSceneName?
    @State private var assetRegistry = AssetRegistry()

    var body: some View {
        RealityView { content, attachments in
            let controlsAnchor = AnchorEntity(.head)
            controlsAnchor.name = "simulation_controls_anchor"
            if let controls = attachments.entity(for: "simulation-controls") {
                controls.position = [0, -0.18, -1.15]
                controlsAnchor.addChild(controls)
            }
            content.add(controlsAnchor)

            do {
                let selectedScene = appModel.selectedSimulationScene
                let scene = try await assetRegistry.loadScene(selectedScene)
                try assetRegistry.decorateSemanticEntities(in: scene, for: selectedScene)
                scene.isEnabled = !appModel.isSimulationPaused
                content.add(scene)
                loadedScene = selectedScene
                isLoading = false
                loadErrorMessage = nil
            } catch is CancellationError {
                // Dismissing the immersive space cancels loading without surfacing an error.
            } catch {
                isLoading = false
                loadErrorMessage = error.localizedDescription
            }
        } update: { content, _ in
            let sceneName = appModel.selectedSimulationScene.rawValue
            content.entities.first { $0.name == sceneName }?.isEnabled = !appModel.isSimulationPaused
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
                    Text(appModel.selectedSimulationScene.rawValue)
                        .foregroundStyle(.secondary)

                    if isLoading {
                        ProgressView("Loading scene…")
                    } else if let loadErrorMessage {
                        Label("Scene unavailable", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(loadErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 12) {
                        Button(
                            appModel.isSimulationPaused ? "Resume" : "Pause",
                            systemImage: appModel.isSimulationPaused ? "play.fill" : "pause.fill"
                        ) {
                            appModel.toggleSimulationPause()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isLoading || loadErrorMessage != nil)
                        .accessibilityHint("Pauses or resumes the visible practice scene")

                        Button("Exit Simulation", systemImage: "xmark.circle.fill") {
                            Task {
                                if let loadedScene {
                                    assetRegistry.releaseScene(loadedScene)
                                    self.loadedScene = nil
                                }
                                await appModel.dismissSimulation(using: dismissImmersiveSpace)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Returns to the shared-space dashboard")
                    }
                }
                .padding(24)
                .glassBackgroundEffect()
            }
        }
        .id(appModel.selectedSimulationScene)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
        }
        .onDisappear {
            if let loadedScene {
                assetRegistry.releaseScene(loadedScene)
                self.loadedScene = nil
            }
            appModel.simulationSpaceDidDisappear()
        }
    }
}
