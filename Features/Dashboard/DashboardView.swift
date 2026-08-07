import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Learner-facing overview of enrolment, progress and internal completion records.
struct DashboardView: View {
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [LearnerProfile]
    @Query private var enrolments: [Enrollment]
    @Query private var progressRecords: [ProgressRecord]
    @Query private var badgeAwards: [BadgeAward]
    @Query private var feedbackRecords: [InstructorFeedback]
    @Query private var signOffs: [PracticalSignOff]

    @State private var exportDocument = LMSExportDocument()
    @State private var isExporting = false
    @State private var isConfirmingDeletion = false
    @State private var statusMessage: String?

    private var learnerID: String {
        authenticationModel.currentUser?.id ?? ""
    }

    private var activeEnrolments: [Enrollment] {
        enrolments
            .filter { $0.learnerID == learnerID && $0.isActive }
            .sorted { $0.enrolledAt > $1.enrolledAt }
    }

    private var learnerProgress: [ProgressRecord] {
        progressRecords
            .filter { $0.learnerID == learnerID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var learnerAwards: [BadgeAward] {
        badgeAwards
            .filter { $0.learnerID == learnerID }
            .sorted { $0.awardedAt > $1.awardedAt }
    }

    private var learnerFeedback: [InstructorFeedback] {
        feedbackRecords
            .filter { $0.learnerID == learnerID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var approvedSignOffs: [PracticalSignOff] {
        signOffs.filter {
            $0.learnerID == learnerID &&
            $0.statusRawValue == PracticalSignOffStatus.approved.rawValue
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 310), spacing: 20)],
                spacing: 20
            ) {
                enrolmentCard
                progressCard
                masteryCard
                achievementCard
                feedbackCard
                privacyCard
            }
            .padding(28)
        }
        .navigationTitle("Dashboard")
        .task(id: learnerID) {
            ensureLearnerProfile()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "lifesaver-vision-data-export"
        ) { result in
            switch result {
            case .success:
                statusMessage = "Your data export was saved."
            case .failure:
                statusMessage = "The data export could not be saved."
            }
        }
        .confirmationDialog(
            "Delete this local account?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Local Account", role: .destructive) {
                Task { await deleteLocalAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This purges learning records stored on this device. This cannot be undone.")
        }
    }

    private var enrolmentCard: some View {
        LearnerDashboardCard(title: "Enrolment", systemImage: "books.vertical") {
            if activeEnrolments.isEmpty {
                Text("No active course enrolments yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeEnrolments) { enrolment in
                    let progress = learnerProgress.first {
                        $0.courseID == enrolment.courseID
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(enrolment.courseID)
                            .font(.headline)
                        Text("Content version \(progress?.contentVersion ?? "Not started")")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let lastLessonID = progress?.lastLessonID {
                            Button("Resume \(lastLessonID)", systemImage: "play.fill") {
                                statusMessage = "Ready to resume \(lastLessonID)."
                            }
                            .accessibilityHint("Returns to your last saved position")
                        } else {
                            Text("Start from the course catalogue when you are ready.")
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }

    private var progressCard: some View {
        LearnerDashboardCard(title: "Progress", systemImage: "chart.bar.fill") {
            if learnerProgress.isEmpty {
                Text("Progress appears after your first learning activity.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(learnerProgress) { progress in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(progress.courseID)
                                .font(.headline)
                            Spacer()
                            Text(progress.completionFraction, format: .percent.precision(.fractionLength(0)))
                        }
                        ProgressView(value: progress.completionFraction)
                            .accessibilityLabel("Course completion")
                            .accessibilityValue(Text(progress.completionFraction, format: .percent))
                        Text("Version \(progress.contentVersion) • \(progress.completedLessonIDs.count) lessons completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !approvedSignOffs.isEmpty {
                Label(
                    "Instructor practical sign-off recorded — internal completion record",
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
            }
        }
    }

    private var masteryCard: some View {
        LearnerDashboardCard(title: "Mastery Map", systemImage: "point.3.connected.trianglepath.dotted") {
            ContentUnavailableView(
                "Mastery map coming later",
                systemImage: "map",
                description: Text("This placeholder will connect theory, practice and scenario evidence without implying physical depth or force measurement.")
            )
        }
    }

    private var achievementCard: some View {
        LearnerDashboardCard(title: "Achievements", systemImage: "medal.fill") {
            if learnerAwards.isEmpty {
                Text("Complete safe practice activities to earn internal achievements.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(learnerAwards) { award in
                    Label {
                        VStack(alignment: .leading) {
                            Text(badgeTitle(for: award.badgeID))
                            Text(award.awardedAt, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "shield.checkered")
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var feedbackCard: some View {
        LearnerDashboardCard(title: "Instructor Feedback", systemImage: "text.bubble.fill") {
            if learnerFeedback.isEmpty {
                Text("Written guidance from your instructor will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(learnerFeedback) { feedback in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(feedback.feedback)
                        Text("Course \(feedback.courseID) • \(feedback.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var privacyCard: some View {
        LearnerDashboardCard(title: "Your Data", systemImage: "lock.shield.fill") {
            Text("Export all local learning data as JSON or request deletion of this local account.")
                .foregroundStyle(.secondary)

            HStack {
                Button("Export Data", systemImage: "square.and.arrow.up") {
                    Task { await prepareExport() }
                }
                .accessibilityHint("Creates a JSON copy of your local learning records")

                Button("Delete Account", systemImage: "trash", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .accessibilityHint("Permanently deletes this account's local records")
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Status: \(statusMessage)")
            }
        }
    }

    private func ensureLearnerProfile() {
        guard let user = authenticationModel.currentUser, !user.id.isEmpty else { return }
        guard !profiles.contains(where: { $0.id == user.id }) else { return }
        modelContext.insert(
            LearnerProfile(
                id: user.id,
                displayName: user.displayName,
                roleRawValue: user.role.rawValue
            )
        )
        do {
            try modelContext.save()
        } catch {
            statusMessage = "Your local profile could not be prepared."
        }
    }

    @MainActor
    private func prepareExport() async {
        guard !learnerID.isEmpty else { return }
        let repository = SwiftDataRepositoryStore(modelContainer: modelContext.container)
        let privacy = PrivacyOperationsService(
            modelContainer: modelContext.container,
            auditLog: repository
        )
        do {
            exportDocument = LMSExportDocument(
                data: try await privacy.exportLearnerData(learnerID: learnerID)
            )
            isExporting = true
        } catch {
            statusMessage = "Your data export could not be prepared."
        }
    }

    @MainActor
    private func deleteLocalAccount() async {
        guard !learnerID.isEmpty else { return }
        let repository = SwiftDataRepositoryStore(modelContainer: modelContext.container)
        let privacy = PrivacyOperationsService(
            modelContainer: modelContext.container,
            auditLog: repository
        )
        do {
            _ = try await privacy.requestAccountDeletion(learnerID: learnerID)
            await authenticationModel.signOut()
        } catch {
            statusMessage = "The account deletion could not be completed. Please try again."
        }
    }

    private func badgeTitle(for identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

private struct LearnerDashboardCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: systemImage)
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .glassBackgroundEffect()
    }
}
