import SwiftUI

/// Entry point populated only by clinically eligible, published course content.
struct AssessmentView: View {
    var body: some View {
        ContentUnavailableView(
            "No Approved Knowledge Check Yet",
            systemImage: "checklist",
            description: Text(
                "Knowledge checks appear here after source checking and clinical approval. Attempts are untimed and include a source-backed review."
            )
        )
        .navigationTitle("Assessments")
        .accessibilityHint("No scored assessment is currently available")
    }
}
