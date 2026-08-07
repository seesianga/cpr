import Foundation

/// Calm, non-monetised learning recognition with an instructor-only final level.
struct GamificationEngine: Sendable {
    func evaluate(
        event: GamificationEvent,
        currentXP: Int,
        metrics: BadgeMetricSnapshot,
        existingAwards: [BadgeAwardValue],
        approvedSignOffs: [PracticalSignOffValue],
        policy: GamificationPolicy
    ) -> GamificationDecision {
        let xpAwarded = event.scoreOutcome.xpEligible ? max(0, policy.safeCompletionXP) : 0
        let totalXP = max(0, currentXP) + xpAwarded
        let signOffApproved = approvedSignOffs.contains {
            $0.learnerID == event.learnerID &&
            $0.courseID == event.courseID &&
            $0.status == .approved
        }
        let eligibleLevels = policy.levels.filter {
            totalXP >= $0.minimumXP &&
            (!$0.requiresApprovedPracticalSignOff || signOffApproved)
        }
        let level = eligibleLevels.max { $0.id < $1.id }
            ?? LearningLevel(
                id: 1,
                title: "Awareness Learner",
                minimumXP: 0,
                requiresApprovedPracticalSignOff: false
            )

        let existingBadgeIDs = Set(existingAwards.map(\.badgeID))
        let awards: [BadgeAwardValue]
        if event.scoreOutcome.xpEligible {
            awards = policy.badgeRules.compactMap { rule in
                guard !existingBadgeIDs.contains(rule.id),
                      let value = metrics.values[rule.metric],
                      rule.comparison.matches(value: value, target: rule.target)
                else { return nil }
                return BadgeAwardValue(
                    id: "\(event.learnerID)#\(rule.id)",
                    learnerID: event.learnerID,
                    badgeID: rule.id,
                    title: rule.title,
                    sourceAttemptID: event.sourceAttemptID,
                    awardedAt: event.completedAt
                )
            }
        } else {
            awards = []
        }

        return GamificationDecision(
            xpAwarded: xpAwarded,
            totalXP: totalXP,
            level: level,
            newBadgeAwards: awards
        )
    }

    func practiceStreak(
        successfulPracticeDates: [Date],
        through date: Date,
        calendar: Calendar
    ) -> Int {
        let throughDay = calendar.startOfDay(for: date)
        let days = Set(
            successfulPracticeDates
                .map { calendar.startOfDay(for: $0) }
                .filter { $0 <= throughDay }
        )
        guard let latest = days.max(),
              let gap = calendar.dateComponents([.day], from: latest, to: throughDay).day,
              gap <= 1
        else { return 0 }

        var streak = 0
        var cursor = latest
        while days.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else {
                break
            }
            cursor = previous
        }
        return streak
    }

    func nextReviewDate(
        lastPractice: Date,
        successfulRepetitionCount: Int,
        policy: SpacedRepetitionPolicy = .standard,
        calendar: Calendar
    ) -> Date {
        let intervals = policy.intervalDays.isEmpty ? [1] : policy.intervalDays
        let index = min(max(0, successfulRepetitionCount), intervals.count - 1)
        return calendar.date(
            byAdding: .day,
            value: max(1, intervals[index]),
            to: lastPractice
        ) ?? lastPractice
    }
}
