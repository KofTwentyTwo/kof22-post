import Foundation

/// A photo attached to a composition. Local photos have a `fileName` in
/// `SharedContainer.photosDirectory` until they are uploaded and get a `mediaId`.
public struct ComposedPhoto: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var fileName: String?
    public var mediaId: Int64?
    public var remoteURL: String?
    public var altText: String
    public var caption: String

    public init(id: UUID = UUID(), fileName: String? = nil, mediaId: Int64? = nil, remoteURL: String? = nil,
                altText: String = "", caption: String = "") {
        self.id = id
        self.fileName = fileName
        self.mediaId = mediaId
        self.remoteURL = remoteURL
        self.altText = altText
        self.caption = caption
    }

    public var isUploaded: Bool { mediaId != nil }

    public func localURL(in directory: URL = SharedContainer.photosDirectory) -> URL? {
        fileName.map { directory.appending(path: $0) }
    }
}

/// What the user wrote, independent of whether it has been sent yet.
public struct PostComposition: Codable, Sendable, Equatable {
    public var blog: String
    public var title: String
    public var body: String
    public var tags: [String]
    public var linkURL: String
    public var locationLabel: String
    public var keepLocation: Bool
    public var status: PostStatus
    public var publishAt: Date?
    public var photos: [ComposedPhoto]
    /// For edits: whether the server copy had a link, so removing it sends `null`.
    public var originalHadLink: Bool

    public init(blog: String = "quick-bits", title: String = "", body: String = "", tags: [String] = [],
                linkURL: String = "", locationLabel: String = "", keepLocation: Bool = false,
                status: PostStatus = .published, publishAt: Date? = nil, photos: [ComposedPhoto] = [],
                originalHadLink: Bool = false) {
        self.blog = blog
        self.title = title
        self.body = body
        self.tags = tags
        self.linkURL = linkURL
        self.locationLabel = locationLabel
        self.keepLocation = keepLocation
        self.status = status
        self.publishAt = publishAt
        self.photos = photos
        self.originalHadLink = originalHadLink
    }

    /// Starts an edit from a server post.
    public init(post: Post) {
        self.init(
            blog: post.blog, title: post.title, body: post.body, tags: post.tags,
            linkURL: post.link?.url ?? "", locationLabel: post.locationLabel ?? "",
            status: post.status, publishAt: post.publishAt,
            photos: post.media.map {
                ComposedPhoto(mediaId: $0.mediaId, remoteURL: $0.thumbnailUrl ?? $0.url,
                              altText: $0.altText ?? "", caption: $0.caption ?? "")
            },
            originalHadLink: post.link != nil
        )
    }

    public var isEmpty: Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && photos.isEmpty && linkURL.isEmpty
    }

    /// Short label for lists and notifications.
    public var summary: String {
        let title = title.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty { return title }
        let derived = MockBackend.deriveTitle(body)
        return derived == "Field note" && !photos.isEmpty ? "\(photos.count) photo post" : derived
    }

    /// The server requires a body; a photo or link-only post gets a minimal one.
    var bodyForServer: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return body }
        if !linkURL.isEmpty { return linkURL }
        return photos.isEmpty ? body : "📷"
    }

    var mediaAttachments: [MediaAttachment] {
        photos.compactMap { photo in
            photo.mediaId.map {
                MediaAttachment(mediaId: $0, altText: photo.altText.nilIfBlank, caption: photo.caption.nilIfBlank)
            }
        }
    }

    public func validationMessage(limits: AuthoringLimits) -> String? {
        if isEmpty { return "Write something, add a photo or a link." }
        if body.count > limits.maxBodyLength { return "Posts are limited to \(limits.maxBodyLength) characters." }
        if title.count > limits.maxTitleLength { return "Titles are limited to \(limits.maxTitleLength) characters." }
        if tags.count > limits.maxTags { return "At most \(limits.maxTags) tags." }
        if photos.count > limits.maxPhotosPerPost { return "At most \(limits.maxPhotosPerPost) photos per post." }
        if status == .scheduled {
            guard let publishAt else { return "Pick a time to schedule." }
            if publishAt.timeIntervalSinceNow < 60 { return "Schedule at least a minute ahead." }
        }
        if !linkURL.isEmpty, URL(string: linkURL)?.scheme?.hasPrefix("http") != true {
            return "Links must start with http:// or https://"
        }
        return nil
    }

    func createBody() -> PostCreate {
        PostCreate(
            blog: blog,
            title: title.nilIfBlank,
            body: bodyForServer,
            status: status,
            publishAt: status == .scheduled ? publishAt : nil,
            tags: tags,
            locationLabel: locationLabel.nilIfBlank,
            linkUrl: linkURL.nilIfBlank,
            media: mediaAttachments
        )
    }

    /// Full-state update: the server treats blank title as "derive" and blank
    /// location as "clear"; a removed link needs an explicit null (`clearLink`).
    func updateBody() -> (PostUpdate, clearLink: Bool) {
        let update = PostUpdate(
            blog: blog,
            title: title.trimmingCharacters(in: .whitespaces),
            body: bodyForServer,
            status: status,
            publishAt: status == .scheduled ? publishAt : nil,
            tags: tags,
            locationLabel: locationLabel.trimmingCharacters(in: .whitespaces),
            linkUrl: linkURL.nilIfBlank,
            media: mediaAttachments
        )
        return (update, linkURL.nilIfBlank == nil && originalHadLink)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
