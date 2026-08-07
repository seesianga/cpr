import SwiftUI

/// Administrative workspace for academy configuration.
struct AdministrationView: View {
    var body: some View {
        ContentUnavailableView(
            "Administration",
            systemImage: "gearshape.2",
            description: Text("Administrative tools will be available in a later phase.")
        )
        .navigationTitle("Administration")
    }
}
