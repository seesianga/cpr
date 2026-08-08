import RealityKit
import SwiftUI

/// Mixed-immersion practice host with permanently visible pause and exit controls.
struct SimulationSpaceRootView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppModel.self) private var appModel

    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var loadedScene: SpatialSceneName?
    @State private var assetRegistry = AssetRegistry()
    @State private var spatialAudioManager = SpatialAudioManager()
    @State private var cprSession = CPRPracticeSessionModel()
    @State private var aedSession = AEDPracticeSessionModel()
    @State private var drsabcSession = DRSABCPracticeSessionModel()
    @State private var draggedPadName: String?
    @State private var draggedPadOffset = SIMD3<Float>.zero

    var body: some View {
        RealityView { content, attachments in
            let controlsAnchor = AnchorEntity(.head)
            controlsAnchor.name = "simulation_controls_anchor"
            if let controls = attachments.entity(for: "simulation-interface") {
                controls.position = [0, -0.04, -1.35]
                controlsAnchor.addChild(controls)
            }
            content.add(controlsAnchor)

            do {
                let selectedScene = appModel.selectedSimulationScene
                if let loadedScene, loadedScene != selectedScene {
                    assetRegistry.releaseScene(loadedScene)
                }
                let scene = try await assetRegistry.loadScene(selectedScene)
                try assetRegistry.decorateSemanticEntities(in: scene, for: selectedScene)
                scene.isEnabled = !appModel.isSimulationPaused
                content.add(scene)
                spatialAudioManager.configure(
                    in: scene,
                    sceneIsActive: scenePhase == .active && appModel.immersionState == .open
                )
                loadedScene = selectedScene
                isLoading = false
                loadErrorMessage = nil

                if selectedScene == .cprPracticeRoom {
                    let targets = try assetRegistry.handTrackingTargets(in: scene)
                    cprSession.configureHandTracking(targets: targets)
                    await cprSession.startHandTracking()
                }
            } catch is CancellationError {
                // Dismissing or changing rooms cancels loading without surfacing an error.
            } catch {
                isLoading = false
                loadErrorMessage = error.localizedDescription
            }
        } update: { content, _ in
            let sceneName = appModel.selectedSimulationScene.rawValue
            content.entities.first { $0.name == sceneName }?.isEnabled = !appModel.isSimulationPaused

            if appModel.selectedPracticeExperience == .cpr,
               let scene = content.entities.first(where: { $0.name == sceneName }),
               let sternum = assetRegistry.firstEntity(named: "sternum_target", in: scene) {
                let pulseScale: Float = cprSession.visualMetronomePulse ? 1.08 : 1.0
                sternum.scale = SIMD3<Float>(repeating: pulseScale)
            }
        } attachments: {
            Attachment(id: "simulation-interface") {
                VStack(spacing: 14) {
                    safetyControls
                    practicePanel
                    AudioCaptionOverlay(audioDirector: appModel.audioDirector)
                }
            }
        }
        .id(appModel.selectedSimulationScene)
        .gesture(spatialTapGesture)
        .simultaneousGesture(padDragGesture)
        .task(id: appModel.selectedPracticeExperience) {
            cprSession.setAudioDirector(appModel.audioDirector)
            aedSession.setAudioDirector(appModel.audioDirector)
            switch appModel.selectedPracticeExperience {
            case .cpr:
                await cprSession.prepare()
            case .aed:
                aedSession.prepare()
            case .drsabc:
                drsabcSession.prepare()
            }
        }
        .onChange(of: appModel.isSimulationPaused, initial: true) { _, paused in
            aedSession.setPaused(paused)
            drsabcSession.setPaused(paused)
            Task { await cprSession.setPaused(paused) }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
            spatialAudioManager.setSceneActive(
                newPhase == .active && appModel.immersionState == .open
            )
        }
        .onChange(of: aedSession.state) { _, newState in
            Task { @MainActor in
                await playSpatialAEDCue(for: newState)
            }
        }
        .onDisappear {
            spatialAudioManager.stopAll()
            assetRegistry.releaseAllScenes()
            loadedScene = nil
            aedSession.stop()
            Task { await cprSession.stop() }
            appModel.simulationSpaceDidDisappear()
        }
    }

    private var safetyControls: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SIMULATION")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                Text(appModel.selectedPracticeExperience.title)
                    .font(.headline)
            }
            Spacer()

            if isLoading {
                ProgressView().accessibilityLabel("Loading practice room")
            } else if loadErrorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Practice room unavailable")
            }

            Button(
                appModel.isSimulationPaused ? "Resume" : "Pause",
                systemImage: appModel.isSimulationPaused ? "play.fill" : "pause.fill"
            ) {
                appModel.toggleSimulationPause()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Pauses or resumes the practice engine and visible room")

            Button("Exit", systemImage: "xmark.circle.fill") {
                Task { await exitSimulation() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Ends hand input and returns to the shared-space dashboard")
        }
        .frame(width: 620)
        .padding(18)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private var practicePanel: some View {
        if let loadErrorMessage {
            VStack(spacing: 8) {
                Label("Scene unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(loadErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 560)
            .padding(20)
            .glassBackgroundEffect()
        } else {
            switch appModel.selectedPracticeExperience {
            case .cpr:
                CPRPracticeImmersivePanel(model: cprSession)
            case .aed:
                AEDPracticeImmersivePanel(
                    model: aedSession,
                    currentScene: appModel.selectedSimulationScene,
                    onRequestPlacementRoom: {
                        requestAEDPlacementRoom()
                    }
                )
            case .drsabc:
                DRSABCPracticeImmersivePanel(model: drsabcSession)
            }
        }
    }

    private var spatialTapGesture: some Gesture {
        TapGesture()
            .targetedToAnyEntity()
            .onEnded { value in
                guard !appModel.isSimulationPaused else { return }
                handleSpatialTap(on: value.entity)
            }
    }

    private var padDragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard appModel.selectedPracticeExperience == .aed,
                      appModel.selectedSimulationScene == .aedPlacementRoom,
                      !appModel.isSimulationPaused,
                      aedSession.state == .awaitingPads,
                      let pad = Self.semanticAncestor(
                        of: value.entity,
                        matching: ["aed_left_pad", "aed_right_pad"]
                      ),
                      let parent = pad.parent
                else { return }
                let location = value.convert(
                    value.location3D,
                    from: .local,
                    to: parent
                )
                if draggedPadName != pad.name {
                    draggedPadName = pad.name
                    draggedPadOffset = pad.position - location
                }
                pad.position = location + draggedPadOffset
            }
            .onEnded { value in
                defer {
                    draggedPadName = nil
                    draggedPadOffset = .zero
                }
                guard appModel.selectedPracticeExperience == .aed,
                      appModel.selectedSimulationScene == .aedPlacementRoom,
                      !appModel.isSimulationPaused,
                      aedSession.state == .awaitingPads,
                      let pad = Self.semanticAncestor(
                        of: value.entity,
                        matching: ["aed_left_pad", "aed_right_pad"]
                      )
                else { return }
                aedSession.placeDraggedPad(
                    padName: pad.name,
                    destinationZoneName: nearestPadZone(to: pad)
                )
            }
    }

    private func handleSpatialTap(on entity: Entity) {
        switch appModel.selectedPracticeExperience {
        case .cpr:
            guard let target = Self.semanticAncestor(
                of: entity,
                matching: ["sternum_target", "xiphoid_avoid_zone", "control_panel"]
            ) else { return }
            switch (cprSession.state, target.name) {
            case (.landmarkCheck, "sternum_target"):
                cprSession.choosePlacement(.sternumTarget)
            case (.landmarkCheck, "xiphoid_avoid_zone"):
                cprSession.choosePlacement(.xiphoidAvoidZone)
            case (.compressionCycles, "sternum_target"),
                 (.compressionCycles, "control_panel"):
                cprSession.recordFallbackCompression()
            default:
                break
            }

        case .aed:
            guard let target = Self.semanticAncestor(
                of: entity,
                matching: [
                    "training_razor", "prep_cloth", "aed_case", "aed_unit",
                    "electrode_packet", "aed_power_button", "aed_shock_button",
                    "clear_zone", "bystander_01", "bystander_02"
                ]
            ) else { return }
            switch target.name {
            case "training_razor":
                aedSession.completePreparation(.hairPreventsPadContact)
            case "prep_cloth":
                aedSession.completePreparation(.wetChest)
            case "bystander_01", "bystander_02":
                aedSession.confirmBystanderClear(target.name)
            case "clear_zone":
                aedSession.activateClearZone()
            case "aed_shock_button":
                aedSession.pressSimulatedShockControl()
            default:
                // The remaining objects are interactive orientation affordances; the
                // corresponding labelled controls provide the complete action path.
                break
            }

        case .drsabc:
            guard let target = Self.semanticAncestor(
                of: entity,
                matching: ["safety_hazards", "training_manikin", "bystander_01"]
            ) else { return }
            switch (drsabcSession.currentStep, target.name) {
            case (.danger, "safety_hazards"):
                drsabcSession.inspectDanger(sceneUnsafe: true, enteredUnsafeScene: false)
            case (.response, "training_manikin"):
                drsabcSession.checkResponse(isUnresponsive: true)
            case (.shout, "bystander_01"):
                drsabcSession.shoutForHelp(helpActivated: true)
            default:
                break
            }
        }
    }

    private func nearestPadZone(to pad: Entity) -> String? {
        var root = pad
        while let parent = root.parent { root = parent }
        let padBounds = pad.visualBounds(recursive: true, relativeTo: nil)
        guard !padBounds.isEmpty else { return nil }
        let candidates: [AEDPadDropZone] = [
            "aed_right_pad_zone", "aed_left_pad_zone"
        ].compactMap { name in
            guard let entity = assetRegistry.firstEntity(named: name, in: root) else {
                return nil
            }
            let bounds = entity.visualBounds(recursive: true, relativeTo: nil)
            guard !bounds.isEmpty else { return nil }
            return AEDPadDropZone(name: name, center: bounds.center, extents: bounds.extents)
        }
        return AEDPadDropZoneClassifier.nearestOverlappingZone(
            padCenter: padBounds.center,
            padExtents: padBounds.extents,
            zones: candidates
        )
    }

    private func requestAEDPlacementRoom() {
        isLoading = true
        loadErrorMessage = nil
        appModel.moveAEDPractice(to: .aedPlacementRoom)
    }

    private func exitSimulation() async {
        await cprSession.stop()
        aedSession.stop()
        assetRegistry.releaseAllScenes()
        loadedScene = nil
        await appModel.dismissSimulation(using: dismissImmersiveSpace)
    }

    @MainActor
    private func playSpatialAEDCue(for state: AEDPracticeState?) async {
        let cueID: String? = switch state {
        case .analysing: "sfx.aed_analysis"
        case .charging: "sfx.aed_charging"
        case .clearConfirmation: "sfx.clear_cue"
        default: nil
        }
        guard let cueID else { return }
        _ = try? await spatialAudioManager.play(
            AudioCue(rawValue: cueID),
            route: .aedUnit
        )
        await appModel.audioDirector.presentVisualCue(AudioCue(rawValue: cueID))
    }

    private static func semanticAncestor(
        of entity: Entity,
        matching names: Set<String>
    ) -> Entity? {
        var cursor: Entity? = entity
        while let candidate = cursor {
            if names.contains(candidate.name) { return candidate }
            cursor = candidate.parent
        }
        return nil
    }
}
