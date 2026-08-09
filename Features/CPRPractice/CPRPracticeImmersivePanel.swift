import SwiftUI

struct CPRInterruptionPresentation: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case inactive
        case underway
        case thresholdExceeded
    }

    let status: Status

    init(seconds: Double) {
        if seconds > 10 {
            status = .thresholdExceeded
        } else if seconds > 0 {
            status = .underway
        } else {
            status = .inactive
        }
    }

    var label: String {
        switch status {
        case .inactive: "No active interruption"
        case .underway: "Interruption underway"
        case .thresholdExceeded: "Over the 10-second interruption threshold"
        }
    }

    var systemImage: String {
        switch status {
        case .inactive: "checkmark.circle"
        case .underway: "timer"
        case .thresholdExceeded: "exclamationmark.triangle.fill"
        }
    }

    var isThresholdExceeded: Bool { status == .thresholdExceeded }
}

/// Head-anchored CPR coaching panel. Spatial targets and every button submit the same
/// typed events through `CPRPracticeSessionModel`.
struct CPRPracticeImmersivePanel: View {
    @Environment(\.lifesaverVisualStyle) private var visualStyle
    @State private var isDistanceLogExpanded = false
    let model: CPRPracticeSessionModel
    let reduceMotion: Bool
    let learnerID: String
    let onRestart: () -> Void
    let onReturnToDashboard: () -> Void

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

            if let explanation = model.handTrackingFallbackExplanation {
                Label(explanation, systemImage: "hand.raised.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            switch model.loadState {
            case .idle, .loading:
                ProgressView("Loading source-backed practice…")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .lifesaverStatusChip(.critical)
            case .ready:
                practiceContent
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
        .frame(maxWidth: 560)
        .padding(24)
        .glassBackgroundEffect()
        .disabled(model.isPaused)
    }

    @ViewBuilder
    private var practiceContent: some View {
        if let summary = model.summary {
            summaryView(summary)
        } else {
            gripStatusRow
            if model.state == .compressionCycles,
               model.handTrackingState != .running {
                recordCompressionButton
            }
            metricsStrip
            distanceLogSection
            controls
        }
    }

    /// Whether the trainer currently has the two-hand grip, so the learner knows
    /// compressions are being counted without reaching for the fallback control.
    private var gripStatusRow: some View {
        Label(model.gripStatusText, systemImage: gripStatusSymbol)
            .font(.footnote)
            .lifesaverStatusChip(gripStatusRole)
            .accessibilityLabel(model.gripStatusText)
    }

    private var gripStatusSymbol: String {
        guard model.isAutomaticCountingActive else { return "hand.raised.slash" }
        return model.handStacking == .likelyStacked
            ? "hands.and.sparkles.fill"
            : "hand.point.up.braille"
    }

    private var gripStatusRole: LifesaverStatusRole {
        guard model.isAutomaticCountingActive else { return .warning }
        return model.handStacking == .likelyStacked ? .success : .neutral
    }

    /// Per-descent contact distance log. Collapsed by default so the coaching panel stays
    /// calm; expanded it explains why each descent did or did not count.
    @ViewBuilder
    private var distanceLogSection: some View {
        let samples = model.compressionDistanceLog
        if !samples.isEmpty {
            let entries = CPRCompressionDistanceLogPresenter.entries(from: samples)
            let summary = CPRCompressionDistanceLogPresenter.summary(from: samples)
            DisclosureGroup(isExpanded: $isDistanceLogExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    distanceLogTable(entries)
                    if samples.count > entries.count {
                        Text(
                            "Showing the most recent \(entries.count) of \(samples.count) descents."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Text(
                        "Travel is how far your hands moved against the virtual chest surface, and the 40–60 mm band is a movement target only. It cannot confirm real compression depth: depth, force and recoil are not physically assessed."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            } label: {
                VStack(alignment: .leading) {
                    Text("Contact distance log (virtual)").font(.caption.bold())
                    Text(summary.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHint("Lists the measured virtual travel of each recent descent")
        }
    }

    private func distanceLogTable(
        _ entries: [CPRCompressionDistanceLogEntry]
    ) -> some View {
        ScrollView(.vertical) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("#")
                    Text("Time")
                    Text("Travel")
                    Text("Band")
                    Text("Result")
                }
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

                ForEach(entries) { entry in
                    GridRow {
                        Text("\(entry.id)")
                        Text(entry.elapsedLabel)
                        Text(entry.travelLabel)
                        Text(entry.travelBand.label)
                            .foregroundStyle(
                                entry.travelBand.isWithinTargetBand ? .green : .secondary
                            )
                        Text(entry.statusLabel)
                            .foregroundStyle(entry.isCounted ? .primary : .secondary)
                    }
                    .font(.caption2.monospacedDigit())
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(entry.accessibilityLabel)
                }
            }
        }
        .frame(maxHeight: 200)
    }

    private var metricsStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { metricsContent }
            VStack(alignment: .leading, spacing: 10) { metricsContent }
        }
    }

    @ViewBuilder
    private var metricsContent: some View {
            let interruption = CPRInterruptionPresentation(
                seconds: model.liveInterruptionSeconds
            )
            VStack(alignment: .leading) {
                Text("Compressions").font(.caption).foregroundStyle(.secondary)
                Text("\(model.metrics.totalCompressions)").font(.title3.monospacedDigit())
            }
            if let travel = model.recentContactTravelAverageMetres {
                VStack(alignment: .leading) {
                    Text("Contact travel (virtual)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int((travel * 1000).rounded())) mm")
                        .font(.title3.monospacedDigit())
                    Text("Interaction distance, not physical depth")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(
                    "Average virtual contact travel \(Int((travel * 1000).rounded())) millimetres; interaction distance, not a physical depth measurement"
                )
            }
            VStack(alignment: .leading) {
                Text("Rate band").font(.caption).foregroundStyle(.secondary)
                Text(rateText).font(.title3.monospacedDigit())
                    .lifesaverStatusChip(rateStatusRole)
                Text(rateStatusText)
                    .font(.caption2)
            }
            VStack(alignment: .leading) {
                Text("Interruption timer").font(.caption).foregroundStyle(.secondary)
                Text(model.liveInterruptionSeconds, format: .number.precision(.fractionLength(1)))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(
                        interruption.isThresholdExceeded
                            ? visualStyle.foregroundColor(for: .critical)
                            : .primary
                    )
                Label(interruption.label, systemImage: interruption.systemImage)
                    .font(.caption2)
                    .lifesaverStatusChip(
                        interruption.isThresholdExceeded ? .critical : .neutral
                    )
            }
            if reduceMotion {
                Label(
                    model.visualMetronomePulse ? "Beat 1" : "Beat 2",
                    systemImage: model.visualMetronomePulse ? "1.circle.fill" : "2.circle.fill"
                )
                .font(.headline.monospacedDigit())
                .accessibilityLabel("Discrete visual metronome at 110 compressions per minute")
            } else {
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
                if model.handTrackingState == .running {
                    recordCompressionButton
                }
                HStack {
                    Button("Start short rest", systemImage: "timer") {
                        model.startRest()
                    }
                    .buttonStyle(.bordered)
                    Button("End practice", systemImage: "stop.circle") {
                        Task { await model.endSession(learnerID: learnerID) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(learnerID.isEmpty)
                    .accessibilityHint(
                        learnerID.isEmpty
                            ? "Sign in or continue as a guest before saving practice"
                            : "Creates a learner-linked internal practice record after the full cycle"
                    )
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
            Group {
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
    }

    private var recordCompressionButton: some View {
        Button("Record compression", systemImage: "hand.tap.fill") {
            model.recordFallbackCompression()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityHint("Tap repeatedly for cadence feedback when hand tracking is unavailable")
    }

    private var rateText: String {
        guard let rate = model.metrics.latestCadencePerMinute else {
            return model.targetRateText
        }
        return "\(Int(rate.rounded()))/min"
    }

    private var rateStatusRole: LifesaverStatusRole {
        guard let band = model.metrics.cadenceBands.last else { return .neutral }
        return band == .withinSupportedBand ? .success : .warning
    }

    private var rateStatusText: String {
        guard let band = model.metrics.cadenceBands.last else {
            return "Waiting for rhythm evidence"
        }
        return band == .withinSupportedBand
            ? "Within supported rhythm band"
            : "Adjust rhythm toward the supported band"
    }
}
