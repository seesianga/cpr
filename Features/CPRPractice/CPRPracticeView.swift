import SwiftUI

/// Launch point for guided CPR practice activities.
struct CPRPracticeView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("Guided CPR practice") {
                Text("Practise positioning, lower-half sternum hand placement, rhythm and short interruption windows with the training manikin.")
                Label("Target cadence: 100–120 compressions per minute; the visual metronome practises at 110.", systemImage: "metronome")
                Label("Compression depth, force and recoil are not physically assessed without a verified external sensor.", systemImage: "sensor")
                    .foregroundStyle(.secondary)
            }

            Section("Optional hand tracking") {
                Text("If permission is declined, the complete lesson remains available with gaze and pinch plus clearly labelled buttons. Tap cadence supplies rhythm feedback; automatic placement, interruption and hand-stacking guidance are unavailable.")
            }

            Section("Enter practice") {
                Toggle("I am ready to enter mixed immersion", isOn: $appModel.hasUserOptedInToImmersion)
                Button("Enter CPR Practice", systemImage: "visionpro") {
                    appModel.selectPractice(.cpr)
                    Task { await appModel.openSimulation(using: openImmersiveSpace) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appModel.hasUserOptedInToImmersion ||
                    appModel.immersionState != .closed
                )
                .accessibilityHint("Opens the CPR training manikin room; pause and exit controls remain visible")

                if let notice = appModel.immersionNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("CPR Practice")
    }
}
