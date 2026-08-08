import SwiftUI

enum SettingsAccessibilityLabels {
    static let narrationVolume = "Narration volume"
    static let dialogueVolume = "Dialogue volume"
    static let soundEffectsVolume = "Sound effects volume"
    static let musicVolume = "Music volume"
}

/// Learner-controlled audio and accessibility preferences.
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage(AudioPreferenceKeys.narrationVolume) private var narrationVolume = 0.8
    @AppStorage(AudioPreferenceKeys.dialogueVolume) private var dialogueVolume = 0.8
    @AppStorage(AudioPreferenceKeys.musicVolume) private var musicVolume = 0.5
    @AppStorage(AudioPreferenceKeys.soundEffectsVolume) private var soundEffectsVolume = 0.7
    @AppStorage(AudioPreferenceKeys.narrationSpeed) private var narrationSpeed = 1.0

    @AppStorage(AudioPreferenceKeys.captionsEnabled) private var captionsEnabled = true
    @AppStorage(AudioPreferenceKeys.reduceMotion) private var reduceMotion = false
    @AppStorage(AudioPreferenceKeys.highContrast) private var highContrast = false

    var body: some View {
        Form {
            Section("Audio") {
                volumeControl(
                    "Narration",
                    accessibilityLabel: SettingsAccessibilityLabels.narrationVolume,
                    value: $narrationVolume
                )
                volumeControl(
                    "Dialogue and Safety Voice",
                    accessibilityLabel: SettingsAccessibilityLabels.dialogueVolume,
                    value: $dialogueVolume
                )
                volumeControl(
                    "Music",
                    accessibilityLabel: SettingsAccessibilityLabels.musicVolume,
                    value: $musicVolume
                )
                volumeControl(
                    "Sound Effects",
                    accessibilityLabel: SettingsAccessibilityLabels.soundEffectsVolume,
                    value: $soundEffectsVolume
                )

                Picker("Narration Speed", selection: $narrationSpeed) {
                    Text("0.8×").tag(0.8)
                    Text("1.0×").tag(1.0)
                    Text("1.2×").tag(1.2)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Changes lesson narration speed while preserving the selected track")
            }

            Section("Accessibility") {
                Toggle("Show Captions", isOn: $captionsEnabled)
                Toggle("Reduce Motion", isOn: $reduceMotion)
                Toggle("Increase Contrast", isOn: $highContrast)
            }
        }
        .navigationTitle("Settings")
        .onChange(
            of: [
                narrationVolume,
                dialogueVolume,
                musicVolume,
                soundEffectsVolume,
                narrationSpeed
            ]
        ) { _, _ in
            Task { await appModel.audioDirector.refreshPreferences() }
        }
    }

    private func volumeControl(
        _ title: LocalizedStringKey,
        accessibilityLabel: String,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Slider(value: value, in: 0...1)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityValue(Text(value.wrappedValue, format: .percent))
        }
    }
}
