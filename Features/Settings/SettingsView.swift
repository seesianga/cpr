import SwiftUI

/// Learner-controlled audio and accessibility preferences.
struct SettingsView: View {
    @AppStorage("settings.audio.narrationVolume") private var narrationVolume = 0.8
    @AppStorage("settings.audio.musicVolume") private var musicVolume = 0.5
    @AppStorage("settings.audio.soundEffectsVolume") private var soundEffectsVolume = 0.7

    @AppStorage("settings.accessibility.captionsEnabled") private var captionsEnabled = true
    @AppStorage("settings.accessibility.reduceMotion") private var reduceMotion = false
    @AppStorage("settings.accessibility.highContrast") private var highContrast = false

    var body: some View {
        Form {
            Section("Audio") {
                volumeControl("Narration", value: $narrationVolume)
                volumeControl("Music", value: $musicVolume)
                volumeControl("Sound Effects", value: $soundEffectsVolume)
            }

            Section("Accessibility") {
                Toggle("Show Captions", isOn: $captionsEnabled)
                Toggle("Reduce Motion", isOn: $reduceMotion)
                Toggle("Increase Contrast", isOn: $highContrast)
            }
        }
        .navigationTitle("Settings")
    }

    private func volumeControl(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Slider(value: value, in: 0...1)
                .accessibilityValue(Text(value.wrappedValue, format: .percent))
        }
    }
}
