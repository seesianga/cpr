import SwiftData
import SwiftUI

/// Volumetric laboratory host. Scene lifecycle remains app-wide while each laboratory
/// mode owns its authored RealityKit scene and releases it when the volume closes.
struct LearningLabRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.modelContext) private var modelContext
    @State private var modulePresentationModel: ModulePresentationModel?
    @State private var accessErrorMessage: String?

    var body: some View {
        Group {
            if let model = modulePresentationModel,
               case .loaded = model.state,
               !SpatialLaboratoryAccessPolicy.authorisedModes(in: model.modules).isEmpty {
                SpatialLaboratoryView(
                    authorisedModes: SpatialLaboratoryAccessPolicy.authorisedModes(
                        in: model.modules
                    )
                )
            } else if let model = modulePresentationModel,
                      case .loaded = model.state {
                ContentUnavailableView(
                    "Learning laboratory locked",
                    systemImage: "lock.cube",
                    description: Text(
                        "The authoritative course gate has not made \(SpatialLaboratoryAccessPolicy.lockedModuleIDs(in: model.modules).joined(separator: ", ")) available. Open its lessons from Courses first."
                    )
                )
            } else if let accessErrorMessage {
                ContentUnavailableView(
                    "Learning laboratory unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(accessErrorMessage)
                )
            } else {
                ProgressView("Checking laboratory access…")
            }
        }
            .task(id: authenticationModel.currentUser?.id) {
                await loadAccess()
            }
            .onChange(of: scenePhase, initial: true) { _, newPhase in
                appModel.handleScenePhase(newPhase)
            }
    }

    @MainActor
    private func loadAccess() async {
        guard let learnerID = authenticationModel.currentUser?.id else {
            accessErrorMessage = "Sign in before opening module-linked laboratory content."
            return
        }
        do {
            let model = try ModulePresentationModel.production(
                modelContainer: modelContext.container
            )
            modulePresentationModel = model
            await model.load(learnerID: learnerID)
            if case .failed = model.state {
                accessErrorMessage = "Course access could not be verified."
            }
        } catch {
            accessErrorMessage = "Course access could not be verified."
        }
    }
}
