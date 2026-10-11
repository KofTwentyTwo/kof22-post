import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// PUTs photo bytes to a presigned upload URL.
public protocol UploadPerformer: Sendable {
    func put(fileURL: URL, to url: URL, headers: [String: String]) async throws
}

public struct URLSessionUploadPerformer: UploadPerformer {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 300
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError(status: http.statusCode, code: "upload_put_failed",
                           message: String(data: data.prefix(300), encoding: .utf8) ?? "Upload failed")
        }
    }
}

/// The hand-written layer over the generated client: auth, error mapping,
/// idempotency keys and ETags. Everything the app sends goes through here.
public struct SiteService: Sendable {
    let client: Client
    let uploader: any UploadPerformer

    public init(serverURL: URL, transport: any ClientTransport, auth: AuthSession, uploader: any UploadPerformer) {
        self.client = Client(
            serverURL: serverURL,
            transport: transport,
            middlewares: [ErrorEnvelopeMiddleware(), RawHeaderMiddleware(), ExplicitNullMiddleware(), AuthMiddleware(auth: auth)]
        )
        self.uploader = uploader
    }

    public static func live(config: AppConfig = .production, auth: AuthSession) -> SiteService {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
        return SiteService(
            serverURL: config.apiBaseURL,
            transport: URLSessionTransport(configuration: .init(session: session)),
            auth: auth,
            uploader: URLSessionUploadPerformer()
        )
    }

    public static func mock(backend: MockBackend, auth: AuthSession) -> SiteService {
        SiteService(
            serverURL: AppConfig.mockAPIBaseURL,
            transport: MockTransport(backend: backend),
            auth: auth,
            uploader: MockUploadPerformer(backend: backend)
        )
    }

    /// Unwraps errors thrown by middlewares out of the generator's `ClientError`.
    private func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as ClientError {
            throw error.underlyingError
        }
    }

    public func versions() async throws -> APIVersions {
        try await call { try await client.getApiVersions().ok.body.json }
    }

    public func me() async throws -> Me {
        try await call { try await client.getMe().ok.body.json }
    }

    public func myPosts(status: PostStatus? = nil, cursor: String? = nil, limit: Int = 20) async throws -> PostPage {
        try await call {
            try await client.listMyPosts(query: .init(status: status, cursor: cursor, limit: limit)).ok.body.json
        }
    }

    public func post(id: Int64) async throws -> Post {
        try await call { try await client.getMyPost(path: .init(postId: id)).ok.body.json }
    }

    public func createPost(_ post: PostCreate, idempotencyKey: String) async throws -> Post {
        try await call {
            try await client.createPost(headers: .init(idempotencyKey: idempotencyKey), body: .json(post))
                .created.body.json
        }
    }

    /// `clearLink` sends `"linkUrl": null`; `ifMatch` is the post's `version` or ETag.
    public func updatePost(id: Int64, _ update: PostUpdate, clearLink: Bool = false, ifMatch: String) async throws -> Post {
        var update = update
        if clearLink { update.linkUrl = ExplicitNullMiddleware.sentinel }
        return try await call {
            try await client.updatePost(
                path: .init(postId: id), headers: .init(ifMatch: Self.quoted(ifMatch)), body: .json(update)
            ).ok.body.json
        }
    }

    public func deletePost(id: Int64, ifMatch: String?) async throws {
        _ = try await call {
            try await client.deletePost(path: .init(postId: id), headers: .init(ifMatch: ifMatch.map(Self.quoted)))
                .noContent
        }
    }

    public func createUpload(_ upload: UploadCreate, idempotencyKey: String) async throws -> UploadTicket {
        try await call {
            try await client.createUpload(headers: .init(idempotencyKey: idempotencyKey), body: .json(upload))
                .created.body.json
        }
    }

    public func putUpload(fileURL: URL, ticket: UploadTicket) async throws {
        guard let url = URL(string: ticket.uploadUrl) else { throw URLError(.badURL) }
        try await uploader.put(fileURL: fileURL, to: url, headers: ticket.headers.additionalProperties)
    }

    public func completeUpload(id: String, _ complete: UploadComplete) async throws -> MediaItem {
        try await call {
            try await client.completeUpload(path: .init(uploadId: id), body: .json(complete)).ok.body.json
        }
    }

    public func tags(matching query: String, blog: String?, limit: Int = 20) async throws -> [AuthoringTag] {
        try await call {
            try await client.listMyTags(query: .init(q: query.isEmpty ? nil : query, blog: blog, limit: limit))
                .ok.body.json.items
        }
    }

    public func linkPreview(for url: String) async throws -> LinkPreview {
        try await call { try await client.getLinkPreview(body: .json(.init(url: url))).ok.body.json }
    }

    /// ETags are quoted on the wire; `version` in bodies is not.
    static func quoted(_ tag: String) -> String {
        if tag == "*" || tag.hasPrefix("\"") || tag.hasPrefix("W/") { return tag }
        return "\"\(tag)\""
    }
}
