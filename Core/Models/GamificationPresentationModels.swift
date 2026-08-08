import Foundation

enum MasterySkill: String, CaseIterable, Identifiable, Sendable {
    case knowledge = "Knowledge"
    case sequence = "Sequence"
    case rhythm = "Rhythm"
    case aedSafety = "AED safety"
    case communication = "Communication"

    var id: String { rawValue }
}

enum MasteryEvidenceStatus: String, Sendable, Equatable {
    case locked
    case notApplicable
    case notStarted
    case learningComplete
    case safePracticeEvidence

    var label: String {
        switch self {
        case .locked: "Locked"
        case .notApplicable: "Not part of this module"
        case .notStarted: "No evidence yet"
        case .learningComplete: "Learning complete; practice not evidenced"
        case .safePracticeEvidence: "Safe practice evidence recorded"
        }
    }

    var symbolName: String {
        switch self {
        case .locked: "lock.fill"
        case .notApplicable: "minus.circle"
        case .notStarted: "circle.dashed"
        case .learningComplete: "book.closed.fill"
        case .safePracticeEvidence: "checkmark.shield.fill"
        }
    }
}

struct PracticeAttemptEvidence: Sendable, Equatable {
    let id: String
    let activityID: String
    let attemptKind: String
    let completedAt: Date?
    let score: Double?
    let passed: Bool?
    let criticalErrorCodes: [String]

    var isSafeSuccess: Bool {
        completedAt != nil && passed == true && criticalErrorCodes.isEmpty
    }

    var searchableText: String {
        "\(activityID) \(attemptKind)".lowercased()
    }
}

struct MasteryCell: Identifiable, Sendable, Equatable {
    let moduleID: String
    let skill: MasterySkill
    let status: MasteryEvidenceStatus

    var id: String { "\(moduleID)#\(skill.id)" }
}

struct MasteryRow: Identifiable, Sendable, Equatable {
    let moduleID: String
    let moduleTitle: String
    let cells: [MasteryCell]

    var id: String { moduleID }
}

struct MasteryMatrixBuilder: Sendable {
    private static let skillsByModule: [String: Set<MasterySkill>] = [
        "M0": [.knowledge],
        "M1": [.knowledge],
        "M2": [.knowledge, .sequence, .communication],
        "M3": [.knowledge, .sequence],
        "M4": [.knowledge, .rhythm],
        "M5": [.knowledge, .aedSafety],
        "M6": [.knowledge, .sequence],
        "M7": Set(MasterySkill.allCases),
        "M8": [.knowledge, .communication],
        "M9": [.knowledge, .aedSafety],
        "M10": [.knowledge, .communication]
    ]

    func build(
        modules: [PresentedCourseModule],
        completedModuleIDs: Set<String>,
        attempts: [PracticeAttemptEvidence]
    ) -> [MasteryRow] {
        modules.map { presented in
            let module = presented.module
            let applicable = Self.skillsByModule[module.id] ?? [.knowledge]
            return MasteryRow(
                moduleID: module.id,
                moduleTitle: module.title,
                cells: MasterySkill.allCases.map { skill in
                    MasteryCell(
                        moduleID: module.id,
                        skill: skill,
                        status: status(
                            moduleID: module.id,
                            skill: skill,
                            isPresentable: presented.isPresentable,
                            applicable: applicable.contains(skill),
                            learningComplete: completedModuleIDs.contains(module.id),
                            attempts: attempts
                        )
                    )
                }
            )
        }
    }

    private func status(
        moduleID: String,
        skill: MasterySkill,
        isPresentable: Bool,
        applicable: Bool,
        learningComplete: Bool,
        attempts: [PracticeAttemptEvidence]
    ) -> MasteryEvidenceStatus {
        guard isPresentable else { return .locked }
        guard applicable else { return .notApplicable }

        let relevantSafeEvidence = attempts.contains { attempt in
            guard attempt.isSafeSuccess else { return false }
            let text = attempt.searchableText
            let moduleMatch = text.contains(moduleID.lowercased()) || moduleID == "M7"
            switch skill {
            case .knowledge:
                return moduleMatch && (text.contains("assessment") || text.contains("theory"))
            case .sequence:
                return moduleMatch && (text.contains("drsabc") || text.contains("scenario") || text.contains("sequence"))
            case .rhythm:
                return moduleMatch && text.contains("cpr")
            case .aedSafety:
                return moduleMatch && (text.contains("aed") || text.contains("scenario"))
            case .communication:
                return moduleMatch && (text.contains("scenario") || text.contains("handover") || text.contains("call"))
            }
        }
        if relevantSafeEvidence { return .safePracticeEvidence }
        return learningComplete ? .learningComplete : .notStarted
    }
}

struct PersonalBest: Identifiable, Sendable, Equatable {
    let activityID: String
    let score: Double
    let completedAt: Date

    var id: String { activityID }
}

struct PracticeDashboardSummary: Sendable, Equatable {
    let successfulAttemptCount: Int
    let practiceStreak: Int
    let nextReviewDate: Date?
    let personalBests: [PersonalBest]
    let derivedXP: Int

    static func make(
        attempts: [PracticeAttemptEvidence],
        through date: Date,
        calendar: Calendar,
        engine: GamificationEngine = GamificationEngine()
    ) -> PracticeDashboardSummary {
        let successful = attempts.filter(\.isSafeSuccess)
        let dates = successful.compactMap(\.completedAt)
        let nextReview: Date?
        if let last = dates.max() {
            nextReview = engine.nextReviewDate(
                lastPractice: last,
                successfulRepetitionCount: max(0, successful.count - 1),
                calendar: calendar
            )
        } else {
            nextReview = nil
        }

        let bests = Dictionary(grouping: successful, by: \.activityID)
            .compactMap { activityID, records -> PersonalBest? in
                guard let best = records
                    .filter({ $0.score != nil && $0.completedAt != nil })
                    .max(by: { ($0.score ?? 0) < ($1.score ?? 0) }),
                      let score = best.score,
                      let completedAt = best.completedAt
                else { return nil }
                return PersonalBest(
                    activityID: activityID,
                    score: score,
                    completedAt: completedAt
                )
            }
            .sorted { $0.activityID < $1.activityID }

        return PracticeDashboardSummary(
            successfulAttemptCount: successful.count,
            practiceStreak: engine.practiceStreak(
                successfulPracticeDates: dates,
                through: date,
                calendar: calendar
            ),
            nextReviewDate: nextReview,
            personalBests: bests,
            derivedXP: successful.count * GamificationPolicy.standard(badgeRules: []).safeCompletionXP
        )
    }
}

struct AchievementBadgeDescriptor: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let assetName: String
    let isConfigured: Bool

    static func catalogue(rules: [BadgeRule]) -> [AchievementBadgeDescriptor] {
        (1...14).map { index in
            if rules.indices.contains(index - 1) {
                let rule = rules[index - 1]
                return AchievementBadgeDescriptor(
                    id: rule.id,
                    title: rule.title,
                    assetName: String(format: "badge_m%02d", index),
                    isConfigured: true
                )
            }
            return AchievementBadgeDescriptor(
                id: "reserved-achievement-\(index)",
                title: "Future achievement",
                assetName: String(format: "badge_m%02d", index),
                isConfigured: false
            )
        }
    }
}
