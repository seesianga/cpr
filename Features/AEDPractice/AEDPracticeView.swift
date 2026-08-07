import SwiftUI

/// Launch point for guided AED practice activities.
struct AEDPracticeView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("AED trainer") {
                Text("Practise chest preparation, pad placement, hands-off analysis, an interactive clear sweep and immediate return to compressions.")
                Text("The AED and shock are simulated. No electrical shock is delivered.")
                    .foregroundStyle(.secondary)
            }

            Section("Interaction access") {
                Text("Every spatial gaze-and-pinch or drag interaction also has a labelled button control. The clear check still requires checking the clear-zone ring and each bystander; it is never reduced to one button.")
            }

            Section("Enter practice") {
                Toggle("I am ready to enter mixed immersion", isOn: $appModel.hasUserOptedInToImmersion)
                Button("Enter AED Practice", systemImage: "visionpro") {
                    appModel.selectPractice(.aed)
                    Task { await appModel.openSimulation(using: openImmersiveSpace) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appModel.hasUserOptedInToImmersion ||
                    appModel.immersionState != .closed
                )
                .accessibilityHint("Opens the simulated AED preparation room; pause and exit controls remain visible")

                if let notice = appModel.immersionNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("AED Practice")
    }
}
