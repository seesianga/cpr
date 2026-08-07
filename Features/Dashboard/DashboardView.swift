import SwiftUI

/// Learner-facing overview of courses and internal completion records.
struct DashboardView: View {
    var body: some View {
        ContentUnavailableView(
            "Learner Dashboard",
            systemImage: "rectangle.grid.2x2",
            description: Text("Your learning overview will appear here.")
        )
        .navigationTitle("Dashboard")
    }
}
