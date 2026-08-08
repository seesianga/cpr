import SwiftData
import SwiftUI

@main
struct LifesaverVisionApp: App {
    @State private var appModel = AppModel()
    @State private var authenticationModel: AuthenticationModel
    @State private var immersionStyle: ImmersionStyle = .mixed
    private let modelContainer: ModelContainer

    init() {
        modelContainer = AppPersistence.makeContainer()
        let service: any AuthenticationService
        #if UITEST
        if ProcessInfo.processInfo.arguments.contains("--ui-test-authenticated-learner") {
            service = InMemoryAuthenticationService(
                currentUser: AuthenticatedUser(
                    id: "ui-test-learner",
                    displayName: "UI Test Learner",
                    role: .learner,
                    sessionKind: .guest
                )
            )
        } else {
            service = LocalAuthenticationService()
        }
        #else
        service = LocalAuthenticationService()
        #endif
        _authenticationModel = State(
            initialValue: AuthenticationModel(service: service)
        )
    }

    var body: some Scene {
        WindowGroup("Dashboard", id: AppModel.dashboardWindowID) {
            AuthenticationGateView(model: authenticationModel)
                .environment(appModel)
                .modelContainer(modelContainer)
        }

        WindowGroup("Learning Lab", id: AppModel.learningLabWindowID) {
            LearningLabRootView()
                .environment(appModel)
                .environment(authenticationModel)
                .modelContainer(modelContainer)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 0.72, depth: 0.60, in: .meters)

        WindowGroup("Achievement Gallery", id: AppModel.achievementGalleryWindowID) {
            AchievementGalleryRootView()
                .environment(appModel)
                .environment(authenticationModel)
                .modelContainer(modelContainer)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.0, height: 0.72, depth: 0.70, in: .meters)

        ImmersiveSpace(id: AppModel.simulationSpaceID) {
            SimulationSpaceRootView()
                .environment(appModel)
                .environment(authenticationModel)
                .modelContainer(modelContainer)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}

private enum AppPersistence {
    @MainActor
    static func makeContainer() -> ModelContainer {
        #if UITEST
        do {
            return try PersistenceBootstrap.makeModelContainer(inMemory: true)
        } catch {
            fatalError("Unable to initialise the isolated test learning store.")
        }
        #else
        do {
            return try PersistenceBootstrap.makeModelContainer()
        } catch {
            // Retain full local functionality when the on-device store cannot be opened.
            // The in-memory fallback is intentionally CloudKit-independent.
            do {
                return try PersistenceBootstrap.makeModelContainer(inMemory: true)
            } catch {
                fatalError("Unable to initialise the local learning store.")
            }
        }
        #endif
    }
}
