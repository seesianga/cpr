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
    @State private var persistedScenarioAttemptID: String?
    @State private var spatialSpeechCaption: SpatialSpeechCaptionPlayback?
    @State private var spatialAudioSceneStarted: SpatialSceneName?

    private var effectiveReduceMotion: Bool {
        SpatialAccessibility.effectiveReduceMotion(
            systemSetting: systemReduceMotion,
            appSetting: appReduceMotion
        )
    }

    var body: some View {
        RealityView { content, attachments in
            let controlsAnchor = AnchorEntity(.head)
            controlsAnchor.name = "simulation_controls_anchor"
            if let controls = attachments.entity(for: "simulation-interface") {
                let horizontalOffset: Float = switch appModel.onboardingDominantHand {
                case .left: -0.10
                case .right: 0.10
                case .noPreference: 0
                case nil: 0
                }
                let verticalOffset: Float = appModel.onboardingComfortPosture == .seated
                    ? -0.12
                    : -0.04
                controls.position = [horizontalOffset, verticalOffset, -1.35]
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
                spatialAudioSceneStarted = nil
                loadedScene = selectedScene
                appModel.simulationRoomDidLoad(selectedScene)
                isLoading = false
                loadErrorMessage = nil

                if scenePhase == .active && appModel.immersionState == .open {
                    await startSpatialSceneAudio(for: selectedScene)
                }

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
                let pulseScale: Float = !effectiveReduceMotion && cprSession.visualMetronomePulse
                    ? 1.08
                    : 1.0
                sternum.scale = SIMD3<Float>(repeating: pulseScale)
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
                await cprSession.prepare()
            case .aed:
                aedSession.prepare()
            case .drsabc:
                drsabcSession.prepare()
            case .integratedScenario:
                guard let scenarioID = appModel.selectedIntegratedScenarioID,
                      let patternID = appModel.selectedIntegratedScenarioPatternID
                else { break }
                // Loading DebriefSpace recreates the RealityView. Retain the immutable
                // completed session instead of preparing (and erasing) it again.
                guard integratedScenarioSession.debrief == nil else { break }
                persistedScenarioAttemptID = nil
                integratedScenarioSession.prepare(
                    scenarioID: scenarioID,
                    patternID: patternID,
                    audioDirector: appModel.audioDirector
                )
            }
        }
        .task {
            comfortSession.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                comfortSession.update()
            }
        }
        .onChange(of: appModel.isSimulationPaused, initial: true) { _, paused in
            aedSession.setPaused(paused)
            drsabcSession.setPaused(paused)
            integratedScenarioSession.setPaused(paused)
            Task { await cprSession.setPaused(paused) }
            Task {
                for channel in AudioChannel.allCases {
                    if paused {
                        await appModel.audioDirector.pause(channel)
                    } else {
                        await appModel.audioDirector.resume(channel)
                    }
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
        .onChange(of: integratedScenarioSession.debrief) { _, debrief in
            guard let debrief else { return }
            persistScenarioAttempt(debrief)
            appModel.moveIntegratedScenarioToDebrief()
        }
        .onDisappear {
            if appModel.immersionState == .open,
               appModel.isSimulationRoomTransitionInFlight {
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
            aedSession.stop()
            Task { await cprSession.stop() }
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
                        reduceMotion: effectiveReduceMotion
                    )
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
                case .integratedScenario:
                    IntegratedScenarioImmersivePanel(model: integratedScenarioSession)
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
            Button(
                appModel.isSimulationPaused ? "Resume" : "Pause",
                systemImage: appModel.isSimulationPaused ? "play.fill" : "pause.fill"
            ) {
                appModel.toggleSimulationPause()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Pauses or resumes the practice engine, audio, and visible room")

            Button("Exit", systemImage: "xmark.circle.fill") {
                Task { await exitSimulation() }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Ends hand input and returns to the shared-space dashboard")
        }
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
                matching: ["bystander_01", "bystander_02", "sternum_target", "xiphoid_avoid_zone"]
            ) else { return }
            playInterfaceSFX("sfx.pinch_confirm")
            switch target.name {
            case "bystander_01", "bystander_02":
                integratedScenarioSession.assignSelectedTask(
                    to: target.name,
                    method: .gazeAndPinch
                )
            case "sternum_target":
                integratedScenarioSession.performCPR(unsafeXiphoidPlacement: false)
            case "xiphoid_avoid_zone":
                integratedScenarioSession.performCPR(unsafeXiphoidPlacement: true)
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
              loadedScene == scene,
              spatialAudioSceneStarted != scene
        else { return }

        spatialAudioSceneStarted = scene
        spatialSpeechCaption = nil
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

    @MainActor
    private func persistScenarioAttempt(_ debrief: ScenarioDebrief) {
        guard persistedScenarioAttemptID == nil,
              let user = authenticationModel.currentUser,
              !user.id.isEmpty,
              let encoded = try? JSONEncoder().encode(integratedScenarioSession.eventLog),
              let responseJSON = String(data: encoded, encoding: .utf8)
        else { return }

        let attemptID = UUID().uuidString
        persistedScenarioAttemptID = attemptID
        let attempt = AttemptRecord(
            id: attemptID,
            learnerID: user.id,
            activityID: debrief.scenarioID,
            courseID: "lifesaver-vision-cpr-aed-spatial-academy",
            contentVersion: "1.0.0",
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
            try awardScenarioBadges(
                attemptID: attemptID,
                learnerID: user.id,
                debrief: debrief
            )
            try modelContext.save()
        } catch {
            persistedScenarioAttemptID = nil
        }
    }

    @MainActor
    private func awardScenarioBadges(
        attemptID: String,
        learnerID: String,
        debrief: ScenarioDebrief
    ) throws {
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
        let metrics = BadgeMetricSnapshot(values: [
            "dangerChecks": actionIDs.contains(where: { $0.hasSuffix("action-assess-scene") }) ? 1 : 0,
            "activationChecks": actionIDs.contains(where: { $0.hasSuffix("action-activate-help") }) ? 1 : 0,
            "rhythmAccuracy": contributionByDimension[.cprSequenceAndRhythm] ?? 0,
            "longestInterruptionSeconds": debrief.feedback.contains(where: {
                $0.code.contains("prolonged_compression_interruption")
            }) ? 11 : 0,
            "padPlacementAccuracy": contributionByDimension[.aedPreparationAndPlacement] ?? 0,
            "clearChecks": actionIDs.contains(where: { $0.hasSuffix("action-clear-for-aed") }) ? 1 : 0,
            "communicationScore": contributionByDimension[.communication] ?? 0,
            "successfulPracticeCount": Double(priorAttempts.count + (debrief.scoreOutcome.xpEligible ? 1 : 0)),
            "approvedSignOffCount": Double(signOffs.filter {
                $0.statusRawValue == PracticalSignOffStatus.approved.rawValue
            }.count)
        ])
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
                courseID: "lifesaver-vision-cpr-aed-spatial-academy",
                contentVersion: "1.0.0",
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
                    contentVersion: "1.0.0",
                    sourceAttemptID: award.sourceAttemptID,
                    reason: "Source-backed safe scenario evidence"
                )
            )
        }
        if !decision.newBadgeAwards.isEmpty {
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
    }
}
