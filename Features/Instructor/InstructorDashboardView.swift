import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Instructor workspace for cohorts, learner support and practical sign-off.
struct InstructorDashboardView: View {
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.modelContext) private var modelContext

    @Query private var cohorts: [Cohort]
    @Query private var enrolments: [Enrollment]
    @Query private var profiles: [LearnerProfile]
    @Query private var progressRecords: [ProgressRecord]
    @Query private var attempts: [AttemptRecord]
    @Query private var feedbackRecords: [InstructorFeedback]
    @Query private var signOffs: [PracticalSignOff]

    @State private var selectedCohortID = ""
    @State private var newCohortName = ""
    @State private var assignedModuleID = ""
    @State private var enrolmentLearnerID = ""
    @State private var enrolmentCourseID = ""
    @State private var feedbackLearnerID = ""
    @State private var feedbackCourseID = ""
    @State private var feedbackText = ""
    @State private var practicalLearnerID = ""
    @State private var practicalCourseID = ""
    @State private var practicalContentVersion = ""
    @State private var practicalDate = Date.now
    @State private var exportDocument = LMSExportDocument()
    @State private var exportType = UTType.json
    @State private var exportFilename = "cohort-report"
    @State private var isExporting = false
    @State private var statusMessage: String?

    private var instructorID: String {
        authenticationModel.currentUser?.id ?? ""
    }

    private var selectedCohort: Cohort? {
        cohorts.first { $0.id == selectedCohortID }
    }

    private var selectedLearnerIDs: Set<String> {
        Set(
            enrolments
                .filter { $0.cohortID == selectedCohortID && $0.isActive }
                .map(\.learnerID)
        )
    }

    var body: some View {
        Group {
            if authenticationModel.currentUser?.role == .instructor {
                instructorContent
            } else {
                ContentUnavailableView(
                    "Instructor Access Required",
                    systemImage: "person.badge.shield.checkmark",
                    description: Text("Sign in with an instructor role supplied by the production authorisation service.")
                )
            }
        }
        .navigationTitle("Instructor")
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: exportType,
            defaultFilename: exportFilename
        ) { result in
            statusMessage = switch result {
            case .success: "The cohort report was saved."
            case .failure: "The cohort report could not be saved."
            }
        }
    }

    private var instructorContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                cohortManagement
                moduleAndEnrolmentManagement
                learnerReview
                feedbackManagement
                practicalManagement
                reportExports

                Text("Production permissions are enforced server-side. These local controls support the offline demonstration workflow and create internal completion records only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
        .onChange(of: cohorts.map(\.id), initial: true) { _, identifiers in
            if !identifiers.contains(selectedCohortID) {
                selectedCohortID = identifiers.sorted().first ?? ""
            }
        }
    }

    private var cohortManagement: some View {
        InstructorCard(title: "Cohorts", systemImage: "person.3.fill") {
            HStack {
                TextField("New cohort name", text: $newCohortName)
                    .accessibilityLabel("New cohort name")
                Button("Create Cohort", systemImage: "plus") {
                    createCohort()
                }
                .disabled(newCohortName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if cohorts.isEmpty {
                Text("Create a cohort to assign learning and review learner records.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Selected cohort", selection: $selectedCohortID) {
                    ForEach(cohorts.sorted { $0.name < $1.name }) { cohort in
                        Text(cohort.name).tag(cohort.id)
                    }
                }
                .pickerStyle(.menu)

                ForEach(cohorts.sorted { $0.name < $1.name }) { cohort in
                    InstructorCohortRow(
                        cohort: cohort,
                        isSelected: cohort.id == selectedCohortID,
                        select: { selectedCohortID = cohort.id },
                        save: save,
                        delete: { deleteCohort(cohort) }
                    )
                }
            }
        }
    }

    private var moduleAndEnrolmentManagement: some View {
        InstructorCard(title: "Assignments", systemImage: "books.vertical.fill") {
            if let selectedCohort {
                Text("Assign modules to \(selectedCohort.name)")
                    .font(.headline)
                HStack {
                    TextField("Module or course ID", text: $assignedModuleID)
                        .accessibilityLabel("Module or course identifier")
                    Button("Assign", systemImage: "plus.circle") {
                        let identifier = assignedModuleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !identifier.isEmpty else { return }
                        if !selectedCohort.assignedCourseIDs.contains(identifier) {
                            selectedCohort.assignedCourseIDs.append(identifier)
                            selectedCohort.updatedAt = .now
                            save()
                        }
                        assignedModuleID = ""
                    }
                }
                ForEach(selectedCohort.assignedCourseIDs.sorted(), id: \.self) { moduleID in
                    HStack {
                        Label(moduleID, systemImage: "book.closed")
                        Spacer()
                        Button("Remove \(moduleID)", systemImage: "minus.circle", role: .destructive) {
                            selectedCohort.assignedCourseIDs.removeAll { $0 == moduleID }
                            selectedCohort.updatedAt = .now
                            save()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Remove assignment \(moduleID)")
                    }
                }

                Divider()
                Text("Add learner enrolment")
                    .font(.headline)
                HStack {
                    TextField("Learner ID", text: $enrolmentLearnerID)
                        .accessibilityLabel("Learner identifier")
                    TextField("Course ID", text: $enrolmentCourseID)
                        .accessibilityLabel("Course identifier")
                    Button("Enrol", systemImage: "person.badge.plus") {
                        enrolLearner()
                    }
                    .disabled(
                        enrolmentLearnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        enrolmentCourseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            } else {
                Text("Select or create a cohort first.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var learnerReview: some View {
        InstructorCard(title: "Learner Progress and Attempts", systemImage: "chart.bar.doc.horizontal") {
            let selectedProgress = progressRecords.filter { selectedLearnerIDs.contains($0.learnerID) }
            let selectedAttempts = attempts
                .filter { selectedLearnerIDs.contains($0.learnerID) }
                .sorted { $0.startedAt > $1.startedAt }

            if selectedProgress.isEmpty && selectedAttempts.isEmpty {
                Text("No learner activity has been recorded for this cohort.")
                    .foregroundStyle(.secondary)
            }

            ForEach(selectedProgress) { progress in
                VStack(alignment: .leading, spacing: 6) {
                    Text(profileName(progress.learnerID))
                        .font(.headline)
                    ProgressView(value: progress.completionFraction)
                        .accessibilityLabel("Progress for \(profileName(progress.learnerID))")
                        .accessibilityValue(Text(progress.completionFraction, format: .percent))
                    Text("\(progress.courseID) • version \(progress.contentVersion) • \(progress.completionFraction.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(selectedAttempts) { attempt in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profileName(attempt.learnerID))
                            .font(.headline)
                        Spacer()
                        if let score = attempt.score {
                            Text(score, format: .percent.precision(.fractionLength(0)))
                        }
                    }
                    Text("\(attempt.activityID) • content version \(attempt.contentVersion)")
                        .font(.subheadline)
                    if attempt.criticalErrorCodes.isEmpty {
                        Label("No critical errors recorded", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Label("Mandatory remediation required", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(attempt.criticalErrorCodes.sorted().joined(separator: ", "))
                            .font(.caption)
                            .accessibilityLabel("Critical errors: \(attempt.criticalErrorCodes.joined(separator: ", "))")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var feedbackManagement: some View {
        InstructorCard(title: "Written Feedback", systemImage: "text.bubble.fill") {
            TextField("Learner ID", text: $feedbackLearnerID)
                .accessibilityLabel("Feedback learner identifier")
            TextField("Course ID", text: $feedbackCourseID)
                .accessibilityLabel("Feedback course identifier")
            TextField("Supportive written feedback", text: $feedbackText, axis: .vertical)
                .lineLimit(3...8)
                .accessibilityLabel("Written instructor feedback")
            Button("Save Feedback", systemImage: "square.and.arrow.down") {
                addFeedback()
            }
            .disabled(
                feedbackLearnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                feedbackCourseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            ForEach(
                feedbackRecords
                    .filter { selectedLearnerIDs.contains($0.learnerID) }
                    .sorted { $0.updatedAt > $1.updatedAt }
            ) { feedback in
                VStack(alignment: .leading, spacing: 4) {
                    Text(profileName(feedback.learnerID)).font(.headline)
                    Text(feedback.feedback)
                    Text("Course \(feedback.courseID) • \(feedback.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var practicalManagement: some View {
        InstructorCard(title: "Practical Assessment", systemImage: "figure.strengthtraining.traditional") {
            Text("Schedule a manikin-based assessment. Compression depth and force remain Not physically assessed unless a verified external sensor provider is connected.")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Learner ID", text: $practicalLearnerID)
                    .accessibilityLabel("Practical assessment learner identifier")
                TextField("Course ID", text: $practicalCourseID)
                    .accessibilityLabel("Practical assessment course identifier")
                TextField("Content version", text: $practicalContentVersion)
                    .accessibilityLabel("Practical assessment content version")
            }
            DatePicker("Assessment date", selection: $practicalDate)
            Button("Schedule Assessment", systemImage: "calendar.badge.plus") {
                schedulePractical()
            }
            .disabled(
                practicalLearnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                practicalCourseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                practicalContentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            ForEach(
                signOffs
                    .filter { selectedLearnerIDs.contains($0.learnerID) }
                    .sorted { ($0.scheduledAt ?? .distantPast) > ($1.scheduledAt ?? .distantPast) }
            ) { signOff in
                InstructorPracticalRow(signOff: signOff, save: save)
            }
        }
    }

    private var reportExports: some View {
        InstructorCard(title: "Cohort Reports", systemImage: "doc.badge.arrow.up") {
            Text("Reports include learner progress, attempts, critical errors and the content version used.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Export CSV", systemImage: "tablecells") {
                    prepareReport(type: .commaSeparatedText)
                }
                Button("Export JSON", systemImage: "curlybraces") {
                    prepareReport(type: .json)
                }
            }
            .disabled(selectedCohort == nil)

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Status: \(statusMessage)")
            }
        }
    }

    private func createCohort() {
        let name = newCohortName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let cohort = Cohort(name: name, instructorIDs: [instructorID])
        modelContext.insert(cohort)
        selectedCohortID = cohort.id
        newCohortName = ""
        save()
    }

    private func deleteCohort(_ cohort: Cohort) {
        for enrolment in enrolments where enrolment.cohortID == cohort.id {
            modelContext.delete(enrolment)
        }
        modelContext.delete(cohort)
        save()
    }

    private func enrolLearner() {
        guard let cohort = selectedCohort else { return }
        let learnerID = enrolmentLearnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let courseID = enrolmentCourseID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learnerID.isEmpty, !courseID.isEmpty else { return }
        if let existing = enrolments.first(where: {
            $0.cohortID == cohort.id && $0.learnerID == learnerID && $0.courseID == courseID
        }) {
            existing.isActive = true
            existing.updatedAt = .now
        } else {
            modelContext.insert(
                Enrollment(
                    id: "\(cohort.id)#\(learnerID)#\(courseID)",
                    cohortID: cohort.id,
                    learnerID: learnerID,
                    courseID: courseID
                )
            )
        }
        enrolmentLearnerID = ""
        enrolmentCourseID = ""
        save()
    }

    private func addFeedback() {
        let learnerID = feedbackLearnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let courseID = feedbackCourseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learnerID.isEmpty, !courseID.isEmpty, !text.isEmpty else { return }
        modelContext.insert(
            InstructorFeedback(
                learnerID: learnerID,
                instructorID: instructorID,
                courseID: courseID,
                feedback: text
            )
        )
        feedbackText = ""
        save()
    }

    private func schedulePractical() {
        let learnerID = practicalLearnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let courseID = practicalCourseID.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = practicalContentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !learnerID.isEmpty, !courseID.isEmpty, !version.isEmpty else { return }
        modelContext.insert(
            PracticalSignOff(
                learnerID: learnerID,
                instructorID: instructorID,
                courseID: courseID,
                contentVersion: version,
                scheduledAt: practicalDate,
                manikinResultJSON: "{\"compressionDepth\":\"Not physically assessed\",\"force\":\"Not physically assessed\"}"
            )
        )
        practicalLearnerID = ""
        practicalCourseID = ""
        practicalContentVersion = ""
        save()
    }

    private func prepareReport(type: UTType) {
        guard let cohort = selectedCohort else { return }
        let selectedEnrolments = enrolments.filter { $0.cohortID == cohort.id && $0.isActive }
        let entries = selectedEnrolments.flatMap { enrolment -> [CohortReportEntry] in
            let progress = progressRecords.first {
                $0.learnerID == enrolment.learnerID && $0.courseID == enrolment.courseID
            }
            let matchingAttempts = attempts.filter {
                $0.learnerID == enrolment.learnerID &&
                ($0.courseID == nil || $0.courseID == enrolment.courseID)
            }
            if matchingAttempts.isEmpty {
                return [
                    CohortReportEntry(
                        id: "\(enrolment.id)#progress",
                        learnerID: enrolment.learnerID,
                        learnerDisplayName: profileName(enrolment.learnerID),
                        courseID: enrolment.courseID,
                        completionFraction: progress?.completionFraction,
                        attemptID: nil,
                        activityID: nil,
                        contentVersion: progress?.contentVersion ?? "No attempt recorded",
                        score: nil,
                        passed: nil,
                        criticalErrorCodes: []
                    )
                ]
            }
            return matchingAttempts.map { attempt in
                CohortReportEntry(
                    id: attempt.id,
                    learnerID: enrolment.learnerID,
                    learnerDisplayName: profileName(enrolment.learnerID),
                    courseID: enrolment.courseID,
                    completionFraction: progress?.completionFraction,
                    attemptID: attempt.id,
                    activityID: attempt.activityID,
                    contentVersion: attempt.contentVersion,
                    score: attempt.score,
                    passed: attempt.passed,
                    criticalErrorCodes: attempt.criticalErrorCodes
                )
            }
        }
        let report = CohortReport(
            schemaVersion: 1,
            cohortID: cohort.id,
            cohortName: cohort.name,
            generatedAt: .now,
            entries: entries
        )
        let exporter = CohortReportExportService()
        do {
            exportDocument = LMSExportDocument(
                data: type == .json ? try exporter.jsonData(for: report) : exporter.csvData(for: report)
            )
            exportType = type
            exportFilename = type == .json ? "cohort-report.json" : "cohort-report.csv"
            isExporting = true
        } catch {
            statusMessage = "The cohort report could not be prepared."
        }
    }

    private func profileName(_ learnerID: String) -> String {
        profiles.first { $0.id == learnerID }?.displayName ?? learnerID
    }

    private func save() {
        do {
            try modelContext.save()
            statusMessage = "Changes saved locally."
        } catch {
            statusMessage = "Changes could not be saved."
        }
    }
}

private struct InstructorCohortRow: View {
    @Bindable var cohort: Cohort
    let isSelected: Bool
    let select: () -> Void
    let save: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            Button(action: select) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select \(cohort.name)")
            TextField("Cohort name", text: $cohort.name)
                .onSubmit(save)
                .accessibilityLabel("Cohort name")
            Toggle("Active", isOn: $cohort.isActive)
                .onChange(of: cohort.isActive) { _, _ in save() }
            Button("Delete \(cohort.name)", systemImage: "trash", role: .destructive, action: delete)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Delete cohort \(cohort.name)")
        }
    }
}

private struct InstructorPracticalRow: View {
    @Bindable var signOff: PracticalSignOff
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(signOff.learnerID) • \(signOff.courseID)")
                    .font(.headline)
                Spacer()
                Text(signOff.statusRawValue.capitalized)
                    .foregroundStyle(statusColour)
            }
            Text("Content version \(signOff.contentVersion)")
                .font(.subheadline)
            Text("Compression depth: Not physically assessed • Force: Not physically assessed")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Manikin-based observation notes", text: $signOff.notes, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityLabel("Practical observation notes")
            TextField("Required remediation before reassessment", text: remediationBinding, axis: .vertical)
                .lineLimit(2...5)
                .accessibilityLabel("Practical remediation")
            HStack {
                Button("Save Notes", systemImage: "square.and.arrow.down") {
                    signOff.assessedAt = .now
                    save()
                }
                Button("Sign Off", systemImage: "checkmark.seal") {
                    signOff.statusRawValue = PracticalSignOffStatus.approved.rawValue
                    signOff.assessedAt = .now
                    signOff.signedAt = .now
                    signOff.remediation = nil
                    save()
                }
                .disabled(signOff.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Reject with Remediation", systemImage: "arrow.counterclockwise", role: .destructive) {
                    signOff.statusRawValue = PracticalSignOffStatus.rejected.rawValue
                    signOff.assessedAt = .now
                    signOff.signedAt = nil
                    save()
                }
                .disabled((signOff.remediation ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 6)
    }

    private var remediationBinding: Binding<String> {
        Binding(
            get: { signOff.remediation ?? "" },
            set: { signOff.remediation = $0.isEmpty ? nil : $0 }
        )
    }

    private var statusColour: Color {
        switch PracticalSignOffStatus(rawValue: signOff.statusRawValue) {
        case .approved: .green
        case .rejected: .orange
        case .scheduled, .none: .secondary
        }
    }
}

private struct InstructorCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
