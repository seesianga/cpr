import XCTest
@testable import LifesaverVision

@MainActor
final class AccessibilityPreferencesTests: XCTestCase {
    func testEveryVolumeSliderHasTheRequiredSpecificAccessibilityLabel() {
        XCTAssertEqual(SettingsAccessibilityLabels.narrationVolume, "Narration volume")
        XCTAssertEqual(SettingsAccessibilityLabels.dialogueVolume, "Dialogue volume")
        XCTAssertEqual(SettingsAccessibilityLabels.soundEffectsVolume, "Sound effects volume")
        XCTAssertEqual(SettingsAccessibilityLabels.musicVolume, "Music volume")
    }

    func testStoredHighContrastPreferencePropagatesToVisualTokens() throws {
        let suite = "AccessibilityPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AudioPreferencesStore(defaults: defaults)
        var preference = AudioPreferencesSnapshot.defaults
        preference.highContrast = true

        store.save(preference)
        let style = LifesaverVisualStyle(preferences: store.snapshot())

        XCTAssertTrue(style.highContrast)
        XCTAssertEqual(style.captionBackgroundOpacity, 0.94)
        XCTAssertEqual(style.captionBorderOpacity, 1.0)
        XCTAssertEqual(style.statusBorderWidth, 2)
    }
}
