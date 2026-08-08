import Observation
import SwiftUI

/// The source-backed practice experience hosted by the single mixed immersive space.
enum SpatialPracticeExperience: String, CaseIterable, Identifiable, Sendable {
    case onboarding
    case cpr
    case aed
    case drsabc
    case integratedScenario

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onboarding: "Pause and Exit Practice"
        case .cpr: "CPR Practice"
        case .aed: "AED Practice"
        case .drsabc: "DRSABC Practice"
        case .integratedScenario: "Integrated Scenario"
        }
    }

    var initialScene: SpatialSceneName {
        switch self {
        case .onboarding: .academyLobby
        case .cpr: .cprPracticeRoom
        case .aed: .aedPreparationRoom
        case .drsabc: .drsabcTrainingRoom
        case .integratedScenario: .scenarioHome
        }
    }
}

/// App-wide scene coordination for the shared, volumetric, and immersive experiences.
@MainActor
@Observable
final class AppModel {
    static let dashboardWindowID = "Dashboard"
    static let learningLabWindowID = "LearningLab"
    static let achievementGalleryWindowID = "AchievementGallery"
    static let simulationSpaceID = "SimulationSpace"

    let audioDirector: SystemAudioDirector

    enum ImmersionState: Equatable {
        case closed
        case opening
        case open
        case dismissing
    }

    private(set) var scenePhase: ScenePhase = .active
    private(set) var immersionState: ImmersionState = .closed
    private(set) var isSimulationPaused = false
    private(set) var isSimulationRoomTransitionInFlight = false
    var hasUserOptedInToImmersion = false
    var immersionNotice: String?
    private(set) var selectedPracticeExperience: SpatialPracticeExperience = .cpr
    var selectedSimulationScene: SpatialSceneName = .cprPracticeRoom
    private(set) var selectedIntegratedScenarioID: String?
    private(set) var selectedIntegratedScenarioPatternID: String?
    private(set) var onboardingExitPracticeCompleted = false
    private(set) var onboardingPausePracticeCompleted = false
    private(set) var onboardingComfortPosture: OnboardingComfortPosture?
    private(set) var onboardingDominantHand: OnboardingDominantHand?
    private(set) var onboardingInputMethod: OnboardingInputMethod?
    private var onboardingExitPracticeActive = false

    init(audioDirector: SystemAudioDirector = SystemAudioDirector()) {
        self.audioDirector = audioDirector
    }

    /// Selects a practice without opening immersion. This lets the shared-space launch view
    /// explain the exact mode before the learner opts in.
    func selectPractice(_ experience: SpatialPracticeExperience) {
        guard immersionState == .closed else { return }
        selectedPracticeExperience = experience
        selectedSimulationScene = experience.initialScene
        immersionNotice = nil
    }

    func beginOnboardingExitPractice() {
        guard immersionState == .closed else { return }
        selectPractice(.onboarding)
        onboardingExitPracticeActive = true
        onboardingExitPracticeCompleted = false
        onboardingPausePracticeCompleted = false
    }

    func configureOnboardingSession(
        posture: OnboardingComfortPosture,
        dominantHand: OnboardingDominantHand,
        inputMethod: OnboardingInputMethod
    ) {
        onboardingComfortPosture = posture
        onboardingDominantHand = dominantHand
        onboardingInputMethod = inputMethod
    }

    func selectIntegratedScenario(
        scenarioID: String,
        patternID: String,
        scene: IntegratedScenarioScene
    ) {
        guard immersionState == .closed else { return }
        selectedPracticeExperience = .integratedScenario
        selectedIntegratedScenarioID = scenarioID
        selectedIntegratedScenarioPatternID = patternID
        selectedSimulationScene = scene.spatialSceneName
        immersionNotice = nil
    }

    func moveIntegratedScenarioToDebrief() {
        guard selectedPracticeExperience == .integratedScenario,
              immersionState == .open
        else { return }
        isSimulationRoomTransitionInFlight = true
        selectedSimulationScene = .debriefSpace
    }

    /// AED preparation and placement are one session across two independently loaded rooms.
    func moveAEDPractice(to scene: SpatialSceneName) {
        guard selectedPracticeExperience == .aed,
              scene == .aedPreparationRoom || scene == .aedPlacementRoom
        else { return }
        isSimulationRoomTransitionInFlight = scene != selectedSimulationScene
        selectedSimulationScene = scene
    }

    func simulationRoomDidLoad(_ scene: SpatialSceneName) {
        guard scene == selectedSimulationScene else { return }
        isSimulationRoomTransitionInFlight = false
    }

    /// Records application lifecycle changes without making assumptions about learner progress.
    func handleScenePhase(_ newPhase: ScenePhase) {
        scenePhase = newPhase

        Task {
            await audioDirector.setImmersiveScene(
                active: newPhase == .active,
                isOpen: immersionState == .open
            )
        }

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
        isSimulationRoomTransitionInFlight = false
        immersionNotice = nil

        switch await openImmersiveSpace(id: Self.simulationSpaceID) {
        case .opened:
            immersionState = .open
            isSimulationPaused = false
            await audioDirector.setImmersiveScene(
                active: scenePhase == .active,
                isOpen: true
            )
        case .userCancelled:
            immersionState = .closed
            hasUserOptedInToImmersion = false
            onboardingExitPracticeActive = false
            immersionNotice = "Simulation entry was cancelled."
            await audioDirector.setImmersiveScene(active: false, isOpen: false)
        case .error:
            immersionState = .closed
            hasUserOptedInToImmersion = false
            onboardingExitPracticeActive = false
            immersionNotice = "The simulation could not be opened. Please try again."
            await audioDirector.setImmersiveScene(active: false, isOpen: false)
        @unknown default:
            immersionState = .closed
            hasUserOptedInToImmersion = false
            onboardingExitPracticeActive = false
            immersionNotice = "The simulation returned an unsupported result."
            await audioDirector.setImmersiveScene(active: false, isOpen: false)
        }
    }

    /// Leaves the immersive simulation and returns control to the shared-space dashboard.
    func dismissSimulation(using dismissImmersiveSpace: DismissImmersiveSpaceAction) async {
        guard immersionState == .open else { return }

        immersionState = .dismissing
        if onboardingExitPracticeActive && selectedPracticeExperience == .onboarding {
            onboardingExitPracticeCompleted = true
            onboardingExitPracticeActive = false
        }
        await dismissImmersiveSpace()
        await audioDirector.setImmersiveScene(active: false, isOpen: false)
        immersionState = .closed
        isSimulationRoomTransitionInFlight = false
        isSimulationPaused = false
        immersionNotice = nil
        hasUserOptedInToImmersion = false
    }

    /// Pauses app-owned scene activity. RealityKit rendering remains available for safe exit controls.
    func toggleSimulationPause() {
        guard immersionState == .open else { return }
        isSimulationPaused.toggle()
        if selectedPracticeExperience == .onboarding {
            onboardingPausePracticeCompleted = true
        }
        immersionNotice = isSimulationPaused ? "Simulation paused." : nil
    }

    /// Reconciles state when the system closes the immersive space independently of the exit button.
    func simulationSpaceDidDisappear() {
        immersionState = .closed
        isSimulationRoomTransitionInFlight = false
        isSimulationPaused = false
        hasUserOptedInToImmersion = false
        onboardingExitPracticeActive = false
        Task {
            await audioDirector.setImmersiveScene(active: false, isOpen: false)
        }
    }
}
