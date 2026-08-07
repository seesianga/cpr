import Foundation

enum LocalAuthenticationError: Error, Sendable, Equatable {
    case invalidAppleCredential
    case corruptStoredSession
}

/// Local session coordinator. Production identity and role authorisation require a server.
actor LocalAuthenticationService: AuthenticationService {
    private struct SessionEnvelope: Codable, Sendable {
        let user: AuthenticatedUser
        let appleUserIdentifier: String?
        let savedAt: Date
    }

    private let sessionKey = "authenticated-session-v1"
    private let sessionStore: any SessionStore
    private let credentialStateProvider: any AppleCredentialStateProviding
    private var cachedUser: AuthenticatedUser?

    init(
        sessionStore: any SessionStore = KeychainStore(),
        credentialStateProvider: any AppleCredentialStateProviding = AppleCredentialStateProvider()
    ) {
        self.sessionStore = sessionStore
        self.credentialStateProvider = credentialStateProvider
    }

    func currentUser() -> AuthenticatedUser? {
        cachedUser
    }

    func restoreSession() async throws -> AuthenticatedUser? {
        guard let data = try await sessionStore.data(for: sessionKey) else {
            cachedUser = nil
            return nil
        }
        let envelope: SessionEnvelope
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            envelope = try decoder.decode(SessionEnvelope.self, from: data)
        } catch {
            try await sessionStore.removeValue(for: sessionKey)
            cachedUser = nil
            throw LocalAuthenticationError.corruptStoredSession
        }

        #if !DEMO
        if envelope.user.role == .admin || envelope.user.sessionKind == .demoAdministrator {
            try await sessionStore.removeValue(for: sessionKey)
            cachedUser = nil
            return nil
        }
        #endif

        if envelope.user.sessionKind == .apple {
            guard let appleUserIdentifier = envelope.appleUserIdentifier else {
                try await sessionStore.removeValue(for: sessionKey)
                cachedUser = nil
                return nil
            }
            let state = await credentialStateProvider.credentialState(for: appleUserIdentifier)
            guard state == .authorised || state == .transferred else {
                try await sessionStore.removeValue(for: sessionKey)
                cachedUser = nil
                return nil
            }
        }

        cachedUser = envelope.user
        return envelope.user
    }

    func signInAsGuest(displayName: String?) async throws -> AuthenticatedUser {
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = AuthenticatedUser(
            id: "guest-\(UUID().uuidString)",
            displayName: trimmedName?.isEmpty == false ? trimmedName ?? "Guest Learner" : "Guest Learner",
            role: .learner,
            sessionKind: .guest
        )
        try await persist(user: user, appleUserIdentifier: nil)
        return user
    }

    func signInWithApple(_ credential: AppleSignInCredential) async throws -> AuthenticatedUser {
        let identifier = credential.userIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            throw LocalAuthenticationError.invalidAppleCredential
        }
        let name = credential.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = AuthenticatedUser(
            id: "apple-\(identifier)",
            displayName: name?.isEmpty == false ? name ?? "Learner" : "Learner",
            role: .learner,
            sessionKind: .apple
        )

        // Tokens and authorisation codes are intentionally not retained.
        try await persist(user: user, appleUserIdentifier: identifier)
        return user
    }

    func signOut() async throws {
        try await sessionStore.removeValue(for: sessionKey)
        cachedUser = nil
    }

    private func persist(user: AuthenticatedUser, appleUserIdentifier: String?) async throws {
        let envelope = SessionEnvelope(
            user: user,
            appleUserIdentifier: appleUserIdentifier,
            savedAt: .now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await sessionStore.set(try encoder.encode(envelope), for: sessionKey)
        cachedUser = user
    }

    #if DEMO
    fileprivate func installDemoAdministrator() async throws -> AuthenticatedUser {
        let user = AuthenticatedUser(
            id: "demo-admin-\(UUID().uuidString)",
            displayName: "Demo Administrator",
            role: .admin,
            sessionKind: .demoAdministrator
        )
        try await persist(user: user, appleUserIdentifier: nil)
        return user
    }
    #endif
}

#if DEMO
/// Demo-configuration-only role bootstrap. It uses no password or embedded credential.
enum AdminBootstrap {
    static func installDemoAdministrator(
        into service: LocalAuthenticationService
    ) async throws -> AuthenticatedUser {
        try await service.installDemoAdministrator()
    }
}
#endif
