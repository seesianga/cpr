import SwiftUI

/// Reading and knowledge-learning workspace.
struct TheoryLearningView: View {
    var body: some View {
        ContentUnavailableView(
            "Theory Learning",
            systemImage: "book.pages",
            description: Text("Theory lessons will be available in a later phase.")
        )
        .navigationTitle("Theory")
    }
}
