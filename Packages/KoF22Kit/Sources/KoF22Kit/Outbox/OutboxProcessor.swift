import Foundation

/// Posts outcome notifications (the app uses local notifications).
public protocol OutboxNotifier: Sendable {
    func posted(summary: String, status: PostStatus, url: String?) async
    func failed(summary: String, message: String) async
}

public struct SilentNotifier: OutboxNotifier {
    public init() {}
    public func posted(summary: String, status: PostStatus, url: String?) async {}
    public func failed(summary: String, message: String) async {}
}

/// Sends queued items: uploads photos (create ticket, PUT, complete), then creates,
/// updates or deletes the post. Every step is retry-safe:
///   - creates and upload tickets carry idempotency keys derived from the item;
///   - uploaded `mediaId`s are written back before the post call, so a retry
///     never uploads a photo twice;
///   - updates send `If-Match`, and a 412 stops for the user instead of overwriting.
public actor OutboxProcessor {
    public typealias ServiceProvider = @Sendable () async -> SiteService?

    private let store: OutboxStore
    private let service: ServiceProvider
    private let notifier: any OutboxNotifier
    private let photosDirectory: URL
    private let workDirectory: URL
    private let now: @Sendable () -> Date
    private var running = false
    private var rerun = false
    private var limits: AuthoringLimits?

    /// Attempts before an item stops retrying on its own.
    public static let maxAutomaticAttempts = 6

    public init(store: OutboxStore, service: @escaping ServiceProvider, notifier: any OutboxNotifier = SilentNotifier(),
                photosDirectory: URL = SharedContainer.photosDirectory,
                now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.service = service
        self.notifier = notifier
        self.photosDirectory = photosDirectory
        self.workDirectory = FileManager.default.temporaryDirectory.appending(path: "kof22-upload", directoryHint: .isDirectory)
        self.now = now
    }

    static func backoff(attempt: Int) -> TimeInterval {
        min(pow(2, Double(max(attempt - 1, 0))) * 5, 15 * 60)
    }

    /// Sends everything that is due. Concurrent calls coalesce into one more pass.
    public func drain() async {
        if running { rerun = true; return }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            guard let service = await service() else { return }
            let items = (try? await store.due(now: now())) ?? []
            for item in items {
                if Task.isCancelled { return }
                await process(item, service: service)
            }
        } while rerun
        try? await store.pruneSent()
    }

    func process(_ item: OutboxSnapshot, service: SiteService) async {
        let id = item.id
        try? await store.update(id) { $0.state = .sending; $0.phase = "Sending"; $0.lastError = nil }
        do {
            switch item.operation {
            case .delete:
                guard let postID = item.serverPostID else { throw APIError(status: 400, code: "bad_request", message: "Missing post id") }
                do {
                    try await service.deletePost(id: postID, ifMatch: item.ifMatch)
                } catch let error as APIError where error.status == 404 {
                    // Already gone: the goal is reached.
                }
                try? await store.removeCached(postID)
                try await store.update(id) { $0.state = .sent; $0.phase = nil; $0.progress = 1 }
            case .create, .update:
                let composition = try await uploadPhotos(item, service: service)
                let post: Post
                if item.operation == .create {
                    post = try await service.createPost(composition.createBody(), idempotencyKey: item.idempotencyKey)
                } else {
                    guard let postID = item.serverPostID, let ifMatch = item.ifMatch else {
                        throw APIError(status: 400, code: "bad_request", message: "Missing post id or version")
                    }
                    let (update, clearLink) = composition.updateBody()
                    post = try await service.updatePost(id: postID, update, clearLink: clearLink, ifMatch: ifMatch)
                }
                try? await store.cache([post])
                try await store.update(id) { item in
                    item.state = .sent
                    item.phase = nil
                    item.progress = 1
                    item.serverPostID = post.id
                    item.ifMatch = post.version
                    item.resultURL = post.url
                }
                for photo in composition.photos {
                    if let url = photo.localURL(in: photosDirectory) { try? FileManager.default.removeItem(at: url) }
                }
                await notifier.posted(summary: composition.summary, status: post.status, url: post.url)
            }
        } catch {
            await recordFailure(item, error: error)
        }
    }

    private func uploadPhotos(_ item: OutboxSnapshot, service: SiteService) async throws -> PostComposition {
        var composition = item.composition
        let pending = composition.photos.indices.filter { !composition.photos[$0].isUploaded }
        guard !pending.isEmpty else { return composition }
        let limits = try await currentLimits(service)
        for (done, index) in pending.enumerated() {
            let photo = composition.photos[index]
            try await store.update(item.id) {
                $0.phase = "Uploading photo \(done + 1) of \(pending.count)"
                $0.progress = Double(done) / Double(pending.count + 1)
            }
            guard let source = photo.localURL(in: photosDirectory), FileManager.default.fileExists(atPath: source.path()) else {
                throw APIError(status: 410, code: "photo_missing", message: "A photo for this post is no longer on the device")
            }
            let prepared = try MediaProcessor.prepare(
                source: source, keepLocation: composition.keepLocation,
                acceptedTypes: limits.photoContentTypes, maxBytes: limits.maxPhotoBytes, workDirectory: workDirectory
            )
            defer { try? FileManager.default.removeItem(at: prepared.fileURL) }
            // The attempt number keeps a retry after an expired ticket from replaying it.
            let key = "\(item.idempotencyKey)-p-\(photo.id.uuidString.prefix(8))-a\(item.attempts)"
            let ticket = try await service.createUpload(
                UploadCreate(fileName: prepared.fileURL.lastPathComponent, contentType: prepared.contentType,
                             byteSize: prepared.byteSize),
                idempotencyKey: key
            )
            try await service.putUpload(fileURL: prepared.fileURL, ticket: ticket)
            let media = try await service.completeUpload(
                id: ticket.uploadId,
                UploadComplete(altText: photo.altText.nilIfBlank, caption: photo.caption.nilIfBlank,
                               keepLocation: composition.keepLocation)
            )
            composition.photos[index].mediaId = media.mediaId
            composition.photos[index].remoteURL = media.thumbnailUrl ?? media.url
            let saved = composition
            try await store.update(item.id) { $0.composition = saved }
        }
        return composition
    }

    private func currentLimits(_ service: SiteService) async throws -> AuthoringLimits {
        if let limits { return limits }
        let fetched = try await service.me().limits
        limits = fetched
        return fetched
    }

    private func recordFailure(_ item: OutboxSnapshot, error: any Error) async {
        let message = ErrorClassifier.message(for: error)
        let disposition = ErrorClassifier.disposition(for: error)
        let attempts = item.attempts + 1
        let instant = now()
        let retrying: Bool
        if case .retryLater = disposition, attempts < Self.maxAutomaticAttempts { retrying = true } else { retrying = false }
        try? await store.update(item.id) { stored in
            stored.attempts = attempts
            stored.lastError = message
            stored.phase = nil
            if retrying, case .retryLater(let after) = disposition {
                stored.state = .queued
                stored.nextAttemptAt = instant.addingTimeInterval(after ?? Self.backoff(attempt: attempts))
            } else if disposition == .conflict {
                stored.state = .failed
                stored.isConflict = true
                stored.lastError = "This post changed on the server since you opened it."
            } else {
                stored.state = .failed
            }
        }
        if !retrying {
            await notifier.failed(summary: item.composition.summary, message: message)
        }
    }

    /// Resolves a 412 by taking the server's current version and sending again.
    public func overwrite(_ id: UUID) async {
        guard let service = await service(), let item = try? await store.snapshot(id), let postID = item.serverPostID else { return }
        do {
            let current = try await service.post(id: postID)
            try await store.update(id) { stored in
                stored.ifMatch = current.version
                stored.isConflict = false
                stored.state = .queued
                stored.attempts = 0
                stored.nextAttemptAt = nil
                stored.lastError = nil
            }
            await drain()
        } catch {
            await recordFailure(item, error: error)
        }
    }
}
