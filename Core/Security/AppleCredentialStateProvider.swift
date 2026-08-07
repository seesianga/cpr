import AuthenticationServices
import Foundation

/// Availability-guarded adapter around Apple credential-state callbacks.
struct AppleCredentialStateProvider: AppleCredentialStateProviding {
    func credentialState(for userIdentifier: String) async -> AppleCredentialState {
        guard #available(visionOS 1.0, *) else { return .unknown }
        return await withCheckedContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: userIdentifier) {
                state,
                _ in
                let value: AppleCredentialState
                switch state {
                case .authorized:
                    value = .authorised
                case .revoked:
                    value = .revoked
                case .notFound:
                    value = .notFound
                case .transferred:
                    value = .transferred
                @unknown default:
                    value = .unknown
                }
                continuation.resume(returning: value)
            }
        }
    }
}

struct FixedAppleCredentialStateProvider: AppleCredentialStateProviding {
    let state: AppleCredentialState

    func credentialState(for userIdentifier: String) async -> AppleCredentialState {
        state
    }
}
