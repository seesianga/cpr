import Foundation
import SwiftData
import XCTest
@testable import LifesaverVision

@MainActor
final class AuditAndSyncTests: XCTestCase {
    func testAuditLogBuildsHashChainAndDetectsPersistedTampering() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let auditLog = SwiftDataRepositoryStore(modelContainer: container)

        for index in 0..<3 {
            try await auditLog.record(
                auditEvent(index: index, id: "audit-\(index)")
            )
        }

        let events = try await auditLog.events()
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.first?.previousHash, "")
        XCTAssertTrue(events.allSatisfy { !$0.entryHash.isEmpty })
        XCTAssertEqual(events[1].previousHash, events[0].entryHash)
        XCTAssertEqual(events[2].previousHash, events[1].entryHash)
        let initiallyValid = try await auditLog.verifyIntegrity()
        XCTAssertTrue(initiallyValid)

        let context = ModelContext(container)
        var descriptor = FetchDescriptor<AuditLogEntry>(
            sortBy: [SortDescriptor(\.sequenceNumber)]
        )
        descriptor.fetchLimit = 3
        let persisted = try context.fetch(descriptor)
        persisted[1].action = "tampered-action"
        try context.save()

        let freshVerifier = SwiftDataRepositoryStore(modelContainer: container)
        let validAfterTampering = try await freshVerifier.verifyIntegrity()
        XCTAssertFalse(validAfterTampering)
    }

    func testConcurrentAuditWritesRemainSequentialAndValid() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let auditLog = SwiftDataRepositoryStore(modelContainer: container)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                let event = auditEvent(index: index, id: "concurrent-audit-\(index)")
                group.addTask {
                    try await auditLog.record(event)
                }
            }
            try await group.waitForAll()
        }

        let events = try await auditLog.events()
        XCTAssertEqual(events.count, 12)
        XCTAssertEqual(Set(events.map(\.id)).count, 12)
        let isValid = try await auditLog.verifyIntegrity()
        XCTAssertTrue(isValid)
        for index in events.indices.dropFirst() {
            XCTAssertEqual(events[index].previousHash, events[index - 1].entryHash)
        }
    }

    func testNoopBackendLeavesDurableEventPending() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let auditLog = SwiftDataRepositoryStore(modelContainer: container)
        let service = OfflineFirstSyncService(
            modelContainer: container,
            backend: NoopCloudBackend(),
            auditLog: auditLog
        )
        let event = syncEvent(id: "pending-event", updatedAt: Date(timeIntervalSince1970: 100))

        try await service.enqueue(event)
        let report = try await service.synchronize()

        XCTAssertEqual(report.uploadedRecordCount, 0)
        XCTAssertEqual(report.downloadedRecordCount, 0)
        XCTAssertEqual(report.conflictCount, 0)
        let pending = try await service.pendingEvents()
        let auditEvents = try await auditLog.events()
        XCTAssertEqual(pending, [event])
        XCTAssertTrue(auditEvents.isEmpty)
    }

    func testAcceptingBackendDrainsQueueAndCountsRemoteChanges() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let auditLog = SwiftDataRepositoryStore(modelContainer: container)
        let backend = AcceptingTestCloudBackend(
            changes: [
                CloudChange(
                    id: "remote-change-1",
                    aggregateType: "progress",
                    aggregateID: "learner-remote",
                    payloadJSON: "{}",
                    updatedAt: Date(timeIntervalSince1970: 300)
                )
            ]
        )
        let service = OfflineFirstSyncService(
            modelContainer: container,
            backend: backend,
            auditLog: auditLog
        )
        let events = [
            syncEvent(id: "accepted-1", updatedAt: Date(timeIntervalSince1970: 100)),
            syncEvent(id: "accepted-2", updatedAt: Date(timeIntervalSince1970: 200))
        ]
        for event in events {
            try await service.enqueue(event)
        }

        let report = try await service.synchronize()

        XCTAssertEqual(report.uploadedRecordCount, 2)
        XCTAssertEqual(report.downloadedRecordCount, 1)
        XCTAssertEqual(report.conflictCount, 0)
        let pending = try await service.pendingEvents()
        XCTAssertTrue(pending.isEmpty)
    }

    func testLastWriterWinsConflictsDrainQueueAndAppendAuditEntries() async throws {
        let container = try PersistenceBootstrap.makeModelContainer(inMemory: true)
        let auditLog = SwiftDataRepositoryStore(modelContainer: container)
        let localWins = syncEvent(
            id: "local-wins",
            updatedAt: Date(timeIntervalSince1970: 300)
        )
        let remoteWins = syncEvent(
            id: "remote-wins",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let backend = ConflictingTestCloudBackend(
            conflicts: [
                SyncConflict(
                    localEventID: localWins.id,
                    remotePayloadJSON: "{\"winner\":\"remote-old\"}",
                    remoteUpdatedAt: Date(timeIntervalSince1970: 200)
                ),
                SyncConflict(
                    localEventID: remoteWins.id,
                    remotePayloadJSON: "{\"winner\":\"remote-new\"}",
                    remoteUpdatedAt: Date(timeIntervalSince1970: 400)
                )
            ]
        )
        let service = OfflineFirstSyncService(
            modelContainer: container,
            backend: backend,
            auditLog: auditLog
        )
        try await service.enqueue(localWins)
        try await service.enqueue(remoteWins)

        let report = try await service.synchronize()

        XCTAssertEqual(report.uploadedRecordCount, 1)
        XCTAssertEqual(report.conflictCount, 2)
        let pending = try await service.pendingEvents()
        XCTAssertTrue(pending.isEmpty)

        let auditEvents = try await auditLog.events()
        XCTAssertEqual(auditEvents.count, 2)
        XCTAssertTrue(auditEvents.allSatisfy {
            $0.category == "synchronisation" &&
            $0.action == "last_writer_wins_conflict_resolved"
        })
        XCTAssertEqual(Set(auditEvents.compactMap { $0.metadata["winner"] }), ["local", "remote"])
        let isValid = try await auditLog.verifyIntegrity()
        XCTAssertTrue(isValid)
    }

    private func auditEvent(index: Int, id: String) -> AuditEvent {
        AuditEvent(
            id: id,
            actorID: "admin-test",
            category: "test",
            action: "action-\(index)",
            timestamp: Date(timeIntervalSince1970: Double(index + 1)),
            metadata: ["index": String(index)]
        )
    }

    private func syncEvent(id: String, updatedAt: Date) -> QueuedSyncEvent {
        QueuedSyncEvent(
            id: id,
            aggregateType: "progress",
            aggregateID: "learner-1",
            eventType: "upsert",
            payloadJSON: "{\"completion\":0.5}",
            queuedAt: Date(timeIntervalSince1970: 50),
            localUpdatedAt: updatedAt,
            attemptCount: 0
        )
    }
}

private struct AcceptingTestCloudBackend: CloudBackend {
    let changes: [CloudChange]

    func push(_ events: [QueuedSyncEvent]) async throws -> CloudPushResult {
        CloudPushResult(acceptedEventIDs: Set(events.map(\.id)))
    }

    func pullChanges(since: Date?) async throws -> [CloudChange] {
        changes
    }
}

private struct ConflictingTestCloudBackend: CloudBackend {
    let conflicts: [SyncConflict]

    func push(_ events: [QueuedSyncEvent]) async throws -> CloudPushResult {
        CloudPushResult(conflicts: conflicts)
    }

    func pullChanges(since: Date?) async throws -> [CloudChange] {
        []
    }
}
