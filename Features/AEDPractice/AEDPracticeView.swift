import SwiftUI

/// Launch point for guided AED practice activities.
struct AEDPracticeView: View {
    var body: some View {
        ContentUnavailableView(
            "AED Practice",
            systemImage: "waveform.path.ecg",
            description: Text("Guided practice will be available in a later phase.")
        )
        .navigationTitle("AED Practice")
    }
}
