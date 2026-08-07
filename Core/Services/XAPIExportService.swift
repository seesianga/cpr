import Foundation

/// Converts internal learning events into typed xAPI-compatible statements.
struct XAPIExportService: Sendable {
    static let accountHomePage = "https://lifesaver.vision/learners"
    static let contentVersionExtension = "https://lifesaver.vision/xapi/extensions/content-version"

    func statement(for event: LearningEventRecord) throws -> XAPIStatement {
        guard !event.actorAccountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XAPIExportError.invalidActorAccount
        }
        guard let scheme = event.activityID.scheme,
              scheme == "https" || scheme == "http"
        else { throw XAPIExportError.invalidActivityIRI }
        if let scaled = event.result?.scaledScore {
            guard scaled.isFinite, (-1...1).contains(scaled) else {
                throw XAPIExportError.invalidScaledScore
            }
        }

        let result = event.result.map {
            XAPIResult(
                score: $0.scaledScore.map(XAPIScore.init(scaled:)),
                success: $0.success,
                completion: $0.completion,
                duration: $0.durationISO8601
            )
        }
        return XAPIStatement(
            id: event.id,
            actor: XAPIActor(
                objectType: "Agent",
                account: XAPIAccount(
                    homePage: Self.accountHomePage,
                    name: event.actorAccountID
                )
            ),
            verb: XAPIVerb(
                id: event.verb.iri,
                display: ["en-SG": event.verb.display]
            ),
            object: XAPIActivity(
                objectType: "Activity",
                id: event.activityID.absoluteString,
                definition: XAPIActivityDefinition(name: ["en-SG": event.activityName])
            ),
            result: result,
            context: XAPIContext(
                registration: event.registrationID,
                extensions: [Self.contentVersionExtension: event.contentVersion]
            ),
            timestamp: event.timestamp
        )
    }

    func encodedStatement(for event: LearningEventRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(statement(for: event))
    }

    func encodedStatements(for events: [LearningEventRecord]) throws -> Data {
        let statements = try events.sorted { $0.timestamp < $1.timestamp }.map(statement)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(statements)
    }
}
