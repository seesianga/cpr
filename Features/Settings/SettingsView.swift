import SwiftUI

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
                volumeControl("Narration", value: $narrationVolume)
                volumeControl("Dialogue and Safety Voice", value: $dialogueVolume)
                volumeControl("Music", value: $musicVolume)
                volumeControl("Sound Effects", value: $soundEffectsVolume)

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

    private func volumeControl(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Slider(value: value, in: 0...1)
                .accessibilityValue(Text(value.wrappedValue, format: .percent))
        }
    }
}
