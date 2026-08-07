import SwiftUI

/// Calm progress recognition for completed learning activities.
struct GamificationView: View {
    var body: some View {
        ContentUnavailableView(
            "Learning Progress",
            systemImage: "medal",
            description: Text("Milestones and internal completion records will appear here.")
        )
        .navigationTitle("Progress")
    }
}
