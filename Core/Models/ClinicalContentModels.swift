import Foundation

/// Heterogeneous JSON value used by the clinical-fact catalogue's structured values.
enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Review status from the authoritative clinical-fact extract. Unknown values fail closed.
enum ClinicalReviewStatus: Codable, Sendable, Equatable {
    case sourceChecked
    case requiresSMEReview
    case clinicallyApproved
    case unknown(String)

    var rawValue: String {
        switch self {
        case .sourceChecked: "source_checked"
        case .requiresSMEReview: "requires_sme_review"
        case .clinicallyApproved: "clinically_approved"
        case let .unknown(value): value
        }
    }

    var blocksScoredUse: Bool {
        switch self {
        case .sourceChecked, .clinicallyApproved: false
        case .requiresSMEReview, .unknown: true
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "source_checked", "reviewed": self = .sourceChecked
        case "requires_sme_review": self = .requiresSMEReview
        case "clinically_approved": self = .clinicallyApproved
        default: self = .unknown(rawValue)
        }
    }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ClinicalFactSource: Codable, Sendable, Equatable {
    let doc: String
    let edition: String
    let section: String
    let page: Int
}

struct ClinicalFact: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let statement: String
    let values: [String: JSONValue]
    let sources: [ClinicalFactSource]
    let reviewStatus: ClinicalReviewStatus
    let supersedes2018: Bool
    let notes: String
}

struct ClinicalFactsDocument: Codable, Sendable, Equatable {
    let version: String
    let extractedAt: String
    let citationConvention: String
    let languageNote: String
    let facts: [ClinicalFact]
}

struct ClinicalFactCatalogue: Sendable, Equatable {
    let documentVersion: String
    let factsByID: [String: ClinicalFact]

    init(document: ClinicalFactsDocument) {
        documentVersion = document.version
        factsByID = Dictionary(uniqueKeysWithValues: document.facts.map { ($0.id, $0) })
    }

    subscript(factID: String) -> ClinicalFact? {
        factsByID[factID]
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> ClinicalFactCatalogue {
        guard let url = bundle.url(
            forResource: "CLINICAL_FACTS_EXTRACT",
            withExtension: "json"
        ) else {
            throw ClinicalContentError.factCatalogueNotFound
        }
        let document = try JSONDecoder().decode(
            ClinicalFactsDocument.self,
            from: Data(contentsOf: url)
        )
        return ClinicalFactCatalogue(document: document)
    }
}

enum ContentLifecycle: String, Codable, Sendable, CaseIterable, Hashable {
    case draft
    case sourceChecked
    case clinicalReviewRequired
    case clinicallyApproved
    case published
    case superseded
    case retired

    var permitsScoredUse: Bool {
        self == .clinicallyApproved || self == .published
    }
}

struct ContentVersionState: Codable, Sendable, Equatable {
    let courseID: String
    let contentVersion: String
    let lifecycle: ContentLifecycle
    let updatedAt: Date
}

enum ClinicalContentError: Error, Sendable, Equatable {
    case factCatalogueNotFound
    case duplicateFactID(String)
    case courseNotFound(courseID: String, contentVersion: String)
    case lifecycleNotFound(courseID: String, contentVersion: String)
    case invalidLifecycleTransition(from: ContentLifecycle, to: ContentLifecycle)
    case scoredContentBlocked([ClinicalSafetyIssue])
}

enum ClinicalSafetyReason: String, Codable, Sendable, Equatable {
    case missingFactReference
    case unknownFactReference
    case requiresSMEReview
    case unknownReviewStatus
    case embeddedReviewStatusBlocked
    case contentVersionMismatch
    case reviewRequiredContainerWaiverMissing
    case reviewRequiredContainerWaiverInvalid
    case noScoredQuestions
}

struct ClinicalSafetyIssue: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let scoredItemID: String
    let factID: String?
    let reason: ClinicalSafetyReason
}

struct ClinicalSafetyReport: Codable, Sendable, Equatable {
    let eligibleAssessmentIDs: [String]
    let excludedAssessmentIDs: [String]
    let eligibleScenarioIDs: [String]
    let excludedScenarioIDs: [String]
    let issues: [ClinicalSafetyIssue]

    var permitsActivation: Bool { issues.isEmpty }
}

struct ScoredContentCatalogue: Sendable, Equatable {
    let courseID: String
    let contentVersion: String
    let assessments: [Assessment]
    let scenarios: [Scenario]
    let safetyReport: ClinicalSafetyReport
}

struct CourseImportReport: Sendable, Equatable {
    let importedCourseIDs: [String]
    let importedVersionCount: Int
}
