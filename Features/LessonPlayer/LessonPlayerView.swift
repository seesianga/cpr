import SwiftData
import SwiftUI

/// Source-backed, non-timed lesson reader. The route has already passed the authoritative
/// CourseEngine presentation gate before this view is constructed.
@MainActor
struct LessonPlayerView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @State private var model: LessonPlayerSessionModel

    init(
        route: LessonPlayerRoute,
        audioDirector: any LessonAudioDirecting,
        assessmentProvider: any LessonAssessmentProviding,
        resumeStore: LessonResumeStore = LessonResumeStore(),
        preferences: AudioPreferencesStore = AudioPreferencesStore()
    ) {
        _model = State(
            initialValue: LessonPlayerSessionModel(
                route: route,
                audioDirector: audioDirector,
                assessmentProvider: assessmentProvider,
                resumeStore: resumeStore,
                preferences: preferences
            )
        )
    }

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                lessonHeader

                if let block = model.currentBlock {
                    LessonContentBlockView(presentation: block)
                    narrationControls(for: block)
                    sourceAndTranscript(for: block)
                } else {
                    ContentUnavailableView(
                        "No Lesson Blocks",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(
                            "This module has no authored lesson blocks in content version \(model.route.contentVersion)."
                        )
                    )
                }

                lessonNavigation
                finishLessonCard
                activities
                assessments
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(model.route.module.title)
        .overlay(alignment: .bottom) {
            LessonCaptionOverlay(audioDirector: model.audioDirectorForCaptions)
                .padding(.bottom, 16)
                .allowsHitTesting(false)
        }
        .sheet(
            item: Binding(
                get: { model.quizLaunch },
                set: { launch in
                    if launch == nil { model.dismissQuiz() }
                }
            )
        ) { launch in
            LessonQuizSheet(
                launch: launch,
                learnerID: model.route.learnerID,
                courseID: model.route.courseID,
                contentVersion: model.route.contentVersion,
                onClose: model.dismissQuiz
            )
        }
        .task {
            let progressWriter = SwiftDataLessonProgressWriter(
                modelContainer: modelContext.container
            )
            await model.prepare(progressWriter: progressWriter)
            while !Task.isCancelled {
                await model.refreshPlayback()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .onDisappear {
            model.persistPosition()
            Task { await model.stop() }
        }
    }

    private var lessonHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.route.module.id)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Content version \(model.route.contentVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.positionLabel)
                    .font(.subheadline.monospacedDigit())
                    .accessibilityLabel("Lesson position: \(model.positionLabel)")
            }

            Text(model.currentLesson?.title ?? model.route.module.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text(model.currentLesson?.summary ?? model.route.module.summary)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func narrationControls(for block: LessonBlockPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if block.isAwaitingClinicalApproval {
                Label(
                    "Text and captions only — narration is intentionally unavailable while this block awaits clinical approval.",
                    systemImage: "speaker.slash.fill"
                )
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("lesson-narration-unavailable-\(block.id)")
            } else {
                HStack(spacing: 12) {
                    Button(
                        model.isCurrentNarrationPlaying ? "Pause Narration" : "Play Narration",
                        systemImage: model.isCurrentNarrationPlaying ? "pause.fill" : "play.fill"
                    ) {
                        Task { await model.toggleNarration() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Plays or pauses narration for this source-checked block")

                    Button("Replay", systemImage: "arrow.counterclockwise") {
                        Task { await model.replayNarration() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Restarts narration for this block")

                    Picker(
                        "Narration Speed",
                        selection: Binding(
                            get: { model.narrationSpeed },
                            set: { speed in
                                Task { await model.setNarrationSpeed(speed) }
                            }
                        )
                    ) {
                        Text("0.8×").tag(0.8)
                        Text("1.0×").tag(1.0)
                        Text("1.2×").tag(1.2)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                    .accessibilityHint("Changes narration speed and restarts active narration")
                }

                if model.playbackSnapshot.duration > 0,
                   model.playbackSnapshot.activeCue == block.narrationCue {
                    ProgressView(
                        value: model.playbackSnapshot.currentTime,
                        total: model.playbackSnapshot.duration
                    )
                    .accessibilityLabel("Narration progress")
                    .accessibilityValue(
                        "\(Int(model.playbackSnapshot.currentTime.rounded())) of \(Int(model.playbackSnapshot.duration.rounded())) seconds"
                    )
                }
            }

            if let notice = model.narrationNotice {
                Label(notice, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Narration status: \(notice)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private func sourceAndTranscript(for block: LessonBlockPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup("Transcript") {
                Text(block.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .accessibilityHint("Shows the complete text for this lesson block")

            DisclosureGroup("Source references") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(block.block.sourceReferences) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.document)
                                .font(.headline)
                            Text("\(source.edition) · \(source.section) · page \(source.page)")
                            Text("Review status: \(source.reviewStatus.replacingOccurrences(of: "_", with: " "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.top, 8)
            }
            .accessibilityHint("Shows document, edition, section, page and review status")
        }
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var lessonNavigation: some View {
        HStack(spacing: 12) {
            Button("Previous Block", systemImage: "chevron.left") {
                Task { await model.movePrevious() }
            }
            .disabled(!model.canMovePrevious)

            Menu("Jump to Block", systemImage: "list.bullet") {
                ForEach(model.lessons) { lesson in
                    Section(lesson.title) {
                        ForEach(lesson.contentBlocks) { block in
                            Button(block.title) {
                                Task { await model.move(toBlockID: block.id) }
                            }
                        }
                    }
                }
            }

            Spacer()

            Button("Next Block", systemImage: "chevron.right") {
                Task { await model.moveNext() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canMoveNext)
        }
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    private var finishLessonCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Finish this lesson")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("This action is untimed. It records this authored lesson for your learner, course and content version without replacing earlier completions.")
                .foregroundStyle(.secondary)

            Button(
                model.isCurrentLessonComplete ? "Lesson Finished" : "Finish Lesson",
                systemImage: model.isCurrentLessonComplete
                    ? "checkmark.circle.fill"
                    : "checkmark.circle"
            ) {
                let progressWriter = SwiftDataLessonProgressWriter(
                    modelContainer: modelContext.container
                )
                Task { await model.finishCurrentLesson(using: progressWriter) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.isSavingCompletion ||
                    model.isCurrentLessonComplete ||
                    !model.isAtEndOfCurrentLesson
            )
            .accessibilityIdentifier("lesson-finish-\(model.currentLesson?.id ?? "unavailable")")
            .accessibilityHint(
                model.isAtEndOfCurrentLesson
                    ? "Saves this lesson as complete for the current content version"
                    : "Navigate to the final authored block before finishing this lesson"
            )

            if !model.isAtEndOfCurrentLesson, !model.isCurrentLessonComplete {
                Label(
                    "Continue to the final authored block to enable Finish Lesson.",
                    systemImage: "arrow.right.circle"
                )
                .foregroundStyle(.secondary)
            }

            if model.isSavingCompletion {
                ProgressView("Saving lesson completion…")
                    .accessibilityLabel("Saving lesson completion")
            }

            if let notice = model.completionNotice {
                Label(
                    notice,
                    systemImage: model.completionSaveFailed
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .foregroundStyle(model.completionSaveFailed ? .orange : .green)
                .accessibilityLabel("Lesson completion status: \(notice)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var activities: some View {
        if !model.currentActivities.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Activities")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                ForEach(model.currentActivities) { route in
                    activityCard(route)
                }
            }
        }
    }

    @ViewBuilder
    private func activityCard(_ route: LessonActivityRoute) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(route.activity.title)
                .font(.headline)
            Text(route.activity.instructions)
                .foregroundStyle(.secondary)

            switch route.destination {
            case .spatialLaboratory:
                Button("Open Spatial Laboratory", systemImage: "cube.transparent") {
                    openWindow(id: AppModel.learningLabWindowID)
                }
                    .accessibilityHint("Opens the linked volumetric learning activity")
            case .cprPractice:
                NavigationLink("Open CPR Practice", destination: CPRPracticeView())
                    .accessibilityHint("Opens the CPR practice launch screen with explicit immersion opt-in")
            case .aedPractice:
                NavigationLink("Open AED Practice", destination: AEDPracticeView())
                    .accessibilityHint("Opens the AED practice launch screen with explicit immersion opt-in")
            case .scenarioPractice:
                NavigationLink("Open Scenario Practice", destination: ScenariosView())
                    .accessibilityHint("Opens the scenario launch screen with explicit immersion opt-in")
            case .assessment:
                Button("Open Knowledge Check", systemImage: "checklist") {
                    Task { await model.requestCurrentLessonAssessment() }
                }
            case .onboarding:
                Label(
                    "This calibration is completed in the first-run orientation flow.",
                    systemImage: "figure.seated.seatbelt"
                )
                .foregroundStyle(.secondary)
            case .lessonGuided:
                Label(
                    "Use the instructions above for this untimed guided activity.",
                    systemImage: "text.book.closed"
                )
                .foregroundStyle(.secondary)
            case .unavailable:
                Label(
                    "This activity type is not available in this app version. The authored instructions remain visible.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("lesson-activity-\(route.id)")
    }

    @ViewBuilder
    private var assessments: some View {
        if !model.currentAssessments.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Knowledge Checks")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)

                ForEach(model.currentAssessments) { assessment in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(assessment.title).font(.headline)
                            Text(
                                assessment.isScored
                                    ? "Scored access is checked against the clinically eligible course catalogue."
                                    : "Unscored and untimed — does not affect XP, access or practical sign-off."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Launch", systemImage: "checklist") {
                            Task { await model.requestQuiz(assessment) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(18)
                    .background(.thinMaterial, in: .rect(cornerRadius: 16))
                }

                if let notice = model.assessmentNotice {
                    Label(notice, systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Knowledge-check status: \(notice)")
                }
            }
        }
    }
}

private struct LessonContentBlockView: View {
    let presentation: LessonBlockPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if presentation.isGuidelineUpdate {
                Label("What changed since 2018", systemImage: "arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .accessibilityIdentifier("lesson-guideline-update-\(presentation.id)")
            }

            if presentation.isAwaitingClinicalApproval {
                Label("Awaiting clinical approval", systemImage: "checkmark.seal.text.page")
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.18), in: .capsule)
                    .accessibilityIdentifier("lesson-review-required-\(presentation.id)")
            }

            Text(presentation.block.title)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)

            if presentation.surface == .mediaPlaceholder {
                Label(
                    "Supporting media is unavailable; the complete authored text remains below.",
                    systemImage: "photo.badge.exclamationmark"
                )
                .foregroundStyle(.secondary)
            }

            Text(presentation.block.body)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(backgroundStyle, in: .rect(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(borderStyle, lineWidth: presentation.isGuidelineUpdate ? 2 : 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lesson-block-\(presentation.id)")
    }

    private var backgroundStyle: Color {
        if presentation.isGuidelineUpdate { return .blue.opacity(0.12) }
        if presentation.isAwaitingClinicalApproval { return .orange.opacity(0.10) }
        switch presentation.surface {
        case .text: return .white.opacity(0.06)
        case .callout: return .cyan.opacity(0.09)
        case .mediaPlaceholder: return .gray.opacity(0.10)
        }
    }

    private var borderStyle: Color {
        if presentation.isGuidelineUpdate { return .blue.opacity(0.8) }
        if presentation.isAwaitingClinicalApproval { return .orange.opacity(0.7) }
        switch presentation.surface {
        case .text: return .white.opacity(0.15)
        case .callout: return .cyan.opacity(0.45)
        case .mediaPlaceholder: return .gray.opacity(0.45)
        }
    }
}

private struct LessonQuizSheet: View {
    let launch: LessonQuizLaunch
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let onClose: () -> Void
    @State private var quizModel: QuizSessionViewModel

    init(
        launch: LessonQuizLaunch,
        learnerID: String,
        courseID: String,
        contentVersion: String,
        onClose: @escaping () -> Void
    ) {
        self.launch = launch
        self.learnerID = learnerID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.onClose = onClose
        _quizModel = State(
            initialValue: QuizSessionViewModel(
                assessment: launch.assessment,
                configuration: AdminAssessmentConfiguration(
                    passThreshold: launch.assessment.passingScore
                ),
                clinicalEligibility: launch.eligibility,
                learnerID: learnerID,
                courseID: courseID,
                contentVersion: contentVersion
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if !launch.assessment.isScored {
                    Label(
                        "Unscored diagnostic review — this result does not affect progress, XP or access.",
                        systemImage: "info.circle.fill"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.blue.opacity(0.12), in: .rect(cornerRadius: 12))
                }

                QuizSessionView(
                    model: quizModel
                )
            }
            .padding()
            .navigationTitle(launch.assessment.title)
            .toolbar {
                Button("Close", systemImage: "xmark") { onClose() }
            }
        }
    }
}

/// Lesson-local overlay uses the lesson audio protocol so playhead reads are dynamically
/// dispatched. Captions stay visible for the full authored cue duration and never time out UI.
private struct LessonCaptionOverlay: View {
    let audioDirector: any LessonAudioDirecting

    @AppStorage(AudioPreferenceKeys.captionsEnabled) private var captionsEnabled = true
    @State private var snapshot = AudioPlaybackSnapshot.idle
    @State private var track: CaptionTrack?
    @State private var loadedAssetID: String?

    var body: some View {
        Group {
            if captionsEnabled, let captionText {
                Text(captionText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
                    .padding(14)
                    .lifesaverCaptionSurface()
                    .glassBackgroundEffect()
                    .accessibilityLabel("Caption: \(captionText)")
            }
        }
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
        guard let track else { return nil }
        return track.text(at: snapshot.currentTime)
    }

    private func loadTrackIfNeeded(for cue: AudioCue?) {
        guard let cue, AudioChannel.inferred(from: cue)?.isSpeech == true else {
            loadedAssetID = nil
            track = nil
            return
        }
        guard loadedAssetID != cue.rawValue else { return }
        loadedAssetID = cue.rawValue
        track = BundleCaptionResolver().track(for: cue.rawValue)
    }
}
