import SwiftUI

/// Reading and knowledge-learning workspace. Module availability and lesson entry are
/// deliberately delegated to the same CourseEngine-backed catalogue used everywhere else.
struct TheoryLearningView: View {
    var body: some View {
        CourseCatalogueView()
    }
}
