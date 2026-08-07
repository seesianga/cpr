import SwiftUI

@main
struct LifesaverVisionApp: App {
    @State private var appModel = AppModel()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup("Dashboard", id: AppModel.dashboardWindowID) {
            DashboardRootView()
                .environment(appModel)
        }

        WindowGroup("Learning Lab", id: AppModel.learningLabWindowID) {
            LearningLabRootView()
                .environment(appModel)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 0.72, depth: 0.60, in: .meters)

        ImmersiveSpace(id: AppModel.simulationSpaceID) {
            SimulationSpaceRootView()
                .environment(appModel)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
