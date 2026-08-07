import SwiftUI

/// Catalogue of the academy's available learning modules.
struct CourseCatalogueView: View {
    var body: some View {
        ContentUnavailableView(
            "Course Catalogue",
            systemImage: "books.vertical",
            description: Text("Course modules will be listed here.")
        )
        .navigationTitle("Courses")
    }
}
