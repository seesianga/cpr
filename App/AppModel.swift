import Observation
import SwiftUI

/// App-wide scene coordination for the shared, volumetric, and immersive experiences.
@MainActor
@Observable
final class AppModel {
    static let dashboardWindowID = "Dashboard"
    static let learningLabWindowID = "LearningLab"
    static let simulationSpaceID = "SimulationSpace"

    enum ImmersionState: Equatable {
        case closed
        case opening
        case open
        case dismissing
    }

    private(set) var scenePhase: ScenePhase = .active
    private(set) var immersionState: ImmersionState = .closed
    var hasUserOptedInToImmersion = false
    var immersionNotice: String?

    /// Records application lifecycle changes without making assumptions about learner progress.
    func handleScenePhase(_ newPhase: ScenePhase) {
        scenePhase = newPhase

        if newPhase != .active, immersionState == .open {
            immersionNotice = "Simulation paused while Lifesaver Vision is inactive."
        }
    }

    /// Opens the simulation only after the learner has explicitly opted in.
    func openSimulation(using openImmersiveSpace: OpenImmersiveSpaceAction) async {
        guard hasUserOptedInToImmersion, immersionState == .closed else {
            if !hasUserOptedInToImmersion {
                immersionNotice = "Confirm that you are ready before entering the simulation."
            }
            return
        }

        immersionState = .opening
        immersionNotice = nil

        switch await openImmersiveSpace(id: Self.simulationSpaceID) {
        case .opened:
            immersionState = .open
        case .userCancelled:
            immersionState = .closed
            immersionNotice = "Simulation entry was cancelled."
        case .error:
            immersionState = .closed
            immersionNotice = "The simulation could not be opened. Please try again."
        @unknown default:
            immersionState = .closed
            immersionNotice = "The simulation returned an unsupported result."
        }
    }

    /// Leaves the immersive simulation and returns control to the shared-space dashboard.
    func dismissSimulation(using dismissImmersiveSpace: DismissImmersiveSpaceAction) async {
        guard immersionState == .open else { return }

        immersionState = .dismissing
        await dismissImmersiveSpace()
        immersionState = .closed
        immersionNotice = nil
    }

    /// Reconciles state when the system closes the immersive space independently of the exit button.
    func simulationSpaceDidDisappear() {
        immersionState = .closed
    }
}
