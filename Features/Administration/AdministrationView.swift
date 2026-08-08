import SwiftData
import SwiftUI

/// Administrative workspace for local academy configuration and aggregate oversight.
struct AdministrationView: View {
    @Environment(AuthenticationModel.self) private var authenticationModel
    @Environment(\.modelContext) private var modelContext

    @Query private var profiles: [LearnerProfile]
    @Query private var cohorts: [Cohort]
    @Query private var enrolments: [Enrollment]
    @Query private var attempts: [AttemptRecord]
    @Query private var results: [AssessmentResult]
    @Query private var contentVersions: [ContentVersionRecord]
    @Query private var auditEntries: [AuditLogEntry]

    @AppStorage("academy.assessment.passThreshold") private var passThreshold = 0.80
    @AppStorage("academy.badges.rulesJSON") private var badgeRulesJSON = ""
    @AppStorage(RetentionPreferenceKeys.progressDays) private var progressRetentionDays = 730
    @AppStorage(RetentionPreferenceKeys.attemptDays) private var attemptRetentionDays = 730
    @AppStorage(RetentionPreferenceKeys.feedbackDays) private var feedbackRetentionDays = 730
    @AppStorage(RetentionPreferenceKeys.learningEventDays) private var learningEventRetentionDays = 730
    @AppStorage(RetentionPreferenceKeys.offlineQueueDays) private var offlineQueueRetentionDays = 30
    @AppStorage(RetentionPreferenceKeys.revokedConsentDays) private var consentRetentionDays = 365
    @AppStorage("academy.instructor.permissionsJSON") private var instructorPermissionsJSON = "[]"

    @State private var newUserName = ""
    @State private var newUserRole = Role.learner
    @State private var badgeRulesDraft = ""
    @State private var permittedInstructorIDs = Set<String>()
    @State private var auditIntegrity: Bool?
    @State private var statusMessage: String?

    private var adminID: String {
        authenticationModel.currentUser?.id ?? ""
    }

    private var activeLearnerCount: Int {
        profiles.filter { $0.isActive && $0.roleRawValue == Role.learner.rawValue }.count
    }

    private var completedAttemptCount: Int {
        attempts.filter { $0.completedAt != nil }.count
    }

    private var averageAssessmentScore: Double? {
        guard !results.isEmpty else { return nil }
        return results.map(\.score).reduce(0, +) / Double(results.count)
    }

    var body: some View {
        Group {
            if authenticationModel.currentUser?.role == .admin {
                administrationContent
            } else {
                ContentUnavailableView(
                    "Administrator Access Required",
                    systemImage: "lock.shield",
                    description: Text("Administrator access is available only through the Demo configuration bootstrap or a production authorisation service.")
                )
            }
        }
        .navigationTitle("Administration")
    }

    private var administrationContent: some View {
        ScrollView {
            VStack(spacing: 22) {
                userManagement
                instructorPermissions
                contentLifecycle
                assessmentAndBadgeConfiguration
                aggregateAnalytics
                auditViewer
                retentionConfiguration

                Text("Local role controls are for the offline demonstration only. Production authorisation must be enforced server-side. Practical outcomes are internal completion records, not external certification.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        }
        .task {
            ensureAdministratorProfile()
            loadInstructorPermissions()
            prepareBadgeConfigurationIfNeeded()
            await verifyAuditIntegrity()
        }
    }

    private var userManagement: some View {
        AdministrationCard(title: "Users and Roles", systemImage: "person.crop.circle.badge.gearshape") {
            Text("Create learner or instructor profiles. Administrator roles cannot be assigned here.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Display name", text: $newUserName)
                    .accessibilityLabel("New user display name")
                Picker("Role", selection: $newUserRole) {
                    Text("Learner").tag(Role.learner)
                    Text("Instructor").tag(Role.instructor)
                }
                .pickerStyle(.segmented)
                Button("Add User", systemImage: "person.badge.plus") {
                    addUser()
                }
                .disabled(newUserName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if profiles.isEmpty {
                Text("No local user profiles are available.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(profiles.sorted { $0.displayName < $1.displayName }) { profile in
                    AdministrationUserRow(
                        profile: profile,
                        save: {
                            profile.updatedAt = .now
                            save(
                                auditAction: "user_profile_updated",
                                metadata: ["role": profile.roleRawValue, "isActive": String(profile.isActive)]
                            )
                        }
                    )
                }
            }
        }
    }

    private var instructorPermissions: some View {
        AdministrationCard(title: "Instructor Permissions", systemImage: "person.badge.key.fill") {
            Text("Grant local demonstration permission to manage cohorts and practical assessments.")
                .foregroundStyle(.secondary)
            let instructors = profiles.filter { $0.roleRawValue == Role.instructor.rawValue }
            if instructors.isEmpty {
                Text("No instructor profiles have been created.")
                    .foregroundStyle(.secondary)
            }
            ForEach(instructors.sorted { $0.displayName < $1.displayName }) { instructor in
                Toggle(
                    "\(instructor.displayName) — cohort and practical management",
                    isOn: permissionBinding(for: instructor.id)
                )
                .accessibilityHint("Controls this instructor's local demonstration permission")
            }
        }
    }

    private var contentLifecycle: some View {
        AdministrationCard(title: "Course Versions", systemImage: "shippingbox.and.arrow.backward") {
            Text("Publishing is allowed only from Clinically Approved and is revalidated against the clinical fact catalogue. SME-review flags block activation.")
                .foregroundStyle(.secondary)

            if contentVersions.isEmpty {
                Text("No versioned course records have been imported.")
                    .foregroundStyle(.secondary)
            }
            ForEach(contentVersions.sorted(by: versionSort)) { version in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(version.courseID)
                                .font(.headline)
                            Text("Version \(version.contentVersion)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(lifecycleTitle(version.lifecycleRawValue))
                            .foregroundStyle(lifecycleColour(version.lifecycleRawValue))
                    }
                    HStack {
                        Button("Publish", systemImage: "paperplane.fill") {
                            Task { await publish(version) }
                        }
                        .disabled(version.lifecycleRawValue != ContentLifecycle.clinicallyApproved.rawValue)
                        .accessibilityHint("Runs clinical validation, then publishes this content version")

                        Button("Retire", systemImage: "archivebox", role: .destructive) {
                            Task { await retire(version) }
                        }
                        .disabled(version.lifecycleRawValue == ContentLifecycle.retired.rawValue)
                    }
                }
                .padding(.vertical, 5)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Administration status: \(statusMessage)")
            }
        }
    }

    private var assessmentAndBadgeConfiguration: some View {
        AdministrationCard(title: "Assessment and Badge Configuration", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Theory pass threshold")
                    .font(.headline)
                Slider(value: $passThreshold, in: 0.50...1.00, step: 0.05)
                    .accessibilityLabel("Theory assessment pass threshold")
                    .accessibilityValue(Text(passThreshold, format: .percent))
                Text(passThreshold, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Badge rules (JSON)")
                .font(.headline)
            Text("Rules remain data-driven. Save only a valid array of badge-rule records.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextEditor(text: $badgeRulesDraft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .accessibilityLabel("Badge rule JSON configuration")
            Button("Validate and Save Badge Rules", systemImage: "checkmark.shield") {
                validateBadgeConfiguration()
            }

            Label("Public leaderboard is off by default", systemImage: "eye.slash.fill")
                .foregroundStyle(.secondary)
            Text("No loot boxes, purchases or monetisation mechanics are used.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var aggregateAnalytics: some View {
        AdministrationCard(title: "Aggregate Analytics", systemImage: "chart.pie.fill") {
            Text("Counts and averages only — no learner-level analytics are shown here.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                AggregateMetric(title: "Active learners", value: String(activeLearnerCount))
                AggregateMetric(title: "Active enrolments", value: String(enrolments.filter(\.isActive).count))
                AggregateMetric(title: "Cohorts", value: String(cohorts.count))
                AggregateMetric(title: "Completed attempts", value: String(completedAttemptCount))
                AggregateMetric(
                    title: "Average assessment score",
                    value: averageAssessmentScore?.formatted(.percent.precision(.fractionLength(0))) ?? "No results"
                )
            }
        }
    }

    private var auditViewer: some View {
        AdministrationCard(title: "Audit Log", systemImage: "checkmark.shield.fill") {
            HStack {
                Label(
                    auditIntegrityLabel,
                    systemImage: auditIntegrity == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(auditIntegrity == true ? .green : .orange)
                Spacer()
                Button("Verify Chain", systemImage: "arrow.clockwise") {
                    Task { await verifyAuditIntegrity() }
                }
            }

            if auditEntries.isEmpty {
                Text("The append-only audit log is empty.")
                    .foregroundStyle(.secondary)
            }
            ForEach(auditEntries.sorted { $0.sequenceNumber > $1.sequenceNumber }.prefix(30)) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(entry.sequenceNumber) • \(entry.action)")
                        .font(.headline)
                    Text("\(entry.category) • \(entry.timestamp.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Hash \(entry.entryHash.prefix(12))…")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var retentionConfiguration: some View {
        AdministrationCard(title: "Data Retention", systemImage: "clock.arrow.circlepath") {
            Text("Retention is enforced locally by record category. Values are days.")
                .foregroundStyle(.secondary)
            RetentionStepper(title: "Progress", value: $progressRetentionDays)
            RetentionStepper(title: "Attempts and results", value: $attemptRetentionDays)
            RetentionStepper(title: "Instructor feedback", value: $feedbackRetentionDays)
            RetentionStepper(title: "Learning events", value: $learningEventRetentionDays)
            RetentionStepper(title: "Offline queue", value: $offlineQueueRetentionDays)
            RetentionStepper(title: "Revoked consent", value: $consentRetentionDays)
            Button("Apply Retention Now", systemImage: "trash.slash") {
                Task { await enforceRetention() }
            }
            .accessibilityHint("Purges local records older than the configured periods")
        }
    }

    private func ensureAdministratorProfile() {
        guard let user = authenticationModel.currentUser,
              user.role == .admin,
              !profiles.contains(where: { $0.id == user.id })
        else { return }
        modelContext.insert(
            LearnerProfile(
                id: user.id,
                displayName: user.displayName,
                roleRawValue: Role.admin.rawValue
            )
        )
        save(auditAction: "demo_administrator_profile_prepared")
    }

    private func addUser() {
        let name = newUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, newUserRole != .admin else { return }
        let role = newUserRole
        modelContext.insert(
            LearnerProfile(displayName: name, roleRawValue: role.rawValue)
        )
        newUserName = ""
        newUserRole = .learner
        save(auditAction: "user_profile_created", metadata: ["role": role.rawValue])
    }

    private func permissionBinding(for instructorID: String) -> Binding<Bool> {
        Binding(
            get: { permittedInstructorIDs.contains(instructorID) },
            set: { isEnabled in
                if isEnabled {
                    permittedInstructorIDs.insert(instructorID)
                } else {
                    permittedInstructorIDs.remove(instructorID)
                }
                persistInstructorPermissions()
            }
        )
    }

    private func loadInstructorPermissions() {
        guard let data = instructorPermissionsJSON.data(using: .utf8),
              let identifiers = try? JSONDecoder().decode([String].self, from: data)
        else {
            permittedInstructorIDs = []
            return
        }
        permittedInstructorIDs = Set(identifiers)
    }

    private func persistInstructorPermissions() {
        let identifiers = permittedInstructorIDs.sorted()
        if let data = try? JSONEncoder().encode(identifiers),
           let json = String(data: data, encoding: .utf8) {
            instructorPermissionsJSON = json
            recordAudit(action: "instructor_permissions_updated", metadata: ["permissionCount": String(identifiers.count)])
        }
    }

    private func prepareBadgeConfigurationIfNeeded() {
        if badgeRulesJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let rules = try? BadgeRuleCodec.loadBundled(),
           let data = try? JSONEncoder().encode(rules),
           let json = String(data: data, encoding: .utf8) {
            badgeRulesJSON = json
        }
        badgeRulesDraft = badgeRulesJSON
    }

    private func validateBadgeConfiguration() {
        guard let data = badgeRulesDraft.data(using: .utf8),
              let rules = try? JSONDecoder().decode([BadgeRule].self, from: data),
              !rules.isEmpty,
              Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({ $0.target.isFinite })
        else {
            statusMessage = "Badge rules are invalid and were not saved."
            return
        }
        if let encoded = try? JSONEncoder().encode(rules),
           let normalised = String(data: encoded, encoding: .utf8) {
            badgeRulesJSON = normalised
            badgeRulesDraft = normalised
            statusMessage = "Badge rules validated and saved locally."
            recordAudit(action: "badge_rules_updated", metadata: ["ruleCount": String(rules.count)])
        }
    }

    @MainActor
    private func publish(_ version: ContentVersionRecord) async {
        do {
            let repository = SwiftDataRepositoryStore(modelContainer: modelContext.container)
            let service = ContentVersionService(
                courses: repository,
                versions: repository,
                auditLog: repository,
                facts: try ClinicalFactCatalogue.loadBundled()
            )
            try await service.publish(
                courseID: version.courseID,
                contentVersion: version.contentVersion,
                actorID: adminID
            )
            statusMessage = "Version \(version.contentVersion) was published after clinical validation."
        } catch {
            statusMessage = "Publishing was blocked. Confirm lifecycle, sources and clinical review status."
        }
    }

    @MainActor
    private func retire(_ version: ContentVersionRecord) async {
        do {
            let repository = SwiftDataRepositoryStore(modelContainer: modelContext.container)
            let service = ContentVersionService(
                courses: repository,
                versions: repository,
                auditLog: repository,
                facts: try ClinicalFactCatalogue.loadBundled()
            )
            try await service.transition(
                courseID: version.courseID,
                contentVersion: version.contentVersion,
                to: .retired,
                actorID: adminID
            )
            statusMessage = "Version \(version.contentVersion) was retired. Existing attempt records are preserved."
        } catch {
            statusMessage = "This course version could not be retired from its current lifecycle state."
        }
    }

    @MainActor
    private func enforceRetention() async {
        let configuration = RetentionConfiguration(
            progressDays: progressRetentionDays,
            attemptDays: attemptRetentionDays,
            feedbackDays: feedbackRetentionDays,
            learningEventDays: learningEventRetentionDays,
            offlineQueueDays: offlineQueueRetentionDays,
            revokedConsentDays: consentRetentionDays
        )
        let repository = SwiftDataRepositoryStore(modelContainer: modelContext.container)
        let privacy = PrivacyOperationsService(
            modelContainer: modelContext.container,
            auditLog: repository
        )
        do {
            let report = try await privacy.enforceRetention(configuration)
            statusMessage = "Retention applied. \(report.purgedRecordCount) expired local records were purged."
        } catch {
            statusMessage = "Retention settings are invalid or could not be applied."
        }
    }

    @MainActor
    private func verifyAuditIntegrity() async {
        let repository = SwiftDataRepositoryStore(modelContainer: modelContext.container)
        auditIntegrity = (try? await repository.verifyIntegrity()) ?? false
    }

    private func save(auditAction: String, metadata: [String: String] = [:]) {
        do {
            try modelContext.save()
            statusMessage = "Changes saved locally."
            recordAudit(action: auditAction, metadata: metadata)
        } catch {
            statusMessage = "Changes could not be saved."
        }
    }

    private func recordAudit(action: String, metadata: [String: String] = [:]) {
        let container = modelContext.container
        let actorID = adminID
        Task {
            let repository = SwiftDataRepositoryStore(modelContainer: container)
            try? await repository.record(
                AuditEvent(
                    id: UUID().uuidString,
                    actorID: actorID,
                    category: "administration",
                    action: action,
                    timestamp: .now,
                    metadata: metadata
                )
            )
            await verifyAuditIntegrity()
        }
    }

    private func versionSort(_ lhs: ContentVersionRecord, _ rhs: ContentVersionRecord) -> Bool {
        if lhs.courseID != rhs.courseID { return lhs.courseID < rhs.courseID }
        return lhs.contentVersion > rhs.contentVersion
    }

    private func lifecycleTitle(_ rawValue: String) -> String {
        switch ContentLifecycle(rawValue: rawValue) {
        case .sourceChecked: "Source Checked"
        case .clinicalReviewRequired: "Clinical Review Required"
        case .clinicallyApproved: "Clinically Approved"
        case .published: "Published"
        case .superseded: "Superseded"
        case .retired: "Retired"
        case .draft: "Draft"
        case .none: "Unknown — blocked"
        }
    }

    private func lifecycleColour(_ rawValue: String) -> Color {
        switch ContentLifecycle(rawValue: rawValue) {
        case .published, .clinicallyApproved: .green
        case .clinicalReviewRequired, .none: .orange
        case .retired, .superseded: .secondary
        case .sourceChecked, .draft: .blue
        }
    }

    private var auditIntegrityLabel: String {
        switch auditIntegrity {
        case true: "Hash chain verified"
        case false: "Hash chain verification failed"
        case nil: "Hash chain not yet verified"
        }
    }
}

private struct AdministrationUserRow: View {
    @Bindable var profile: LearnerProfile
    let save: () -> Void

    var body: some View {
        HStack {
            TextField("Display name", text: $profile.displayName)
                .onSubmit(save)
                .accessibilityLabel("User display name")
            if profile.roleRawValue == Role.admin.rawValue {
                Label("Administrator — Demo bootstrap only", systemImage: "lock.shield.fill")
                    .font(.subheadline)
            } else {
                Picker("Role", selection: $profile.roleRawValue) {
                    Text("Learner").tag(Role.learner.rawValue)
                    Text("Instructor").tag(Role.instructor.rawValue)
                }
                .onChange(of: profile.roleRawValue) { _, _ in save() }
                .pickerStyle(.menu)
            }
            Toggle("Active", isOn: $profile.isActive)
                .onChange(of: profile.isActive) { _, _ in save() }
        }
    }
}

private struct AggregateMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.title.bold())
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

private struct RetentionStepper: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        Stepper("\(title): \(value) days", value: $value, in: 0...3_650, step: 30)
            .accessibilityValue("\(value) days")
    }
}

private struct AdministrationCard<Content: View>: View {
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
