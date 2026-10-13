/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import Foundation
   import Observation
   import PhotosUI
   import SwiftUI
   import UniformTypeIdentifiers

   /// State and actions of the composer: text, tags, link preview, photos, location,
   /// local-draft autosave and queueing the post. Used for new posts, edits and the
   /// Share Extension.
   @MainActor
   @Observable
   public final class ComposeModel: Identifiable {
      /// Whether the composer creates a post or edits one already on the server.
      public enum Mode: Equatable {
         /// A new post; it autosaves as a local draft.
         case new
         /// An existing post, sent with its version so the server can detect conflicts.
         case edit(postID: Int64, version: String)
      }

      /// Delay after the last keystroke before asking for tag suggestions.
      private static let tagDebounceMilliseconds = 200
      /// Delay after the last edit of the link before fetching its preview.
      private static let linkDebounceMilliseconds = 600
      /// Delay after the last change before saving the local draft.
      private static let autosaveDelay: Duration = .seconds(1)
      /// Number of tag suggestions requested.
      private static let tagSuggestionLimit = 8
      /// Longest tag name accepted (`blogTag.name`).
      private static let maxTagLength = PostFieldLimits.tag
      /// Pause after the last body edit before details are suggested.
      static let suggestDebounceMilliseconds = 2_000
      /// Shortest body worth asking the model about, in characters.
      static let minimumSuggestBodyLength = 20
      /// Extension used when a picked item reports no type.
      static let fallbackExtension = "jpg"

      /// The post being written.
      public var composition: PostComposition
      /// New post or edit.
      public let mode: Mode
      /// The local draft that autosave writes to, once one exists.
      public var draftID: UUID?
      /// Whether the optional title field is shown.
      public var showTitle: Bool
      /// Text typed in the tag field and not yet turned into a tag.
      public var tagInput = ""
      /// Existing tags matching `tagInput`, excluding ones already added.
      public private(set) var tagSuggestions: [BlogTagRef] = []
      /// Preview of `composition.linkURL`, once fetched.
      public private(set) var linkPreview: LinkPreview?
      /// Why the link preview could not be fetched.
      public private(set) var linkPreviewError: String?
      /// Whether picked photos are still being copied in.
      public internal(set) var isLoadingPhotos = false
      /// A message for the composer's alert, or nil.
      public var message: String?
      /// Whether the post is being queued.
      public var isSubmitting = false
      /// Whether the current location is being looked up.
      public internal(set) var isLocating = false
      /// Place labels found for the current position, most specific first.
      public internal(set) var locationOptions: [String] = []
      /// Whether the on-device model is writing details.
      public internal(set) var isSuggesting = false
      /// Why the last suggestion failed, or nil.
      public internal(set) var suggestionError: String?
      /// Detail fields the user typed in; automatic suggestions leave them alone.
      public var editedDetails: Set<PostDetailField> = []

      /// The app's composition root.
      let app: AppModel
      /// Pending tag-suggestion lookup, cancelled by the next keystroke.
      private var tagTask: Task<Void, Never>?
      /// Pending link-preview fetch, cancelled by the next edit.
      private var linkTask: Task<Void, Never>?
      /// Pending autosave, cancelled by the next change.
      private var autosaveTask: Task<Void, Never>?
      /// Pending automatic suggestion, cancelled by the next body edit.
      var suggestTask: Task<Void, Never>?
      /// Writes the details; replaceable in tests.
      let suggester: any PostDetailSuggesting

      /// Creates a composer for `composition`, or an empty post on the default blog. The
      /// title field starts visible when there is a title or the blog is not Quick Bits.
      public init(
         app: AppModel, composition: PostComposition? = nil, mode: Mode = .new, draftID: UUID? = nil,
         suggester: any PostDetailSuggesting = OnDevicePostSuggester()
      ) {
         self.app = app
         self.suggester = suggester
         self.mode = mode
         self.draftID = draftID
         let initial = composition ?? PostComposition(blog: app.defaultBlog)
         self.composition = initial
         self.showTitle = !initial.title.isEmpty || initial.blog != AppModel.fallbackBlogSlug
         if case .edit = mode { editedDetails = Set(PostDetailField.allCases) }
         if !initial.linkURL.isEmpty { linkChanged() }
         ////////////////////////////////////////////////////////////////
         // shared or prefilled text gets details without a keystroke //
         ////////////////////////////////////////////////////////////////
         if case .new = mode, !initial.body.isEmpty { bodyChanged() }
      }

      /// Whether this composer edits a post already on the server.
      public var isEditing: Bool {
         if case .edit = mode { return true }
         return false
      }

      /// Photo rules of the signed-in account.
      public var limits: PhotoLimits { app.limits }

      /// Whether on-device suggestions can run on this iPhone.
      public var canSuggest: Bool { suggester.isAvailable }

      /// Why on-device suggestions are unavailable, for the details section.
      public var suggestionUnavailableReason: String? { suggester.unavailableReason }

      /// Number of photos that still need alt text.
      public var photosMissingAltText: Int { composition.photos.filter { $0.altText.isEmpty }.count }

      /// Waits for `duration`. Returns false when the task was cancelled meanwhile, which is
      /// how a newer keystroke replaces a pending lookup.
      static func debounce(_ duration: Duration) async -> Bool {
         do {
            try await Task.sleep(for: duration)
            return !Task.isCancelled
         }
         catch {
            ////////////////////////////////////////////////////////////
            // Cancellation is the expected way a debounce is dropped //
            ////////////////////////////////////////////////////////////
            return false
         }
      }

      //////////
      // Tags //
      //////////

      /// Turns a trailing comma or space into a tag; otherwise looks up suggestions for
      /// the text typed so far after a short pause.
      public func tagInputChanged() {
         let query = tagInput.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
         if tagInput.hasSuffix(",") || tagInput.hasSuffix(" ") && !query.isEmpty {
            addTag(query.trimmingCharacters(in: CharacterSet(charactersIn: ",")))
            return
         }
         tagTask?.cancel()
         let blog = composition.blog
         let service = app.service
         tagTask = Task {
            guard await Self.debounce(.milliseconds(Self.tagDebounceMilliseconds)) else { return }
            let found: [BlogTagRef]
            do {
               found = try await service.tags(matching: query, blog: blog, limit: Self.tagSuggestionLimit)
            }
            catch {
               ////////////////////////////////////////////////////////////////////
               // Suggestions are a convenience; typing a tag still works, so a  //
               // failed lookup only clears the list.                            //
               ////////////////////////////////////////////////////////////////////
               Log.api.notice("Tag suggestions failed: \(ErrorClassifier.message(for: error), privacy: .public)")
               found = []
            }
            guard !Task.isCancelled else { return }
            tagSuggestions = found.filter { tag in !composition.tags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }
         }
      }

      /// Adds `raw` as a tag after stripping `#`, commas and whitespace. Empty, overlong,
      /// duplicate tags and tags beyond the account limit are ignored.
      public func addTag(_ raw: String) {
         let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#, ").union(.whitespacesAndNewlines))
         tagInput = ""
         tagSuggestions = []
         guard !name.isEmpty, name.count <= Self.maxTagLength,
            !composition.tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
         else { return }
         composition.tags.append(name)
         changed()
      }

      /// Removes the tag named `name`.
      public func removeTag(_ name: String) {
         composition.tags.removeAll { $0 == name }
         changed()
      }

      //////////
      // Link //
      //////////

      /// Clears the old preview and, when the link is an http(s) URL with a host, fetches
      /// a new preview after a short pause.
      public func linkChanged() {
         linkTask?.cancel()
         linkPreview = nil
         linkPreviewError = nil
         let url = composition.linkURL.trimmingCharacters(in: .whitespaces)
         guard URL(string: url)?.scheme?.hasPrefix("http") == true, URL(string: url)?.host() != nil else { return }
         let service = app.service
         linkTask = Task {
            guard await Self.debounce(.milliseconds(Self.linkDebounceMilliseconds)) else { return }
            do {
               let preview = try await service.linkPreview(for: url)
               if !Task.isCancelled { linkPreview = preview }
            }
            catch {
               Log.api.notice("Link preview failed: \(ErrorClassifier.message(for: error), privacy: .public)")
               if !Task.isCancelled { linkPreviewError = ErrorClassifier.message(for: error) }
            }
         }
         changed()
      }

   }

   /// Autosave and submitting.
   extension ComposeModel {
      /////////////////////////
      // Autosave and submit //
      /////////////////////////

      /// Debounced autosave of new posts as a local draft so nothing typed is lost.
      public func changed() {
         guard !isEditing, !isSubmitting else { return }
         autosaveTask?.cancel()
         let snapshot = composition
         let existing = draftID
         autosaveTask = Task {
            guard await Self.debounce(Self.autosaveDelay) else { return }
            await autosave(snapshot, existing: existing)
         }
      }

      /// Saves `snapshot` as the local draft, or deletes the draft once the post is empty.
      /// Autosave runs every second while typing, so failures are logged, not alerted.
      private func autosave(_ snapshot: PostComposition, existing: UUID?) async {
         do {
            if snapshot.isEmpty {
               guard let existing else { return }
               try await app.store.deleteDraft(existing)
               draftID = nil
            }
            else {
               draftID = try await app.store.saveLocalDraft(snapshot, id: existing)
            }
         }
         catch {
            Log.storage.warning("Local draft autosave failed: \(error.localizedDescription, privacy: .public)")
         }
      }

      /// Validates and queues the post. Returns true when queued.
      public func submit(as status: PostStatus, publishAt: Date? = nil) async -> Bool {
         var outgoing = composition
         outgoing.status = status
         outgoing.publishAt = status == .scheduled ? publishAt : nil
         if !tagInput.trimmingCharacters(in: .whitespaces).isEmpty {
            addTag(tagInput)
            outgoing.tags = composition.tags
         }
         if let problem = outgoing.validationMessage(limits: limits) {
            message = problem
            return false
         }
         isSubmitting = true
         defer { isSubmitting = false }
         autosaveTask?.cancel()
         do {
            switch mode {
            case .new:
               try await app.submit(outgoing, replacingDraft: draftID)
            case .edit(let postID, let version):
               try await app.submit(outgoing, operation: .update, serverPostID: postID, ifMatch: version)
            }
            return true
         }
         catch {
            Log.outbox.warning("Post could not be queued: \(error.localizedDescription, privacy: .public)")
            message = "Could not queue the post: \(error.localizedDescription)"
            return false
         }
      }

      /// Clears the composer after a successful submit (new posts only).
      public func reset() {
         composition = PostComposition(blog: app.defaultBlog)
         draftID = nil
         tagInput = ""
         linkPreview = nil
         showTitle = false
      }

      /// Throws the post away: deletes its local draft (which owns the photo files) or,
      /// without a draft, the photo files directly, then clears the composer.
      public func discard() async {
         autosaveTask?.cancel()
         if let draftID {
            do {
               try await app.store.deleteDraft(draftID)
            }
            catch {
               Log.storage.warning("Local draft could not be deleted: \(error.localizedDescription, privacy: .public)")
               message = "The draft could not be deleted: \(error.localizedDescription)"
            }
         }
         else {
            composition.photos.forEach(Self.deleteLocalFile(of:))
         }
         reset()
      }
   }
#endif
