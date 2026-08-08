import Foundation
import SwiftData
import XCTest
@testable import LifesaverVision

@MainActor
final class LessonPlayerTests: XCTestCase {
    func testBlockPresentationCoversEveryBlockKindAndReviewRequiredHasNoNarration() {
        let text = block(id: "text", kind: .text, reviewStatus: .sourceChecked)
        let callout = block(
            id: "callout",
            kind: .callout,
            reviewStatus: .clinicalReviewRequired
        )
        let media = block(
            id: "media",
            kind: .mediaPlaceholder,
            reviewStatus: .sourceChecked
        )

        let textPresentation = LessonBlockPresentation(block: text)
        let calloutPresentation = LessonBlockPresentation(block: callout)
        let mediaPresentation = LessonBlockPresentation(block: media)

        XCTAssertEqual(textPresentation.surface, .text)
        XCTAssertEqual(calloutPresentation.surface, .callout)
        XCTAssertEqual(mediaPresentation.surface, .mediaPlaceholder)
        XCTAssertEqual(textPresentation.narrationCue, AudioCue(rawValue: "nar.text"))
        XCTAssertNil(calloutPresentation.narrationCue)
        XCTAssertTrue(calloutPresentation.isAwaitingClinicalApproval)
        XCTAssertEqual(mediaPresentation.transcript, media.body)
    }

    func testEveryBundledBlockBuildsAPresentationAndUpdateCardsUseDistinctStyling() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let blocks = course.modules.flatMap(\.lessons).flatMap(\.contentBlocks)
        let presentations = blocks.map(LessonBlockPresentation.init)
        let byID = Dictionary(uniqueKeysWithValues: presentations.map { ($0.id, $0) })
        let updateIDs = [
            "M1-B7", "M2-B4", "M3-B7", "M3-B11",
            "M6-B9", "M9-B10", "M10-B4", "M10-B5A"
        ]

        XCTAssertEqual(presentations.count, blocks.count)
        XCTAssertEqual(presentations.map(\.id), blocks.map(\.id))
        XCTAssertTrue(presentations.allSatisfy { !$0.transcript.isEmpty })
        for updateID in updateIDs {
            XCTAssertTrue(
                try XCTUnwrap(byID[updateID]).isGuidelineUpdate,
                "Expected distinct guideline-update styling for \(updateID)"
            )
        }

        let reviewRequired = presentations.filter(\.isAwaitingClinicalApproval)
        XCTAssertFalse(reviewRequired.isEmpty)
        XCTAssertTrue(reviewRequired.allSatisfy { $0.narrationCue == nil })
        XCTAssertTrue(
            try XCTUnwrap(byID["M9-B10"]).isAwaitingClinicalApproval,
            "A review-gated update must retain both the update and approval-chip states"
        )
    }

    func testRouteResolverRejectsEveryNonPresentableModuleIncludingM9() throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let m0 = try XCTUnwrap(course.modules.first { $0.id == "M0" })
        let m9 = try XCTUnwrap(course.modules.first { $0.id == "M9" })
        let authoritativeSnapshot = [
            PresentedCourseModule(module: m0, isPresentable: true, lockReasons: []),
            PresentedCourseModule(
                module: m9,
                isPresentable: false,
                lockReasons: [.instructorApprovalNotRecorded]
            )
        ]
        let resolver = LessonPlayerRouteResolver()

        XCTAssertNotNil(
            resolver.resolve(
                moduleID: "M0",
                authoritativeModules: authoritativeSnapshot,
                learnerID: "learner-1",
                courseID: course.id,
                contentVersion: course.version.contentVersion
            )
        )
        XCTAssertNil(
            resolver.resolve(
                moduleID: "M9",
                authoritativeModules: authoritativeSnapshot,
                learnerID: "learner-1",
                courseID: course.id,
                contentVersion: course.version.contentVersion
            )
        )
        XCTAssertNil(
            resolver.resolve(
                moduleID: "not-returned-by-engine",
                authoritativeModules: authoritativeSnapshot,
                learnerID: "learner-1",
                courseID: course.id,
                contentVersion: course.version.contentVersion
            )
        )
        XCTAssertNil(
            resolver.resolve(
                moduleID: "M0",
                authoritativeModules: authoritativeSnapshot,
                learnerID: "",
                courseID: course.id,
                contentVersion: course.version.contentVersion
            )
        )
    }

    func testCatalogueModelCannotCreateRouteForModuleOmittedByEngine() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let repository = InMemoryCourseRepository(courses: [course])
        try await repository.setLifecycle(
            .clinicallyApproved,
            courseID: course.id,
            contentVersion: course.version.contentVersion
        )
        let m0 = try XCTUnwrap(course.modules.first { $0.id == "M0" })
        let engine = LessonPlayerPresentationEngine(modulesToReturn: [m0])
        let model = ModulePresentationModel(
            engine: engine,
            courses: repository,
            progress: InMemoryProgressRepository(),
            versions: repository
        )

        await model.load(learnerID: "learner-route-test")

        XCTAssertEqual(model.state, .loaded)
        XCTAssertNotNil(
            model.lessonPlayerRoute(moduleID: "M0", learnerID: "learner-route-test")
        )
        XCTAssertNil(
            model.lessonPlayerRoute(moduleID: "M9", learnerID: "learner-route-test"),
            "A raw course module omitted by presentableModules must never acquire a route"
        )
    }

    func testResumePositionIsScopedByLearnerCourseAndContentVersion() async throws {
        let suite = "LessonPlayerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LessonResumeStore(defaults: defaults)
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let module = try XCTUnwrap(course.modules.first { $0.id == "M0" })
        let blocks = try XCTUnwrap(module.lessons.first).contentBlocks
        let resumedBlock = try XCTUnwrap(blocks.dropFirst().first)
        let route = try authorisedRoute(
            learnerID: "learner-a",
            course: course,
            module: module
        )
        let audio = MissingLessonAudioDirector()
        let assessments = AvailableLessonAssessmentProvider()
        let model = LessonPlayerSessionModel(
            route: route,
            audioDirector: audio,
            assessmentProvider: assessments,
            resumeStore: store,
            preferences: AudioPreferencesStore(defaults: defaults)
        )

        await model.move(toBlockID: resumedBlock.id)
        model.persistPosition()

        let restored = LessonPlayerSessionModel(
            route: route,
            audioDirector: audio,
            assessmentProvider: assessments,
            resumeStore: store,
            preferences: AudioPreferencesStore(defaults: defaults)
        )
        XCTAssertEqual(restored.currentBlock?.id, resumedBlock.id)

        let otherLearnerRoute = try authorisedRoute(
            learnerID: "learner-b",
            course: course,
            module: module
        )
        let otherLearner = LessonPlayerSessionModel(
            route: otherLearnerRoute,
            audioDirector: audio,
            assessmentProvider: assessments,
            resumeStore: store,
            preferences: AudioPreferencesStore(defaults: defaults)
        )
        XCTAssertEqual(otherLearner.currentBlock?.id, blocks.first?.id)
    }

    func testMissingNarrationLeavesTranscriptAndReportsRecoverableStatus() async throws {
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let module = try XCTUnwrap(course.modules.first { $0.id == "M0" })
        let route = try authorisedRoute(
            learnerID: "learner-audio-test",
            course: course,
            module: module
        )
        let audio = MissingLessonAudioDirector()
        let model = LessonPlayerSessionModel(
            route: route,
            audioDirector: audio,
            assessmentProvider: AvailableLessonAssessmentProvider()
        )
        let expectedTranscript = try XCTUnwrap(model.currentBlock?.transcript)

        await model.toggleNarration()
        let receivedRequests = await audio.receivedRequests()

        XCTAssertFalse(expectedTranscript.isEmpty)
        XCTAssertEqual(model.currentBlock?.transcript, expectedTranscript)
        XCTAssertTrue(model.narrationNotice?.contains("transcript") == true)
        XCTAssertEqual(receivedRequests.count, 1)
    }

    func testActivityResolverMapsKnownRoutesAndFailsClosedForUnknownTypes() {
        let expectedDestinations: [String: LessonActivityDestination] = [
            "onboardingCalibration": .onboarding,
            "diagnosticAssessment": .assessment,
            "awarenessAssessment": .assessment,
            "spatialSequenceGallery": .spatialLaboratory,
            "cprRhythmPractice": .cprPractice,
            "aedPreparationLab": .aedPractice,
            "aedPadPlacement": .aedPractice,
            "aedClearCheck": .aedPractice,
            "branchingDialogue": .scenarioPractice,
            "simulatedEmergencyCall": .scenarioPractice,
            "specialCircumstanceDrill": .scenarioPractice,
            "integratedScenario": .scenarioPractice,
            "conceptSort": .lessonGuided,
            "handoverDialogue": .lessonGuided,
            "structuredReflection": .lessonGuided
        ]
        let resolver = LessonActivityRouteResolver()

        for (activityType, expectedDestination) in expectedDestinations {
            XCTAssertEqual(
                resolver.resolve(activity(type: activityType)).destination,
                expectedDestination,
                "Unexpected route for authored activity type \(activityType)"
            )
        }
        XCTAssertEqual(
            resolver.resolve(activity(type: "future-unreviewed-activity")).destination,
            .unavailable
        )
    }

    func testFinishLessonPreservesExistingIDsAndWritesLastLessonForExactVersion() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        let originalTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        context.insert(
            ProgressRecord(
                id: "existing-progress-id",
                learnerID: "learner-progress",
                courseID: "course-progress",
                contentVersion: "2.0.0",
                completedLessonIDs: ["lesson-prior", "legacy-unknown"],
                lastLessonID: "lesson-prior",
                completionFraction: 0.25,
                updatedAt: originalTimestamp
            )
        )
        try context.save()
        let writer = SwiftDataLessonProgressWriter(modelContainer: container)
        let completionTimestamp = originalTimestamp.addingTimeInterval(60)

        let outcome = try await writer.finishLesson(
            LessonCompletionRequest(
                scope: LessonProgressScope(
                    learnerID: "learner-progress",
                    courseID: "course-progress",
                    contentVersion: "2.0.0"
                ),
                lessonID: "lesson-current",
                moduleLessonIDs: ["lesson-current"],
                courseLessonIDs: ["lesson-prior", "lesson-current", "lesson-future"],
                completedAt: completionTimestamp
            )
        )

        XCTAssertEqual(
            outcome.completedLessonIDs,
            ["lesson-prior", "lesson-current", "legacy-unknown"]
        )
        XCTAssertEqual(outcome.lastLessonID, "lesson-current")
        XCTAssertEqual(outcome.completionFraction, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertTrue(outcome.didAddLesson)
        XCTAssertTrue(outcome.isModuleComplete)

        let stored = try XCTUnwrap(
            try ModelContext(container).fetch(FetchDescriptor<ProgressRecord>()).first
        )
        XCTAssertEqual(stored.id, "existing-progress-id")
        XCTAssertEqual(
            Set(stored.completedLessonIDs),
            ["lesson-prior", "lesson-current", "legacy-unknown"]
        )
        XCTAssertEqual(stored.lastLessonID, "lesson-current")
        XCTAssertEqual(stored.completionFraction, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(stored.updatedAt, completionTimestamp)
    }

    func testFinishLessonCreatesSeparateProgressRecordForNewContentVersion() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let context = ModelContext(container)
        context.insert(
            ProgressRecord(
                id: "learner-version#course-version#1.0.0",
                learnerID: "learner-version",
                courseID: "course-version",
                contentVersion: "1.0.0",
                completedLessonIDs: ["old-lesson"],
                lastLessonID: "old-lesson",
                completionFraction: 1
            )
        )
        try context.save()
        let writer = SwiftDataLessonProgressWriter(modelContainer: container)

        _ = try await writer.finishLesson(
            LessonCompletionRequest(
                scope: LessonProgressScope(
                    learnerID: "learner-version",
                    courseID: "course-version",
                    contentVersion: "2.0.0"
                ),
                lessonID: "new-lesson",
                moduleLessonIDs: ["new-lesson"],
                courseLessonIDs: ["new-lesson", "next-lesson"],
                completedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        let records = try ModelContext(container).fetch(FetchDescriptor<ProgressRecord>())
        XCTAssertEqual(records.count, 2)
        let oldVersion = try XCTUnwrap(records.first { $0.contentVersion == "1.0.0" })
        let newVersion = try XCTUnwrap(records.first { $0.contentVersion == "2.0.0" })
        XCTAssertEqual(oldVersion.completedLessonIDs, ["old-lesson"])
        XCTAssertEqual(oldVersion.lastLessonID, "old-lesson")
        XCTAssertEqual(newVersion.completedLessonIDs, ["new-lesson"])
        XCTAssertEqual(newVersion.lastLessonID, "new-lesson")
        XCTAssertEqual(newVersion.completionFraction, 0.5, accuracy: 0.000_001)
    }

    func testSessionFinishPersistsAndEmitsModuleCompleteCueOnlyOnce() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let writer = SwiftDataLessonProgressWriter(modelContainer: container)
        let course = try CourseContentCodec.loadCourse(named: "course_v1")
        let module = try XCTUnwrap(course.modules.first { $0.id == "M0" })
        let finalBlock = try XCTUnwrap(module.lessons.first?.contentBlocks.last)
        let route = try authorisedRoute(
            learnerID: "learner-finish",
            course: course,
            module: module
        )
        let audio = MissingLessonAudioDirector()
        let model = LessonPlayerSessionModel(
            route: route,
            audioDirector: audio,
            assessmentProvider: AvailableLessonAssessmentProvider()
        )
        await model.move(toBlockID: finalBlock.id)
        XCTAssertTrue(model.isAtEndOfCurrentLesson)

        await model.finishCurrentLesson(
            using: writer,
            completedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        await model.finishCurrentLesson(
            using: writer,
            completedAt: Date(timeIntervalSince1970: 1_800_000_200)
        )
        let requests = await audio.receivedRequests()

        XCTAssertTrue(model.isCurrentLessonComplete)
        XCTAssertFalse(model.completionSaveFailed)
        XCTAssertTrue(model.completionNotice?.contains("already recorded") == true)
        XCTAssertEqual(
            requests.filter { $0.cue == AudioCue(rawValue: "sfx.module_complete") }.count,
            1
        )

        let restored = LessonPlayerSessionModel(
            route: route,
            audioDirector: audio,
            assessmentProvider: AvailableLessonAssessmentProvider()
        )
        await restored.prepare(progressWriter: writer)
        XCTAssertTrue(restored.isCurrentLessonComplete)
    }

    private func block(
        id: String,
        kind: ContentBlockKind,
        reviewStatus: ContentLifecycle
    ) -> ContentBlock {
        ContentBlock(
            id: id,
            kind: kind,
            title: "Test title",
            body: "Complete test transcript.",
            sourceReferences: [],
            reviewStatus: reviewStatus
        )
    }

    private func activity(type: String) -> InteractiveActivity {
        InteractiveActivity(
            id: "activity-\(type)",
            title: "Test activity",
            activityType: type,
            instructions: "Complete the authored activity.",
            sourceReferences: []
        )
    }

    private func authorisedRoute(
        learnerID: String,
        course: Course,
        module: Module
    ) throws -> LessonPlayerRoute {
        try XCTUnwrap(
            LessonPlayerRouteResolver().resolve(
                moduleID: module.id,
                authoritativeModules: [
                    PresentedCourseModule(
                        module: module,
                        isPresentable: true,
                        lockReasons: []
                    )
                ],
                learnerID: learnerID,
                courseID: course.id,
                contentVersion: course.version.contentVersion
            )
        )
    }
}

private actor LessonPlayerPresentationEngine: CourseModulePresentationServing {
    let modulesToReturn: [Module]

    init(modulesToReturn: [Module]) {
        self.modulesToReturn = modulesToReturn
    }

    func importBundledCourses(
        named resourceNames: [String],
        from bundle: Bundle
    ) -> CourseImportReport {
        CourseImportReport(
            importedCourseIDs: ["lifesaver-vision-cpr-aed-spatial-academy"],
            importedVersionCount: 1
        )
    }

    func presentableModules(for request: ModulePresentationRequest) -> [Module] {
        modulesToReturn
    }
}

private actor MissingLessonAudioDirector: LessonAudioDirecting {
    private var requests: [AudioPlaybackRequest] = []

    func prepare() async throws {}
    func play(_ cue: AudioCue) async {}
    func stopAll() async {}

    func play(_ request: AudioPlaybackRequest) async -> AudioPlaybackResult {
        requests.append(request)
        return .blocked(.missingAsset)
    }

    func pause(_ channel: AudioChannel) async {}
    func resume(_ channel: AudioChannel) async {}
    func replay(_ channel: AudioChannel) async {}
    func stop(_ channel: AudioChannel) async {}
    func refreshPreferences() async {}
    func playbackSnapshot() async -> AudioPlaybackSnapshot { .idle }

    func receivedRequests() -> [AudioPlaybackRequest] { requests }
}

private actor AvailableLessonAssessmentProvider: LessonAssessmentProviding {
    func access(
        to assessment: Assessment,
        courseID: String,
        contentVersion: String
    ) -> LessonAssessmentAccess {
        .available(.eligible)
    }
}
