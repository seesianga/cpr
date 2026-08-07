import Foundation
import Observation

@MainActor
@Observable
final class AuthenticationModel {
    enum State: Equatable {
        case restoring
        case signedOut
        case signedIn(AuthenticatedUser)
    }

    private let service: any AuthenticationService
    private var hasRestored = false
    private(set) var state: State = .restoring
    private(set) var errorMessage: String?

    init(service: any AuthenticationService) {
        self.service = service
    }

    var currentUser: AuthenticatedUser? {
        guard case let .signedIn(user) = state else { return nil }
        return user
    }

    func restoreIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true
        do {
            if let user = try await service.restoreSession() {
                state = .signedIn(user)
            } else {
                state = .signedOut
            }
        } catch {
            state = .signedOut
            errorMessage = "Your saved session could not be restored. Please sign in again."
        }
    }

    func signInAsGuest(displayName: String?) async {
        errorMessage = nil
        do {
            state = .signedIn(try await service.signInAsGuest(displayName: displayName))
        } catch {
            errorMessage = "Guest mode could not be started. Please try again."
        }
    }

    func signInWithApple(_ credential: AppleSignInCredential) async {
        errorMessage = nil
        do {
            state = .signedIn(try await service.signInWithApple(credential))
        } catch {
            errorMessage = "Sign in with Apple could not be completed."
        }
    }

    func reportAppleCancellation() {
        errorMessage = nil
    }

    func reportAppleFailure() {
        errorMessage = "Sign in with Apple could not be completed."
    }

    func signOut() async {
        do {
            try await service.signOut()
            state = .signedOut
            errorMessage = nil
        } catch {
            errorMessage = "Sign out could not be completed. Please try again."
        }
    }
}
