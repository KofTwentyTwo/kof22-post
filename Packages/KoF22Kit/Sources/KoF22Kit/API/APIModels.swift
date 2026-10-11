import Foundation
@_exported import KoF22API

// The generated schema types are the domain model. When the spec changes, code that
// depends on a changed field stops compiling, which is exactly what we want.
public typealias Post = Components.Schemas.AuthoringPost
public typealias PostStatus = Components.Schemas.PostStatus
public typealias PostCreate = Components.Schemas.PostCreate
public typealias PostUpdate = Components.Schemas.PostUpdate
public typealias PostPage = Components.Schemas.PostPage
public typealias PostPhoto = Components.Schemas.PostPhoto
public typealias PostLink = Components.Schemas.PostLink
public typealias MediaAttachment = Components.Schemas.MediaAttachment
public typealias Me = Components.Schemas.Me
public typealias BlogRef = Components.Schemas.BlogRef
public typealias AuthoringLimits = Components.Schemas.AuthoringLimits
public typealias AuthoringTag = Components.Schemas.AuthoringTag
public typealias LinkPreview = Components.Schemas.LinkPreview
public typealias UploadCreate = Components.Schemas.UploadCreate
public typealias UploadTicket = Components.Schemas.UploadTicket
public typealias UploadComplete = Components.Schemas.UploadComplete
public typealias MediaItem = Components.Schemas.MediaItem
public typealias APIVersions = Components.Schemas.Versions

extension Components.Schemas.AuthoringPost: Identifiable {}
extension Components.Schemas.BlogRef: Identifiable {}
extension Components.Schemas.AuthoringTag: Identifiable {}

extension Components.Schemas.PostStatus {
    public var label: String {
        switch self {
        case .draft: "Draft"
        case .scheduled: "Scheduled"
        case .published: "Published"
        }
    }
}

extension Components.Schemas.AuthoringLimits {
    /// Used before `/me` has loaded (values from the backend's `AuthoringService`).
    public static let fallback = AuthoringLimits(
        maxBodyLength: 10_000,
        maxTitleLength: 100,
        maxTags: 10,
        maxPhotosPerPost: 20,
        maxPhotoBytes: 26_214_400,
        photoContentTypes: ["image/jpeg", "image/png"]
    )
}
