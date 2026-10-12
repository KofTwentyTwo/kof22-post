/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// PUTs photo bytes to a presigned upload URL.
public protocol UploadPerformer: Sendable {
   /// Uploads the file at `fileURL` to `url` with the headers the upload ticket requires.
   func put(fileURL: URL, to url: URL, headers: [String: String]) async throws
}

/// Uploads photos straight to object storage with `URLSession`. The presigned URL is not
/// part of the Site API, so this bypasses the generated client and its middlewares.
public struct URLSessionUploadPerformer: UploadPerformer {
   /// Full-resolution photos on a slow connection need far longer than an API call.
   static let uploadTimeout: TimeInterval = 300

   /// How much of a failed upload's response body ends up in the error message.
   static let errorBodyPrefixBytes = 300

   /// Status codes that mean the storage service kept the bytes.
   static let successStatusCodes = 200..<300

   /// The session that performs the upload.
   let session: URLSession

   /// Creates a performer on `session`; tests pass a session with a stub protocol.
   public init(session: URLSession = .shared) { self.session = session }

   /// Uploads the file and throws `APIError` with code `upload_put_failed` for a non-2xx
   /// response, carrying the start of the storage service's response as the message.
   public func put(fileURL: URL, to url: URL, headers: [String: String]) async throws {
      var request = URLRequest(url: url)
      request.httpMethod = "PUT"
      request.timeoutInterval = Self.uploadTimeout
      for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
      let (data, response) = try await session.upload(for: request, fromFile: fileURL)
      guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
      guard Self.successStatusCodes.contains(http.statusCode) else {
         throw APIError(
            status: http.statusCode, code: "upload_put_failed",
            message: String(data: data.prefix(Self.errorBodyPrefixBytes), encoding: .utf8) ?? "Upload failed")
      }
   }
}

/// The hand-written layer over the generated client: auth, error mapping,
/// idempotency keys and ETags. Everything the app sends goes through here.
public struct SiteService: Sendable {
   /// Fail fast instead of waiting for connectivity: the outbox owns retries.
   static let requestTimeout: TimeInterval = 30

   /// Page size used when the caller does not ask for one.
   public static let defaultPageSize = 20

   /// The generated client with the middlewares installed.
   let client: Client
   /// Sends photo bytes to presigned URLs.
   let uploader: any UploadPerformer

   /// Builds the service on any transport. The middleware order matters: errors are
   /// mapped last so the auth middleware still sees the raw 401.
   public init(serverURL: URL, transport: any ClientTransport, auth: AuthSession, uploader: any UploadPerformer) {
      self.client = Client(
         serverURL: serverURL,
         transport: transport,
         middlewares: [ErrorEnvelopeMiddleware(), RawHeaderMiddleware(), ExplicitNullMiddleware(), AuthMiddleware(auth: auth)]
      )
      self.uploader = uploader
   }

   /// The service for the real Site API over `URLSession`.
   public static func live(config: AppConfig = .production, auth: AuthSession) -> Self {
      let configuration = URLSessionConfiguration.default
      configuration.waitsForConnectivity = false
      configuration.timeoutIntervalForRequest = Self.requestTimeout
      let session = URLSession(configuration: configuration)
      return Self(
         serverURL: config.apiBaseURL,
         transport: URLSessionTransport(configuration: .init(session: session)),
         auth: auth,
         uploader: URLSessionUploadPerformer()
      )
   }

   /// The service backed by the in-process mock of the Site API contract.
   public static func mock(backend: MockBackend, auth: AuthSession) -> Self {
      Self(
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
      }
      catch let error as ClientError {
         throw error.underlyingError
      }
   }

   /// The API versions the server supports; needs no sign-in.
   public func versions() async throws -> APIVersions {
      try await call { try await client.getApiVersions().ok.body.json }
   }

   /// The signed-in author, their blogs and the authoring limits.
   public func me() async throws -> Me {
      try await call { try await client.getMe().ok.body.json }
   }

   /// One page of the author's posts, optionally filtered by status.
   public func myPosts(status: PostStatus? = nil, cursor: String? = nil, limit: Int = Self.defaultPageSize) async throws -> PostPage {
      try await call {
         try await client.listMyPosts(query: .init(status: status, cursor: cursor, limit: limit)).ok.body.json
      }
   }

   /// One of the author's posts by id.
   public func post(id: Int64) async throws -> Post {
      try await call { try await client.getMyPost(path: .init(postId: id)).ok.body.json }
   }

   /// Creates a post. The idempotency key makes a retry after a lost response return the
   /// same post instead of creating a second one.
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

   /// Deletes a post, guarded by its version when one is known.
   public func deletePost(id: Int64, ifMatch: String?) async throws {
      _ = try await call {
         try await client.deletePost(path: .init(postId: id), headers: .init(ifMatch: ifMatch.map(Self.quoted)))
            .noContent
      }
   }

   /// Asks for a presigned upload URL for one photo.
   public func createUpload(_ upload: UploadCreate, idempotencyKey: String) async throws -> UploadTicket {
      try await call {
         try await client.createUpload(headers: .init(idempotencyKey: idempotencyKey), body: .json(upload))
            .created.body.json
      }
   }

   /// Sends the photo bytes to the ticket's presigned URL.
   public func putUpload(fileURL: URL, ticket: UploadTicket) async throws {
      guard let url = URL(string: ticket.uploadUrl) else { throw URLError(.badURL) }
      try await uploader.put(fileURL: fileURL, to: url, headers: ticket.headers.additionalProperties)
   }

   /// Confirms an upload so the photo can be attached to a post.
   public func completeUpload(id: String, _ complete: UploadComplete) async throws -> MediaItem {
      try await call {
         try await client.completeUpload(path: .init(uploadId: id), body: .json(complete)).ok.body.json
      }
   }

   /// Tag suggestions for autocomplete; an empty query lists the most used tags.
   public func tags(matching query: String, blog: String?, limit: Int = Self.defaultPageSize) async throws -> [AuthoringTag] {
      try await call {
         try await client.listMyTags(query: .init(q: query.isEmpty ? nil : query, blog: blog, limit: limit))
            .ok.body.json.items
      }
   }

   /// The title and image the server finds for a link.
   public func linkPreview(for url: String) async throws -> LinkPreview {
      try await call { try await client.getLinkPreview(body: .json(.init(url: url))).ok.body.json }
   }

   /// ETags are quoted on the wire; `version` in bodies is not.
   static func quoted(_ tag: String) -> String {
      if tag == "*" || tag.hasPrefix("\"") || tag.hasPrefix("W/") { return tag }
      return "\"\(tag)\""
   }
}
