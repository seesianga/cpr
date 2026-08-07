import SwiftUI

/// Head-anchored CPR coaching panel. Spatial targets and every button submit the same
/// typed events through `CPRPracticeSessionModel`.
struct CPRPracticeImmersivePanel: View {
    let model: CPRPracticeSessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("CPR PRACTICE", systemImage: "heart.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)
            Text(model.guidanceTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(model.guidanceBody)
                .foregroundStyle(.secondary)

            switch model.loadState {
            case .idle, .loading:
                ProgressView("Loading source-backed practice…")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .ready:
                practiceContent
            }

            if let explanation = model.handTrackingFallbackExplanation {
                Label(explanation, systemImage: "hand.raised.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if model.summary == nil {
                Divider()
                HStack {
                    Label("Depth: Not physically assessed", systemImage: "ruler")
                    Label("Force: Not physically assessed", systemImage: "gauge.with.dots.needle.33percent")
                    Label("Recoil: Not physically assessed", systemImage: "arrow.up.and.down")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(width: 560)
        .padding(24)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private var practiceContent: some View {
        if let summary = model.summary {
            summaryView(summary)
        } else {
            metricsStrip
            controls
        }
    }

    private var metricsStrip: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading) {
                Text("Compressions").font(.caption).foregroundStyle(.secondary)
                Text("\(model.metrics.totalCompressions)").font(.title3.monospacedDigit())
            }
            VStack(alignment: .leading) {
                Text("Rate band").font(.caption).foregroundStyle(.secondary)
                Text(rateText).font(.title3.monospacedDigit())
                    .foregroundStyle(rateColour)
            }
            VStack(alignment: .leading) {
                Text("Interruption timer").font(.caption).foregroundStyle(.secondary)
                Text(model.liveInterruptionSeconds, format: .number.precision(.fractionLength(1)))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(model.liveInterruptionSeconds > 10 ? .red : .primary)
            }
            Circle()
                .fill(model.visualMetronomePulse ? Color.red : Color.blue)
                .frame(width: model.visualMetronomePulse ? 34 : 24)
                .animation(.easeInOut(duration: 0.15), value: model.visualMetronomePulse)
                .accessibilityLabel("Visual metronome at 110 compressions per minute")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .positioning:
            Button("Confirm firm, flat positioning", systemImage: "checkmark.circle") {
                model.confirmPositioning()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Continues to the hand-placement landmark check")

        case .landmarkCheck:
            HStack {
                Button("Confirm sternum target", systemImage: "scope") {
                    model.choosePlacement(.sternumTarget)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Accessible alternative to gazing and pinching the blue sternum target")
                Button("Report xiphoid zone", systemImage: "exclamationmark.triangle") {
                    model.choosePlacement(.xiphoidAvoidZone)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Accessible alternative for the red avoid zone")
            }

        case .correctiveFeedback:
            Button("Review target and retry", systemImage: "arrow.counterclockwise") {
                model.acknowledgeCorrection()
            }
            .buttonStyle(.borderedProminent)

        case .compressionCycles:
            VStack(alignment: .leading, spacing: 10) {
                Button("Record compression", systemImage: "hand.tap.fill") {
                    model.recordFallbackCompression()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Tap repeatedly for cadence feedback when hand tracking is unavailable")
                HStack {
                    Button("Start short rest", systemImage: "timer") {
                        model.startRest()
                    }
                    .buttonStyle(.bordered)
                    Button("End practice", systemImage: "stop.circle") {
                        Task { await model.endSession() }
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .restWindow:
            Button("Resume compressions", systemImage: "play.fill") {
                model.endRest()
            }
            .buttonStyle(.borderedProminent)

        case .stopped:
            ProgressView("Preparing summary…")
        case .complete:
            EmptyView()
        case nil:
            EmptyView()
        }
    }

    private func summaryView(_ summary: CPRPracticeSessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.recordLabel).font(.headline)
            Text("Internal feedback score")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(summary.scoreOutcome.percentage / 100, format: .percent.precision(.fractionLength(0)))
                .font(.largeTitle.monospacedDigit())
            Text("Compressions: \(summary.totalCompressions) · cycles: \(summary.completedCycles)")
            if let averageCadence = summary.averageCadencePerMinute {
                Text("Average interaction cadence: \(Int(averageCadence.rounded()))/min")
            }
            Text("Longest interruption: \(summary.longestInterruptionSeconds.formatted(.number.precision(.fractionLength(1)))) s")
            Label("Depth: \(summary.depthAssessment.statusLabel)", systemImage: "ruler")
            Label("Force: \(summary.forceAssessment.statusLabel)", systemImage: "gauge.with.dots.needle.33percent")
            Label("Recoil: Not physically assessed", systemImage: "arrow.up.and.down")
            if let decision = model.gamificationDecision {
                Text("XP awarded by learning rules: \(decision.xpAwarded)")
            } else {
                Text("No XP awarded")
            }
            Text(summary.certificationNotice)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var rateText: String {
        guard let rate = model.metrics.latestCadencePerMinute else {
            return model.targetRateText
        }
        return "\(Int(rate.rounded()))/min"
    }

    private var rateColour: Color {
        guard let band = model.metrics.cadenceBands.last else { return .secondary }
        return band == .withinSupportedBand ? .green : .orange
    }
}
