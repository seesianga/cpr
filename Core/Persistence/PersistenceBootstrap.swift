import SwiftData

/// Constructs the app's local-first SwiftData container.
enum PersistenceBootstrap {
    @MainActor
    static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            LearnerProfile.self,
            ProgressRecord.self,
            AttemptRecord.self,
            AuditLogEntry.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        return try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
    }
}
