import Foundation
import Observation
import SwiftData

/// Narrow semantic alias for lesson-player injection. All playback controls are requirements
/// of `AudioDirector`, which preserves dynamic dispatch through protocol existentials.
protocol LessonAudioDirecting: AudioDirector {}

extension SystemAudioDirector: LessonAudioDirecting {}

/// A route can only be produced from the engine-backed presentation snapshot. Carrying the
/// immutable module value avoids a second, potentially ungated course lookup after navigation.
struct LessonPlayerRoute: Identifiable, Sendable, Equatable, Hashable {
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let module: Module

    fileprivate init(
        learnerID: String,
        courseID: String,
        contentVersion: String,
        module: Module
    ) {
        self.learnerID = learnerID
        self.courseID = courseID
        self.contentVersion = contentVersion
        self.module = module
    }

    var id: String {
        [learnerID, courseID, contentVersion, module.id]
            .map(Self.keyComponent)
            .joined(separator: ".")
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    private static func keyComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Resolves lesson entry without reproducing module-access rules in presentation code.
struct LessonPlayerRouteResolver: Sendable {
    func resolve(
        moduleID: String,
        authoritativeModules: [PresentedCourseModule],
        learnerID: String,
        courseID: String,
        contentVersion: String
    ) -> LessonPlayerRoute? {
        guard !learnerID.isEmpty,
              !courseID.isEmpty,
              !contentVersion.isEmpty,
              let item = authoritativeModules.first(where: { $0.id == moduleID }),
              item.isPresentable
        else { return nil }

        return LessonPlayerRoute(
            learnerID: learnerID,
            courseID: courseID,
            contentVersion: contentVersion,
            module: item.module
        )
    }
}

extension ModulePresentationModel {
    /// The catalogue and every future module entry point should use this resolver rather than
    /// constructing a lesson route from `course_v1.json` directly.
    func lessonPlayerRoute(moduleID: String, learnerID: String) -> LessonPlayerRoute? {
        LessonPlayerRouteResolver().resolve(
            moduleID: moduleID,
            authoritativeModules: modules,
            learnerID: learnerID,
            courseID: courseID,
            contentVersion: contentVersion
        )
    }
}

enum LessonBlockSurface: Sendable, Equatable {
    case text
    case callout
    case mediaPlaceholder
}

/// Pure rendering policy for authored course blocks. Clinical approval and update styling are
/// independent so an update card awaiting review retains both visible states.
struct LessonBlockPresentation: Identifiable, Sendable, Equatable {
    let block: ContentBlock

    var id: String { block.id }

    var surface: LessonBlockSurface {
        switch block.kind {
        case .text: .text
        case .callout: .callout
        case .mediaPlaceholder: .mediaPlaceholder
        }
    }

    var isGuidelineUpdate: Bool {
        let title = block.title.lowercased()
        return title.contains("guideline update") ||
            title.contains("what changed since the 2018 manual") ||
            title.contains("operational update")
    }

    var isAwaitingClinicalApproval: Bool {
        block.reviewStatus == .clinicalReviewRequired
    }

    /// Delivery narration is intentionally limited to source-checked blocks. A source-checked
    /// block can still have a missing file; the audio director reports that recoverable state.
    var narrationCue: AudioCue? {
        guard block.reviewStatus == .sourceChecked else { return nil }
        return AudioCue(rawValue: "nar.\(block.id)")
    }

    var transcript: String { block.body }
}

struct LessonResumeScope: Sendable, Equatable {
    let learnerID: String
    let courseID: String
    let contentVersion: String
    let moduleID: String
}

struct LessonResumePosition: Codable, Sendable, Equatable {
    let lessonID: String
    let blockID: String
    let updatedAt: Date
}

/// Lightweight learner/version-scoped reading position. It deliberately stores authored IDs,
/// not a fragile array index, so a different immutable content version cannot resume into it.
struct LessonResumeStore: @unchecked Sendable {
    private static let keyPrefix = "lesson-player.resume.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load(scope: LessonResumeScope) -> LessonResumePosition? {
        guard let data = defaults.data(forKey: key(for: scope)) else { return nil }
        return try? JSONDecoder().decode(LessonResumePosition.self, from: data)
    }

    func save(_ position: LessonResumePosition, scope: LessonResumeScope) {
        guard let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: key(for: scope))
    }

    func clear(scope: LessonResumeScope) {
        defaults.removeObject(forKey: key(for: scope))
    }

    private func key(for scope: LessonResumeScope) -> String {
        [
            Self.keyPrefix,
            scope.learnerID,
            scope.courseID,
            scope.contentVersion,
            scope.moduleID
        ]
        .map(Self.keyComponent)
        .joined(separator: ".")
    }

    private static func keyComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum LessonActivityDestination: Sendable, Equatable {
    case onboarding
    case assessment
    case spatialLaboratory
    case cprPractice
    case aedPractice
    case scenarioPractice
    case lessonGuided
    case unavailable
}

struct LessonActivityRoute: Identifiable, Sendable, Equatable {
    let activity: InteractiveActivity
    let destination: LessonActivityDestination

    var id: String { activity.id }
}

/// Closed activity routing prevents unknown authored strings from opening an unrelated clinical
/// experience. Unsupported activities remain visible with their complete instructions.
struct LessonActivityRouteResolver: Sendable {
    func resolve(_ activity: InteractiveActivity) -> LessonActivityRoute {
        let destination: LessonActivityDestination = switch activity.activityType {
        case "onboardingCalibration": .onboarding
        case "diagnosticAssessment", "awarenessAssessment": .assessment
        case "spatialSequenceGallery": .spatialLaboratory
        case "cprRhythmPractice": .cprPractice
        case "aedPreparationLab", "aedPadPlacement", "aedClearCheck": .aedPractice
        case "branchingDialogue", "simulatedEmergencyCall", "specialCircumstanceDrill",
             "integratedScenario": .scenarioPractice
        case "conceptSort", "handoverDialogue", "structuredReflection": .lessonGuided
        default: .unavailable
        }
        return LessonActivityRoute(activity: activity, destination: destination)
    }
}

enum LessonAssessmentAccess: Sendable, Equatable {
    case available(ClinicalAssessmentEligibility)
    case unavailable(message: String)
}

protocol LessonAssessmentProviding: Sendable {
    func access(
        to assessment: Assessment,
        courseID: String,
        contentVersion: String
    ) async -> LessonAssessmentAccess
}

/// Scored checks are exposed only when the existing CourseEngine catalogue includes them.
/// Unscored diagnostic/awareness checks remain review-only and never enter scoredContent.
actor CourseEngineLessonAssessmentProvider: LessonAssessmentProviding {
    private let engine: CourseEngine?

    @MainActor
    init(modelContainer: ModelContainer, bundle: Bundle = .main) {
        let repository = SwiftDataRepositoryStore(modelContainer: modelContainer)
        do {
            let facts = try ClinicalFactCatalogue.loadBundled(from: bundle)
            engine = CourseEngine(
                courseRepository: repository,
                versionRepository: repository,
                facts: facts
            )
        } catch {
            engine = nil
        }
    }

    func access(
        to assessment: Assessment,
        courseID: String,
        contentVersion: String
    ) async -> LessonAssessmentAccess {
        guard assessment.isScored else { return .available(.eligible) }
        guard let engine else {
            return .unavailable(
                message: "The clinical fact catalogue required for this knowledge check is unavailable."
            )
        }

        do {
            let catalogue = try await engine.scoredContent(
                courseID: courseID,
                contentVersion: contentVersion
            )
            guard catalogue.assessments.contains(where: { $0.id == assessment.id }) else {
                return .unavailable(
                    message: "This knowledge check is not available in the clinically eligible assessment catalogue."
                )
            }
            return .available(.eligible)
        } catch {
            return .unavailable(
                message: "This scored knowledge check remains unavailable until the course lifecycle permits it."
            )
        }
    }
}

struct LessonQuizLaunch: Identifiable, Sendable, Equatable {
    let assessment: Assessment
    let eligibility: ClinicalAssessmentEligibility

    var id: String { assessment.id }
}

@MainActor
@Observable
final class LessonPlayerSessionModel {
    private struct BlockLocation: Sendable, Equatable {
        let lessonIndex: Int
        let blockIndex: Int
    }

    let route: LessonPlayerRoute
    let lessons: [Lesson]

    private let audioDirector: any LessonAudioDirecting
    private let assessmentProvider: any LessonAssessmentProviding
    private let resumeStore: LessonResumeStore
    private let preferences: AudioPreferencesStore
    private let resumeScope: LessonResumeScope
    private let locations: [BlockLocation]

    private(set) var locationIndex = 0
    private(set) var playbackSnapshot = AudioPlaybackSnapshot.idle
    private(set) var narrationNotice: String?
    private(set) var assessmentNotice: String?
    private(set) var quizLaunch: LessonQuizLaunch?
    private(set) var narrationSpeed: Double

    init(
        route: LessonPlayerRoute,
        audioDirector: any LessonAudioDirecting,
        assessmentProvider: any LessonAssessmentProviding,
        resumeStore: LessonResumeStore = LessonResumeStore(),
        preferences: AudioPreferencesStore = AudioPreferencesStore()
    ) {
        self.route = route
        self.audioDirector = audioDirector
        self.assessmentProvider = assessmentProvider
        self.resumeStore = resumeStore
        self.preferences = preferences
        let orderedLessons = route.module.lessons.sorted {
            if $0.order == $1.order { return $0.id < $1.id }
            return $0.order < $1.order
        }
        let orderedLocations = orderedLessons.indices.flatMap { lessonIndex in
            orderedLessons[lessonIndex].contentBlocks.indices.map { blockIndex in
                BlockLocation(lessonIndex: lessonIndex, blockIndex: blockIndex)
            }
        }
        lessons = orderedLessons
        locations = orderedLocations
        resumeScope = LessonResumeScope(
            learnerID: route.learnerID,
            courseID: route.courseID,
            contentVersion: route.contentVersion,
            moduleID: route.module.id
        )
        narrationSpeed = preferences.snapshot().narrationSpeed

        if let saved = resumeStore.load(scope: resumeScope),
           let savedIndex = orderedLocations.firstIndex(where: { location in
               orderedLessons[location.lessonIndex].id == saved.lessonID &&
                   orderedLessons[location.lessonIndex].contentBlocks[location.blockIndex].id == saved.blockID
           }) {
            locationIndex = savedIndex
        }
    }

    var currentLesson: Lesson? {
        guard let location = currentLocation else { return lessons.first }
        return lessons[location.lessonIndex]
    }

    var currentBlock: LessonBlockPresentation? {
        guard let location = currentLocation else { return nil }
        return LessonBlockPresentation(
            block: lessons[location.lessonIndex].contentBlocks[location.blockIndex]
        )
    }

    var currentActivities: [LessonActivityRoute] {
        (currentLesson?.interactiveActivities ?? []).map(LessonActivityRouteResolver().resolve)
    }

    var currentAssessments: [Assessment] {
        currentLesson?.assessments ?? []
    }

    var audioDirectorForCaptions: any LessonAudioDirecting { audioDirector }

    var positionLabel: String {
        guard !locations.isEmpty else { return "No authored content blocks" }
        return "Block \(locationIndex + 1) of \(locations.count)"
    }

    var canMovePrevious: Bool { locationIndex > 0 }
    var canMoveNext: Bool { locationIndex + 1 < locations.count }

    var isCurrentNarrationPlaying: Bool {
        guard let cue = currentBlock?.narrationCue else { return false }
        return playbackSnapshot.activeCue == cue && playbackSnapshot.isPlaying
    }

    func prepare() async {
        try? await audioDirector.prepare()
        await refreshPlayback()
    }

    func movePrevious() async {
        guard canMovePrevious else { return }
        await move(to: locationIndex - 1)
    }

    func moveNext() async {
        guard canMoveNext else { return }
        await move(to: locationIndex + 1)
    }

    func move(toBlockID blockID: String) async {
        guard let index = locations.firstIndex(where: { location in
            lessons[location.lessonIndex].contentBlocks[location.blockIndex].id == blockID
        }) else { return }
        await move(to: index)
    }

    func toggleNarration() async {
        guard let presentation = currentBlock else { return }
        guard let cue = presentation.narrationCue else {
            narrationNotice = "Narration is intentionally unavailable while this content awaits clinical approval. Read the complete text transcript instead."
            return
        }

        let snapshot = await audioDirector.playbackSnapshot()
        if snapshot.activeCue == cue, snapshot.isPlaying {
            await audioDirector.pause(.narration)
            narrationNotice = "Narration paused."
        } else if snapshot.activeCue == cue, snapshot.isPaused {
            await audioDirector.resume(.narration)
            narrationNotice = nil
        } else {
            await startNarration(cue)
        }
        await refreshPlayback()
    }

    func replayNarration() async {
        guard let presentation = currentBlock else { return }
        guard let cue = presentation.narrationCue else {
            narrationNotice = "Narration is intentionally unavailable while this content awaits clinical approval. Read the complete text transcript instead."
            return
        }

        let snapshot = await audioDirector.playbackSnapshot()
        if snapshot.activeCue == cue {
            await audioDirector.replay(.narration)
            narrationNotice = nil
        } else {
            await startNarration(cue)
        }
        await refreshPlayback()
    }

    func setNarrationSpeed(_ requestedSpeed: Double) async {
        let speed = AudioPreferencesSnapshot.allowedNarrationSpeeds.min {
            abs($0 - requestedSpeed) < abs($1 - requestedSpeed)
        } ?? 1.0
        guard narrationSpeed != speed else { return }
        narrationSpeed = speed

        var snapshot = preferences.snapshot()
        snapshot.narrationSpeed = speed
        preferences.save(snapshot)
        await audioDirector.refreshPreferences()

        if let cue = currentBlock?.narrationCue,
           playbackSnapshot.activeCue == cue,
           playbackSnapshot.isPlaying || playbackSnapshot.isPaused {
            await startNarration(cue)
            narrationNotice = "Narration restarted at \(speed.formatted(.number.precision(.fractionLength(1)))) times speed."
        }
        await refreshPlayback()
    }

    func refreshPlayback() async {
        playbackSnapshot = await audioDirector.playbackSnapshot()
    }

    func requestQuiz(_ assessment: Assessment) async {
        assessmentNotice = nil
        switch await assessmentProvider.access(
            to: assessment,
            courseID: route.courseID,
            contentVersion: route.contentVersion
        ) {
        case let .available(eligibility):
            quizLaunch = LessonQuizLaunch(
                assessment: assessment,
                eligibility: eligibility
            )
        case let .unavailable(message):
            assessmentNotice = message
        }
    }

    func requestCurrentLessonAssessment() async {
        guard let assessment = currentAssessments.first else {
            assessmentNotice = "No knowledge check is attached to this lesson."
            return
        }
        await requestQuiz(assessment)
    }

    func dismissQuiz() {
        quizLaunch = nil
    }

    func stop() async {
        persistPosition()
        await audioDirector.stop(.narration)
        playbackSnapshot = .idle
    }

    func persistPosition() {
        guard let location = currentLocation else { return }
        resumeStore.save(
            LessonResumePosition(
                lessonID: lessons[location.lessonIndex].id,
                blockID: lessons[location.lessonIndex].contentBlocks[location.blockIndex].id,
                updatedAt: .now
            ),
            scope: resumeScope
        )
    }

    private var currentLocation: BlockLocation? {
        guard locations.indices.contains(locationIndex) else { return nil }
        return locations[locationIndex]
    }

    private func move(to index: Int) async {
        guard locations.indices.contains(index) else { return }
        await audioDirector.stop(.narration)
        locationIndex = index
        playbackSnapshot = .idle
        narrationNotice = nil
        assessmentNotice = nil
        persistPosition()
    }

    private func startNarration(_ cue: AudioCue) async {
        let result = await audioDirector.play(
            AudioPlaybackRequest(
                cue: cue,
                channel: .narration,
                context: .sharedSpace,
                autoplay: false,
                narrationSpeed: narrationSpeed
            )
        )
        switch result {
        case .started:
            narrationNotice = nil
        case .blocked(.missingAsset):
            narrationNotice = "Narration is unavailable for this block. The complete text transcript remains available."
        case .blocked:
            narrationNotice = "Narration could not be played. The complete text transcript remains available."
        }
    }
}
