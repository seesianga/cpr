import SwiftUI

/// Knowledge checks and practical assessment status.
struct AssessmentView: View {
    var body: some View {
        ContentUnavailableView(
            "Assessments",
            systemImage: "checklist",
            description: Text("Knowledge checks and instructor sign-off will appear here.")
        )
        .navigationTitle("Assessments")
    }
}
