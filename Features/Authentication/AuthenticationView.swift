import SwiftUI

/// Entry point for choosing or restoring a local learner session.
struct AuthenticationView: View {
    var body: some View {
        ContentUnavailableView(
            "Welcome",
            systemImage: "person.crop.circle",
            description: Text("Authentication will be available in a later phase.")
        )
        .navigationTitle("Sign In")
    }
}
