import Foundation

/// The simulated AED trainer's voice prompts, mirroring the generic prompt sequence of
/// real-world AEDs (power-on guidance → pad application → rhythm analysis → shock or
/// no-shock → CPR coaching). Phrasing is project-authored generic trainer language and
/// deliberately does not sample or imitate any commercial device's recordings.
enum AEDVoicePrompt: String, CaseIterable, Sendable {
    case callForHelp = "sys.aed.call_for_help"
    case removeClothing = "sys.aed.remove_clothing"
    case lookAtPictures = "sys.aed.look_at_pictures"
    case peelPad = "sys.aed.peel_pad"
    case applyPads = "sys.aed.apply_pads"
    case plugConnector = "sys.aed.plug_connector"
    case doNotTouch = "sys.aed.do_not_touch"
    case analysing = "sys.aed.analysing"
    case shockAdvised = "sys.aed.shock_advised"
    case charging = "sys.aed.charging"
    case pressShockButton = "sys.aed.press_shock_button"
    case shockDelivered = "sys.aed.shock_delivered"
    case noShockAdvised = "sys.aed.no_shock_advised"
    case beginCPR = "sys.aed.begin_cpr"
    case pushHardAndFast = "sys.aed.push_hard_and_fast"
    case keepRhythm = "sys.aed.keep_rhythm"

    var cue: AudioCue { AudioCue(rawValue: rawValue) }

    /// On-screen transcript for the prompt, also the caption fallback when the bundled
    /// caption track is unavailable.
    var transcript: String {
        switch self {
        case .callForHelp:
            "Call for help. Call emergency services now."
        case .removeClothing:
            "Remove all clothing from the person's bare chest."
        case .lookAtPictures:
            "Look at the pictures on the pads."
        case .peelPad:
            "Peel one pad from the liner."
        case .applyPads:
            "Apply the pads to the patient's bare chest, exactly as shown in the pictures."
        case .plugConnector:
            "Plug in the pad connector."
        case .doNotTouch:
            "Do not touch the patient."
        case .analysing:
            "Analyzing heart rhythm. Do not touch the patient."
        case .shockAdvised:
            "Shock advised. Stay clear of the patient."
        case .charging:
            "Charging. Stay clear of the patient."
        case .pressShockButton:
            "Stay clear. Press the flashing shock button now."
        case .shockDelivered:
            "Shock delivered."
        case .noShockAdvised:
            "No shock advised."
        case .beginCPR:
            "Begin CPR. Start chest compressions."
        case .pushHardAndFast:
            "Push hard and fast."
        case .keepRhythm:
            "Keep rhythm. Follow the metronome."
        }
    }
}

/// One step of the trainer's spoken/audible output: either a voice prompt or a device
/// alert tone that plays from the AED unit between prompts.
enum AEDPromptStep: Equatable, Sendable {
    case voice(AEDVoicePrompt)
    case alertTone(AudioCue)

    var cue: AudioCue {
        switch self {
        case let .voice(prompt): prompt.cue
        case let .alertTone(cue): cue
        }
    }
}

/// Maps accepted AED state-machine transitions to the trainer's prompt sequences.
/// Sequences are interruptible: a newer safety-relevant transition replaces whatever
/// the trainer was still saying, exactly like a real device.
enum AEDVoicePromptScript {
    static let powerOnAlertCue = AudioCue(rawValue: "sfx.aed_power_on")
    static let shockDeliveredAlertCue = AudioCue(rawValue: "sfx.aed_shock_delivered")

    /// Fallback per-step pacing when no caption track supplies the clip duration.
    static let fallbackVoiceStepSeconds: TimeInterval = 3.0
    static let fallbackAlertStepSeconds: TimeInterval = 1.4
    /// Breathing room between consecutive prompts.
    static let interPromptGapSeconds: TimeInterval = 0.35

    /// The prompt steps triggered by `acceptedEvent` transitioning the machine into
    /// `state`. Keyed on both so a pad-placement retry does not replay the power-on
    /// startup guidance.
    static func steps(
        for state: AEDPracticeState,
        acceptedEvent: AEDPracticeEvent
    ) -> [AEDPromptStep] {
        switch state {
        case .powerOn:
            []
        case .awaitingPads:
            switch acceptedEvent {
            case .pressPowerControl:
                // Full real-world startup guidance sequence after switch-on.
                [
                    .alertTone(powerOnAlertCue),
                    .voice(.callForHelp),
                    .voice(.removeClothing),
                    .voice(.lookAtPictures),
                    .voice(.peelPad),
                    .voice(.applyPads),
                    .voice(.plugConnector)
                ]
            case .retryPadPlacement:
                [.voice(.applyPads)]
            default:
                []
            }
        case .padsIncorrect:
            [.voice(.lookAtPictures), .voice(.applyPads)]
        case .padsCorrect:
            [.voice(.doNotTouch)]
        case .analysing:
            [.voice(.analysing)]
        case .shockAdvised:
            [.voice(.shockAdvised)]
        case .charging:
            [.voice(.charging)]
        case .clearConfirmation:
            [.voice(.pressShockButton)]
        case .simulatedShock:
            [
                .alertTone(shockDeliveredAlertCue),
                .voice(.shockDelivered),
                .voice(.beginCPR),
                .voice(.pushHardAndFast)
            ]
        case .noShockAdvised:
            [
                .voice(.noShockAdvised),
                .voice(.beginCPR),
                .voice(.pushHardAndFast)
            ]
        case .resumeCompressions:
            [.voice(.keepRhythm)]
        case .complete:
            []
        }
    }
}
