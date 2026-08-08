import SwiftUI

enum DebriefAwardPersistenceState: Sendable, Equatable {
    case pending
    case saving
    case saved(xp: Int)
    case practiceOnly(explanation: String)
    case failed
}

/// Calm, evidence-first after-action review. All values were derived from the event log.
struct DebriefView: View {
    let debrief: ScenarioDebrief
    let awardState: DebriefAwardPersistenceState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("After-action review")
                        .font(.largeTitle.bold())
                    Text("Internal completion record — not SRFAC certification")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(
                        debrief.scoreOutcome.percentage / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                        .font(.title.monospacedDigit())
                        .accessibilityLabel("Overall score")
                }

                GroupBox("Safety-first category scores") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(debrief.scoreOutcome.contributions, id: \.dimension) { contribution in
                            HStack {
                                Label(
                                    contribution.dimension.displayName,
                                    systemImage: contribution.normalisedScore >= 0.6
                                        ? "checkmark.circle"
                                        : "arrow.clockwise.circle"
                                )
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(contribution.normalisedScore, format: .percent)
                                        .monospacedDigit()
                                    Text("Weight \(contribution.weight, format: .percent)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(
                                        "Contribution \(contribution.weightedScore, format: .percent)"
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "\(contribution.dimension.displayName): score \(contribution.normalisedScore.formatted(.percent)), weight \(contribution.weight.formatted(.percent)), weighted contribution \(contribution.weightedScore.formatted(.percent))"
                            )
                        }
                    }
                }

                GroupBox("Physical interaction feedback") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let breakdown = debrief.physicalPerformance {
                            performanceRow(
                                "CPR location accuracy",
                                percentage: breakdown.cprLocationAccuracyPercentage
                            )
                            performanceRow(
                                "AED pad placement accuracy",
                                percentage: breakdown.padPlacementAccuracyPercentage
                            )
                            performanceRow(
                                "CPR tempo accuracy",
                                percentage: breakdown.tempoAccuracyPercentage
                            )
                            Divider()
                            performanceRow(
                                "Composite interaction score",
                                percentage: breakdown.compositePercentage
                            )
                            DisclosureGroup("Source references") {
                                ForEach(breakdown.sourceReferences) { reference in
                                    Text("\(reference.document), \(reference.edition), \(reference.section), p. \(reference.page)")
                                        .font(.footnote)
                                }
                            }
                        } else {
                            Text("No physical pad-placement evidence was recorded. Accessible completion remains fully supported and is not scored as zero.")
                                .foregroundStyle(.secondary)
                        }

                        Divider()
                        Label("Depth: Not physically assessed", systemImage: "ruler")
                        Label(
                            "Force: Not physically assessed",
                            systemImage: "gauge.with.dots.needle.33percent"
                        )
                        Label("Recoil: Not physically assessed", systemImage: "arrow.up.and.down")
                    }
                }

                if !debrief.feedback.isEmpty {
                    GroupBox("Guided corrections") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(debrief.feedback) { feedback in
                                VStack(alignment: .leading, spacing: 5) {
                                    Label(feedback.title, systemImage: "exclamationmark.shield")
                                        .font(.headline)
                                    Text(feedback.remediation)
                                    DisclosureGroup("Source references") {
                                        ForEach(feedback.sourceReferences) { reference in
                                            Text("\(reference.document), \(reference.edition), \(reference.section), p. \(reference.page)")
                                                .font(.footnote)
                                        }
                                    }
                                    Text("Replay anchor: event \(feedback.replayAnchor.sequence + 1)")
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                GroupBox("Recorded timeline") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(debrief.timeline) { item in
                            HStack(alignment: .top) {
                                Image(systemName: item.isSafetyCritical ? "shield" : "circle.fill")
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(item.title).font(.headline)
                                    Text(item.detail).foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }

                GroupBox("Next practice") {
                    Text("Recommended in \(debrief.practiceRecommendation.daysUntilNextPractice) days")
                        .font(.headline)
                    Text(debrief.practiceRecommendation.reason)
                        .foregroundStyle(.secondary)
                    awardStatus
                }
            }
            .padding(24)
        }
        .navigationTitle("Debrief")
    }

    @ViewBuilder
    private var awardStatus: some View {
        switch awardState {
        case .pending, .saving:
            Label("Saving internal completion record…", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline)
        case let .saved(xp):
            Label("XP added to this learner record: \(xp)", systemImage: "checkmark.seal.fill")
                .font(.subheadline.monospacedDigit())
        case let .practiceOnly(explanation):
            Label(
                "Practice only — no completion record, XP, or badge was saved. \(explanation)",
                systemImage: "shield.slash.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.orange)
        case .failed:
            Label(
                "The completion record could not be saved. No XP was added.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(.orange)
        }
    }

    private func performanceRow(
        _ title: String,
        percentage: Double?
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let percentage {
                Text("\(percentage.formatted(.number.precision(.fractionLength(0))))%")
                    .monospacedDigit()
            } else {
                Text("Not assessed from physical interaction")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
