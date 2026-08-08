import SwiftUI

struct DRSABCPracticeImmersivePanel: View {
    let model: DRSABCPracticeSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(DRSABCPracticeSessionModel.simulationBadge)
                .font(.caption.bold())
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.red.opacity(0.12), in: Capsule())
                .accessibilityAddTraits(.isHeader)

            Text(model.guidanceTitle)
                .font(.title2.bold())
            Text(model.guidanceBody)
                .foregroundStyle(.secondary)

            switch model.loadState {
            case .idle:
                ProgressView("Loading source-backed DRSABC practice…")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .ready:
                Group {
                    if let correction = model.activeCorrection {
                        correctiveFeedback(correction)
                    } else {
                        stepControls
                    }
                }
                .disabled(model.isPaused)
            }
        }
        .frame(maxWidth: 620)
        .padding(24)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private var stepControls: some View {
        switch model.currentStep {
        case .danger:
            buttonGrid([
                ("Scene is safe", "checkmark.shield", { model.inspectDanger(sceneUnsafe: false, enteredUnsafeScene: false) }),
                ("Hazard found — stay back", "exclamationmark.triangle", { model.inspectDanger(sceneUnsafe: true, enteredUnsafeScene: false) }),
                ("Enter despite hazard (unsafe)", "xmark.shield", { model.inspectDanger(sceneUnsafe: true, enteredUnsafeScene: true) })
            ])

        case .response:
            buttonGrid([
                ("Casualty is unresponsive", "person.fill.questionmark", { model.checkResponse(isUnresponsive: true) }),
                ("Casualty responds", "person.wave.2", { model.checkResponse(isUnresponsive: false) })
            ])

        case .shout:
            buttonGrid([
                ("Shout and activate help", "megaphone.fill", { model.shoutForHelp(helpActivated: true) }),
                ("Continue without calling for help", "speaker.slash", { model.shoutForHelp(helpActivated: false) })
            ])

        case .simulatedCall995:
            VStack(alignment: .leading, spacing: 8) {
                Text(model.simulatedCallTitle).font(.headline)
                Text(model.simulatedCallBody)
                if !model.dispatcherReminder.isEmpty {
                    Label(model.dispatcherReminder, systemImage: "phone.bubble")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Complete simulated call rehearsal", systemImage: "phone.down.fill") {
                    model.rehearseSimulatedCall()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Records only an in-app rehearsal; no call is placed")
            }

        case .aedDelegation:
            buttonGrid([
                ("AED within about a 60-second walk — ask bystander to fetch", "figure.walk", { model.delegateAED(bystanderAvailable: true, aedNear: true, learnerLeavesCasualty: false) }),
                ("Bystander present — AED farther away, continue response", "phone.bubble", { model.delegateAED(bystanderAvailable: true, aedNear: false, learnerLeavesCasualty: false) }),
                ("Alone — stay with casualty", "person.fill.checkmark", { model.delegateAED(bystanderAvailable: false, aedNear: false, learnerLeavesCasualty: false) }),
                ("Alone — leave casualty (unsafe)", "person.fill.xmark", { model.delegateAED(bystanderAvailable: false, aedNear: true, learnerLeavesCasualty: true) })
            ])

        case .breathingCheck:
            buttonGrid([
                ("Breathing absent, abnormal, or unsure", "lungs", { model.assessBreathing(durationSeconds: 8, casualtyGasping: false, breathingNormal: false, treatedGaspingAsNormal: false) }),
                ("Gasping — not normal", "waveform.path", { model.assessBreathing(durationSeconds: 8, casualtyGasping: true, breathingNormal: false, treatedGaspingAsNormal: false) }),
                ("Mistake gasping as normal", "exclamationmark.triangle", { model.assessBreathing(durationSeconds: 8, casualtyGasping: true, breathingNormal: true, treatedGaspingAsNormal: true) }),
                ("Normal breathing observed", "lungs.fill", { model.assessBreathing(durationSeconds: 8, casualtyGasping: false, breathingNormal: true, treatedGaspingAsNormal: false) }),
                ("Check longer than 10 seconds", "timer", { model.assessBreathing(durationSeconds: 11, casualtyGasping: false, breathingNormal: false, treatedGaspingAsNormal: false) })
            ])

        case .compressions, .responsiveCasualty, .monitoringNormalBreathing:
            Button("Complete guided DRSABC branch", systemImage: "checkmark.seal") {
                model.completeTerminalStep()
            }
            .buttonStyle(.borderedProminent)

        case .complete:
            VStack(alignment: .leading, spacing: 6) {
                Label("Internal practice complete", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("This is not SRFAC certification. Practical competency requires instructor sign-off.")
                    .font(.footnote)
            }

        case nil:
            EmptyView()
        }
    }

    private func correctiveFeedback(_ correction: DRSABCRemediation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(correction.message, systemImage: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            ForEach(correction.sourceFactIDs, id: \.self) { factID in
                Text("Clinical fact: \(factID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ForEach(model.activeCorrectionSourceCitations) { citation in
                Text("Source: \(citation.document), \(citation.edition), \(citation.section), page \(citation.page)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Review guidance and retry", systemImage: "arrow.counterclockwise") {
                if model.currentStep == .danger {
                    model.confirmSceneMitigated()
                } else {
                    model.acknowledgeCorrection()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
    }

    private func buttonGrid(
        _ items: [(String, String, () -> Void)]
    ) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230))], spacing: 9) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(item.0, systemImage: item.1, action: item.2)
                    .buttonStyle(.bordered)
            }
        }
    }
}
