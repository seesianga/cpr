import RealityKit
import SwiftUI

/// Volumetric laboratory presenting the original heart-and-lungs learning model.
struct LearningLabRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var assetRegistry = AssetRegistry()

    var body: some View {
        ZStack {
            RealityView { content in
                do {
                    let scene = try await assetRegistry.loadScene(.heartAndLungsVolume)
                    try assetRegistry.decorateSemanticEntities(
                        in: scene,
                        for: .heartAndLungsVolume
                    )
                    content.add(scene)
                    isLoading = false
                    loadErrorMessage = nil
                } catch is CancellationError {
                    // View teardown cancels in-flight loading; no learner-facing error is needed.
                } catch {
                    isLoading = false
                    loadErrorMessage = error.localizedDescription
                }
            }

            if isLoading {
                ProgressView("Loading learning model…")
                    .padding(24)
                    .glassBackgroundEffect()
                    .accessibilityLabel("Loading the heart and lungs learning model")
            } else if let loadErrorMessage {
                ContentUnavailableView {
                    Label("Learning Model Unavailable", systemImage: "heart.slash")
                } description: {
                    Text(loadErrorMessage)
                }
                .padding(24)
                .glassBackgroundEffect()
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
        }
        .onDisappear {
            assetRegistry.releaseScene(.heartAndLungsVolume)
        }
    }
}
