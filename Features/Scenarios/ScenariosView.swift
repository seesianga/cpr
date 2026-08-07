import SwiftUI

/// Catalogue of integrated emergency-response simulations.
struct ScenariosView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("DRSABC guided room") {
                Text("Practise Danger, Response, Shout, a simulated 995 call, AED delegation, breathing assessment and the transition to compressions.")
                Text(DRSABCPracticeSessionModel.simulationBadge)
                    .font(.headline)
                    .foregroundStyle(.red)
            }

            Section("Enter practice") {
                Toggle("I am ready to enter mixed immersion", isOn: $appModel.hasUserOptedInToImmersion)
                Button("Enter DRSABC Practice", systemImage: "visionpro") {
                    appModel.selectPractice(.drsabc)
                    Task { await appModel.openSimulation(using: openImmersiveSpace) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appModel.hasUserOptedInToImmersion ||
                    appModel.immersionState != .closed
                )
                .accessibilityHint("Opens the DRSABC training room; pause and exit controls remain visible")

                if let notice = appModel.immersionNotice {
                    Text(notice).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Scenarios")
    }
}
