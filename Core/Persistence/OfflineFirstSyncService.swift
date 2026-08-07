import Foundation
import SwiftData

/// Simulator-safe backend that performs no network operations and accepts no events.
struct NoopCloudBackend: CloudBackend {
    func push(_ events: [QueuedSyncEvent]) async throws -> CloudPushResult {
        CloudPushResult()
    }

    func pullChanges(since: Date?) async throws -> [CloudChange] {
        []
    }
}

/// Local-first synchronization coordinator with a CloudKit-shaped transport boundary.
///
/// Mutations are durable before any network attempt. Conflicts use
/// last-writer-wins-with-audit; the audit event contains no learner payload.
actor OfflineFirstSyncService: SyncService {
    private let modelContainer: ModelContainer
    private let backend: any CloudBackend
    private let auditLog: any AuditLogService
    private var lastSuccessfulPullAt: Date?

    init(
        modelContainer: ModelContainer,
        backend: any CloudBackend = NoopCloudBackend(),
        auditLog: any AuditLogService
    ) {
        self.modelContainer = modelContainer
        self.backend = backend
        self.auditLog = auditLog
    }

    func enqueue(_ event: QueuedSyncEvent) throws {
        let context = ModelContext(modelContainer)
        let eventID = event.id
        var descriptor = FetchDescriptor<OfflineQueuedEvent>(
            predicate: #Predicate { $0.id == eventID }
        )
        descriptor.fetchLimit = 1
        if let stored = try context.fetch(descriptor).first {
            stored.aggregateType = event.aggregateType
            stored.aggregateID = event.aggregateID
            stored.eventType = event.eventType
            stored.payloadJSON = event.payloadJSON
            stored.localUpdatedAt = event.localUpdatedAt
            stored.stateRawValue = "pending"
            stored.lastErrorDescription = nil
        } else {
            context.insert(
                OfflineQueuedEvent(
                    id: event.id,
                    aggregateType: event.aggregateType,
                    aggregateID: event.aggregateID,
                    eventType: event.eventType,
                    payloadJSON: event.payloadJSON,
                    queuedAt: event.queuedAt,
                    localUpdatedAt: event.localUpdatedAt,
                    attemptCount: event.attemptCount
                )
            )
        }
        try context.save()
    }

    func pendingEvents() throws -> [QueuedSyncEvent] {
        let context = ModelContext(modelContainer)
        let pendingState = "pending"
        let descriptor = FetchDescriptor<OfflineQueuedEvent>(
            predicate: #Predicate { $0.stateRawValue == pendingState },
            sortBy: [SortDescriptor(\.queuedAt)]
        )
        return try context.fetch(descriptor).map(Self.value)
    }

    func synchronize() async throws -> SyncReport {
        let pending = try pendingEvents()
        let pushResult: CloudPushResult
        do {
            pushResult = try await backend.push(pending)
        } catch {
            try markFailedAttempt(eventIDs: Set(pending.map(\.id)), error: error)
            throw error
        }

        let context = ModelContext(modelContainer)
        let conflictsByID = Dictionary(
            uniqueKeysWithValues: pushResult.conflicts.map { ($0.localEventID, $0) }
        )
        var uploadedCount = 0
        var conflictCount = 0

        for event in pending {
            let eventID = event.id
            var descriptor = FetchDescriptor<OfflineQueuedEvent>(
                predicate: #Predicate { $0.id == eventID }
            )
            descriptor.fetchLimit = 1
            guard let stored = try context.fetch(descriptor).first else { continue }

            if let conflict = conflictsByID[event.id] {
                conflictCount += 1
                let remoteWins = conflict.remoteUpdatedAt > event.localUpdatedAt
                if remoteWins {
                    stored.payloadJSON = conflict.remotePayloadJSON
                    stored.remoteUpdatedAt = conflict.remoteUpdatedAt
                }
                try await auditLog.record(
                    AuditEvent(
                        id: UUID().uuidString,
                        actorID: nil,
                        category: "synchronisation",
                        action: "last_writer_wins_conflict_resolved",
                        timestamp: .now,
                        metadata: [
                            "aggregateType": event.aggregateType,
                            "winner": remoteWins ? "remote" : "local"
                        ]
                    )
                )
                context.delete(stored)
                uploadedCount += remoteWins ? 0 : 1
            } else if pushResult.acceptedEventIDs.contains(event.id) {
                context.delete(stored)
                uploadedCount += 1
            }
        }
        try context.save()

        let remoteChanges = try await backend.pullChanges(since: lastSuccessfulPullAt)
        lastSuccessfulPullAt = .now
        return SyncReport(
            completedAt: .now,
            uploadedRecordCount: uploadedCount,
            downloadedRecordCount: remoteChanges.count,
            conflictCount: conflictCount
        )
    }

    private func markFailedAttempt(eventIDs: Set<String>, error: any Error) throws {
        guard !eventIDs.isEmpty else { return }
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<OfflineQueuedEvent>()
        for event in try context.fetch(descriptor) where eventIDs.contains(event.id) {
            event.attemptCount += 1
            event.lastErrorDescription = String(describing: error)
        }
        try context.save()
    }

    private static func value(_ event: OfflineQueuedEvent) -> QueuedSyncEvent {
        QueuedSyncEvent(
            id: event.id,
            aggregateType: event.aggregateType,
            aggregateID: event.aggregateID,
            eventType: event.eventType,
            payloadJSON: event.payloadJSON,
            queuedAt: event.queuedAt,
            localUpdatedAt: event.localUpdatedAt,
            attemptCount: event.attemptCount
        )
    }
}
