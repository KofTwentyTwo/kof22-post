#if os(iOS)
   import Foundation
   import Observation
   import PhotosUI
   import SwiftUI
   import UniformTypeIdentifiers

   @MainActor
   @Observable
   public final class ComposeModel: Identifiable {
      public enum Mode: Equatable {
         case new
         case edit(postID: Int64, version: String)
      }

      public var composition: PostComposition
      public let mode: Mode
      public var draftID: UUID?
      public var showTitle: Bool
      public var tagInput = ""
      public private(set) var tagSuggestions: [AuthoringTag] = []
      public private(set) var linkPreview: LinkPreview?
      public private(set) var linkPreviewError: String?
      public private(set) var isLoadingPhotos = false
      public var message: String?
      public var isSubmitting = false

      private let app: AppModel
      private var tagTask: Task<Void, Never>?
      private var linkTask: Task<Void, Never>?
      private var autosaveTask: Task<Void, Never>?

      public init(app: AppModel, composition: PostComposition? = nil, mode: Mode = .new, draftID: UUID? = nil) {
         self.app = app
         self.mode = mode
         self.draftID = draftID
         let initial = composition ?? PostComposition(blog: app.defaultBlog)
         self.composition = initial
         self.showTitle = !initial.title.isEmpty || initial.blog != "quick-bits"
         if !initial.linkURL.isEmpty { linkChanged() }
      }

      public var isEditing: Bool {
         if case .edit = mode {
            true
         }
         else {
            false
         }
      }
      public var limits: AuthoringLimits { app.limits }

      // MARK: Tags

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
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = (try? await service.tags(matching: query, blog: blog, limit: 8)) ?? []
            guard !Task.isCancelled else { return }
            tagSuggestions = found.filter { tag in !composition.tags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame } }
         }
      }

      public func addTag(_ raw: String) {
         let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#, ").union(.whitespacesAndNewlines))
         tagInput = ""
         tagSuggestions = []
         guard !name.isEmpty, name.count <= 50, composition.tags.count < limits.maxTags,
            !composition.tags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
         else { return }
         composition.tags.append(name)
         changed()
      }

      public func removeTag(_ name: String) {
         composition.tags.removeAll { $0 == name }
         changed()
      }

      // MARK: Link

      public func linkChanged() {
         linkTask?.cancel()
         linkPreview = nil
         linkPreviewError = nil
         let url = composition.linkURL.trimmingCharacters(in: .whitespaces)
         guard URL(string: url)?.scheme?.hasPrefix("http") == true, URL(string: url)?.host() != nil else { return }
         let service = app.service
         linkTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            do {
               let preview = try await service.linkPreview(for: url)
               if !Task.isCancelled { linkPreview = preview }
            }
            catch {
               if !Task.isCancelled { linkPreviewError = ErrorClassifier.message(for: error) }
            }
         }
         changed()
      }

      // MARK: Photos

      public func addPhotos(_ items: [PhotosPickerItem]) async {
         isLoadingPhotos = true
         defer { isLoadingPhotos = false }
         for item in items {
            guard composition.photos.count < limits.maxPhotosPerPost else {
               message = "At most \(limits.maxPhotosPerPost) photos per post."
               break
            }
            do {
               // With full library access, read the original (with its metadata) from Photos.
               if let id = item.itemIdentifier, let (data, ext) = await Permissions.shared.originalData(assetIdentifier: id) {
                  composition.photos.append(ComposedPhoto(fileName: try Self.store(data, ext: ext)))
                  continue
               }
               guard let data = try await item.loadTransferable(type: Data.self) else { continue }
               let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
               composition.photos.append(ComposedPhoto(fileName: try Self.store(data, ext: ext)))
            }
            catch {
               message = "A photo could not be loaded: \(error.localizedDescription)"
            }
         }
         changed()
      }

      public func addPhoto(data: Data, ext: String) {
         guard composition.photos.count < limits.maxPhotosPerPost, let name = try? Self.store(data, ext: ext) else { return }
         composition.photos.append(ComposedPhoto(fileName: name))
         changed()
      }

      public func removePhoto(_ photo: ComposedPhoto) {
         composition.photos.removeAll { $0.id == photo.id }
         if let url = photo.localURL() { try? FileManager.default.removeItem(at: url) }
         changed()
      }

      public func movePhotos(from source: IndexSet, to destination: Int) {
         composition.photos.move(fromOffsets: source, toOffset: destination)
         changed()
      }

      public func update(_ photo: ComposedPhoto) {
         guard let index = composition.photos.firstIndex(where: { $0.id == photo.id }) else { return }
         composition.photos[index] = photo
         changed()
      }

      // MARK: Location

      public private(set) var isLocating = false

      /// Fills the location label from the current position (prompts for access).
      public func useCurrentLocation() async {
         isLocating = true
         defer { isLocating = false }
         do {
            composition.locationLabel = try await Permissions.shared.currentPlaceLabel()
            changed()
         }
         catch {
            message = error.localizedDescription
         }
      }

      public var photosMissingAltText: Int { composition.photos.filter { $0.altText.isEmpty }.count }

      nonisolated static func store(_ data: Data, ext: String) throws -> String {
         let name = "\(UUID().uuidString).\(ext)"
         try data.write(to: SharedContainer.photosDirectory.appending(path: name), options: .completeFileProtectionUntilFirstUserAuthentication)
         return name
      }

      // MARK: Autosave and submit

      /// Debounced autosave of new posts as a local draft so nothing typed is lost.
      public func changed() {
         guard !isEditing, !isSubmitting else { return }
         autosaveTask?.cancel()
         let snapshot = composition
         let store = app.store
         let existing = draftID
         autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if snapshot.isEmpty {
               if let existing { try? await store.deleteDraft(existing); draftID = nil }
               return
            }
            draftID = try? await store.saveLocalDraft(snapshot, id: existing)
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

      public func discard() async {
         autosaveTask?.cancel()
         if let draftID {
            try? await app.store.deleteDraft(draftID)
         }
         else {
            for photo in composition.photos { if let url = photo.localURL() { try? FileManager.default.removeItem(at: url) } }
         }
         reset()
      }
   }
#endif
