import Foundation
import SwiftUI

struct CaptionCue: Identifiable, Sendable, Equatable {
    let id: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct CaptionTrack: Sendable, Equatable {
    let assetID: String
    let cues: [CaptionCue]

    var transcript: String {
        cues.map(\.text).joined(separator: "\n")
    }

    func text(at time: TimeInterval) -> String? {
        cues.first { $0.startTime <= time && time < $0.endTime }?.text
    }
}

enum CaptionParsingError: Error, Sendable, Equatable {
    case missingHeader
    case malformedTimestamp(String)
    case emptyTrack
}

struct WebVTTParser: Sendable {
    func parse(_ data: Data, assetID: String) throws -> CaptionTrack {
        guard let source = String(data: data, encoding: .utf8) else {
            throw CaptionParsingError.missingHeader
        }
        return try parse(source, assetID: assetID)
    }

    func parse(_ source: String, assetID: String) throws -> CaptionTrack {
        let normalised = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard normalised.hasPrefix("WEBVTT") else {
            throw CaptionParsingError.missingHeader
        }

        let blocks = normalised.components(separatedBy: "\n\n")
        var cues: [CaptionCue] = []
        for block in blocks.dropFirst() {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count == 2 else {
                throw CaptionParsingError.malformedTimestamp(lines[timingIndex])
            }
            let start = try Self.parseTimestamp(timingParts[0])
            let endToken = timingParts[1]
                .trimmingCharacters(in: .whitespaces)
                .split(separator: " ", maxSplits: 1)
                .first
                .map(String.init) ?? ""
            let end = try Self.parseTimestamp(endToken)
            let text = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, end > start else { continue }
            cues.append(
                CaptionCue(
                    id: cues.count,
                    startTime: start,
                    endTime: end,
                    text: text
                )
            )
        }
        guard !cues.isEmpty else { throw CaptionParsingError.emptyTrack }
        return CaptionTrack(assetID: assetID, cues: cues)
    }

    private static func parseTimestamp(_ value: String) throws -> TimeInterval {
        let components = value
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ":")
            .map(String.init)
        guard components.count == 2 || components.count == 3 else {
            throw CaptionParsingError.malformedTimestamp(value)
        }
        let hours: Double
        let minutes: Double
        let seconds: Double
        if components.count == 3 {
            guard let parsedHours = Double(components[0]),
                  let parsedMinutes = Double(components[1]),
                  let parsedSeconds = Double(components[2])
            else { throw CaptionParsingError.malformedTimestamp(value) }
            hours = parsedHours
            minutes = parsedMinutes
            seconds = parsedSeconds
        } else {
            guard let parsedMinutes = Double(components[0]),
                  let parsedSeconds = Double(components[1])
            else { throw CaptionParsingError.malformedTimestamp(value) }
            hours = 0
            minutes = parsedMinutes
            seconds = parsedSeconds
        }
        guard hours >= 0, (0..<60).contains(minutes), (0..<60).contains(seconds) else {
            throw CaptionParsingError.malformedTimestamp(value)
        }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

struct BundleCaptionResolver: @unchecked Sendable {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func url(for assetID: String) -> URL? {
        for subdirectory in ["Resources/Captions", "Captions"] {
            if let url = bundle.url(
                forResource: assetID,
                withExtension: "vtt",
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return bundle.url(forResource: assetID, withExtension: "vtt")
    }

    func track(for assetID: String) -> CaptionTrack? {
        guard let url = url(for: assetID),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? WebVTTParser().parse(data, assetID: assetID)
    }
}

/// Caption timing for speech rendered by RealityKit rather than AVAudioPlayer.
struct SpatialSpeechCaptionPlayback: Sendable, Equatable {
    let cue: AudioCue
    let startedAt: Date
    let rate: Double
}

struct SpatialSpeechCaptionOverlay: View {
    let playback: SpatialSpeechCaptionPlayback?
    private let resolver: BundleCaptionResolver

    @AppStorage(AudioPreferenceKeys.captionsEnabled) private var captionsEnabled = true
    @State private var track: CaptionTrack?
    @State private var currentTime: TimeInterval = 0

    init(
        playback: SpatialSpeechCaptionPlayback?,
        bundle: Bundle = .main
    ) {
        self.playback = playback
        resolver = BundleCaptionResolver(bundle: bundle)
    }

    var body: some View {
        Group {
            if captionsEnabled, let text = track?.text(at: currentTime) {
                Text(text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
                    .padding(14)
                    .lifesaverCaptionSurface()
                    .glassBackgroundEffect()
                    .accessibilityLabel("Caption: \(text)")
            }
        }
        .task(id: playback.map {
            "\($0.cue.rawValue)#\($0.startedAt.timeIntervalSinceReferenceDate)#\($0.rate)"
        }) {
            guard let playback else {
                track = nil
                currentTime = 0
                return
            }
            track = resolver.track(for: playback.cue.rawValue)
            while !Task.isCancelled {
                currentTime = max(
                    0,
                    Date().timeIntervalSince(playback.startedAt) * playback.rate
                )
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// Captions follow the current speech playhead; meaningful SFX retain a visual status.
struct AudioCaptionOverlay: View {
    let audioDirector: any AudioDirector
    private let captionResolver: BundleCaptionResolver

    @AppStorage(AudioPreferenceKeys.captionsEnabled) private var captionsEnabled = true
    @State private var snapshot = AudioPlaybackSnapshot.idle
    @State private var track: CaptionTrack?
    @State private var loadedAssetID: String?

    init(
        audioDirector: any AudioDirector,
        bundle: Bundle = .main
    ) {
        self.audioDirector = audioDirector
        captionResolver = BundleCaptionResolver(bundle: bundle)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let visualState = snapshot.visualState {
                Label(visualState.stateLabel, systemImage: "waveform")
                    .font(.headline)
                    .accessibilityLabel(visualAccessibilityLabel(visualState))
            }

            if captionsEnabled, let captionText {
                Text(captionText)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .accessibilityLabel("Caption: \(captionText)")
            }
        }
        .frame(maxWidth: 680)
        .padding(14)
        .lifesaverCaptionSurface()
        .glassBackgroundEffect()
        .opacity(snapshot.visualState == nil && captionText == nil ? 0 : 1)
        .task {
            while !Task.isCancelled {
                let next = await audioDirector.playbackSnapshot()
                snapshot = next
                loadTrackIfNeeded(for: next.activeCue)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var captionText: String? {
        if let speech = track?.text(at: snapshot.currentTime) {
            return speech
        }
        return snapshot.visualState?.captionText
    }

    private func loadTrackIfNeeded(for cue: AudioCue?) {
        guard let cue,
              AudioChannel.inferred(from: cue)?.isSpeech == true
        else {
            loadedAssetID = nil
            track = nil
            return
        }
        guard cue.rawValue != loadedAssetID else { return }
        loadedAssetID = cue.rawValue
        track = captionResolver.track(for: cue.rawValue)
    }

    private func visualAccessibilityLabel(_ visual: AudioVisualState) -> String {
        if let direction = visual.direction {
            return "\(visual.stateLabel), \(direction)"
        }
        return visual.stateLabel
    }
}
