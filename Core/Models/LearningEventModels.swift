import Foundation

enum LearningVerb: String, Codable, Sendable {
    case experienced
    case completed
    case passed
    case failed
    case practised

    var iri: String {
        switch self {
        case .experienced: "http://adlnet.gov/expapi/verbs/experienced"
        case .completed: "http://adlnet.gov/expapi/verbs/completed"
        case .passed: "http://adlnet.gov/expapi/verbs/passed"
        case .failed: "http://adlnet.gov/expapi/verbs/failed"
        case .practised: "https://lifesaver.vision/xapi/verbs/practised"
        }
    }

    var display: String {
        switch self {
        case .experienced: "experienced"
        case .completed: "completed"
        case .passed: "passed"
        case .failed: "failed"
        case .practised: "practised"
        }
    }
}

struct LearningEventResult: Codable, Sendable, Equatable {
    let scaledScore: Double?
    let success: Bool?
    let completion: Bool?
    let durationISO8601: String?
}

struct LearningEventRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let actorAccountID: String
    let verb: LearningVerb
    let activityID: URL
    let activityName: String
    let result: LearningEventResult?
    let contentVersion: String
    let registrationID: UUID?
    let timestamp: Date
}

struct XAPIAccount: Codable, Sendable, Equatable {
    let homePage: String
    let name: String
}

struct XAPIActor: Codable, Sendable, Equatable {
    let objectType: String
    let account: XAPIAccount
}

struct XAPIVerb: Codable, Sendable, Equatable {
    let id: String
    let display: [String: String]
}

struct XAPIActivityDefinition: Codable, Sendable, Equatable {
    let name: [String: String]
}

struct XAPIActivity: Codable, Sendable, Equatable {
    let objectType: String
    let id: String
    let definition: XAPIActivityDefinition
}

struct XAPIScore: Codable, Sendable, Equatable {
    let scaled: Double
}

struct XAPIResult: Codable, Sendable, Equatable {
    let score: XAPIScore?
    let success: Bool?
    let completion: Bool?
    let duration: String?
}

struct XAPIContext: Codable, Sendable, Equatable {
    let registration: UUID?
    let extensions: [String: String]
}

struct XAPIStatement: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let actor: XAPIActor
    let verb: XAPIVerb
    let object: XAPIActivity
    let result: XAPIResult?
    let context: XAPIContext
    let timestamp: Date
}

enum XAPIExportError: Error, Sendable, Equatable {
    case invalidActorAccount
    case invalidActivityIRI
    case invalidScaledScore
}
