import Foundation

struct LearningLevel: Codable, Identifiable, Sendable, Equatable {
    let id: Int
    let title: String
    let minimumXP: Int
    let requiresApprovedPracticalSignOff: Bool
}

enum PracticalSignOffStatus: String, Codable, Sendable {
    case scheduled
    case approved
    case rejected
}

struct PracticalSignOffValue: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let status: PracticalSignOffStatus
    let signedAt: Date?
}

struct GamificationEvent: Codable, Sendable, Equatable {
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let sourceAttemptID: String
    let completedAt: Date
    let scoreOutcome: ScenarioScoreOutcome
}

enum BadgeComparison: String, Codable, Sendable {
    case atLeast
    case atMost
    case equal

    func matches(value: Double, target: Double) -> Bool {
        switch self {
        case .atLeast: value >= target
        case .atMost: value <= target
        case .equal: value == target
        }
    }
}

struct BadgeRule: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let metric: String
    let comparison: BadgeComparison
    let target: Double
}

enum BadgeRuleCodec {
    static func loadBundled(
        named resourceName: String = "badge_rules",
        from bundle: Bundle = .main
    ) throws -> [BadgeRule] {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "Configuration"
        ) ?? bundle.url(forResource: resourceName, withExtension: "json")
        guard let url else { throw CourseContentError.resourceNotFound(resourceName) }
        return try JSONDecoder().decode([BadgeRule].self, from: Data(contentsOf: url))
    }
}

struct BadgeMetricSnapshot: Codable, Sendable, Equatable {
    let values: [String: Double]
}

struct BadgeAwardValue: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let learnerID: String
    let badgeID: String
    let title: String
    let sourceAttemptID: String
    let awardedAt: Date
}

struct GamificationPolicy: Codable, Sendable, Equatable {
    let safeCompletionXP: Int
    let levels: [LearningLevel]
    let badgeRules: [BadgeRule]
    let publicLeaderboardEnabled: Bool

    static func standard(badgeRules: [BadgeRule]) -> GamificationPolicy {
        GamificationPolicy(
            safeCompletionXP: 100,
            levels: [
                LearningLevel(id: 1, title: "Awareness Learner", minimumXP: 0, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 2, title: "Prepared Beginner", minimumXP: 100, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 3, title: "Safety Spotter", minimumXP: 250, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 4, title: "Response Sequencer", minimumXP: 500, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 5, title: "Rhythm Practitioner", minimumXP: 900, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 6, title: "AED Response Practitioner", minimumXP: 1_400, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 7, title: "Scenario-Ready Responder", minimumXP: 2_000, requiresApprovedPracticalSignOff: false),
                LearningLevel(id: 8, title: "Instructor-Verified Practitioner", minimumXP: 2_750, requiresApprovedPracticalSignOff: true)
            ],
            badgeRules: badgeRules,
            publicLeaderboardEnabled: false
        )
    }
}

struct GamificationDecision: Codable, Sendable, Equatable {
    let xpAwarded: Int
    let totalXP: Int
    let level: LearningLevel
    let newBadgeAwards: [BadgeAwardValue]
}

struct SpacedRepetitionPolicy: Codable, Sendable, Equatable {
    let intervalDays: [Int]

    static let standard = SpacedRepetitionPolicy(intervalDays: [1, 3, 7, 14, 30])
}
