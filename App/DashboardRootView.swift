import SwiftUI

/// Shared-space LMS shell with role-scoped navigation.
struct DashboardRootView: View {
    private enum Destination: String, Hashable {
        case learnerDashboard
        case courses
        case theory
        case cprPractice
        case aedPractice
        case scenarios
        case assessments
        case progress
        case learningLab
        case instructor
        case administration
        case settings
    }

    @Environment(AppModel.self) private var appModel
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Destination? = .learnerDashboard

    private var role: Role {
        authenticationModel.currentUser?.role ?? .learner
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if role == .learner {
                    Section("Learner") {
                        navigationLabel("Dashboard", systemImage: "rectangle.grid.2x2", destination: .learnerDashboard)
                        navigationLabel("Courses", systemImage: "books.vertical", destination: .courses)
                        navigationLabel("Theory", systemImage: "book.pages", destination: .theory)
                        navigationLabel("CPR Practice", systemImage: "heart", destination: .cprPractice)
                        navigationLabel("AED Practice", systemImage: "waveform.path.ecg", destination: .aedPractice)
                        navigationLabel("Scenarios", systemImage: "person.2", destination: .scenarios)
                        navigationLabel("Assessments", systemImage: "checklist", destination: .assessments)
                        navigationLabel("Progress", systemImage: "medal", destination: .progress)
                        navigationLabel("Learning Lab", systemImage: "cube.transparent", destination: .learningLab)
                    }
                }

                if role == .instructor {
                    Section("Instructor") {
                        navigationLabel("Instructor Dashboard", systemImage: "person.2.badge.gearshape", destination: .instructor)
                    }
                }

                if role == .admin {
                    Section("Administration") {
                        navigationLabel("Administration", systemImage: "gearshape.2", destination: .administration)
                    }
                }

                Section("Preferences") {
                    navigationLabel("Settings", systemImage: "slider.horizontal.3", destination: .settings)
                }
            }
            .navigationTitle("Lifesaver Vision")
        } detail: {
            NavigationStack {
                destinationView
            }
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            appModel.handleScenePhase(newPhase)
        }
        .onChange(of: role, initial: true) { _, newRole in
            let preferred: Destination = switch newRole {
            case .learner: .learnerDashboard
            case .instructor: .instructor
            case .admin: .administration
            }
            if !isVisible(selection, for: newRole) {
                selection = preferred
            }
        }
    }

    private func isVisible(_ destination: Destination?, for role: Role) -> Bool {
        guard let destination else { return false }
        if destination == .settings { return true }
        switch role {
        case .learner:
            return ![Destination.instructor, .administration].contains(destination)
        case .instructor:
            return destination == .instructor
        case .admin:
            return destination == .administration
        }
    }

    private func navigationLabel(
        _ title: LocalizedStringKey,
        systemImage: String,
        destination: Destination
    ) -> some View {
        Label(title, systemImage: systemImage)
            .tag(destination)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch selection ?? .learnerDashboard {
        case .learnerDashboard:
            DashboardView()
        case .courses:
            CourseCatalogueView()
        case .theory:
            TheoryLearningView()
        case .cprPractice:
            CPRPracticeView()
        case .aedPractice:
            AEDPracticeView()
        case .scenarios:
            ScenariosView()
        case .assessments:
            AssessmentView()
        case .progress:
            GamificationView()
        case .learningLab:
            LearningLabLaunchView()
        case .instructor:
            InstructorDashboardView()
        case .administration:
            AdministrationView()
        case .settings:
            SettingsView()
        }
    }
}

private struct LearningLabLaunchView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("Volumetric Learning") {
                Text("Open a separate learning laboratory volume. Interactive clinical models arrive in a later phase.")
                Button("Open Learning Lab", systemImage: "cube.transparent") {
                    openWindow(id: AppModel.learningLabWindowID)
                }
            }

            Section("Immersive Simulation") {
                Text("Enter only when your surroundings are clear and you are ready to practise in mixed immersion.")
                Toggle("I am ready to enter the simulation", isOn: $appModel.hasUserOptedInToImmersion)

                Button("Enter Simulation", systemImage: "visionpro") {
                    Task {
                        await appModel.openSimulation(using: openImmersiveSpace)
                    }
                }
                .disabled(
                    !appModel.hasUserOptedInToImmersion ||
                    appModel.immersionState != .closed
                )

                Text("SIMULATION ONLY — emergency-call practice never places a call to 995.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let notice = appModel.immersionNotice {
                    Text(notice)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Learning Lab")
    }
}
