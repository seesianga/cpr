import AuthenticationServices
import SwiftUI

/// Calm entry point for Apple sign-in or a fully local guest session.
struct AuthenticationView: View {
    let model: AuthenticationModel
    @State private var guestName = ""

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 24) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 56))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Welcome to Lifesaver Vision")
                    .font(.largeTitle.bold())
                Text("CPR + AED learning in a calm, supportive spatial academy.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                if #available(visionOS 1.0, *) {
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleAppleResult(result)
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(maxWidth: 360, minHeight: 50)
                    .accessibilityLabel("Sign in with Apple")
                }

                Divider()
                    .frame(maxWidth: 360)

                TextField("Name for guest mode (optional)", text: $guestName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .accessibilityLabel("Guest display name")

                Button("Continue as Guest", systemImage: "person.crop.circle.badge.plus") {
                    Task { await model.signInAsGuest(displayName: guestName) }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Starts a local learner session without an Apple account")
            }

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Sign-in error: \(errorMessage)")
            }

            Text("Guest progress is stored on this device. Practical competency requires instructor sign-off and creates an internal completion record only.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
        .padding(48)
        .glassBackgroundEffect()
    }

    @available(visionOS 1.0, *)
    @MainActor
    private func handleAppleResult(_ result: Result<ASAuthorization, any Error>) {
        switch result {
        case let .success(authorization):
            guard let appleCredential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                model.reportAppleFailure()
                return
            }
            let displayName = appleCredential.fullName.map {
                PersonNameComponentsFormatter.localizedString(from: $0, style: .default)
            }
            let credential = AppleSignInCredential(
                userIdentifier: appleCredential.user,
                displayName: displayName,
                email: appleCredential.email,
                identityToken: appleCredential.identityToken,
                authorisationCode: appleCredential.authorizationCode
            )
            Task { await model.signInWithApple(credential) }

        case let .failure(error):
            let nsError = error as NSError
            if nsError.domain == ASAuthorizationError.errorDomain,
               nsError.code == ASAuthorizationError.canceled.rawValue {
                model.reportAppleCancellation()
            } else {
                model.reportAppleFailure()
            }
        }
    }
}

struct AuthenticationGateView: View {
    let model: AuthenticationModel

    var body: some View {
        Group {
            switch model.state {
            case .restoring:
                ProgressView("Restoring your session…")
                    .accessibilityLabel("Restoring your session")
            case .signedOut:
                AuthenticationView(model: model)
            case .signedIn:
                DashboardRootView()
                    .environment(model)
                    .toolbar {
                        Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right") {
                            Task { await model.signOut() }
                        }
                        .accessibilityHint("Ends the current local session")
                    }
            }
        }
        .task {
            await model.restoreIfNeeded()
        }
    }
}
