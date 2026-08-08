import SwiftData
import SwiftUI

/// Source-backed catalogue whose availability comes only from `CourseEngine`.
struct CourseCatalogueView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.modelContext) private var modelContext

    @State private var presentationModel: ModulePresentationModel?
    @State private var setupErrorMessage: String?

    private var learnerID: String {
        authenticationModel.currentUser?.id ?? ""
    }

    var body: some View {
        Group {
            if let presentationModel {
                catalogueContent(presentationModel)
            } else if let setupErrorMessage {
                unavailableContent(message: setupErrorMessage)
            } else {
                ProgressView("Preparing source-backed modules…")
                    .accessibilityLabel("Preparing the source-backed course catalogue")
            }
        }
        .navigationTitle("Courses")
        .task(id: learnerID) {
            await prepareCatalogue()
        }
    }

    @ViewBuilder
    private func catalogueContent(_ model: ModulePresentationModel) -> some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("Checking course access…")
                .accessibilityLabel("Checking course module access")
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 16) {
                    catalogueHeader(model)
                    ForEach(model.modules) { item in
                        moduleEntry(item, model: model)
                    }
                }
                .padding(28)
            }
        case let .failed(message):
            unavailableContent(message: message)
        }
    }

    @ViewBuilder
    private func moduleEntry(
        _ item: PresentedCourseModule,
        model: ModulePresentationModel
    ) -> some View {
        if let route = model.lessonPlayerRoute(moduleID: item.id, learnerID: learnerID) {
            NavigationLink {
                LessonPlayerView(
                    route: route,
                    audioDirector: appModel.audioDirector,
                    assessmentProvider: CourseEngineLessonAssessmentProvider(
                        modelContainer: modelContext.container
                    )
                )
            } label: {
                ModuleCatalogueCard(
                    item: item,
                    isCompleted: model.completedModuleIDs.contains(item.id)
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("module-open-\(item.id)")
            .accessibilityHint("Opens the source-backed lesson player")
        } else {
            ModuleCatalogueCard(
                item: item,
                isCompleted: model.completedModuleIDs.contains(item.id)
            )
            .accessibilityIdentifier("module-card-\(item.id)")
        }
    }

    private func catalogueHeader(_ model: ModulePresentationModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.courseTitle)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Content version \(model.contentVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Module availability is checked against saved lesson progress and the authoritative course lifecycle. Instructor-gated content remains locked until separate module approval is recorded.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassBackgroundEffect()
    }

    private func unavailableContent(message: String) -> some View {
        ContentUnavailableView {
            Label("Course Catalogue Unavailable", systemImage: "books.vertical.fill")
        } description: {
            Text(message)
        } actions: {
            Button("Try Again", systemImage: "arrow.clockwise") {
                Task { await prepareCatalogue(forceNewModel: true) }
            }
            .accessibilityHint("Reloads the source-backed course and checks access again")
        }
    }

    @MainActor
    private func prepareCatalogue(forceNewModel: Bool = false) async {
        if forceNewModel {
            presentationModel = nil
        }
        setupErrorMessage = nil

        do {
            let model: ModulePresentationModel
            if let presentationModel {
                model = presentationModel
            } else {
                model = try ModulePresentationModel.production(
                    modelContainer: modelContext.container
                )
                presentationModel = model
            }

            // No production module-approval repository exists yet. Passing `.none` is
            // intentional and must not be replaced with practical sign-off or demo-role data.
            await model.load(
                learnerID: learnerID,
                instructorApproval: .none
            )
        } catch {
            setupErrorMessage = "The clinical fact catalogue required for course access could not be loaded."
        }
    }
}

private struct ModuleCatalogueCard: View {
    let item: PresentedCourseModule
    let isCompleted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.module.id)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.module.title)
                    .font(.title3.bold())
                Spacer()
                accessLabel
            }

            Text(item.module.summary)
                .foregroundStyle(.secondary)

            if isCompleted {
                Label("All lessons completed", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            if !item.isPresentable {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.lockReasons.enumerated()), id: \.offset) { _, reason in
                        Label(reason.learnerMessage, systemImage: "lock.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassBackgroundEffect()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var accessLabel: some View {
        if item.isPresentable {
            Label("Available", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("module-available-\(item.id)")
        } else {
            Label("Locked", systemImage: "lock.fill")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("module-lock-\(item.id)")
        }
    }
}
