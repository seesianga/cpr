import RealityKit
import SwiftData
import SwiftUI

/// Mixed-immersion practice host with permanently visible pause and exit controls.
struct SimulationSpaceRootView: View {
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(AppModel.self) private var appModel
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage(AudioPreferenceKeys.reduceMotion) private var appReduceMotion = false

    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var loadedScene: SpatialSceneName?
    @State private var assetRegistry = AssetRegistry()
    @State private var spatialAudioManager = SpatialAudioManager()
    @State private var cprSession = CPRPracticeSessionModel()
    @State private var aedSession = AEDPracticeSessionModel()
    @State private var drsabcSession = DRSABCPracticeSessionModel()
    @State private var integratedScenarioSession = IntegratedScenarioSessionModel()
    @State private var draggedPadName: String?
    @State private var draggedPadOffset = SIMD3<Float>.zero
    @State private var comfortSession = ImmersionComfortSession()
    @State private var persistedCPRAttemptID: String?
    @State private var persistedAEDAttemptID: String?
    @State private var persistedDRSABCAttemptID: String?
    @State private var persistedScenarioAttemptID: String?
    @State private var debriefAwardState: DebriefAwardPersistenceState = .pending
    @State private var spatialSpeechCaption: SpatialSpeechCaptionPlayback?
    @State private var spatialAudioSceneStarted: SpatialSceneName?
    @State private var controlsAnchor: AnchorEntity?
    @State private var restartTask: Task<Void, Never>?
    @State private var restartGeneration = 0

    private var effectiveReduceMotion: Bool {
        SpatialAccessibility.effectiveReduceMotion(
            systemSetting: systemReduceMotion,
            appSetting: appReduceMotion
        )
    }

    var body: some View {
        RealityView { content, attachments in
            let controlsAnchor = ImmersivePanelPlacementPolicy.makeAnchor()
            controlsAnchor.name = "simulation_controls_anchor"
            self.controlsAnchor = controlsAnchor
            if let controls = attachments.entity(for: "simulation-interface") {
                let horizontalOffset: Float = switch appModel.onboardingDominantHand {
                case .left: -0.10
                case .right: 0.10
                case .noPreference: 0
                case nil: 0
                }
                controls.position = ImmersivePanelPlacementPolicy.interfaceOffset(
                    horizontalBias: horizontalOffset,
                    isSeated: appModel.onboardingComfortPosture == .seated
                )
                controlsAnchor.addChild(controls)
            }
            content.add(controlsAnchor)

            do {
                let selectedScene = appModel.selectedSimulationScene
                if let loadedScene, loadedScene != selectedScene {
                    if Self.isIntegratedScenarioScene(loadedScene) {
                        integratedScenarioSession.stopHandTracking()
                    }
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
                spatialAudioSceneStarted = nil
                loadedScene = selectedScene
                appModel.simulationRoomDidLoad(selectedScene)
                isLoading = false
                loadErrorMessage = nil

                if scenePhase == .active && appModel.immersionState == .open {
                    await startSpatialSceneAudio(for: selectedScene)
                }

                if appModel.selectedPracticeExperience == .cpr,
                   selectedScene == .cprPracticeRoom {
                    let targets = try assetRegistry.handTrackingTargets(
                        in: scene,
                        for: selectedScene
                    )
                    cprSession.configureHandTracking(targets: targets)
                    if !appModel.isSimulationPaused {
                        await cprSession.startHandTracking()
                    }
                } else if appModel.selectedPracticeExperience == .aed,
                          selectedScene == .aedPreparationRoom ||
                          selectedScene == .aedPlacementRoom {
                    let targets = try assetRegistry.handTrackingTargets(
                        in: scene,
                        for: selectedScene
                    )
                    aedSession.configureHandTracking(targets: targets)
                    configureAEDPhysicalInteraction(in: scene)
                    if !appModel.isSimulationPaused {
                        await aedSession.startHandTracking()
                    }
                } else if appModel.selectedPracticeExperience == .integratedScenario,
                          Self.isIntegratedScenarioScene(selectedScene) {
                    let targets = try assetRegistry.handTrackingTargets(
                        in: scene,
                        for: selectedScene
                    )
                    integratedScenarioSession.configureHandTracking(targets: targets)
                    if !appModel.isSimulationPaused {
                        await integratedScenarioSession.startHandTracking()
                    }
                } else if appModel.selectedPracticeExperience == .integratedScenario {
                    integratedScenarioSession.stopHandTracking()
                }

                #if DEBUG
                if UserDefaults.standard.bool(forKey: "developer.showTorsoGridOverlay"),
                   let grid = assetRegistry.torsoGridMap(in: scene) {
                    scene.addChild(TorsoGridDebugOverlay.make(from: grid))
                }
                #endif
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
                let pulseScale: Float = !effectiveReduceMotion && cprSession.visualMetronomePulse
                    ? 1.08
                    : 1.0
                sternum.scale = SIMD3<Float>(repeating: pulseScale)
            }

            if appModel.selectedPracticeExperience == .integratedScenario,
               let scene = content.entities.first(where: { $0.name == sceneName }) {
                updateRecordedEventReplayMarker(in: scene)
            }

            if appModel.selectedPracticeExperience == .aed,
               let scene = content.entities.first(where: { $0.name == sceneName }) {
                applyAEDPhysicalPadPresentation(in: scene)
            }
        } attachments: {
            Attachment(id: "simulation-interface") {
                VStack(spacing: 14) {
                    safetyControls
                    practicePanel
                    if comfortSession.isBreakSuggestionVisible {
                        comfortBreakSuggestion
                    }
                    AudioCaptionOverlay(audioDirector: appModel.audioDirector)
                    SpatialSpeechCaptionOverlay(playback: spatialSpeechCaption)
                }
            }
        }
        .id(appModel.selectedSimulationScene)
        .gesture(spatialTapGesture)
        .simultaneousGesture(padDragGesture)
        .task(id: appModel.selectedPracticeExperience) {
            await waitForOpenImmersion()
            guard appModel.immersionState == .open else { return }
            cprSession.setAudioDirector(appModel.audioDirector)
            aedSession.setAudioDirector(appModel.audioDirector)
            switch appModel.selectedPracticeExperience {
            case .onboarding:
                break
            case .cpr:
                persistedCPRAttemptID = nil
                await cprSession.prepare()
                guard !Task.isCancelled,
                      appModel.immersionState == .open,
                      appModel.selectedPracticeExperience == .cpr
                else {
                    await cprSession.stop()
                    return
                }
                if appModel.isSimulationPaused {
                    await cprSession.setPaused(true)
                }
            case .aed:
                if aedSession.state == nil {
                    persistedAEDAttemptID = nil
                }
                aedSession.prepareIfNeeded()
            case .drsabc:
                persistedDRSABCAttemptID = nil
                drsabcSession.prepare()
            case .integratedScenario:
                guard let scenarioID = appModel.selectedIntegratedScenarioID,
                      let patternID = appModel.selectedIntegratedScenarioPatternID
                else { break }
                // Room changes recreate the RealityView. Retain an active or completed
                // engine; an explicit restart clears it before preparing a fresh attempt.
                guard integratedScenarioSession.engine == nil else { break }
                persistedScenarioAttemptID = nil
                debriefAwardState = .pending
                await integratedScenarioSession.prepare(
                    scenarioID: scenarioID,
                    patternID: patternID,
                    audioDirector: appModel.audioDirector,
                    modelContainer: modelContext.container
                )
                guard !Task.isCancelled,
                      appModel.immersionState == .open,
                      appModel.selectedPracticeExperience == .integratedScenario,
                      appModel.selectedIntegratedScenarioID == scenarioID,
                      appModel.selectedIntegratedScenarioPatternID == patternID
                else {
                    integratedScenarioSession.stop()
                    return
                }
                if appModel.isSimulationPaused {
                    await integratedScenarioSession.setPaused(true)
                }
            }
        }
        .task {
            comfortSession.startIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                comfortSession.update()
            }
        }
        .onChange(of: appModel.isSimulationPaused, initial: true) { _, paused in
            switch appModel.selectedPracticeExperience {
            case .cpr:
                Task { await cprSession.setPaused(paused) }
            case .aed:
                aedSession.setPaused(paused)
            case .drsabc:
                drsabcSession.setPaused(paused)
            case .integratedScenario:
                Task { await integratedScenarioSession.setPaused(paused) }
            case .onboarding:
                break
            }
            Task {
                for channel in AudioChannel.allCases {
                    if paused {
                        await appModel.audioDirector.pause(channel)
                    } else {
                        await appModel.audioDirector.resume(channel)
                    }
                }
                if !paused,
                   scenePhase == .active,
                   appModel.immersionState == .open,
                   let loadedScene {
                    await startSpatialSceneAudio(for: loadedScene)
                }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
            spatialAudioManager.setSceneActive(
                newPhase == .active && appModel.immersionState == .open
            )
            if newPhase != .active { spatialAudioSceneStarted = nil }
            if newPhase == .active {
                comfortSession.resume()
                if !appModel.isSimulationPaused, let loadedScene {
                    Task { @MainActor in
                        await startSpatialSceneAudio(for: loadedScene)
                    }
                }
            } else {
                comfortSession.suspend()
            }
        }
        .onChange(of: appModel.immersionState, initial: true) { _, state in
            let active = state == .open && scenePhase == .active
            spatialAudioManager.setSceneActive(active)
            if !active { spatialAudioSceneStarted = nil }
            guard active, let loadedScene else { return }
            Task { @MainActor in
                await startSpatialSceneAudio(for: loadedScene)
            }
        }
        .onChange(of: aedSession.state) { _, newState in
            Task { @MainActor in
                await playSpatialAEDCue(for: newState)
            }
            if newState == .complete {
                persistStandaloneAttempt(
                    id: UUID().uuidString,
                    persistedID: &persistedAEDAttemptID,
                    contentVersion: aedSession.contentVersion,
                    activityID: "M5-aed-practice",
                    attemptKind: "aed-practice",
                    score: aedSession.criticalFailures.isEmpty ? 100 : 0,
                    passed: aedSession.criticalFailures.isEmpty,
                    criticalErrorCodes: aedSession.criticalFailures.map(\.rawValue),
                    responseJSON: "{\"eventLogCount\":\(aedSession.eventLogCount)}",
                    resultSummary: "Source-backed AED trainer completion"
                )
            }
        }
        .onChange(of: aedSession.spatialCueRequest) { _, request in
            guard let request else { return }
            Task { @MainActor in
                _ = try? await spatialAudioManager.play(
                    request.cue,
                    route: .aedUnit
                )
                await appModel.audioDirector.presentVisualCue(request.cue)
            }
        }
        .onChange(of: integratedScenarioSession.aedState) { _, newState in
            Task { @MainActor in
                await playSpatialAEDCue(for: newState)
            }
        }
        .onChange(of: cprSession.summary) { _, summary in
            guard let summary else { return }
            persistCPRAttempt(summary)
        }
        .onChange(of: drsabcSession.state) { _, state in
            guard state == .step(.complete) else { return }
            persistStandaloneAttempt(
                id: UUID().uuidString,
                persistedID: &persistedDRSABCAttemptID,
                contentVersion: drsabcSession.contentVersion,
                activityID: "M3-drsabc-sequence-practice",
                attemptKind: "drsabc-practice",
                score: drsabcSession.criticalFailures.isEmpty ? 100 : 0,
                passed: drsabcSession.criticalFailures.isEmpty,
                criticalErrorCodes: drsabcSession.criticalFailures.map(\.rawValue),
                responseJSON: "{\"eventLogCount\":\(drsabcSession.eventLogCount)}",
                resultSummary: "Source-backed DRSABC sequence completion"
            )
        }
        .onChange(of: integratedScenarioSession.debrief) { _, debrief in
            guard let debrief else { return }
            debriefAwardState = .saving
            let persistenceGeneration = restartGeneration
            Task { @MainActor in
                await persistScenarioAttempt(debrief)
                guard restartGeneration == persistenceGeneration,
                      appModel.immersionState == .open,
                      appModel.selectedPracticeExperience == .integratedScenario,
                      integratedScenarioSession.debrief == debrief
                else { return }
                appModel.moveIntegratedScenarioToDebrief()
            }
        }
        .onDisappear {
            if appModel.immersionState == .open,
               appModel.isSimulationRoomTransitionInFlight {
                if let loadedScene, Self.isIntegratedScenarioScene(loadedScene) {
                    integratedScenarioSession.stopHandTracking()
                }
                spatialAudioManager.stopAll()
                spatialSpeechCaption = nil
                spatialAudioSceneStarted = nil
                return
            }
            spatialAudioManager.stopAll()
            spatialSpeechCaption = nil
            spatialAudioSceneStarted = nil
            assetRegistry.releaseAllScenes()
            loadedScene = nil
            controlsAnchor = nil
            restartGeneration &+= 1
            restartTask?.cancel()
            restartTask = nil
            aedSession.stop()
            Task { await cprSession.stop() }
            integratedScenarioSession.stop()
            comfortSession.reset()
            appModel.simulationSpaceDidDisappear()
        }
    }

    private var safetyControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                simulationHeading
                Spacer()
                loadingStatus
                safetyButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    simulationHeading
                    Spacer()
                    loadingStatus
                }
                safetyButtons
            }
        }
        .frame(maxWidth: 620)
        .padding(18)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private var practicePanel: some View {
        ScrollView {
            if let loadErrorMessage {
                VStack(spacing: 8) {
                    Label("Scene unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(loadErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 560)
                .padding(20)
                .glassBackgroundEffect()
            } else {
                switch appModel.selectedPracticeExperience {
                case .onboarding:
                    OnboardingPracticeImmersivePanel()
                case .cpr:
                    CPRPracticeImmersivePanel(
                        model: cprSession,
                        reduceMotion: effectiveReduceMotion,
                        learnerID: authenticationModel.currentUser?.id ?? "",
                        onRestart: restartCPRPractice,
                        onReturnToDashboard: returnToDashboard
                    )
                case .aed:
                    AEDPracticeImmersivePanel(
                        model: aedSession,
                        currentScene: appModel.selectedSimulationScene,
                        onRequestPlacementRoom: {
                            requestAEDPlacementRoom()
                        },
                        onRestart: restartAEDPractice,
                        onReturnToDashboard: returnToDashboard
                    )
                case .drsabc:
                    DRSABCPracticeImmersivePanel(
                        model: drsabcSession,
                        onRestart: restartDRSABCPractice,
                        onReturnToDashboard: returnToDashboard
                    )
                case .integratedScenario:
                    IntegratedScenarioImmersivePanel(
                        model: integratedScenarioSession,
                        awardState: debriefAwardState,
                        onRestart: restartIntegratedScenario,
                        onReturnToDashboard: returnToDashboard
                    )
                }
            }
        }
        .frame(maxHeight: 620)
        .scrollIndicators(.visible)
    }

    private var simulationHeading: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SIMULATION")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(appModel.selectedPracticeExperience.title)
                .font(.headline)
        }
    }

    @ViewBuilder
    private var loadingStatus: some View {
        if isLoading {
            ProgressView().accessibilityLabel("Loading practice room")
        } else if loadErrorMessage != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Practice room unavailable")
        }
    }

    private var safetyButtons: some View {
        HStack(spacing: 12) {
            Button(backButtonTitle, systemImage: backButtonSystemImage) {
                if isAEDPlacementRoom {
                    requestAEDPreparationRoom()
                } else {
                    Task { await exitSimulation() }
                }
            }
            .buttonStyle(.bordered)
            .accessibilityHint(
                isAEDPlacementRoom
                    ? "Returns to the preparation room without clearing this AED practice session"
                    : "Ends this session and returns to the shared-space dashboard"
            )

            Button(
                appModel.isSimulationPaused ? "Resume" : "Pause",
                systemImage: appModel.isSimulationPaused ? "play.fill" : "pause.fill"
            ) {
                appModel.toggleSimulationPause()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Pauses or resumes the practice engine, audio, and visible room")

            Button("Recentre panel", systemImage: "viewfinder") {
                recentreSimulationPanel()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Recentre simulation panel")
            .accessibilityHint(
                "Places the panel once at a comfortable distance in the direction you are currently looking"
            )

            Button("Exit", systemImage: "xmark.circle.fill") {
                Task { await exitSimulation() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Ends hand input and returns to the shared-space dashboard")
        }
    }

    private var isAEDPlacementRoom: Bool {
        appModel.selectedPracticeExperience == .aed &&
            appModel.selectedSimulationScene == .aedPlacementRoom
    }

    private var backButtonTitle: String {
        isAEDPlacementRoom ? "Back to AED preparation" : "Back to dashboard"
    }

    private var backButtonSystemImage: String {
        isAEDPlacementRoom ? "arrow.left" : "rectangle.portrait.and.arrow.right"
    }

    private func recentreSimulationPanel() {
        guard let controlsAnchor else { return }
        ImmersivePanelPlacementPolicy.recentre(controlsAnchor)
    }

    private var comfortBreakSuggestion: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Comfort break suggested", systemImage: "figure.mind.and.body")
                .font(.headline)
            Text("You have spent about 12 minutes in immersion. Pause or Exit whenever you wish; this suggestion never exits automatically.")
                .font(.footnote)
            Button("Dismiss Suggestion", systemImage: "checkmark") {
                comfortSession.dismissSuggestion()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Keeps the immersive session open and hides this persistent suggestion")
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(18)
        .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 18))
        .glassBackgroundEffect()
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
        case .onboarding:
            break
        case .cpr:
            guard let target = Self.semanticAncestor(
                of: entity,
                matching: ["sternum_target", "xiphoid_avoid_zone", "control_panel"]
            ) else { return }
            playInterfaceSFX("sfx.pinch_confirm")
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
            playInterfaceSFX("sfx.pinch_confirm")
            switch target.name {
            case "aed_power_button":
                aedSession.pressPowerButton()
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
            playInterfaceSFX("sfx.pinch_confirm")
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
        case .integratedScenario:
            guard let target = Self.semanticAncestor(
                of: entity,
                matching: [
                    "training_manikin", "bystander_01", "bystander_02",
                    "sternum_target", "xiphoid_avoid_zone",
                    "aed_case", "aed_unit", "aed_power_button",
                    "aed_shock_button", "aed_status_light", "aed_connector",
                    "aed_left_pad", "aed_right_pad",
                    "aed_left_pad_zone", "aed_right_pad_zone", "clear_zone"
                ]
            ) else { return }
            if handleIntegratedScenarioTap(targetName: target.name) {
                playInterfaceSFX("sfx.pinch_confirm")
            }
        }
    }

    @discardableResult
    private func handleIntegratedScenarioTap(targetName: String) -> Bool {
        switch (integratedScenarioSession.stage, targetName) {
        case (.response, "training_manikin"):
            integratedScenarioSession.checkResponse()

        case (.delegation, "bystander_01"),
             (.delegation, "bystander_02"):
            integratedScenarioSession.assignSelectedTask(
                to: targetName,
                method: .gazeAndPinch
            )

        case (.cpr, "sternum_target"):
            integratedScenarioSession.performCPR(unsafeXiphoidPlacement: false)

        case (.cpr, "xiphoid_avoid_zone"):
            integratedScenarioSession.performCPR(unsafeXiphoidPlacement: true)

        case (.aedPreparation, "aed_case"),
             (.aedPreparation, "aed_unit"),
             (.aedPreparation, "aed_power_button"),
             (.aedPreparation, "aed_connector"),
             (.aedPreparation, "aed_left_pad"),
             (.aedPreparation, "aed_right_pad"),
             (.aedPreparation, "aed_left_pad_zone"),
             (.aedPreparation, "aed_right_pad_zone"):
            integratedScenarioSession.prepareAndApplyAED()

        case (.aedAnalysisClear, "clear_zone"):
            integratedScenarioSession.confirmClearForAEDAnalysis(anyoneTouching: false)

        case (.aedAnalysingDecision, "aed_unit"),
             (.aedAnalysingDecision, "aed_status_light"):
            integratedScenarioSession.receiveAEDAnalysisDecision()

        case (.aedCharging, "aed_unit"),
             (.aedCharging, "aed_status_light"):
            integratedScenarioSession.completeAEDCharging(anyoneTouching: false)

        case (.aedClearConfirmation, "clear_zone"):
            integratedScenarioSession.confirmClearBeforeSimulatedShock(anyoneTouching: false)

        case (.aedSimulatedShock, "aed_shock_button"):
            integratedScenarioSession.deliverSimulatedShock(anyoneTouching: false)

        case (.aedResume, "sternum_target"):
            integratedScenarioSession.resumeCPRAfterAEDDecision()

        default:
            return false
        }
        return true
    }

    /// Registers the descriptor-resolved pinch-grabbable items with the AED session.
    /// The physical path is additive; every gaze-pinch and button control remains.
    private func configureAEDPhysicalInteraction(in scene: Entity) {
        let descriptor = assetRegistry.practiceAssetDescriptor
        let itemsByIdentifier = Dictionary(
            uniqueKeysWithValues: assetRegistry.pinchGrabItems(in: scene)
                .map { ($0.identifier, $0) }
        )
        var padItems: [AEDPadSide: PinchGrabItem] = [:]
        if let rightPad = itemsByIdentifier[descriptor.patches.rightPadEntityName] {
            padItems[.right] = rightPad
        }
        if let leftPad = itemsByIdentifier[descriptor.patches.leftPadEntityName] {
            padItems[.left] = leftPad
        }
        aedSession.configurePhysicalInteraction(
            padItems: padItems,
            powerButton: itemsByIdentifier[
                descriptor.defibrillator.powerButtonEntityName
            ]
        )
    }

    /// Renders the model's physical pad state: an actively grabbed pad follows the pinch
    /// midpoint; a released pad moves to its resolved resting position exactly once.
    private func applyAEDPhysicalPadPresentation(in scene: Entity) {
        if let grab = aedSession.activePadGrab,
           let pad = assetRegistry.firstEntity(named: grab.itemIdentifier, in: scene) {
            pad.setPosition(grab.midpointWorld, relativeTo: nil)
        }
        if let snap = aedSession.padSnapPresentation {
            if let pad = assetRegistry.firstEntity(named: snap.itemIdentifier, in: scene) {
                pad.setPosition(snap.worldPosition, relativeTo: nil)
            }
            Task { @MainActor in
                aedSession.acknowledgePadSnap(snap)
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

    private func playInterfaceSFX(_ id: String) {
        Task {
            _ = await appModel.audioDirector.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: id),
                    channel: .soundEffects,
                    context: .immersive,
                    autoplay: true
                )
            )
        }
    }

    private func requestAEDPlacementRoom() {
        isLoading = true
        loadErrorMessage = nil
        appModel.moveAEDPractice(to: .aedPlacementRoom)
    }

    private func requestAEDPreparationRoom() {
        isLoading = true
        loadErrorMessage = nil
        appModel.moveAEDPractice(to: .aedPreparationRoom)
    }

    private func restartCPRPractice() {
        guard restartTask == nil,
              appModel.immersionState == .open,
              !appModel.isSimulationPaused,
              appModel.selectedPracticeExperience == .cpr
        else { return }
        persistedCPRAttemptID = nil
        restartGeneration &+= 1
        let generation = restartGeneration
        restartTask = Task { @MainActor in
            defer { finishRestart(generation: generation) }
            await cprSession.prepare()
            guard restartIsCurrent(
                generation: generation,
                experience: .cpr
            ) else {
                await cprSession.stop()
                return
            }
            if appModel.isSimulationPaused {
                await cprSession.setPaused(true)
            } else {
                await cprSession.startHandTracking()
            }
        }
    }

    private func restartAEDPractice() {
        persistedAEDAttemptID = nil
        aedSession.prepare()
        if appModel.selectedSimulationScene != .aedPreparationRoom {
            requestAEDPreparationRoom()
        }
    }

    private func restartDRSABCPractice() {
        persistedDRSABCAttemptID = nil
        drsabcSession.prepare()
    }

    private func restartIntegratedScenario() {
        guard restartTask == nil,
              appModel.immersionState == .open,
              appModel.selectedPracticeExperience == .integratedScenario,
              let scenarioID = appModel.selectedIntegratedScenarioID,
              let patternID = appModel.selectedIntegratedScenarioPatternID,
              let scene = integratedScenarioSession.scenarioScene
        else { return }

        persistedScenarioAttemptID = nil
        debriefAwardState = .pending
        restartGeneration &+= 1
        let generation = restartGeneration
        restartTask = Task { @MainActor in
            defer { finishRestart(generation: generation) }
            await integratedScenarioSession.reset()
            guard restartIsCurrent(
                generation: generation,
                experience: .integratedScenario
            ) else {
                integratedScenarioSession.stop()
                return
            }
            await integratedScenarioSession.prepare(
                scenarioID: scenarioID,
                patternID: patternID,
                audioDirector: appModel.audioDirector,
                modelContainer: modelContext.container
            )
            guard restartIsCurrent(
                generation: generation,
                experience: .integratedScenario
            ) else {
                integratedScenarioSession.stop()
                return
            }
            if appModel.isSimulationPaused {
                await integratedScenarioSession.setPaused(true)
            }
            if appModel.selectedSimulationScene != scene.spatialSceneName {
                isLoading = true
                loadErrorMessage = nil
            } else if !appModel.isSimulationPaused {
                await integratedScenarioSession.startHandTracking()
                guard restartIsCurrent(
                    generation: generation,
                    experience: .integratedScenario
                ) else {
                    integratedScenarioSession.stop()
                    return
                }
            }
            appModel.moveIntegratedScenarioBackToScene(scene)
        }
    }

    private func returnToDashboard() {
        Task { await exitSimulation() }
    }

    private func restartIsCurrent(
        generation: Int,
        experience: SpatialPracticeExperience
    ) -> Bool {
        !Task.isCancelled &&
            restartGeneration == generation &&
            appModel.immersionState == .open &&
            appModel.selectedPracticeExperience == experience
    }

    private func finishRestart(generation: Int) {
        guard restartGeneration == generation else { return }
        restartTask = nil
    }

    @MainActor
    private func waitForOpenImmersion() async {
        while appModel.immersionState == .opening, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    private func startSpatialSceneAudio(for scene: SpatialSceneName) async {
        guard scenePhase == .active,
              appModel.immersionState == .open,
              !appModel.isSimulationPaused,
              loadedScene == scene,
              spatialAudioSceneStarted != scene
        else { return }

        spatialAudioSceneStarted = scene
        spatialSpeechCaption = nil
        if appModel.selectedPracticeExperience == .integratedScenario,
           integratedScenarioSession.debrief == nil {
            let safetyState = AEDAudioSafetyState.forPracticeState(
                integratedScenarioSession.aedState
            )
            let correctionActive = integratedScenarioSession.stage == .correction
            await appModel.audioDirector.setAEDSafetyState(safetyState)
            await appModel.audioDirector.setSafetyCriticalCorrectionActive(
                correctionActive
            )
            _ = await appModel.audioDirector.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: "music.scenario_bed"),
                    context: .immersive,
                    autoplay: true
                )
            )
        } else if appModel.selectedPracticeExperience == .aed {
            await appModel.audioDirector.setAEDSafetyState(
                AEDAudioSafetyState.forPracticeState(aedSession.state)
            )
            await appModel.audioDirector.setSafetyCriticalCorrectionActive(
                aedSession.hasActiveSafetyCorrection
            )
        }
        if scene == .academyLobby {
            _ = try? await spatialAudioManager.play(
                AudioCue(rawValue: "music.academy_hub"),
                route: .roomAmbience,
                shouldLoop: true
            )
            if appModel.selectedPracticeExperience == .onboarding {
                let guideCue = AudioCue(rawValue: "nar.M0.intro")
                if (try? await spatialAudioManager.play(
                    guideCue,
                    route: .companionGuide
                )) != nil {
                    spatialSpeechCaption = SpatialSpeechCaptionPlayback(
                        cue: guideCue,
                        startedAt: .now,
                        rate: AudioPreferencesStore().snapshot().narrationSpeed
                    )
                }
            }
        }

        if scene == .debriefSpace,
           integratedScenarioSession.debrief != nil {
            let arrivalCue = AudioCue(rawValue: "sfx.paramedic_arrival")
            _ = try? await spatialAudioManager.play(
                arrivalCue,
                route: .paramedicDoor
            )
            await appModel.audioDirector.presentVisualCue(arrivalCue)
        }
    }

    private func exitSimulation() async {
        let pendingRestart = restartTask
        restartGeneration &+= 1
        pendingRestart?.cancel()
        restartTask = nil
        await cprSession.stop()
        aedSession.stop()
        integratedScenarioSession.stop()
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

    private static func isIntegratedScenarioScene(_ scene: SpatialSceneName) -> Bool {
        switch scene {
        case .scenarioHome,
             .scenarioShoppingCentre,
             .scenarioWorkplace,
             .scenarioCommunityFacility:
            true
        default:
            false
        }
    }

    /// Reconstructs the event-log replay anchor as a static spatial highlight at the
    /// relevant semantic entity. It stays visible until the learner acknowledges the
    /// correction and never pulses when Reduce Motion is enabled.
    private func updateRecordedEventReplayMarker(in scene: Entity) {
        let markerName = "recorded_event_replay_marker"
        scene.findEntity(named: markerName)?.removeFromParent()
        guard let correction = integratedScenarioSession.correction else { return }

        let targetName: String = switch correction.replayAnchor.domain {
        case .drsabc:
            if correction.code.contains("unsafe_scene") {
                "safety_hazards"
            } else if correction.code.contains("help_not_activated") {
                "bystander_01"
            } else {
                "training_manikin"
            }
        case .cpr:
            "xiphoid_avoid_zone"
        case .aed:
            correction.code.contains("clear") || correction.code.contains("touching")
                ? "clear_zone"
                : "aed_unit"
        }

        let marker = ModelEntity(
            mesh: .generateSphere(radius: 0.055),
            materials: [SimpleMaterial(color: .orange, isMetallic: false)]
        )
        marker.name = markerName
        marker.components.set(OpacityComponent(opacity: 0.72))
        if let target = assetRegistry.firstEntity(named: targetName, in: scene) {
            marker.position = [0, 0.14, 0]
            target.addChild(marker)
        } else {
            marker.position = [0, 1.25, -1.15]
            scene.addChild(marker)
        }
    }

    @MainActor
    private func persistCPRAttempt(_ summary: CPRPracticeSessionSummary) {
        let outcome = summary.scoreOutcome
        guard persistedCPRAttemptID == nil,
              let user = authenticationModel.currentUser,
              !user.id.isEmpty,
              let encoded = try? JSONEncoder().encode(summary),
              let responseJSON = String(data: encoded, encoding: .utf8)
        else { return }

        persistedCPRAttemptID = outcome.attemptID
        modelContext.insert(
            AttemptRecord(
                id: outcome.attemptID,
                learnerID: user.id,
                activityID: "M4-cpr-rhythm-practice",
                courseID: "lifesaver-vision-cpr-aed-spatial-academy",
                contentVersion: outcome.contentVersion,
                attemptKind: "cpr-practice",
                startedAt: .now,
                completedAt: .now,
                score: outcome.percentage,
                passed: outcome.passed,
                criticalErrorCodes: outcome.remediationCodes,
                responseJSON: responseJSON,
                resultSummary: summary.recordLabel
            )
        )

        do {
            let unlockedBadge = try persistNewCPRBadgeAwards(
                learnerID: user.id,
                contentVersion: outcome.contentVersion
            )
            try modelContext.save()
            if unlockedBadge { playBadgeUnlockedCue() }
        } catch {
            modelContext.rollback()
            persistedCPRAttemptID = nil
        }
    }

    @MainActor
    private func persistStandaloneAttempt(
        id: String,
        persistedID: inout String?,
        contentVersion: String?,
        activityID: String,
        attemptKind: String,
        score: Double,
        passed: Bool,
        criticalErrorCodes: [String],
        responseJSON: String,
        resultSummary: String
    ) {
        guard persistedID == nil,
              let contentVersion,
              !contentVersion.isEmpty,
              let user = authenticationModel.currentUser,
              !user.id.isEmpty
        else { return }

        persistedID = id
        modelContext.insert(
            AttemptRecord(
                id: id,
                learnerID: user.id,
                activityID: activityID,
                courseID: "lifesaver-vision-cpr-aed-spatial-academy",
                contentVersion: contentVersion,
                attemptKind: attemptKind,
                startedAt: .now,
                completedAt: .now,
                score: score,
                passed: passed,
                criticalErrorCodes: criticalErrorCodes,
                responseJSON: responseJSON,
                resultSummary: resultSummary
            )
        )
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            persistedID = nil
        }
    }

    @MainActor
    private func persistNewCPRBadgeAwards(
        learnerID: String,
        contentVersion: String
    ) throws -> Bool {
        guard let decision = cprSession.gamificationDecision else { return false }
        let descriptor = FetchDescriptor<BadgeAward>(
            predicate: #Predicate { $0.learnerID == learnerID }
        )
        let existingBadgeIDs = Set(try modelContext.fetch(descriptor).map(\.badgeID))
        let newAwards = decision.newBadgeAwards.filter {
            !existingBadgeIDs.contains($0.badgeID)
        }
        for award in newAwards {
            modelContext.insert(
                BadgeAward(
                    id: award.id,
                    learnerID: award.learnerID,
                    badgeID: award.badgeID,
                    awardedAt: award.awardedAt,
                    contentVersion: contentVersion,
                    sourceAttemptID: award.sourceAttemptID,
                    reason: "Source-backed CPR practice evidence"
                )
            )
        }
        return !newAwards.isEmpty
    }

    private func playBadgeUnlockedCue() {
        Task {
            _ = await appModel.audioDirector.play(
                AudioPlaybackRequest(
                    cue: AudioCue(rawValue: "sfx.badge_unlocked"),
                    channel: .soundEffects,
                    context: .immersive,
                    autoplay: true
                )
            )
        }
    }

    @MainActor
    private func persistScenarioAttempt(_ debrief: ScenarioDebrief) async {
        debriefAwardState = .saving
        guard case let .scored(startAuthorization) = integratedScenarioSession.scoringDecision,
              startAuthorization.scenarioID == debrief.scenarioID,
              startAuthorization.contentVersion == debrief.scoreOutcome.contentVersion
        else {
            debriefAwardState = .practiceOnly(
                explanation: integratedScenarioSession.scoringDecision.practiceOnlyExplanation
                    ?? ScenarioPracticeOnlyReason.attemptContentMismatch.learnerExplanation
            )
            return
        }

        let persistenceDecision: ScenarioScoringDecision
        do {
            let document = try ScenarioDefinitionsCodec.load()
            persistenceDecision = await ScenarioScoringGate().authorizeBundledPersistence(
                document: document,
                debrief: debrief,
                eventLog: integratedScenarioSession.eventLog,
                modelContainer: modelContext.container
            )
        } catch {
            persistenceDecision = .practiceOnly(.contentUnavailable)
        }
        guard case .scored = persistenceDecision else {
            debriefAwardState = .practiceOnly(
                explanation: persistenceDecision.practiceOnlyExplanation
                    ?? ScenarioPracticeOnlyReason.notVerified.learnerExplanation
            )
            return
        }

        guard persistedScenarioAttemptID == nil,
              let user = authenticationModel.currentUser,
              !user.id.isEmpty,
              let encoded = try? JSONEncoder().encode(integratedScenarioSession.eventLog),
              let responseJSON = String(data: encoded, encoding: .utf8)
        else {
            debriefAwardState = .failed
            return
        }

        let attemptID = UUID().uuidString
        let metadata = ScenarioPersistenceMetadata(debrief: debrief)
        persistedScenarioAttemptID = attemptID
        let attempt = AttemptRecord(
            id: attemptID,
            learnerID: user.id,
            activityID: debrief.scenarioID,
            courseID: metadata.courseID,
            contentVersion: metadata.contentVersion,
            attemptKind: "integrated-scenario",
            startedAt: .now,
            completedAt: .now,
            score: debrief.scoreOutcome.percentage,
            passed: debrief.scoreOutcome.passed,
            criticalErrorCodes: debrief.feedback.map(\.code),
            responseJSON: responseJSON,
            resultSummary: "Event-log-derived after-action review"
        )
        modelContext.insert(attempt)

        do {
            let unlockedBadge = try awardScenarioBadges(
                attemptID: attemptID,
                learnerID: user.id,
                debrief: debrief
            )
            try modelContext.save()
            debriefAwardState = .saved(xp: debrief.recommendedXP)
            if unlockedBadge { playBadgeUnlockedCue() }
        } catch {
            modelContext.rollback()
            persistedScenarioAttemptID = nil
            debriefAwardState = .failed
        }
    }

    @MainActor
    private func awardScenarioBadges(
        attemptID: String,
        learnerID: String,
        debrief: ScenarioDebrief
    ) throws -> Bool {
        let attemptsDescriptor = FetchDescriptor<AttemptRecord>(
            predicate: #Predicate { $0.learnerID == learnerID }
        )
        let awardsDescriptor = FetchDescriptor<BadgeAward>(
            predicate: #Predicate { $0.learnerID == learnerID }
        )
        let signOffDescriptor = FetchDescriptor<PracticalSignOff>(
            predicate: #Predicate { $0.learnerID == learnerID }
        )
        let priorAttempts = try modelContext.fetch(attemptsDescriptor)
            .filter { $0.id != attemptID && $0.passed == true && $0.criticalErrorCodes.isEmpty }
        let storedAwards = try modelContext.fetch(awardsDescriptor)
        let signOffs = try modelContext.fetch(signOffDescriptor)
        let contributionByDimension = Dictionary(
            uniqueKeysWithValues: debrief.scoreOutcome.contributions.map {
                ($0.dimension, $0.normalisedScore)
            }
        )
        let actionIDs = Set(integratedScenarioSession.eventLog.compactMap { record -> String? in
            guard record.wasAccepted,
                  case let .requiredActionCompleted(actionID, _) = record.event
            else { return nil }
            return actionID
        })
        var metricValues: [String: Double] = [
            "dangerChecks": actionIDs.contains(where: { $0.hasSuffix("action-assess-scene") }) ? 1 : 0,
            "activationChecks": actionIDs.contains(where: { $0.hasSuffix("action-activate-help") }) ? 1 : 0,
            "clearChecks": actionIDs.contains(where: { $0.hasSuffix("action-clear-for-aed") }) ? 1 : 0,
            "communicationScore": contributionByDimension[.communication] ?? 0,
            "successfulPracticeCount": Double(priorAttempts.count + (debrief.scoreOutcome.xpEligible ? 1 : 0)),
            "approvedSignOffCount": Double(signOffs.filter {
                $0.statusRawValue == PracticalSignOffStatus.approved.rawValue
            }.count)
        ]
        if let cadenceAccuracy = debrief.cprCadenceAccuracy {
            metricValues["rhythmAccuracy"] = cadenceAccuracy
        }
        if let longestGap = debrief.longestCompressionGapSeconds {
            metricValues["longestInterruptionSeconds"] = longestGap
        }
        let hasPadPlacementEvidence = integratedScenarioSession.eventLog.contains { record in
            guard record.wasAccepted,
                  case .aed(.placePads) = record.event
            else { return false }
            return true
        }
        if hasPadPlacementEvidence {
            metricValues["padPlacementAccuracy"] =
                contributionByDimension[.aedPreparationAndPlacement] ?? 0
        }
        let metrics = BadgeMetricSnapshot(values: metricValues)
        let existingAwards = storedAwards.map {
            BadgeAwardValue(
                id: $0.id,
                learnerID: $0.learnerID,
                badgeID: $0.badgeID,
                title: $0.badgeID,
                sourceAttemptID: $0.sourceAttemptID ?? "",
                awardedAt: $0.awardedAt
            )
        }
        let signOffValues = signOffs.compactMap { signOff -> PracticalSignOffValue? in
            guard let status = PracticalSignOffStatus(rawValue: signOff.statusRawValue) else {
                return nil
            }
            return PracticalSignOffValue(
                id: signOff.id,
                learnerID: signOff.learnerID,
                courseID: signOff.courseID,
                contentVersion: signOff.contentVersion,
                status: status,
                signedAt: signOff.signedAt
            )
        }
        let decision = GamificationEngine().evaluate(
            event: GamificationEvent(
                learnerID: learnerID,
                courseID: ScenarioPersistenceMetadata(debrief: debrief).courseID,
                contentVersion: debrief.scoreOutcome.contentVersion,
                sourceAttemptID: attemptID,
                completedAt: .now,
                scoreOutcome: debrief.scoreOutcome
            ),
            currentXP: priorAttempts.count * 100,
            metrics: metrics,
            existingAwards: existingAwards,
            approvedSignOffs: signOffValues,
            policy: .standard(badgeRules: try BadgeRuleCodec.loadBundled())
        )
        for award in decision.newBadgeAwards {
            modelContext.insert(
                BadgeAward(
                    id: award.id,
                    learnerID: award.learnerID,
                    badgeID: award.badgeID,
                    awardedAt: award.awardedAt,
                    contentVersion: debrief.scoreOutcome.contentVersion,
                    sourceAttemptID: award.sourceAttemptID,
                    reason: "Source-backed safe scenario evidence"
                )
            )
        }
        return !decision.newBadgeAwards.isEmpty
    }
}
