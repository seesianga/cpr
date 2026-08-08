import SwiftData
import SwiftUI

/// Private learning recognition. There is intentionally no public leaderboard.
struct GamificationView: View {
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.openWindow) private var openWindow
    @Query private var attempts: [AttemptRecord]
    @Query private var awards: [BadgeAward]
    @Query private var signOffs: [PracticalSignOff]

    private var learnerID: String { authenticationModel.currentUser?.id ?? "" }
    private var learnerAttempts: [PracticeAttemptEvidence] {
        attempts
            .filter { $0.learnerID == learnerID }
            .map {
                PracticeAttemptEvidence(
                    id: $0.id,
                    activityID: $0.activityID,
                    attemptKind: $0.attemptKind,
                    completedAt: $0.completedAt,
                    score: $0.score,
                    passed: $0.passed,
                    criticalErrorCodes: $0.criticalErrorCodes
                )
            }
    }
    private var learnerAwardIDs: Set<String> {
        Set(awards.filter { $0.learnerID == learnerID }.map(\.badgeID))
    }
    private var badges: [AchievementBadgeDescriptor] {
        AchievementBadgeDescriptor.catalogue(
            rules: (try? BadgeRuleCodec.loadBundled()) ?? []
        )
    }
    private var summary: PracticeDashboardSummary {
        .make(attempts: learnerAttempts, through: .now, calendar: .current)
    }
    private var isInstructorVerified: Bool {
        signOffs.contains {
            $0.learnerID == learnerID &&
            $0.statusRawValue == PracticalSignOffStatus.approved.rawValue
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Achievements")
                            .font(.largeTitle.bold())
                        Label("Private learning record · no public leaderboard", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Volumetric Gallery", systemImage: "cube.transparent") {
                        openWindow(id: AppModel.achievementGalleryWindowID)
                    }
                    .buttonStyle(.borderedProminent)
                }

                practiceOverview
                certificateStatus

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(badges) { badge in
                        badgeCard(badge)
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Progress")
    }

    private var practiceOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Practice schedule", systemImage: "calendar.badge.clock")
                .font(.title2.bold())
            if summary.successfulAttemptCount == 0 {
                Text("No safe completed practice evidence has been recorded.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(summary.practiceStreak)-day streak")
                    .font(.headline)
                Text("\(summary.successfulAttemptCount) safe completions · \(summary.derivedXP) learning XP")
                if let due = summary.nextReviewDate {
                    Label(
                        "Recommended next practice: \(due.formatted(date: .long, time: .omitted))",
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                if !summary.personalBests.isEmpty {
                    Divider()
                    Text("Personal bests").font(.headline)
                    ForEach(summary.personalBests) { best in
                        HStack {
                            Text(best.activityID)
                            Spacer()
                            Text(
                                best.score > 1 ? best.score / 100 : best.score,
                                format: .percent.precision(.fractionLength(0))
                            )
                            .monospacedDigit()
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassBackgroundEffect()
    }

    private var certificateStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Practical record", systemImage: "checkmark.seal")
                .font(.title2.bold())
            Text(
                isInstructorVerified
                    ? "Instructor-verified"
                    : "Internal completion record — not SRFAC certification"
            )
            .font(.headline)
            Text(
                isInstructorVerified
                    ? "A qualified instructor has approved the practical sign-off recorded in this app."
                    : "Course activity alone does not establish practical competency."
            )
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassBackgroundEffect()
    }

    private func badgeCard(_ badge: AchievementBadgeDescriptor) -> some View {
        let earned = badge.isConfigured && learnerAwardIDs.contains(badge.id)
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: earned ? "shield.checkered" : "shield.dashed")
                .font(.largeTitle)
                .accessibilityHidden(true)
            Text(badge.title)
                .font(.headline)
            Text(earned ? "Earned" : badge.isConfigured ? "Not yet earned" : "Reserved placeholder")
                .foregroundStyle(.secondary)
            Text(badge.assetName)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        .padding(18)
        .background(
            earned ? Color.blue.opacity(0.14) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .opacity(earned ? 1 : 0.65)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(badge.title), \(earned ? "earned" : "not earned")")
    }
}
