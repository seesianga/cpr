import SwiftUI

/// Catalogue of integrated emergency-response simulations.
struct ScenariosView: View {
    var body: some View {
        ContentUnavailableView(
            "Practice Scenarios",
            systemImage: "person.2",
            description: Text("Simulation scenarios will be available in a later phase.")
        )
        .navigationTitle("Scenarios")
    }
}
