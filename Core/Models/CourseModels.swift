import Foundation

/// A versioned learning course made up of ordered modules.
struct Course: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let summary: String
    let version: CourseVersion
    let modules: [Module]
    let instructorRequirement: InstructorRequirement
    let completionRule: CompletionRule
    let sourceReferences: [SourceReference]
}

/// Identifies the schema and content release represented by a course payload.
struct CourseVersion: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let contentVersion: String
    let locale: String
    let releasedAt: Date?
}

/// An ordered group of lessons within a course.
struct Module: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let summary: String
    let order: Int
    let lessons: [Lesson]
    let sourceReferences: [SourceReference]
}

/// A single learning unit containing objectives and versioned learning material.
struct Lesson: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let summary: String
    let order: Int
    let learningObjectives: [LearningObjective]
    let contentBlocks: [ContentBlock]
    let interactiveActivities: [InteractiveActivity]
    let scenarios: [Scenario]
    let assessments: [Assessment]
    let sourceReferences: [SourceReference]
}

/// A learner-facing statement describing an intended learning outcome.
struct LearningObjective: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let statement: String
    let sourceReferences: [SourceReference]
}

/// A traceable piece of authored lesson content.
struct ContentBlock: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let kind: ContentBlockKind
    let title: String
    let body: String
    let sourceReferences: [SourceReference]
}

/// Supported presentation categories for a lesson content block.
enum ContentBlockKind: String, Codable, Sendable {
    case text
    case callout
    case mediaPlaceholder = "media_placeholder"
}

/// A learner interaction referenced by a lesson but implemented by a feature module.
struct InteractiveActivity: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let activityType: String
    let instructions: String
    let sourceReferences: [SourceReference]
}

/// A clinical training situation and its reviewable critical actions.
struct Scenario: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let summary: String
    let criticalActions: [CriticalAction]
    let sourceReferences: [SourceReference]
}

/// A scored knowledge check containing traceable questions.
struct Assessment: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let passingScore: Double
    let questions: [Question]
    let sourceReferences: [SourceReference]
}

/// A multiple-choice assessment prompt and its remediation explanation.
struct Question: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let prompt: String
    let choices: [String]
    let correctChoiceIndex: Int
    let explanation: String
    let sourceReferences: [SourceReference]
}

/// A required or recommended action evaluated within a training scenario.
struct CriticalAction: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let actionDescription: String
    let isRequired: Bool
    let sourceReferences: [SourceReference]
}

/// Traceability metadata connecting authored content to an approved source.
///
/// Unresolved clinical content uses `requires_sme_review` as its review status and
/// leaves the reviewer and clinical review date absent until a qualified review occurs.
struct SourceReference: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let document: String
    let edition: String
    let section: String
    let page: String
    let reviewStatus: String
    let reviewer: String?
    let lastClinicalReviewDate: Date?
    let contentVersion: String
}

/// Declares whether practical competency needs an instructor's recorded sign-off.
struct InstructorRequirement: Codable, Sendable, Equatable {
    let isRequired: Bool
    let requirementDescription: String
    let recordLabel: String
}

/// Defines the deterministic conditions for an internal course completion record.
struct CompletionRule: Codable, Sendable, Equatable {
    let requiredLessonIDs: [String]
    let minimumAssessmentScore: Double?
    let requiresInstructorSignOff: Bool
}

/// Encodes and decodes versioned course resources with a stable ISO-8601 date format.
enum CourseContentCodec {
    static func decode(_ data: Data) throws -> Course {
        try makeDecoder().decode(Course.self, from: data)
    }

    static func encode(_ course: Course) throws -> Data {
        try makeEncoder().encode(course)
    }

    /// Exercises the same encode/decode path used by tests and content tooling.
    static func roundTrip(_ course: Course) throws -> Course {
        try decode(encode(course))
    }

    static func loadCourse(
        named resourceName: String,
        from bundle: Bundle = .main
    ) throws -> Course {
        let url = bundle.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "Courses"
        ) ?? bundle.url(forResource: resourceName, withExtension: "json")

        guard let url else {
            throw CourseContentError.resourceNotFound(resourceName)
        }

        return try decode(Data(contentsOf: url))
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

/// Errors raised while locating bundled course content.
enum CourseContentError: Error, Sendable, Equatable {
    case resourceNotFound(String)
}
