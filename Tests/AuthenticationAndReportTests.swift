import Foundation
import XCTest
@testable import LifesaverVision

@MainActor
final class AuthenticationAndReportTests: XCTestCase {
    func testGuestSessionPersistsAndSignsOutWithoutCredentials() async throws {
        let sessionStore = InMemorySessionStore()
        let service = LocalAuthenticationService(
            sessionStore: sessionStore,
            credentialStateProvider: FixedAppleCredentialStateProvider(state: .authorised)
        )

        let user = try await service.signInAsGuest(displayName: "  Demo Learner  ")

        XCTAssertEqual(user.displayName, "Demo Learner")
        XCTAssertEqual(user.role, .learner)
        XCTAssertEqual(user.sessionKind, .guest)
        let restoredUser = try await service.restoreSession()
        XCTAssertEqual(restoredUser, user)

        try await service.signOut()
        let signedOutUser = try await service.restoreSession()
        XCTAssertNil(signedOutUser)
    }

    func testAppleSignInAlwaysCreatesLearnerAndRevocationClearsSession() async throws {
        let sessionStore = InMemorySessionStore()
        let authorisedService = LocalAuthenticationService(
            sessionStore: sessionStore,
            credentialStateProvider: FixedAppleCredentialStateProvider(state: .authorised)
        )
        let credential = AppleSignInCredential(
            userIdentifier: "apple-user-opaque",
            displayName: "Learner",
            email: "not-retained@example.invalid",
            identityToken: Data("token-not-retained".utf8),
            authorisationCode: Data("code-not-retained".utf8)
        )

        let user = try await authorisedService.signInWithApple(credential)

        XCTAssertEqual(user.role, .learner)
        XCTAssertEqual(user.sessionKind, .apple)
        let revokedService = LocalAuthenticationService(
            sessionStore: sessionStore,
            credentialStateProvider: FixedAppleCredentialStateProvider(state: .revoked)
        )
        let restoredUser = try await revokedService.restoreSession()
        let storedSession = try await sessionStore.data(for: "authenticated-session-v1")
        XCTAssertNil(restoredUser)
        XCTAssertNil(storedSession)
    }

    func testAppleSignInRejectsBlankIdentifier() async {
        let service = LocalAuthenticationService(
            sessionStore: InMemorySessionStore(),
            credentialStateProvider: FixedAppleCredentialStateProvider(state: .authorised)
        )
        let credential = AppleSignInCredential(
            userIdentifier: "   ",
            displayName: nil,
            email: nil,
            identityToken: nil,
            authorisationCode: nil
        )

        do {
            _ = try await service.signInWithApple(credential)
            XCTFail("A blank Apple identifier must fail closed")
        } catch {
            XCTAssertEqual(error as? LocalAuthenticationError, .invalidAppleCredential)
        }
    }

    func testCohortCSVQuotesCommasQuotesAndNewlinesAndKeepsContentVersion() throws {
        let report = CohortReport(
            schemaVersion: 1,
            cohortID: "cohort-1",
            cohortName: "Friday cohort",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: [
                CohortReportEntry(
                    id: "entry-1",
                    learnerID: "learner-1",
                    learnerDisplayName: "See, \"Sam\"\nJunior",
                    courseID: "course-1",
                    completionFraction: 0.75,
                    attemptID: "attempt-1",
                    activityID: "scenario-1",
                    contentVersion: "2.1.0",
                    score: 0.82,
                    passed: true,
                    criticalErrorCodes: ["second,error", "first"]
                )
            ]
        )

        let data = CohortReportExportService().csvData(for: report)
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(csv.contains("\"See, \"\"Sam\"\"\nJunior\""))
        XCTAssertTrue(csv.contains("2.1.0"))
        XCTAssertTrue(csv.contains("\"first; second,error\""))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
    }

    func testCohortJSONIsDeterministicallySorted() throws {
        let entries = ["learner-b", "learner-a"].map { learnerID in
            CohortReportEntry(
                id: learnerID,
                learnerID: learnerID,
                learnerDisplayName: learnerID,
                courseID: "course",
                completionFraction: nil,
                attemptID: nil,
                activityID: nil,
                contentVersion: "1.0.0",
                score: nil,
                passed: nil,
                criticalErrorCodes: []
            )
        }
        let report = CohortReport(
            schemaVersion: 1,
            cohortID: "cohort",
            cohortName: "Cohort",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            entries: entries
        )

        let service = CohortReportExportService()
        let first = try service.jsonData(for: report)
        let second = try service.jsonData(for: report)
        let decoded = try JSONDecoder.iso8601.decode(CohortReport.self, from: first)

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded.entries.map(\.learnerID), ["learner-a", "learner-b"])
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
