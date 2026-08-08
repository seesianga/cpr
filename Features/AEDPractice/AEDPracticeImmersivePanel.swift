import SwiftUI

struct AEDPracticeImmersivePanel: View {
    @Environment(\.lifesaverVisualStyle) private var visualStyle
    let model: AEDPracticeSessionModel
    let currentScene: SpatialSceneName
    let onRequestPlacementRoom: () -> Void
    let onRestart: () -> Void
    let onReturnToDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("AED TRAINER — SIMULATED", systemImage: "waveform.path.ecg")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(model.guidanceTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(model.guidanceBody)
                .foregroundStyle(.secondary)

            if let explanation = model.handTrackingFallbackExplanation {
                Label(explanation, systemImage: "hand.raised.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch model.loadState {
            case .idle:
                ProgressView("Loading source-backed AED practice…")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .lifesaverStatusChip(.critical)
            case .ready:
                controls
                    .disabled(model.isPaused)
            }

            Text("Every spatial action has a labelled control below. The simulated shock delivers no electricity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 620)
        .padding(24)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private var controls: some View {
        if currentScene == .aedPreparationRoom, model.state == .powerOn {
            powerOnControls
        } else if currentScene == .aedPreparationRoom, !model.isPreparationComplete {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.preparationItems) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.instruction.title).font(.headline)
                                Spacer()
                                if item.isComplete {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(
                                            visualStyle.foregroundColor(for: .success)
                                        )
                                }
                            }
                            Text(item.instruction.body)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Button(item.isComplete ? "Completed" : accessibleActionTitle(item.condition)) {
                                model.completePreparation(item.condition)
                            }
                            .buttonStyle(.bordered)
                            .disabled(item.isComplete)
                            .accessibilityHint("Accessible alternative to selecting the matching preparation prop")
                        }
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 430)
        } else if currentScene == .aedPreparationRoom {
            Label("All presented chest-preparation checks complete", systemImage: "checkmark.seal.fill")
                .lifesaverStatusChip(.success)
            Button("Continue to pad-placement room", systemImage: "arrow.right") {
                onRequestPlacementRoom()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Loads the AED pad-placement room while preserving this session")
        } else {
            placementAndAEDControls
        }
    }

    @ViewBuilder
    private var placementAndAEDControls: some View {
        switch model.state {
        case .powerOn:
            powerOnControls

        case .awaitingPads:
            VStack(alignment: .leading, spacing: 10) {
                Text(model.padPlacementInstruction?.body ?? "Follow the pad pictures.")
                    .font(.footnote)
                HStack {
                    Button("Place right pad in right zone") {
                        model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Alternative to dragging the right pad below the right collarbone")
                    Button("Place left pad in left zone") {
                        model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: true)
                    }
                    .buttonStyle(.borderedProminent)
                    // fact.aed.padPlacementAdult
                    .accessibilityHint(AEDPadPlacementGuidance.accessibleLeftPadHint)
                }
                Button("Practise an incorrect placement") {
                    model.placePadUsingAccessibleControl(rightPad: true, inCorrectZone: false)
                    model.placePadUsingAccessibleControl(rightPad: false, inCorrectZone: false)
                }
                .buttonStyle(.bordered)
            }

        case .padsIncorrect:
            Button("Retry pad placement", systemImage: "arrow.counterclockwise") {
                model.retryPadPlacement()
            }
            .buttonStyle(.borderedProminent)

        case .padsCorrect, .clearConfirmation:
            clearSweepControls

        case .analysing:
            VStack(alignment: .leading, spacing: 8) {
                Label("HANDS OFF — simulated analysis", systemImage: "hand.raised.fill")
                    .lifesaverStatusChip(.warning)
                HStack {
                    Button("Trainer says shock advised") {
                        model.receiveAnalysisOutcome(.shock)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Trainer says no shock advised") {
                        model.receiveAnalysisOutcome(.noShock)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

        case .shockAdvised:
            Button("Begin simulated charging", systemImage: "bolt.fill") {
                model.beginCharging()
            }
            .buttonStyle(.borderedProminent)

        case .charging:
            Button("Charging prompt complete", systemImage: "checkmark") {
                model.finishCharging()
            }
            .buttonStyle(.borderedProminent)

        case .noShockAdvised, .simulatedShock:
            VStack(alignment: .leading, spacing: 9) {
                if let caption = model.resumeCaptionCue {
                    Label(caption, systemImage: "captions.bubble.fill")
                        .font(.headline)
                        .lifesaverStatusChip(.critical)
                        .accessibilityLabel("Caption cue: \(caption)")
                }
                Text(
                    "Coached countdown: \(model.resumeCoachingSecondsRemaining ?? 0) seconds remaining"
                )
                .font(.title3.monospacedDigit().bold())
                .accessibilityLabel(
                    "\(model.resumeCoachingSecondsRemaining ?? 0) seconds remaining to resume compressions"
                )
                Text("Resume immediately; the countdown is a visible safety backstop, not permission to delay.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Resume compressions now", systemImage: "heart.fill") {
                    model.resumeCompressions()
                }
                .buttonStyle(.borderedProminent)
            }

        case .resumeCompressions:
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Contact cycles").font(.caption).foregroundStyle(.secondary)
                        Text("\(model.guidedCompressionCount)")
                            .font(.title3.monospacedDigit())
                    }
                    VStack(alignment: .leading) {
                        Text("Interaction cadence")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(guidedCadenceText)
                            .font(.title3.monospacedDigit())
                    }
                    Circle()
                        .fill(model.visualMetronomePulse ? Color.red : Color.blue)
                        .frame(width: model.visualMetronomePulse ? 32 : 24)
                        .accessibilityLabel(
                            "Visual metronome at \(Int(CPRPracticePolicy.sourceBacked.practiceTempoPerMinute)) compressions per minute"
                        )
                }
                Text("Target cadence: \(model.targetRateText). Depth, force, and recoil are Not physically assessed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Finish AED practice", systemImage: "checkmark.seal") {
                    model.finish()
                }
                .buttonStyle(.borderedProminent)
            }

        case .complete:
            VStack(alignment: .leading, spacing: 6) {
                Label("Internal practice complete", systemImage: "checkmark.seal.fill")
                    .lifesaverStatusChip(.success)
                Text("This is not SRFAC certification. Practical competency requires instructor sign-off.")
                    .font(.footnote)
                HStack {
                    Button("Practise again", systemImage: "arrow.counterclockwise") {
                        onRestart()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Return to dashboard", systemImage: "rectangle.portrait.and.arrow.right") {
                        onReturnToDashboard()
                    }
                    .buttonStyle(.bordered)
                }
            }

        case nil:
            EmptyView()
        }
    }

    private var powerOnControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let instruction = model.powerOnInstruction {
                Text(instruction.title)
                    .font(.headline)
                Text(instruction.body)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Switch on simulated AED", systemImage: "power") {
                model.pressPowerButton()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                "Accessible alternative to gazing and pinching the AED power button"
            )
        }
    }

    private var clearSweepControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Interactive clear check: complete all three actions")
                .font(.headline)
            HStack {
                ForEach(["bystander_01", "bystander_02"], id: \.self) { entityName in
                    Button(model.bystanderClearStates[entityName] == true ? "Bystander clear ✓" : "Confirm bystander clear") {
                        model.confirmBystanderClear(entityName)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Alternative to gazing and pinching \(entityName.replacingOccurrences(of: "_", with: " "))")
                }
            }
            Button(model.clearZoneActivated ? "Clear-zone ring activated ✓" : "Activate clear-zone ring") {
                model.activateClearZone()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Alternative to gazing and pinching the clear-zone ring; this does not replace checking both bystanders")

            if model.state == .clearConfirmation {
                Button("Press simulated shock control", systemImage: "bolt.trianglebadge.exclamationmark.fill") {
                    model.pressSimulatedShockControl()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.clearZoneActivated || !model.allBystandersConfirmedClear)
                .accessibilityHint("Available only after the interactive ring sweep and both bystander confirmations")
            }
        }
    }

    private func accessibleActionTitle(_ condition: AEDChestCondition) -> String {
        switch condition {
        case .hairPreventsPadContact: "Use training razor"
        case .jewelleryAtPadSite: "Move jewellery clear"
        case .implantedDeviceNearPadSite: "Confirm four-finger clearance"
        case .medicationPatchAtPadSite: "Remove simulated patch"
        case .wetChest: "Dry simulated chest"
        }
    }

    private var guidedCadenceText: String {
        guard let cadence = model.guidedCadencePerMinute else {
            return model.targetRateText
        }
        return "\(Int(cadence.rounded()))/min"
    }
}
