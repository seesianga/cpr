import SwiftData

/// The first persisted LMS schema. Future releases add a new `VersionedSchema` instead
/// of changing this model list in place.
enum LMSVersionedSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [
            LearnerProfile.self,
            ProgressRecord.self,
            AttemptRecord.self,
            AuditLogEntry.self,
            Cohort.self,
            Enrollment.self,
            AssessmentResult.self,
            BadgeAward.self,
            InstructorFeedback.self,
            PracticalSignOff.self,
            ContentVersionRecord.self,
            OfflineQueuedEvent.self,
            ConsentRecord.self,
            LearningEventEntity.self
        ]
    }
}

/// Migration plan stub. Add explicit lightweight or custom stages when V2 is introduced.
enum LMSMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [LMSVersionedSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

/// Constructs the app's local-first SwiftData container without a CloudKit dependency.
enum PersistenceBootstrap {
    @MainActor
    static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LMSVersionedSchemaV1.self)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        return try ModelContainer(
            for: schema,
            migrationPlan: LMSMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
