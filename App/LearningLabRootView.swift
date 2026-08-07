import RealityKit
import SwiftUI

/// Volumetric learning laboratory placeholder for later procedural clinical models.
struct LearningLabRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack {
            RealityView { _ in
                // RealityKit entities are intentionally added in a later phase.
            }

            VStack(spacing: 12) {
                Image(systemName: "cube.transparent")
                    .font(.system(size: 44))
                    .foregroundStyle(.blue)
                Text("Learning Laboratory")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Volumetric learning models will appear here.")
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .glassBackgroundEffect()
        }
        .accessibilityElement(children: .contain)
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
        }
    }
}
