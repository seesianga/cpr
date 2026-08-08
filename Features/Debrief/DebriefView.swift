import SwiftUI

/// Calm, evidence-first after-action review. All values were derived from the event log.
struct DebriefView: View {
    let debrief: ScenarioDebrief

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
                                Text(contribution.normalisedScore, format: .percent)
                                    .monospacedDigit()
                            }
                            .accessibilityElement(children: .combine)
                        }
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
                    Text("Recommended XP: \(debrief.recommendedXP)")
                        .font(.subheadline.monospacedDigit())
                }
            }
            .padding(24)
        }
        .navigationTitle("Debrief")
    }
}
