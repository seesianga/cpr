import Observation
import SwiftUI

/// The source-backed practice experience hosted by the single mixed immersive space.
enum SpatialPracticeExperience: String, CaseIterable, Identifiable, Sendable {
    case cpr
    case aed
    case drsabc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpr: "CPR Practice"
        case .aed: "AED Practice"
        case .drsabc: "DRSABC Practice"
        }
    }

    var initialScene: SpatialSceneName {
        switch self {
        case .cpr: .cprPracticeRoom
        case .aed: .aedPreparationRoom
        case .drsabc: .drsabcTrainingRoom
        }
    }
}

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
    private(set) var isSimulationPaused = false
    var hasUserOptedInToImmersion = false
    var immersionNotice: String?
    private(set) var selectedPracticeExperience: SpatialPracticeExperience = .cpr
    var selectedSimulationScene: SpatialSceneName = .cprPracticeRoom

    /// Selects a practice without opening immersion. This lets the shared-space launch view
    /// explain the exact mode before the learner opts in.
    func selectPractice(_ experience: SpatialPracticeExperience) {
        guard immersionState == .closed else { return }
        selectedPracticeExperience = experience
        selectedSimulationScene = experience.initialScene
        immersionNotice = nil
    }

    /// AED preparation and placement are one session across two independently loaded rooms.
    func moveAEDPractice(to scene: SpatialSceneName) {
        guard selectedPracticeExperience == .aed,
              scene == .aedPreparationRoom || scene == .aedPlacementRoom
        else { return }
        selectedSimulationScene = scene
    }

    /// Records application lifecycle changes without making assumptions about learner progress.
    func handleScenePhase(_ newPhase: ScenePhase) {
        scenePhase = newPhase

        if newPhase != .active, immersionState == .open {
            isSimulationPaused = true
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
            isSimulationPaused = false
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
        isSimulationPaused = false
        immersionNotice = nil
    }

    /// Pauses app-owned scene activity. RealityKit rendering remains available for safe exit controls.
    func toggleSimulationPause() {
        guard immersionState == .open else { return }
        isSimulationPaused.toggle()
        immersionNotice = isSimulationPaused ? "Simulation paused." : nil
    }

    /// Reconciles state when the system closes the immersive space independently of the exit button.
    func simulationSpaceDidDisappear() {
        immersionState = .closed
        isSimulationPaused = false
    }
}
