import SwiftUI

/// Volumetric laboratory host. Scene lifecycle remains app-wide while each laboratory
/// mode owns its authored RealityKit scene and releases it when the volume closes.
struct LearningLabRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel

    var body: some View {
        SpatialLaboratoryView()
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                appModel.handleScenePhase(newPhase)
            }
    }
}
