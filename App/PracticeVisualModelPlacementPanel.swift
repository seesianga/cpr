import SwiftUI

/// In-headset placement controls for imported Reality Composer Pro models.
///
/// Developer tuning only: it moves visuals, never a detection target. Adjustments
/// persist, and the readout is the literal to bake into source once a placement is right.
struct PracticeVisualModelPlacementPanel: View {
    let models: [PracticeVisualModel]
    let store: PracticeVisualModelPlacementStore
    let reports: PracticeAlignmentReportStore
    /// Solving needs the live scene, which only the RealityView holds. Both callbacks run
    /// from button actions — never from the view's update pass, where writing observable
    /// state would re-enter update endlessly.
    let onAlign: (PracticeVisualModel) -> Void
    /// Re-applies and re-measures after a manual nudge, so the readout below always
    /// describes what is actually on the manikin.
    let onPlacementChanged: (PracticeVisualModel) -> Void

    @State private var selection: PracticeVisualModel?
    @State private var isExpanded = false

    private static let offsetStepMetres: Float = 0.01
    private static let rotationStepDegrees: Float = 15
    private static let scaleStep: Float = 1.1

    private var activeModel: PracticeVisualModel? {
        selection ?? models.first
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let model = activeModel {
                VStack(alignment: .leading, spacing: 10) {
                    if models.count > 1 {
                        Picker("Model", selection: Binding(
                            get: { model },
                            set: { selection = $0 }
                        )) {
                            ForEach(models, id: \.self) { candidate in
                                Text(candidate.rawValue).tag(candidate)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    let placement = store.placement(for: model)
                    axisRow("Left / right", value: placement.offsetMetres.x) { delta in
                        adjust(model) { $0.offsetMetres.x += delta }
                    }
                    axisRow("Up / down", value: placement.offsetMetres.y) { delta in
                        adjust(model) { $0.offsetMetres.y += delta }
                    }
                    axisRow("Head / feet", value: placement.offsetMetres.z) { delta in
                        adjust(model) { $0.offsetMetres.z += delta }
                    }

                    stepperRow(
                        "Roll (face up)",
                        reading: String(format: "%.0f°", placement.rollDegrees),
                        decrease: { adjust(model) { $0.rollDegrees -= Self.rotationStepDegrees } },
                        increase: { adjust(model) { $0.rollDegrees += Self.rotationStepDegrees } }
                    )
                    stepperRow(
                        "Pitch",
                        reading: String(format: "%.0f°", placement.pitchDegrees),
                        decrease: { adjust(model) { $0.pitchDegrees -= Self.rotationStepDegrees } },
                        increase: { adjust(model) { $0.pitchDegrees += Self.rotationStepDegrees } }
                    )
                    stepperRow(
                        "Yaw",
                        reading: String(format: "%.0f°", placement.yawDegrees),
                        decrease: { adjust(model) { $0.yawDegrees -= Self.rotationStepDegrees } },
                        increase: { adjust(model) { $0.yawDegrees += Self.rotationStepDegrees } }
                    )
                    stepperRow(
                        "Scale",
                        reading: String(format: "%.2f×", placement.scale),
                        decrease: { adjust(model) { $0.scale /= Self.scaleStep } },
                        increase: { adjust(model) { $0.scale *= Self.scaleStep } }
                    )

                    Button("Align to manikin", systemImage: "scope") {
                        onAlign(model)
                    }
                    .font(.caption)
                    .accessibilityHint(
                        "Registers this model onto the manikin's measured torso, matching its chest width and sternum landmark"
                    )

                    if !model.replacedPlaceholderEntityNames.isEmpty {
                        Toggle(
                            "Hide placeholder body",
                            isOn: Binding(
                                get: { placement.hidesPlaceholder },
                                set: { isOn in
                                    adjust(model) { $0.hidesPlaceholder = isOn }
                                }
                            )
                        )
                        .font(.caption)
                    }

                    if model == .human {
                        Toggle(
                            "Crop to manikin envelope",
                            isOn: Binding(
                                get: { placement.cropsToPhysicalEnvelope },
                                set: { isOn in
                                    adjust(model) { $0.cropsToPhysicalEnvelope = isOn }
                                }
                            )
                        )
                        .font(.caption)
                        .accessibilityHint(
                            "Hides imported body geometry that extends past the physical manikin"
                        )
                    }

                    accuracyReadout(for: model)

                    Text(placement.sourceLiteral)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button("Reset \(model.rawValue)", systemImage: "arrow.uturn.backward") {
                        store.reset(model)
                        onPlacementChanged(model)
                    }
                    .font(.caption)
                }
                .padding(.top, 6)
            } else {
                Text("No imported model is attached in this room.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Model placement (developer)", systemImage: "move.3d")
                .font(.caption.bold())
        }
        .frame(maxWidth: 420)
    }

    /// Registration quality, in centimetres and degrees.
    ///
    /// This is the panel's reason to exist beyond nudging: it turns "does the body look
    /// right?" into a number the operator can act on, and the before/after pair is the
    /// evidence that registration did something.
    @ViewBuilder
    private func accuracyReadout(for model: PracticeVisualModel) -> some View {
        if let accuracy = reports.alignment[model] {
            VStack(alignment: .leading, spacing: 3) {
                Label {
                    Text(accuracy.isAligned ? "Registered" : "Not yet registered")
                } icon: {
                    Image(
                        systemName: accuracy.isAligned
                            ? "checkmark.circle.fill"
                            : "exclamationmark.circle"
                    )
                }
                .font(.caption.bold())
                .foregroundStyle(accuracy.isAligned ? .green : .orange)

                Text(accuracy.summary)
                    .font(.caption2.monospacedDigit())
                    .textSelection(.enabled)

                if let report = reports.report(for: model) {
                    Text(report.demoLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let crop = reports.crop[model] {
                    Text(crop.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                accuracy.isAligned
                    ? "Registered onto the manikin"
                    : "Not yet registered onto the manikin"
            )
            .accessibilityValue(accuracy.summary)
        }
    }

    private func axisRow(
        _ title: String,
        value: Float,
        onChange: @escaping (Float) -> Void
    ) -> some View {
        stepperRow(
            title,
            reading: String(format: "%.2f m", value),
            decrease: { onChange(-Self.offsetStepMetres) },
            increase: { onChange(Self.offsetStepMetres) }
        )
    }

    private func stepperRow(
        _ title: String,
        reading: String,
        decrease: @escaping () -> Void,
        increase: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 92, alignment: .leading)
            Button {
                decrease()
            } label: {
                Image(systemName: "minus")
            }
            .accessibilityLabel("Decrease \(title)")
            Text(reading)
                .font(.caption.monospacedDigit())
                .frame(width: 72)
            Button {
                increase()
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Increase \(title)")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func adjust(
        _ model: PracticeVisualModel,
        _ transform: (inout PracticeVisualModelPlacement) -> Void
    ) {
        var placement = store.placement(for: model)
        transform(&placement)
        store.update(placement, for: model)
        onPlacementChanged(model)
    }
}
