import Foundation
import SwiftData
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Sendable {
    case comfort
    case scope
    case simulatedCall
    case exitPractice
    case dataHandling
    case knowledgeCheck

    var title: String {
        switch self {
        case .comfort: "Comfort and access"
        case .scope: "What the academy can assess"
        case .simulatedCall: "Call practice"
        case .exitPractice: "Pause and Exit practice"
        case .dataHandling: "Your learning data"
        case .knowledgeCheck: "Starting knowledge check"
        }
    }
}

enum OnboardingComfortPosture: String, CaseIterable, Identifiable, Sendable {
    case seated = "Seated"
    case standing = "Standing"

    var id: String { rawValue }
}

enum OnboardingDominantHand: String, CaseIterable, Identifiable, Sendable {
    case left = "Left"
    case right = "Right"
    case noPreference = "No preference"

    var id: String { rawValue }
}

enum OnboardingInputMethod: String, CaseIterable, Identifiable, Sendable {
    case eyesAndHands = "Eyes and hands"
    case accessibilityControl = "Accessibility control"
    case sharedControls = "Shared on-screen controls"

    var id: String { rawValue }
}

enum OnboardingPracticeGate {
    static func isComplete(pausePractised: Bool, exitPractised: Bool) -> Bool {
        pausePractised && exitPractised
    }
}

/// Persists only the completion boundary. Comfort, hand and input choices deliberately
/// remain session-only, matching the authored M0 privacy statement.
struct OnboardingCompletionStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "onboarding.completedLearnerVersions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isComplete(learnerID: String, courseID: String, contentVersion: String) -> Bool {
        completedKeys.contains(Self.recordKey(
            learnerID: learnerID,
            courseID: courseID,
            contentVersion: contentVersion
        ))
    }

    func markComplete(learnerID: String, courseID: String, contentVersion: String) {
        var values = completedKeys
        values.insert(Self.recordKey(
            learnerID: learnerID,
            courseID: courseID,
            contentVersion: contentVersion
        ))
        defaults.set(values.sorted(), forKey: key)
    }

    func clear(learnerID: String) {
        let prefix = "\(learnerID)#"
        let retained = completedKeys.filter { !$0.hasPrefix(prefix) }
        defaults.set(retained.sorted(), forKey: key)
    }

    private var completedKeys: Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private static func recordKey(
        learnerID: String,
        courseID: String,
        contentVersion: String
    ) -> String {
        [learnerID, courseID, contentVersion].joined(separator: "#")
    }
}

/// First-run gate. M0 can be opened only when the authoritative module-presentation
/// service returned it as presentable.
struct OnboardingGateView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AuthenticationModel.self) private var authenticationModel
    @State private var presentationModel: ModulePresentationModel?
    @State private var authorisedM0: PresentedCourseModule?
    @State private var isComplete = false
    @State private var loadFailed = false

    private let completionStore = OnboardingCompletionStore()

    var body: some View {
        Group {
            if isComplete {
                DashboardRootView()
            } else if let authorisedM0 {
                OnboardingView(presentedModule: authorisedM0) {
                    await completeOrientation(module: authorisedM0)
                }
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Orientation unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("The authoritative course access gate did not make Module 0 available. Try again before starting the course.")
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView("Preparing orientation…")
                    .accessibilityLabel("Preparing source-backed Module 0 orientation")
            }
        }
        .task(id: authenticationModel.currentUser?.id) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        guard let user = authenticationModel.currentUser else { return }
        #if UITEST
        if ProcessInfo.processInfo.arguments.contains("--ui-test-skip-onboarding") {
            isComplete = true
            return
        }
        #endif
        loadFailed = false
        do {
            let model = try ModulePresentationModel.production(
                modelContainer: modelContext.container
            )
            presentationModel = model
            await model.load(learnerID: user.id)
            guard case .loaded = model.state,
                  let module = model.modules.first(where: {
                      $0.id == "M0" && $0.isPresentable
                  })
            else {
                loadFailed = true
                return
            }
            if completionStore.isComplete(
                learnerID: user.id,
                courseID: "lifesaver-vision-cpr-aed-spatial-academy",
                contentVersion: model.contentVersion
            ) {
                isComplete = true
            } else {
                authorisedM0 = module
            }
        } catch {
            loadFailed = true
        }
    }

    @MainActor
    private func completeOrientation(module: PresentedCourseModule) async -> Bool {
        guard let user = authenticationModel.currentUser,
              let presentationModel,
              !presentationModel.courseID.isEmpty,
              !presentationModel.contentVersion.isEmpty
        else { return false }

        let moduleLessonIDs = Set(module.module.lessons.map(\.id))
        guard module.module.lessons.count == 1,
              let lessonID = module.module.lessons.first?.id
        else { return false }
        let courseLessonIDs = Set(
            presentationModel.modules.flatMap { presented in
                presented.module.lessons.map(\.id)
            }
        )
        let writer = SwiftDataLessonProgressWriter(
            modelContainer: modelContext.container
        )

        do {
            _ = try await writer.finishLesson(
                LessonCompletionRequest(
                    scope: LessonProgressScope(
                        learnerID: user.id,
                        courseID: presentationModel.courseID,
                        contentVersion: presentationModel.contentVersion
                    ),
                    lessonID: lessonID,
                    moduleLessonIDs: moduleLessonIDs,
                    courseLessonIDs: courseLessonIDs,
                    completedAt: .now
                )
            )
            completionStore.markComplete(
                learnerID: user.id,
                courseID: presentationModel.courseID,
                contentVersion: presentationModel.contentVersion
            )
            isComplete = true
            return true
        } catch {
            return false
        }
    }
}

struct OnboardingView: View {
    let presentedModule: PresentedCourseModule
    let onComplete: @MainActor () async -> Bool

    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @AppStorage(AudioPreferenceKeys.captionsEnabled) private var captionsEnabled = true
    @AppStorage(AudioPreferenceKeys.reduceMotion) private var appReduceMotion = false
    @State private var step: OnboardingStep = .comfort
    @State private var posture: OnboardingComfortPosture?
    @State private var dominantHand: OnboardingDominantHand?
    @State private var inputMethod: OnboardingInputMethod?
    @State private var showSettings = false
    @State private var diagnosticComplete = false
    @State private var isSavingCompletion = false
    @State private var completionSaveFailed = false

    private var lesson: Lesson? { presentedModule.module.lessons.first }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    stepContent
                        .frame(maxWidth: 860, alignment: .leading)
                        .padding(32)
                }
                Divider()
                navigationControls
            }
            .navigationTitle("Module 0 — Orientation & Safety")
            .sheet(isPresented: $showSettings) {
                NavigationStack { SettingsView() }
                    .environment(appModel)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(step.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(OnboardingStep.allCases.count)
            )
            .accessibilityLabel("Orientation progress")
            .accessibilityValue("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
        }
        .padding(28)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .comfort:
            VStack(alignment: .leading, spacing: 20) {
                sourceBlock("M0-B4")
                Picker("Comfort posture for this session", selection: $posture) {
                    Text("Choose a posture").tag(nil as OnboardingComfortPosture?)
                    ForEach(OnboardingComfortPosture.allCases) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }
                Picker("Dominant hand for this session", selection: $dominantHand) {
                    Text("Choose a hand preference").tag(nil as OnboardingDominantHand?)
                    ForEach(OnboardingDominantHand.allCases) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }
                Picker("Preferred input for this session", selection: $inputMethod) {
                    Text("Choose an input method").tag(nil as OnboardingInputMethod?)
                    ForEach(OnboardingInputMethod.allCases) { item in
                        Text(item.rawValue).tag(Optional(item))
                    }
                }
                Toggle("Captions on", isOn: $captionsEnabled)
                Toggle("Reduce app motion", isOn: $appReduceMotion)
                Label(
                    systemReduceMotion
                        ? "System Reduce Motion is on and will also be honoured."
                        : "System Reduce Motion is off; you can change it in device settings.",
                    systemImage: "figure.walk.motion"
                )
                .foregroundStyle(.secondary)
                Text("Lifesaver Vision uses Dynamic Type. Choose your preferred text size in system accessibility settings; lesson and control text will reflow.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("These comfort, hand and input selections are not stored as a separate profile.")
                    .font(.footnote.bold())
            }

        case .scope:
            VStack(alignment: .leading, spacing: 18) {
                sourceBlock("M0-B1")
                Label("Depth: Not physically assessed", systemImage: "ruler")
                Label("Force: Not physically assessed", systemImage: "gauge.with.dots.needle.33percent")
                Label("No SRFAC certification is issued", systemImage: "doc.badge.ellipsis")
                Text("The academy can provide learning feedback for sequence, hand-placement zone, rhythm, interruptions and posture heuristics. Practical competency still requires qualified instructor sign-off.")
                    .foregroundStyle(.secondary)
            }

        case .simulatedCall:
            VStack(alignment: .leading, spacing: 18) {
                sourceBlock("M0-B2")
                Label("SIMULATION ONLY", systemImage: "phone.badge.waveform")
                    .font(.title2.bold())
                    .foregroundStyle(.red)
                Text("No control in Lifesaver Vision places a telephone call to 995.")
                    .font(.headline)
            }

        case .exitPractice:
            VStack(alignment: .leading, spacing: 18) {
                sourceBlock("M0-B3")
                Text("Enter the calm lobby, try Pause and Resume, then gaze at and pinch the persistent Exit control. Orientation cannot finish until Exit has actually been used once.")
                @Bindable var appModel = appModel
                Toggle(
                    "I am comfortable entering this safe practice space",
                    isOn: $appModel.hasUserOptedInToImmersion
                )
                Button("Enter Pause and Exit Practice", systemImage: "visionpro") {
                    appModel.beginOnboardingExitPractice()
                    Task { await appModel.openSimulation(using: openImmersiveSpace) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !appModel.hasUserOptedInToImmersion ||
                    appModel.immersionState != .closed ||
                    appModel.onboardingExitPracticeCompleted
                )
                statusLabel(
                    title: appModel.onboardingPausePracticeCompleted
                        ? "Pause control practised"
                        : "Pause control not yet practised",
                    complete: appModel.onboardingPausePracticeCompleted
                )
                statusLabel(
                    title: appModel.onboardingExitPracticeCompleted
                        ? "Exit control practised"
                        : "Exit control still required",
                    complete: appModel.onboardingExitPracticeCompleted
                )
            }

        case .dataHandling:
            VStack(alignment: .leading, spacing: 18) {
                sourceBlock("M0-B7")
                sourceBlock("M0-B8")
                Button("Open Data and Accessibility Settings", systemImage: "slider.horizontal.3") {
                    showSettings = true
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Opens app settings without completing orientation")
            }

        case .knowledgeCheck:
            if let assessment = lesson?.assessments.first(where: { !$0.isScored }) {
                UnscoredDiagnosticView(assessment: assessment) {
                    diagnosticComplete = true
                }
            } else {
                ContentUnavailableView(
                    "Knowledge check unavailable",
                    systemImage: "questionmark.circle",
                    description: Text("Orientation will not be marked complete without the authored unscored check.")
                )
            }
        }
    }

    private var navigationControls: some View {
        HStack {
            Button("Back", systemImage: "chevron.left") {
                guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
                step = previous
            }
            .disabled(step == .comfort)

            Spacer()

            if step == .knowledgeCheck {
                Button("Complete Orientation", systemImage: "checkmark.seal.fill") {
                    Task {
                        isSavingCompletion = true
                        completionSaveFailed = !(await onComplete())
                        isSavingCompletion = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!diagnosticComplete || isSavingCompletion)

                if isSavingCompletion {
                    ProgressView("Saving orientation completion…")
                } else if completionSaveFailed {
                    Label(
                        "Orientation completion could not be saved. Your existing learning record was not replaced; try again.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            } else {
                Button("Continue", systemImage: "chevron.right") {
                    if step == .comfort,
                       let posture,
                       let dominantHand,
                       let inputMethod {
                        appModel.configureOnboardingSession(
                            posture: posture,
                            dominantHand: dominantHand,
                            inputMethod: inputMethod
                        )
                    }
                    guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
                    step = next
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
            }
        }
        .padding(24)
    }

    private var canContinue: Bool {
        switch step {
        case .comfort:
            posture != nil && dominantHand != nil && inputMethod != nil
        case .exitPractice:
            OnboardingPracticeGate.isComplete(
                pausePractised: appModel.onboardingPausePracticeCompleted,
                exitPractised: appModel.onboardingExitPracticeCompleted
            )
        default:
            true
        }
    }

    @ViewBuilder
    private func sourceBlock(_ id: String) -> some View {
        if let block = lesson?.contentBlocks.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(block.title).font(.title2.bold())
                Text(block.body)
                DisclosureGroup("Source reference") {
                    ForEach(block.sourceReferences) { source in
                        Text("\(source.document), \(source.edition), \(source.section), page \(source.page)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func statusLabel(title: String, complete: Bool) -> some View {
        Label(title, systemImage: complete ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(complete ? .green : .secondary)
            .accessibilityValue(complete ? "Complete" : "Incomplete")
    }
}

struct OnboardingPracticeImmersivePanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("SAFE CONTROL PRACTICE", systemImage: "hand.tap.fill")
                .font(.caption.bold())
            Text("Pause, Resume, then Exit")
                .font(.title2.bold())
            Text("Use the persistent controls above. No clinical task is active and no performance is scored.")
                .foregroundStyle(.secondary)
            if let posture = appModel.onboardingComfortPosture,
               let dominantHand = appModel.onboardingDominantHand,
               let inputMethod = appModel.onboardingInputMethod {
                Label(
                    "\(posture.rawValue) · \(dominantHand.rawValue) hand · \(inputMethod.rawValue)",
                    systemImage: "accessibility"
                )
                .font(.footnote)
                .accessibilityLabel(
                    "Session calibration: \(posture.rawValue), \(dominantHand.rawValue) hand, \(inputMethod.rawValue)"
                )
            }
            status(
                appModel.onboardingPausePracticeCompleted,
                complete: "Pause control practised",
                incomplete: "Try Pause, then Resume"
            )
            status(
                appModel.onboardingExitPracticeCompleted,
                complete: "Exit control practised",
                incomplete: "Finish with Exit"
            )
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(24)
        .glassBackgroundEffect()
    }

    private func status(_ isComplete: Bool, complete: String, incomplete: String) -> some View {
        Label(
            isComplete ? complete : incomplete,
            systemImage: isComplete ? "checkmark.circle.fill" : "circle.dashed"
        )
        .accessibilityValue(isComplete ? "Complete" : "Incomplete")
    }
}

private struct UnscoredDiagnosticView: View {
    let assessment: Assessment
    let onComplete: () -> Void
    @Environment(AppModel.self) private var appModel

    @State private var questionIndex = 0
    @State private var selectedChoiceIDs: Set<String> = []
    @State private var hasReviewedCurrentAnswer = false
    @State private var reviewedQuestionIDs: Set<String> = []

    private var question: Question? {
        assessment.questions.indices.contains(questionIndex)
            ? assessment.questions[questionIndex]
            : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("UNSCORED · UNTIMERED", systemImage: "info.circle.fill")
                .font(.headline)
                .foregroundStyle(.blue)
            Text("This check establishes a starting point. It does not award XP, create a pass/fail result, or block learning.")
                .foregroundStyle(.secondary)

            if let question {
                Text("Question \(questionIndex + 1) of \(assessment.questions.count)")
                    .font(.headline)
                Text(question.prompt)
                    .font(.title2.bold())

                ForEach(question.choices) { choice in
                    Button {
                        if question.type == .multipleChoice {
                            if selectedChoiceIDs.contains(choice.id) {
                                selectedChoiceIDs.remove(choice.id)
                            } else {
                                selectedChoiceIDs.insert(choice.id)
                            }
                        } else {
                            selectedChoiceIDs = [choice.id]
                        }
                    } label: {
                        Label(
                            choice.text,
                            systemImage: selectedChoiceIDs.contains(choice.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .buttonStyle(.plain)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .disabled(hasReviewedCurrentAnswer)
                    .accessibilityValue(
                        selectedChoiceIDs.contains(choice.id) ? "Selected" : "Not selected"
                    )
                }

                if hasReviewedCurrentAnswer {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            selectedChoiceIDs == Set(question.correctChoiceIDs)
                                ? "Matches the source-backed answer"
                                : "Review the source-backed answer",
                            systemImage: selectedChoiceIDs == Set(question.correctChoiceIDs)
                                ? "checkmark.circle.fill"
                                : "book.fill"
                        )
                        .font(.headline)
                        Text(question.explanation)
                        DisclosureGroup("Sources") {
                            ForEach(question.sourceReferences) { source in
                                Text("\(source.document), \(source.edition), \(source.section), page \(source.page)")
                                    .font(.footnote)
                            }
                        }
                    }
                    .padding(16)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))

                    Button(
                        questionIndex == assessment.questions.count - 1
                            ? "Finish Review"
                            : "Next Question",
                        systemImage: "chevron.right"
                    ) {
                        reviewedQuestionIDs.insert(question.id)
                        if questionIndex == assessment.questions.count - 1 {
                            onComplete()
                        } else {
                            questionIndex += 1
                            selectedChoiceIDs = []
                            hasReviewedCurrentAnswer = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Review Answer", systemImage: "book.fill") {
                        hasReviewedCurrentAnswer = true
                        let cue = selectedChoiceIDs == Set(question.correctChoiceIDs)
                            ? "sfx.answer_correct"
                            : "sfx.answer_incorrect"
                        Task {
                            _ = await appModel.audioDirector.play(
                                AudioPlaybackRequest(
                                    cue: AudioCue(rawValue: cue),
                                    channel: .soundEffects,
                                    context: .sharedSpace
                                )
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedChoiceIDs.isEmpty)
                }
            }
        }
    }
}
