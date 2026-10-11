import CryptoKit
import Foundation
import ImageIO

/// An in-process stand-in for the Site API v1 authoring endpoints, following the
/// behaviour documented in Website-Backend (`AuthoringService`, `MediaUploadService`,
/// `IdempotencyStore`): validation limits, idempotent replays, ETag/If-Match,
/// scheduled publishing, presigned uploads and the error envelope.
///
/// It works on the generated schema types, so a spec change that the mock does not
/// follow fails to compile. State is persisted as JSON when a directory is given.
public actor MockBackend {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data?
        public var headers: [String: String] = [:]
    }

    struct StoredUpload: Codable {
        var fileName: String
        var contentType: String
        var byteSize: Int64
        var expiresAt: Date
        var receivedFile: String?
        var mediaId: Int64?
    }

    struct StoredMedia: Codable {
        var file: String
        var mimeType: String
        var width: Int?
        var height: Int?
        var altText: String?
    }

    struct Replay: Codable {
        var bodyHash: String
        var status: Int
        var body: Data?
        var headers: [String: String]
    }

    struct State: Codable {
        var nextPostId: Int64 = 1
        var nextMediaId: Int64 = 1
        var nextTagId: Int64 = 100
        var posts: [Post] = []
        var tags: [AuthoringTag] = []
        var uploads: [String: StoredUpload] = [:]
        var media: [Int64: StoredMedia] = [:]
        var replays: [String: Replay] = [:]
    }

    public static let blogs: [BlogRef] = [
        BlogRef(id: 1, slug: "quick-bits", name: "Quick Bits", isDefault: true),
        BlogRef(id: 2, slug: "deep-thoughts", name: "Deep Thoughts", isDefault: false),
    ]
    static let mediaScheme = "mock-media"

    private var state = State()
    private let directory: URL?
    private let now: @Sendable () -> Date
    private let latency: Duration
    /// When true every request fails like a device with no connection.
    public var simulateOffline = false

    public init(directory: URL?, latency: Duration = .zero, now: @escaping @Sendable () -> Date = { .now }) {
        self.directory = directory
        self.latency = latency
        self.now = now
        if let directory,
           let data = try? Data(contentsOf: directory.appending(path: "state.json")),
           let saved = try? Self.decoder.decode(State.self, from: data) {
            state = saved
        } else {
            state = Self.seed(now: now())
        }
    }

    public func setSimulateOffline(_ value: Bool) { simulateOffline = value }

    public func reset() {
        state = Self.seed(now: now())
        if let directory { try? FileManager.default.removeItem(at: directory.appending(path: "media")) }
        save()
    }

    // MARK: - Dispatch

    /// Handles one request. `pathParameters` come from the route (postId, uploadId).
    public func handle(operation: String, method: String, path: String, query: [String: String],
                       headers: [String: String], body: Data?) async throws -> Response {
        if latency > .zero { try await Task.sleep(for: latency) }
        if simulateOffline { throw URLError(.notConnectedToInternet) }
        promoteScheduled()
        let segments = path.split(separator: "/").map(String.init)
        defer { save() }
        switch operation {
        case "getApiVersions": return json(200, versions())
        case "getMe": return json(200, me())
        case "listMyPosts": return try listPosts(query)
        case "createPost":
            return try idempotent("createPost", headers: headers, body: body) { try createPost(body) }
        case "getMyPost": return try withPost(segments) { json(200, $0, etag: $0.version) }
        case "updatePost": return try updatePost(postID(segments), headers: headers, body: body)
        case "deletePost": return try deletePost(postID(segments), headers: headers)
        case "createUpload":
            return try idempotent("createUpload", headers: headers, body: body) { try createUpload(body) }
        case "completeUpload": return try completeUpload(segments.dropLast().last ?? "", body: body)
        case "listMyTags": return listTags(query)
        case "getLinkPreview": return try linkPreview(body)
        default: return problem(404, "not_found", "No such endpoint")
        }
    }

    /// Receives the bytes PUT to a presigned upload URL.
    public func receiveUpload(id: String, from fileURL: URL) throws {
        guard var upload = state.uploads[id] else { throw APIError(status: 403, code: "forbidden", message: "Unknown upload URL") }
        guard upload.expiresAt > now() else { throw APIError(status: 403, code: "forbidden", message: "Upload URL expired") }
        let name = "upload-\(id)"
        let target = mediaDirectory().appending(path: name)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: fileURL, to: target)
        upload.receivedFile = name
        state.uploads[id] = upload
        save()
    }

    /// Resolves the `mock-media:` URLs stored in posts to files on disk.
    public nonisolated func fileURL(forMockMedia url: String, directory base: URL) -> URL? {
        guard url.hasPrefix(Self.mediaScheme + ":") else { return nil }
        return base.appending(path: "media").appending(path: String(url.dropFirst(Self.mediaScheme.count + 1)))
    }

    // MARK: - Me and versions

    func me() -> Me {
        Me(
            email: "james@kof22.com",
            name: "James Maes",
            groups: ["kof22-admins"],
            author: .init(id: 1, name: "James Maes", slug: "james-maes"),
            canPost: true,
            blogs: Self.blogs,
            defaultBlog: "quick-bits",
            limits: .fallback
        )
    }

    func versions() -> APIVersions {
        APIVersions(
            currentVersion: "v1",
            supportedVersions: ["v1"],
            versions: [.init(version: "v1", semver: "1.0.0 (mock)", status: .current,
                             docsUrl: "https://api.kof22.com/v1/", openapiUrl: "https://api.kof22.com/v1/openapi.json")]
        )
    }

    // MARK: - Posts

    private func listPosts(_ query: [String: String]) throws -> Response {
        var posts = state.posts
        if let status = query["status"] {
            guard let wanted = PostStatus(rawValue: status) else { return problem(400, "bad_request", "Unknown status") }
            posts = posts.filter { $0.status == wanted }
        }
        posts.sort { ($0.updatedAt ?? .distantPast, $0.id) > ($1.updatedAt ?? .distantPast, $1.id) }
        let limit = min(max(Int(query["limit"] ?? "") ?? 20, 1), 50)
        var offset = 0
        if let cursor = query["cursor"] {
            guard let data = Data(base64Encoded: cursor), let value = Int(String(decoding: data, as: UTF8.self)) else {
                return problem(400, "bad_request", "Invalid cursor")
            }
            offset = value
        }
        let page = Array(posts.dropFirst(offset).prefix(limit)).map(resolved)
        let next = offset + page.count < posts.count ? Data(String(offset + page.count).utf8).base64EncodedString() : nil
        return json(200, PostPage(items: page, nextCursor: next))
    }

    private func createPost(_ body: Data?) throws -> Response {
        guard let body, let input = try? Self.decoder.decode(PostCreate.self, from: body) else {
            return problem(400, "bad_request", "Body must be a JSON object")
        }
        var issues: [APIError.Detail] = []
        let limits = AuthoringLimits.fallback
        if input.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { issues.append(.init(field: "body", issue: "required")) }
        if input.body.count > limits.maxBodyLength { issues.append(.init(field: "body", issue: "at most \(limits.maxBodyLength) characters")) }
        if let title = input.title, title.count > limits.maxTitleLength { issues.append(.init(field: "title", issue: "at most \(limits.maxTitleLength) characters")) }
        if (input.locationLabel?.count ?? 0) > 200 { issues.append(.init(field: "locationLabel", issue: "at most 200 characters")) }
        let blog = try blog(input.blog, issues: &issues)
        let tags = normalizedTags(input.tags ?? [], issues: &issues)
        let status = input.status ?? .draft
        let publishAt = schedule(status: status, publishAt: input.publishAt, issues: &issues)
        let media = attachments(input.media ?? [], issues: &issues)
        let link = try input.linkUrl.flatMap { $0.isEmpty ? nil : try preview(for: $0, field: "linkUrl", issues: &issues) }
        guard issues.isEmpty else { return validation(issues) }

        let id = state.nextPostId
        state.nextPostId += 1
        let explicitTitle = input.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (explicitTitle?.isEmpty == false) ? explicitTitle! : Self.deriveTitle(input.body)
        let instant = now()
        var post = Post(
            id: id, blogId: blog.id, blog: blog.slug, status: status, title: title, body: input.body,
            slug: uniqueSlug(explicitTitle?.isEmpty == false ? Self.slugify(title) : Self.timestampSlug(instant), blogID: blog.id),
            publishAt: publishAt, tags: tags, locationLabel: Self.blankToNil(input.locationLabel),
            link: link, media: media, createdAt: instant, updatedAt: instant, version: Self.newVersion()
        )
        if status == .published { publish(&post) }
        registerTags(tags, blogID: blog.id)
        state.posts.append(post)
        return json(201, resolved(post), etag: post.version,
                    extra: ["Location": "https://api.kof22.com/v1/me/posts/\(id)"])
    }

    private func updatePost(_ id: Int64?, headers: [String: String], body: Data?) throws -> Response {
        guard let id, let index = state.posts.firstIndex(where: { $0.id == id }) else { return problem(404, "not_found", "Post not found") }
        guard let ifMatch = headers["if-match"], !ifMatch.isEmpty else {
            return problem(428, "precondition_required", "If-Match is required")
        }
        var post = state.posts[index]
        guard Self.matches(ifMatch, version: post.version) else {
            return problem(412, "precondition_failed", "The post changed since it was read", etag: post.version)
        }
        guard let body,
              let raw = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let input = try? Self.decoder.decode(PostUpdate.self, from: body) else {
            return problem(400, "bad_request", "Body must be a JSON object")
        }
        var issues: [APIError.Detail] = []
        if raw["body"] != nil {
            let text = input.body ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.count > 10_000 {
                issues.append(.init(field: "body", issue: "required, at most 10000 characters"))
            } else {
                post.body = text
            }
        }
        if raw["blog"] != nil {
            let blog = try blog(input.blog, issues: &issues)
            post.blog = blog.slug
            post.blogId = blog.id
        }
        if raw["title"] != nil {
            let title = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if title.count > 100 { issues.append(.init(field: "title", issue: "at most 100 characters")) }
            post.title = title.isEmpty ? Self.deriveTitle(post.body) : title
        }
        if raw["locationLabel"] != nil { post.locationLabel = Self.blankToNil(input.locationLabel) }
        if raw["tags"] != nil { post.tags = normalizedTags(input.tags ?? [], issues: &issues) }
        if raw["media"] != nil { post.media = attachments(input.media ?? [], issues: &issues) }
        if raw["linkUrl"] != nil {
            post.link = raw["linkUrl"] is NSNull ? nil : try preview(for: input.linkUrl ?? "", field: "linkUrl", issues: &issues)
        }
        if let status = input.status {
            let publishAt = schedule(status: status, publishAt: input.publishAt, issues: &issues)
            if issues.isEmpty {
                post.status = status
                post.publishAt = publishAt
                if status == .published, post.publishedAt == nil { publish(&post) }
                if status == .draft { post.publishedAt = nil; post.url = nil }
            }
        }
        guard issues.isEmpty else { return validation(issues) }
        registerTags(post.tags, blogID: post.blogId)
        post.updatedAt = now()
        post.version = Self.newVersion()
        state.posts[index] = post
        return json(200, resolved(post), etag: post.version)
    }

    private func deletePost(_ id: Int64?, headers: [String: String]) throws -> Response {
        guard let id, let index = state.posts.firstIndex(where: { $0.id == id }) else { return problem(404, "not_found", "Post not found") }
        if let ifMatch = headers["if-match"], !ifMatch.isEmpty, !Self.matches(ifMatch, version: state.posts[index].version) {
            return problem(412, "precondition_failed", "The post changed since it was read", etag: state.posts[index].version)
        }
        state.posts.remove(at: index)
        return Response(status: 204, body: nil)
    }

    private func withPost(_ segments: [String], _ body: (Post) -> Response) throws -> Response {
        guard let id = postID(segments), let post = state.posts.first(where: { $0.id == id }) else {
            return problem(404, "not_found", "Post not found")
        }
        return body(resolved(post))
    }

    private func postID(_ segments: [String]) -> Int64? { segments.last.flatMap { Int64($0) } }

    private func promoteScheduled() {
        let instant = now()
        for index in state.posts.indices where state.posts[index].status == .scheduled {
            if let at = state.posts[index].publishAt, at <= instant {
                state.posts[index].status = .published
                publish(&state.posts[index], at: at)
            }
        }
    }

    private func publish(_ post: inout Post, at date: Date? = nil) {
        post.status = .published
        post.publishedAt = date ?? now()
        post.url = "https://www.kof22.com/blogs/\(post.blog)/\(post.slug)"
    }

    private func blog(_ slug: String?, issues: inout [APIError.Detail]) throws -> BlogRef {
        let slug = slug ?? "quick-bits"
        if let blog = Self.blogs.first(where: { $0.slug == slug }) { return blog }
        issues.append(.init(field: "blog", issue: "unknown blog \(slug)"))
        return Self.blogs[0]
    }

    private func schedule(status: PostStatus, publishAt: Date?, issues: inout [APIError.Detail]) -> Date? {
        guard status == .scheduled else { return nil }
        guard let publishAt else {
            issues.append(.init(field: "publishAt", issue: "required when status is scheduled"))
            return nil
        }
        let delta = publishAt.timeIntervalSince(now())
        if delta < 30 { issues.append(.init(field: "publishAt", issue: "must be at least 30 seconds in the future")) }
        if delta > 366 * 24 * 3600 { issues.append(.init(field: "publishAt", issue: "must be within 366 days")) }
        return publishAt
    }

    private func normalizedTags(_ tags: [String], issues: inout [APIError.Detail]) -> [String] {
        if tags.count > 10 { issues.append(.init(field: "tags", issue: "at most 10 tags")) }
        var seen = Set<String>()
        var out: [String] = []
        for tag in tags {
            var name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("#") { name.removeFirst() }
            if name.isEmpty || name.count > 50 || Self.slugify(name).isEmpty {
                issues.append(.init(field: "tags", issue: "invalid tag '\(tag)'"))
                continue
            }
            if seen.insert(Self.slugify(name)).inserted { out.append(name) }
        }
        return out
    }

    private func registerTags(_ names: [String], blogID: Int64) {
        for name in names where !state.tags.contains(where: { $0.blogId == blogID && $0.slug == Self.slugify(name) }) {
            state.tags.append(AuthoringTag(id: state.nextTagId, name: name, slug: Self.slugify(name), blogId: blogID))
            state.nextTagId += 1
        }
    }

    private func attachments(_ items: [MediaAttachment], issues: inout [APIError.Detail]) -> [PostPhoto] {
        if items.count > 20 { issues.append(.init(field: "media", issue: "at most 20 photos")) }
        return items.compactMap { item in
            guard let media = state.media[item.mediaId] else {
                issues.append(.init(field: "media", issue: "unknown mediaId \(item.mediaId)"))
                return nil
            }
            let url = "\(Self.mediaScheme):\(media.file)"
            return PostPhoto(mediaId: item.mediaId, url: url, thumbnailUrl: url, width: media.width, height: media.height,
                             altText: item.altText ?? media.altText, caption: item.caption)
        }
    }

    private func uniqueSlug(_ base: String, blogID: Int64) -> String {
        var slug = base.isEmpty ? Self.timestampSlug(now()) : base
        var n = 2
        while state.posts.contains(where: { $0.blogId == blogID && $0.slug == slug }) {
            slug = "\(base)-\(n)"
            n += 1
        }
        return slug
    }

    /// Mock media URLs are rewritten to file URLs so the app can display them.
    private func resolved(_ post: Post) -> Post {
        guard let directory else { return post }
        var copy = post
        copy.media = post.media.map { photo in
            var photo = photo
            if let file = fileURL(forMockMedia: photo.url, directory: directory) { photo.url = file.absoluteString }
            if let thumb = photo.thumbnailUrl, let file = fileURL(forMockMedia: thumb, directory: directory) {
                photo.thumbnailUrl = file.absoluteString
            }
            return photo
        }
        return copy
    }

    // MARK: - Uploads

    private func createUpload(_ body: Data?) throws -> Response {
        guard let body, let input = try? Self.decoder.decode(UploadCreate.self, from: body) else {
            return problem(400, "bad_request", "Body must be a JSON object")
        }
        let limits = AuthoringLimits.fallback
        if input.contentType == .imageHeic || input.contentType == .imageHeif {
            return problem(415, "heic_conversion_unavailable", "HEIC is not accepted by this server; send JPEG")
        }
        if input.byteSize > limits.maxPhotoBytes {
            return problem(413, "payload_too_large", "Photos are limited to \(limits.maxPhotoBytes) bytes")
        }
        if input.byteSize <= 0 { return validation([.init(field: "byteSize", issue: "must be positive")]) }
        let id = UUID().uuidString.lowercased()
        let expires = now().addingTimeInterval(15 * 60)
        state.uploads[id] = StoredUpload(fileName: input.fileName, contentType: input.contentType.rawValue,
                                         byteSize: input.byteSize, expiresAt: expires)
        let ticket = UploadTicket(
            uploadId: id,
            uploadUrl: "https://mock.s3.kof22.invalid/kof22-website-incoming/\(id)",
            method: .put,
            headers: .init(additionalProperties: ["Content-Type": input.contentType.rawValue]),
            expiresAt: expires,
            maxBytes: limits.maxPhotoBytes,
            completeUrl: "https://api.kof22.com/v1/me/uploads/\(id)/complete"
        )
        return json(201, ticket)
    }

    private func completeUpload(_ id: String, body: Data?) throws -> Response {
        guard var upload = state.uploads[id] else { return problem(404, "not_found", "Upload not found") }
        let input = body.flatMap { try? Self.decoder.decode(UploadComplete.self, from: $0) } ?? UploadComplete()
        if let mediaId = upload.mediaId, let media = state.media[mediaId] {
            return json(200, mediaItem(mediaId, media, locationRemoved: !(input.keepLocation ?? false)))
        }
        guard let received = upload.receivedFile else {
            if upload.expiresAt < now() { return problem(409, "upload_expired", "The upload URL expired") }
            return problem(409, "upload_not_received", "No file has been uploaded yet")
        }
        let fileURL = mediaDirectory().appending(path: received)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return problem(415, "unsupported_media_type", "The uploaded file is not an image")
        }
        let mediaId = state.nextMediaId
        state.nextMediaId += 1
        let ext = upload.contentType == "image/png" ? "png" : "jpg"
        let file = "media-\(mediaId).\(ext)"
        try? FileManager.default.moveItem(at: fileURL, to: mediaDirectory().appending(path: file))
        let media = StoredMedia(file: file, mimeType: upload.contentType,
                                width: properties[kCGImagePropertyPixelWidth] as? Int,
                                height: properties[kCGImagePropertyPixelHeight] as? Int,
                                altText: Self.blankToNil(input.altText))
        state.media[mediaId] = media
        upload.mediaId = mediaId
        state.uploads[id] = upload
        return json(200, mediaItem(mediaId, media, locationRemoved: !(input.keepLocation ?? false)))
    }

    private func mediaItem(_ id: Int64, _ media: StoredMedia, locationRemoved: Bool) -> MediaItem {
        let url = directory.flatMap { fileURL(forMockMedia: "\(Self.mediaScheme):\(media.file)", directory: $0)?.absoluteString }
            ?? "\(Self.mediaScheme):\(media.file)"
        return MediaItem(mediaId: id, url: url, thumbnailUrl: url, width: media.width, height: media.height,
                         mimeType: media.mimeType, altText: media.altText, caption: nil, locationRemoved: locationRemoved)
    }

    private func mediaDirectory() -> URL {
        let base = directory ?? FileManager.default.temporaryDirectory.appending(path: "kof22-mock-\(ObjectIdentifier(self).hashValue)")
        let url = base.appending(path: "media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Tags and links

    private func listTags(_ query: [String: String]) -> Response {
        let blogSlug = query["blog"] ?? "quick-bits"
        let blogID = Self.blogs.first { $0.slug == blogSlug }?.id ?? 1
        let q = (query["q"] ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let limit = min(max(Int(query["limit"] ?? "") ?? 20, 1), 50)
        let tags = state.tags.filter { $0.blogId == blogID }
        let prefix = tags.filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }.sorted { $0.name < $1.name }
        let contains = tags.filter { !q.isEmpty && !$0.name.lowercased().hasPrefix(q) && $0.name.lowercased().contains(q) }
            .sorted { $0.name < $1.name }
        return json(200, Components.Schemas.TagList(items: Array((prefix + contains).prefix(limit))))
    }

    private func linkPreview(_ body: Data?) throws -> Response {
        guard let body, let input = try? Self.decoder.decode(Components.Schemas.LinkPreviewRequest.self, from: body) else {
            return problem(400, "bad_request", "Body must be a JSON object")
        }
        var issues: [APIError.Detail] = []
        guard let preview = try preview(for: input.url, field: "url", issues: &issues), issues.isEmpty else {
            return problem(422, "link_not_allowed", "Only public http(s) URLs can be previewed")
        }
        return json(200, LinkPreview(url: preview.url, title: preview.title, description: preview.description,
                                     imageUrl: preview.imageUrl))
    }

    private func preview(for raw: String, field: String, issues: inout [APIError.Detail]) throws -> PostLink? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty, host != "localhost" else {
            issues.append(.init(field: field, issue: "must be a public http(s) URL"))
            return nil
        }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return PostLink(url: url.absoluteString, title: "\(name) (mock preview)",
                        description: "Link previews are fetched server-side; this one comes from the mock API.",
                        imageUrl: nil)
    }

    // MARK: - Idempotency

    private func idempotent(_ operation: String, headers: [String: String], body: Data?,
                            perform: () throws -> Response) throws -> Response {
        guard let key = headers["idempotency-key"] else { return try perform() }
        guard (8...255).contains(key.count), key.allSatisfy({ $0.isLetter || $0.isNumber || "._:-".contains($0) }) else {
            return validation([.init(field: "Idempotency-Key", issue: "8-255 characters of [A-Za-z0-9._:-]")])
        }
        let hash = SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
        let slot = "\(operation):\(key)"
        if let replay = state.replays[slot] {
            guard replay.bodyHash == hash else {
                return problem(422, "idempotency_key_reused", "Idempotency-Key was used with a different body")
            }
            var headers = replay.headers
            headers["Idempotent-Replayed"] = "true"
            return Response(status: replay.status, body: replay.body, headers: headers)
        }
        let response = try perform()
        if (200..<300).contains(response.status) {
            state.replays[slot] = Replay(bodyHash: hash, status: response.status, body: response.body, headers: response.headers)
        }
        return response
    }

    // MARK: - Helpers

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func json(_ status: Int, _ value: some Encodable, etag: String? = nil, extra: [String: String] = [:]) -> Response {
        var headers = extra
        headers["Content-Type"] = "application/json"
        headers["X-API-Version"] = "1.0.0"
        if let etag { headers["ETag"] = "\"\(etag)\"" }
        return Response(status: status, body: try? Self.encoder.encode(value), headers: headers)
    }

    private func problem(_ status: Int, _ code: String, _ message: String,
                         details: [APIError.Detail] = [], etag: String? = nil) -> Response {
        let body = Components.Schemas._Error(error: .init(
            code: code, message: message, status: status,
            details: details.isEmpty ? nil : details.map { .init(field: $0.field, issue: $0.issue) }
        ))
        return json(status, body, etag: etag)
    }

    private func validation(_ issues: [APIError.Detail]) -> Response {
        problem(422, "validation_failed", issues.first.map { "\($0.field) \($0.issue)" } ?? "Validation failed", details: issues)
    }

    private func save() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(state) {
            try? data.write(to: directory.appending(path: "state.json"), options: .atomic)
        }
    }

    static func matches(_ ifMatch: String, version: String) -> Bool {
        ifMatch.split(separator: ",").contains { raw in
            var tag = raw.trimmingCharacters(in: .whitespaces)
            if tag == "*" { return true }
            if tag.hasPrefix("W/") { tag.removeFirst(2) }
            return tag.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == version
        }
    }

    static func newVersion() -> String {
        (0..<10).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func blankToNil(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// First non-empty line without markdown punctuation, at most 100 characters.
    public static func deriveTitle(_ body: String) -> String {
        let line = body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var text = line.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+|\d+\.\s+)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "Field note" }
        return text.count > 100 ? String(text.prefix(100)).trimmingCharacters(in: .whitespaces) : text
    }

    public static func slugify(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        let slug = folded.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(slug.prefix(80))
    }

    static func timestampSlug(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static func seed(now: Date) -> State {
        var state = State()
        for (blogID, names) in [(Int64(1), ["Apple", "Linux", "Programming", "Swift", "Unix"]), (2, ["Apple", "Unix"])] {
            for name in names {
                state.tags.append(AuthoringTag(id: state.nextTagId, name: name, slug: slugify(name), blogId: blogID))
                state.nextTagId += 1
            }
        }
        let samples: [(String, String?, PostStatus, [String], TimeInterval)] = [
            ("Welcome to the **mock** Site API. Posts you write here stay on this device.", nil, .published, ["Swift"], -7200),
            ("Draft about `launchctl` quirks I keep forgetting.", nil, .draft, ["Unix"], -3600),
        ]
        for (body, title, status, tags, offset) in samples {
            let date = now.addingTimeInterval(offset)
            let derived = title ?? deriveTitle(body)
            var post = Post(id: state.nextPostId, blogId: 1, blog: "quick-bits", status: status, title: derived, body: body,
                            slug: timestampSlug(date), tags: tags, media: [], createdAt: date, updatedAt: date,
                            version: newVersion())
            if status == .published {
                post.publishedAt = date
                post.url = "https://www.kof22.com/blogs/quick-bits/\(post.slug)"
            }
            state.posts.append(post)
            state.nextPostId += 1
        }
        return state
    }
}
