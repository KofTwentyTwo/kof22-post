import Foundation
import SwiftData

/// A Sendable copy of an `OutboxItem` for work off the main actor.
public struct OutboxSnapshot: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var operation: OutboxOperation
    public var state: OutboxState
    public var composition: PostComposition
    public var serverPostID: Int64?
    public var ifMatch: String?
    public var idempotencyKey: String
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var lastError: String?
    public var isConflict: Bool
    public var resultURL: String?

    init(_ item: OutboxItem) {
        id = item.id
        operation = item.operation
        state = item.state
        composition = item.composition
        serverPostID = item.serverPostID
        ifMatch = item.ifMatch
        idempotencyKey = item.idempotencyKey
        attempts = item.attempts
        nextAttemptAt = item.nextAttemptAt
        lastError = item.lastError
        isConflict = item.isConflict
        resultURL = item.resultURL
    }
}

/// All outbox writes go through this actor so the app, the processor and the
/// Share Extension never race on the same context.
@ModelActor
public actor OutboxStore {
    private func item(_ id: UUID) throws -> OutboxItem? {
        try modelContext.fetch(FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.id == id })).first
    }

    @discardableResult
    public func enqueue(_ composition: PostComposition, operation: OutboxOperation, serverPostID: Int64? = nil,
                        ifMatch: String? = nil, replacing draftID: UUID? = nil) throws -> UUID {
        if let draftID, let draft = try item(draftID) {
            draft.composition = composition
            draft.operationRaw = operation.rawValue
            draft.serverPostID = serverPostID
            draft.ifMatch = ifMatch
            draft.state = .queued
            draft.updatedAt = .now
            try modelContext.save()
            return draftID
        }
        let item = OutboxItem(operation: operation, state: .queued, composition: composition,
                              serverPostID: serverPostID, ifMatch: ifMatch)
        modelContext.insert(item)
        try modelContext.save()
        return item.id
    }

    /// Autosave for the composer. Returns the draft's id.
    @discardableResult
    public func saveLocalDraft(_ composition: PostComposition, id: UUID?) throws -> UUID {
        if let id, let existing = try item(id) {
            existing.composition = composition
            existing.updatedAt = .now
            try modelContext.save()
            return id
        }
        let item = OutboxItem(operation: .create, state: .localDraft, composition: composition)
        modelContext.insert(item)
        try modelContext.save()
        return item.id
    }

    public func snapshot(_ id: UUID) throws -> OutboxSnapshot? {
        try item(id).map(OutboxSnapshot.init)
    }

    /// Items ready to send now, oldest first. Items stuck in `sending` (the app was
    /// killed mid-send) are picked up again; idempotency keys make that safe.
    public func due(now: Date = .now) throws -> [OutboxSnapshot] {
        let queued = OutboxState.queued.rawValue
        let sending = OutboxState.sending.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw == queued || $0.stateRaw == sending },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return try modelContext.fetch(descriptor)
            .filter { ($0.nextAttemptAt ?? .distantPast) <= now }
            .map(OutboxSnapshot.init)
    }

    public func nextWakeDate() throws -> Date? {
        let queued = OutboxState.queued.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.stateRaw == queued })
        return try modelContext.fetch(descriptor).compactMap(\.nextAttemptAt).min()
    }

    public func update(_ id: UUID, _ change: @Sendable (OutboxItem) -> Void) throws {
        guard let item = try item(id) else { return }
        change(item)
        item.updatedAt = .now
        try modelContext.save()
    }

    /// Manual retry from the Outbox screen.
    public func retry(_ id: UUID) throws {
        try update(id) { item in
            item.state = .queued
            item.attempts = 0
            item.nextAttemptAt = nil
            item.lastError = nil
        }
    }

    /// "Send now": everything queued or failed becomes due immediately.
    public func retryAll() throws {
        let queued = OutboxState.queued.rawValue
        let failed = OutboxState.failed.rawValue
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.stateRaw == queued || $0.stateRaw == failed })
        for item in try modelContext.fetch(descriptor) where !item.isConflict {
            item.state = .queued
            item.nextAttemptAt = nil
            item.attempts = 0
        }
        try modelContext.save()
    }

    public func delete(_ id: UUID) throws {
        guard let item = try item(id) else { return }
        for photo in item.composition.photos {
            if let url = photo.localURL() { try? FileManager.default.removeItem(at: url) }
        }
        modelContext.delete(item)
        try modelContext.save()
    }

    /// Drops sent items older than `age`, keeping the list short.
    public func pruneSent(olderThan age: TimeInterval = 7 * 24 * 3600) throws {
        let sent = OutboxState.sent.rawValue
        let cutoff = Date.now.addingTimeInterval(-age)
        let descriptor = FetchDescriptor<OutboxItem>(predicate: #Predicate { $0.stateRaw == sent && $0.updatedAt < cutoff })
        for item in try modelContext.fetch(descriptor) { modelContext.delete(item) }
        try modelContext.save()
    }

    public func cache(_ posts: [Post]) throws {
        for post in posts {
            let id = post.id
            if let existing = try modelContext.fetch(FetchDescriptor<CachedPost>(predicate: #Predicate { $0.postID == id })).first {
                existing.update(from: post)
            } else {
                modelContext.insert(CachedPost(post: post))
            }
        }
        try modelContext.save()
    }

    public func removeCached(_ postID: Int64) throws {
        try modelContext.delete(model: CachedPost.self, where: #Predicate { $0.postID == postID })
        try modelContext.save()
    }

    public func cachedPosts() throws -> [Post] {
        try modelContext.fetch(FetchDescriptor<CachedPost>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
            .compactMap(\.post)
    }

    public func pendingCount() throws -> Int {
        let sent = OutboxState.sent.rawValue
        let draft = OutboxState.localDraft.rawValue
        return try modelContext.fetchCount(FetchDescriptor<OutboxItem>(
            predicate: #Predicate { $0.stateRaw != sent && $0.stateRaw != draft }
        ))
    }
}
