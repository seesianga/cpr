import SwiftUI

/// Launch point for guided CPR practice activities.
struct CPRPracticeView: View {
    var body: some View {
        ContentUnavailableView(
            "CPR Practice",
            systemImage: "heart",
            description: Text("Guided practice will be available in a later phase.")
        )
        .navigationTitle("CPR Practice")
    }
}
