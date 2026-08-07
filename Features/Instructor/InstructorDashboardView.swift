import SwiftUI

/// Instructor workspace for learner support and practical sign-off.
struct InstructorDashboardView: View {
    var body: some View {
        ContentUnavailableView(
            "Instructor Dashboard",
            systemImage: "person.2.badge.gearshape",
            description: Text("Cohort review and practical sign-off tools will appear here.")
        )
        .navigationTitle("Instructor")
    }
}
