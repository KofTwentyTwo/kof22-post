/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing

@testable import KoF22Kit

/// The presigned upload flow of the mock: ticket, PUT, complete, and every way it
/// can be refused.
@Suite struct MockBackendUploadTests {
   /// A file-backed mock with a controllable clock and a folder for source files.
   struct Setup {
      /// Calls into the backend.
      let caller: MockCaller
      /// The backend's directory.
      let directory: URL
      /// Source files to upload.
      let sources: URL
      /// The backend's clock.
      let clock: TestClock
   }

   /// Builds a file-backed mock.
   static func makeSetup() throws -> Setup {
      let clock = TestClock()
      let directory = try KitFiles.makeDirectory()
      let sources = try KitFiles.makeDirectory()
      return Setup(
         caller: MockCaller(backend: MockBackend(directory: directory, now: clock.provider)), directory: directory,
         sources: sources, clock: clock)
   }

   /// Creates a ticket for a JPEG and returns its id.
   static func ticket(_ caller: MockCaller, contentType: UploadCreate.ContentTypePayload = .imageJpeg) async throws -> String {
      let response = try await caller.call(
         "createUpload", json: UploadCreate(fileName: "photo", contentType: contentType, byteSize: 1_000))
      return try caller.decode(UploadTicket.self, response).uploadId
   }

   @Test func ticketsRefuseHEICOversizeAndEmptyFiles() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      #expect(try await caller.call("createUpload", raw: nil).status == 400)
      for type in [UploadCreate.ContentTypePayload.imageHeic, .imageHeif] {
         let response = try await caller.call("createUpload", json: UploadCreate(fileName: "a", contentType: type, byteSize: 10))
         #expect(response.status == 415)
      }
      let huge = try await caller.call(
         "createUpload", json: UploadCreate(fileName: "a", contentType: .imageJpeg, byteSize: 26_214_401))
      #expect(huge.status == 413)
      let empty = try await caller.call("createUpload", json: UploadCreate(fileName: "a", contentType: .imageJpeg, byteSize: 0))
      #expect(try caller.firstIssueField(empty) == "byteSize")
   }

   @Test func ticketsCarryAPresignedPutThatExpires() async throws {
      let setup = try Self.makeSetup()
      let response = try await setup.caller.call(
         "createUpload", json: UploadCreate(fileName: "a.png", contentType: .imagePng, byteSize: 10))
      let ticket = try setup.caller.decode(UploadTicket.self, response)
      #expect(response.status == 201)
      #expect(ticket.uploadUrl.hasSuffix("/\(ticket.uploadId)"))
      #expect(ticket.expiresAt == setup.clock.now.addingTimeInterval(900))
      #expect(ticket.headers.additionalProperties["Content-Type"] == "image/png")
   }

   @Test func completingReturnsMediaAndRepeatingReplaysIt() async throws {
      let setup = try Self.makeSetup()
      let source = setup.sources.appending(path: "in.png")
      try KitFiles.writeImage(to: source, type: .png)
      let id = try await Self.ticket(setup.caller, contentType: .imagePng)
      try await setup.caller.backend.receiveUpload(id: id, from: source)
      try await setup.caller.backend.receiveUpload(id: id, from: source)
      let path = "/v1/me/uploads/\(id)/complete"
      let first = try setup.caller.decode(
         MediaItem.self,
         try await setup.caller.call("completeUpload", path: path, json: UploadComplete(altText: " Sky ", keepLocation: true)))
      #expect(first.altText == "Sky")
      #expect(first.width == 16)
      #expect(first.locationRemoved == false)
      #expect(first.url.hasSuffix("media-\(first.mediaId).png"))
      #expect(FileManager.default.fileExists(atPath: try #require(URL(string: first.url)).path(percentEncoded: false)))
      let again = try setup.caller.decode(MediaItem.self, try await setup.caller.call("completeUpload", path: path, raw: nil))
      #expect(again.mediaId == first.mediaId)
      #expect(again.locationRemoved == true)

      let post = try await setup.caller.create(PostCreate(body: "photo", media: [MediaAttachment(mediaId: first.mediaId)]))
      #expect(post.media.first?.altText == "Sky")
      #expect(post.media.first?.url.hasPrefix("file:") == true)
   }

   @Test func inMemoryMockServesMockMediaURLs() async throws {
      let caller = MockCaller(backend: MockBackend(directory: nil))
      let source = try KitFiles.makeDirectory().appending(path: "in.jpg")
      try KitFiles.writeImage(to: source)
      let media = try await caller.upload(file: source)
      #expect(media.url == "mock-media:media-1.jpg")
      let post = try await caller.create(PostCreate(body: "x", media: [MediaAttachment(mediaId: media.mediaId)]))
      #expect(post.media.first?.url == "mock-media:media-1.jpg")
   }

   @Test func completeNeedsAKnownUploadWithReceivedBytes() async throws {
      let setup = try Self.makeSetup()
      let unknown = try await setup.caller.call("completeUpload", path: "/v1/me/uploads/nope/complete", raw: nil)
      #expect(unknown.status == 404)
      #expect(try await setup.caller.call("completeUpload", path: "/", raw: nil).status == 404)
      let id = try await Self.ticket(setup.caller)
      let path = "/v1/me/uploads/\(id)/complete"
      let early = try await setup.caller.call("completeUpload", path: path, raw: nil)
      #expect(early.status == 409)
      #expect(try setup.caller.errorCode(early) == "upload_not_received")
      setup.clock.advance(by: 901)
      let expired = try await setup.caller.call("completeUpload", path: path, raw: nil)
      #expect(try setup.caller.errorCode(expired) == "upload_expired")
   }

   @Test func putIsRefusedForUnknownOrExpiredURLs() async throws {
      let setup = try Self.makeSetup()
      let source = setup.sources.appending(path: "in.jpg")
      try KitFiles.writeImage(to: source)
      let unknown = await #expect(throws: APIError.self) { try await setup.caller.backend.receiveUpload(id: "nope", from: source) }
      #expect(unknown?.status == 403)
      let id = try await Self.ticket(setup.caller)
      setup.clock.advance(by: 901)
      let expired = await #expect(throws: APIError.self) { try await setup.caller.backend.receiveUpload(id: id, from: source) }
      #expect(expired?.message == "Upload URL expired")
   }

   @Test func aFileThatIsNotAnImageIsRefused() async throws {
      let setup = try Self.makeSetup()
      let source = setup.sources.appending(path: "notes.txt")
      try Data("not an image".utf8).write(to: source)
      let id = try await Self.ticket(setup.caller)
      try await setup.caller.backend.receiveUpload(id: id, from: source)
      let response = try await setup.caller.call("completeUpload", path: "/v1/me/uploads/\(id)/complete", raw: nil)
      #expect(response.status == 415)
      #expect(try setup.caller.errorCode(response) == "unsupported_media_type")
   }
}
