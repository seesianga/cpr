import Foundation
import Observation

enum CPRPracticeSessionLoadState: Sendable, Equatable {
    case idle
    case loading
    case ready
    case failed(message: String)
}

/// Main-actor coordinator for a CPR practice attempt.
///
/// All transition and scoring decisions remain in the pure Swift engines. This model only
/// translates input signals into typed events and exposes their results to presentation code.
@MainActor
@Observable
final class CPRPracticeSessionModel {
    private let handTracking: any HandTrackingServicing
    private let sensorProvider: any CPRSensorProvider
    private var audioDirector: any AudioDirector
    private let bundle: Bundle
    private let badgeRuleLoader: (Bundle) throws -> [BadgeRule]
    private var machine: CPRPracticeStateMachine?
    private var content: PracticeMachineContentContract?
    private var signalTask: Task<Void, Never>?
    private var metronomeTask: Task<Void, Never>?
    private var interruptionTimerTask: Task<Void, Never>?
    private var restStartedAt: Double?
    private var lastCompressionActiveClock: Double?
    private var lastFallbackCompressionTimestamp: Double?
    private var handTimestampOffset: Double?
    private var accumulatedPausedSeconds = 0.0
    private var pauseStartedAt: Double?

    /// Rolling cap for the session-scoped per-compression distance log.
    static let maximumRetainedDistanceSamples = 400
    /// Counted samples averaged for the live "contact travel" coaching figure.
    static let recentDistanceSampleWindow = 10

    private(set) var loadState: CPRPracticeSessionLoadState = .idle
    private(set) var handTrackingState: HandTrackingState = .idle
    private(set) var latestFeedback: String?
    private(set) var summary: CPRPracticeSessionSummary?
    private(set) var gamificationDecision: GamificationDecision?
    private(set) var visualMetronomePulse = false
    private(set) var liveInterruptionSeconds = 0.0
    private(set) var isPaused = false
    /// Per-descent distance records from the contact-cycle detector. Virtual-surface
    /// interaction distances for coaching and threshold tuning — never a physical
    /// compression-depth measurement.
    private(set) var compressionDistanceLog: [CompressionDistanceSample] = []
    /// The most recent clamped detector-threshold adjustment, if any occurred.
    private(set) var latestThresholdAdaptation: CompressionThresholdAdaptation?

    init(
        handTracking: any HandTrackingServicing = HandTrackingService(),
        sensorProvider: any CPRSensorProvider = UnavailableCPRSensorProvider(),
        audioDirector: any AudioDirector = NoOpAudioDirector(),
        badgeRuleLoader: @escaping (Bundle) throws -> [BadgeRule] = {
            try BadgeRuleCodec.loadBundled(from: $0)
        },
        bundle: Bundle = .main
    ) {
        self.handTracking = handTracking
        self.sensorProvider = sensorProvider
        self.audioDirector = audioDirector
        self.badgeRuleLoader = badgeRuleLoader
        self.bundle = bundle
    }

    var state: CPRPracticeState? { machine?.state }
    var metrics: CPRPracticeMetrics { machine?.metrics ?? CPRPracticeMetrics() }
    var criticalFailures: [CPRPracticeCriticalFailure] { machine?.criticalFailures ?? [] }
    var eventLogCount: Int { machine?.eventLog.count ?? 0 }
    var targetRateText: String {
        guard let policy = content?.cprPolicy else { return "100–120/min" }
        return "\(Int(policy.minimumRatePerMinute))–\(Int(policy.maximumRatePerMinute))/min"
    }
    var practiceTempoPerMinute: Double { content?.cprPolicy.practiceTempoPerMinute ?? 110 }
    var minimumCompressionsForCompletion: Int {
        content?.cprPolicy.preferredCompressionsPerCycle ?? 100
    }
    var handTrackingFallbackExplanation: String? { handTrackingState.fallbackExplanation }

    /// Mean descent travel (metres) over the recent counted samples, for live display.
    var recentContactTravelAverageMetres: Double? {
        let counted = compressionDistanceLog
            .filter(\.countedAsCompression)
            .suffix(Self.recentDistanceSampleWindow)
        guard !counted.isEmpty else { return nil }
        let total = counted.reduce(0.0) { $0 + Double($1.descentDistanceMetres) }
        return total / Double(counted.count)
    }

    func setAudioDirector(_ audioDirector: any AudioDirector) {
        self.audioDirector = audioDirector
    }

    var guidanceTitle: String {
        switch machine?.state {
        case .positioning: "Position the manikin"
        case .landmarkCheck: "Check hand placement"
        case .correctiveFeedback: "Correct placement"
        case .compressionCycles: "Continue compressions"
        case .restWindow: "Short rest window"
        case .stopped: "Practice stopped"
        case .complete: "Session complete"
        case nil: "Preparing practice"
        }
    }

    var guidanceBody: String {
        if let latestFeedback { return latestFeedback }
        return switch machine?.state {
        case .positioning:
            "Confirm the training manikin is supine on a firm, flat surface."
        case .landmarkCheck:
            "Place the heel of the hand on the highlighted lower-half sternum target and avoid the xiphoid zone."
        case .correctiveFeedback:
            "Review the highlighted target, then retry the landmark check."
        case .compressionCycles:
            "Use the visual pulse and keep the measured interaction cadence in the supported band. Allow full recoil; recoil and depth are Not physically assessed."
        case .restWindow:
            "Keep this planned interruption to 10 seconds or less, then resume compressions."
        case .stopped:
            "Finish the internal practice record when the supported stop condition applies."
        case .complete:
            "Review the practice summary. This is not SRFAC certification."
        case nil:
            "Source-backed practice content is loading."
        }
    }

    func prepare() async {
        guard !Task.isCancelled else { return }
        guard loadState != .loading else { return }
        loadState = .loading
        summary = nil
        gamificationDecision = nil
        latestFeedback = nil
        compressionDistanceLog.removeAll(keepingCapacity: false)
        latestThresholdAdaptation = nil
        resetAttemptClocks()
        do {
            let loaded = try PracticeMachineContentContract.loadBundled(from: bundle)
            content = loaded
            machine = CPRPracticeStateMachine(policy: loaded.cprPolicy)
            loadState = .ready
            startSignalConsumerIfNeeded()
            try? await audioDirector.prepare()
            guard !Task.isCancelled else {
                await stop()
                return
            }
            startMetronome()
        } catch {
            content = nil
            machine = nil
            loadState = .failed(
                message: "The source-backed CPR practice policy could not be loaded. Practice is unavailable until the content is corrected."
            )
        }
    }

    func configureHandTracking(targets: HandTrackingTargets) {
        handTracking.configure(targets: targets)
    }

    func startHandTracking() async {
        await handTracking.start()
        handTrackingState = handTracking.state
    }

    func setPaused(
        _ paused: Bool,
        at timestampSeconds: Double = ProcessInfo.processInfo.systemUptime
    ) async {
        guard isPaused != paused else { return }
        if paused {
            isPaused = true
            pauseStartedAt = timestampSeconds
            handTimestampOffset = nil
            handTracking.pause()
        } else {
            if let pauseStartedAt {
                accumulatedPausedSeconds += max(0, timestampSeconds - pauseStartedAt)
            }
            self.pauseStartedAt = nil
            isPaused = false
            handTimestampOffset = nil
            await handTracking.start()
        }
        handTrackingState = handTracking.state
    }

    func confirmPositioning() {
        submit(.confirmPositioning)
    }

    func choosePlacement(_ zone: CPRHandPlacementZone) {
        submit(.classifyHandPlacement(zone))
    }

    func acknowledgeCorrection() {
        submit(.acknowledgeCorrection)
    }

    /// Accessible cadence fallback. The timestamp is injected by tests and originates from
    /// the button/tap event in production; no clinical value is fabricated.
    func recordFallbackCompression(
        at timestampSeconds: Double = ProcessInfo.processInfo.systemUptime
    ) {
        guard !isPaused else { return }
        let activeTimestamp = activeClock(at: timestampSeconds)
        if let previous = lastFallbackCompressionTimestamp,
           let maximum = content?.cprPolicy.maximumRestSeconds {
            let gap = activeTimestamp - previous
            if gap > maximum {
                submit(.recordInterruption(durationSeconds: gap))
            }
        }
        lastFallbackCompressionTimestamp = activeTimestamp
        let entry = submit(
            .compressionDetected(
                timestampSeconds: activeTimestamp,
                placement: .sternumTarget,
                handStacking: .indeterminate
            )
        )
        if entry?.wasAccepted == true {
            lastCompressionActiveClock = activeTimestamp
        }
    }

    func startRest(at timestampSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        let entry = submit(.startRest)
        if entry?.wasAccepted == true {
            restStartedAt = activeClock(at: timestampSeconds)
        }
    }

    func endRest(at timestampSeconds: Double = ProcessInfo.processInfo.systemUptime) {
        guard let restStartedAt else { return }
        self.restStartedAt = nil
        submit(
            .endRest(
                durationSeconds: max(0, activeClock(at: timestampSeconds) - restStartedAt)
            )
        )
    }

    func endSession(
        reason: CPRStopReason = .emergencyTeamTookOver,
        learnerID: String = "local-learner",
        currentXP: Int = 0,
        at timestampSeconds: Double = ProcessInfo.processInfo.systemUptime
    ) async {
        guard !isPaused, let content else { return }
        guard machine?.state == .compressionCycles else {
            latestFeedback = "Complete positioning and the guided compression cycle before ending the practice."
            return
        }
        guard metrics.totalCompressions >= content.cprPolicy.preferredCompressionsPerCycle,
              metrics.completedCycles > 0
        else {
            latestFeedback = "Complete the source-backed practice cycle of about \(content.cprPolicy.preferredCompressionsPerCycle) compressions before creating a completion record."
            return
        }

        recordTerminalInterruptionIfNeeded(at: timestampSeconds)
        guard var machine = self.machine else { return }

        _ = machine.handle(.stop(reason))
        _ = machine.handle(.finish)
        self.machine = machine

        let attemptID = UUID().uuidString
        let input = CPRPracticeScoreInput(
            attemptID: attemptID,
            contentVersion: content.contentVersion,
            metrics: machine.metrics,
            criticalFailures: machine.criticalFailures
        )
        let builtSummary: CPRPracticeSessionSummary
        do {
            builtSummary = try await ScoringEngine().summarize(
                input,
                sensorProvider: sensorProvider
            )
            summary = builtSummary
        } catch {
            summary = nil
            gamificationDecision = nil
            latestFeedback = "The practice record could not be scored. No XP was awarded."
            return
        }

        // XP is computed exclusively by the existing policy engine. A missing policy
        // resource fails closed while retaining the already-built internal summary.
        do {
            let policy = GamificationPolicy.standard(badgeRules: try badgeRuleLoader(bundle))
            var badgeMetrics: [String: Double] = [
                "longestInterruptionSeconds": builtSummary.longestInterruptionSeconds,
                "successfulPracticeCount": builtSummary.scoreOutcome.xpEligible ? 1 : 0
            ]
            if let cadence = builtSummary.scoreOutcome.contributions.first(
                where: { $0.dimension == .cadenceBand }
            )?.normalisedScore {
                badgeMetrics["rhythmAccuracy"] = cadence
            }
            gamificationDecision = GamificationEngine().evaluate(
                event: CPRPracticeGamificationEvent(
                    learnerID: learnerID,
                    courseID: content.courseID,
                    contentVersion: content.contentVersion,
                    sourceAttemptID: attemptID,
                    completedAt: Date(),
                    scoreOutcome: builtSummary.scoreOutcome
                ),
                currentXP: currentXP,
                metrics: BadgeMetricSnapshot(values: badgeMetrics),
                existingAwards: [],
                approvedSignOffs: [],
                policy: policy
            )
        } catch {
            gamificationDecision = nil
            latestFeedback = "The internal practice summary is available, but the XP policy could not be loaded. No XP was awarded."
        }
    }

    func stop() async {
        signalTask?.cancel()
        signalTask = nil
        metronomeTask?.cancel()
        metronomeTask = nil
        interruptionTimerTask?.cancel()
        interruptionTimerTask = nil
        handTracking.stop()
        handTrackingState = handTracking.state
        await audioDirector.stopAll()
    }

    @discardableResult
    private func submit(
        _ event: CPRPracticeEvent
    ) -> StateMachineEventLogEntry<
        CPRPracticeState,
        CPRPracticeEvent,
        CPRPracticeRejectionReason,
        CPRPracticeRemediation
    >? {
        guard !isPaused, var machine else { return nil }
        let entry = machine.handle(event)
        self.machine = machine
        if case .compressionDetected = event, entry.wasAccepted {
            lastCompressionActiveClock = activeClock(
                at: ProcessInfo.processInfo.systemUptime
            )
            liveInterruptionSeconds = 0
            startInterruptionTimerIfNeeded()
        }
        switch entry.outcome {
        case let .accepted(_, remediation):
            latestFeedback = remediation?.message
        case let .rejected(_, remediation):
            latestFeedback = remediation.message
        }
        return entry
    }

    private func startSignalConsumerIfNeeded() {
        guard signalTask == nil else { return }
        let signals = handTracking.signals
        signalTask = Task { [weak self] in
            for await signal in signals {
                guard !Task.isCancelled, let self else { return }
                self.consume(signal)
            }
        }
    }

    private func consume(_ signal: HandTrackingDerivedEvent) {
        guard !isPaused else { return }
        switch signal {
        case let .trackingAvailabilityChanged(isAvailable):
            let temporaryMessage = "Hand observations are temporarily unavailable. Continue with the accessible compression control."
            if !isAvailable, handTracking.state.fallbackExplanation == nil {
                latestFeedback = temporaryMessage
            } else if isAvailable, latestFeedback == temporaryMessage {
                latestFeedback = nil
            }
            handTrackingState = handTracking.state
        case let .placementChanged(zone):
            if machine?.state == .landmarkCheck,
               zone != .xiphoidAvoidZone {
                submit(.classifyHandPlacement(zone))
            }
        case let .placementDwellConfirmed(zone):
            if machine?.state == .landmarkCheck {
                submit(.classifyHandPlacement(zone))
            }
        case .handStackingChanged, .cadenceUpdated, .grabInteractionChanged:
            break
        case .interruptionMeasured:
            if let event = signal.cprPracticeEvent {
                submit(event)
            }
        case let .compressionDetected(timestamp, placement, stacking):
            submit(
                .compressionDetected(
                    timestampSeconds: normalizedHandTimestamp(timestamp),
                    placement: placement,
                    handStacking: stacking
                )
            )
        case let .compressionDistanceMeasured(sample):
            recordDistanceSample(sample)
        case let .compressionThresholdAdapted(adaptation):
            latestThresholdAdaptation = adaptation
            latestFeedback = Self.thresholdAdaptationFeedback(adaptation)
        }
    }

    private func recordDistanceSample(_ sample: CompressionDistanceSample) {
        compressionDistanceLog.append(sample)
        if compressionDistanceLog.count > Self.maximumRetainedDistanceSamples {
            compressionDistanceLog.removeFirst(
                compressionDistanceLog.count - Self.maximumRetainedDistanceSamples
            )
        }
    }

    private static func thresholdAdaptationFeedback(
        _ adaptation: CompressionThresholdAdaptation
    ) -> String {
        switch adaptation.reason {
        case .nearMissDescentsAboveEntryBand:
            "Several presses stopped just above the virtual chest surface, so the trainer widened its contact-detection range. Keep pressing through to the highlighted target."
        case .shallowCyclesBelowReleaseHysteresis:
            "Your contact cycles were travelling a very short distance, so the trainer relaxed its release filter to keep counting your rhythm. Aim for fuller strokes with complete release."
        }
    }

    private func startMetronome() {
        metronomeTask?.cancel()
        let intervalNanoseconds = UInt64((60 / practiceTempoPerMinute) * 1_000_000_000)
        let audioDirector = audioDirector
        metronomeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
                guard let self else { return }
                guard !self.isPaused else { continue }
                self.visualMetronomePulse.toggle()
                _ = await audioDirector.play(
                    AudioPlaybackRequest(
                        cue: AudioCue(rawValue: "sfx.metronome"),
                        channel: .soundEffects,
                        context: .immersive,
                        autoplay: true
                    )
                )
            }
        }
    }

    private func startInterruptionTimerIfNeeded() {
        guard interruptionTimerTask == nil else { return }
        interruptionTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                guard !self.isPaused,
                      self.machine?.state == .compressionCycles,
                      let lastCompressionActiveClock = self.lastCompressionActiveClock
                else { continue }
                self.liveInterruptionSeconds = max(
                    0,
                    self.activeClock(at: ProcessInfo.processInfo.systemUptime) -
                        lastCompressionActiveClock
                )
            }
        }
    }

    private func recordTerminalInterruptionIfNeeded(at timestampSeconds: Double) {
        guard let maximum = content?.cprPolicy.maximumRestSeconds,
              let lastCompressionActiveClock
        else { return }
        let gap = max(0, activeClock(at: timestampSeconds) - lastCompressionActiveClock)
        if gap > maximum {
            submit(.recordInterruption(durationSeconds: gap))
        }
    }

    private func activeClock(at timestampSeconds: Double) -> Double {
        let currentPause = pauseStartedAt.map { max(0, timestampSeconds - $0) } ?? 0
        return max(0, timestampSeconds - accumulatedPausedSeconds - currentPause)
    }

    private func normalizedHandTimestamp(_ sourceTimestamp: Double) -> Double {
        let now = activeClock(at: ProcessInfo.processInfo.systemUptime)
        if handTimestampOffset == nil {
            handTimestampOffset = now - sourceTimestamp
        }
        return max(0, sourceTimestamp + (handTimestampOffset ?? 0))
    }

    private func resetAttemptClocks() {
        restStartedAt = nil
        lastCompressionActiveClock = nil
        lastFallbackCompressionTimestamp = nil
        handTimestampOffset = nil
        accumulatedPausedSeconds = 0
        pauseStartedAt = nil
        liveInterruptionSeconds = 0
        isPaused = false
    }
}
