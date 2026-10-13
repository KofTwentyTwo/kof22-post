/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import AppIntents
import KoF22UI
import UniformTypeIdentifiers

/// "Post to Field Notes": publishes without opening the app (Siri, Shortcuts,
/// Action Button). Offline posts are queued and sent later.
struct PostToFieldNotesIntent: AppIntent {
   /// Name shown in Shortcuts and Siri.
   static let title: LocalizedStringResource = "Post to Field Notes"
   /// Explanation shown under the action in Shortcuts.
   static let description = IntentDescription("Publish a quick post to Field Notes on kof22.com.")

   /// The post body.
   @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
   var text: String

   /// Optional link attached to the post.
   @Parameter(title: "Link")
   var link: URL?

   /// Optional photos, copied into the shared container before queueing.
   @Parameter(title: "Photos", supportedContentTypes: [.image])
   var photos: [IntentFile]?

   /// Tags applied to the post; empty by default.
   @Parameter(title: "Tags", default: [])
   var tags: [String]

   /// Sentence-style summary used by the Shortcuts editor.
   static var parameterSummary: some ParameterSummary {
      Summary("Post \(\.$text) to Field Notes") {
         \.$link
         \.$photos
         \.$tags
      }
   }

   /// Signs in from stored credentials if needed, validates the composition, queues it
   /// and tries to send it at once. Reports whether it posted or stayed queued.
   @MainActor
   func perform() async throws -> some IntentResult & ProvidesDialog {
      let app = AppServices.shared
      if !app.isSignedIn { await app.bootstrap() }
      guard app.isSignedIn else {
         throw IntentError.message("Open KoF22 Postr and sign in first.")
      }
      var composed: [ComposedPhoto] = []
      for file in photos ?? [] {
         let ext = file.type?.preferredFilenameExtension ?? "jpg"
         let name = "\(UUID().uuidString).\(ext)"
         try file.data.write(to: SharedContainer.photosDirectory.appending(path: name))
         composed.append(ComposedPhoto(fileName: name))
      }
      let blog = app.blogs.first { $0.slug == Post.defaultBlogSlug }?.name ?? "Field Notes"
      let composition = await PostComposition(
         blog: Post.defaultBlogSlug, body: text, tags: tags,
         linkURL: link?.absoluteString ?? "", photos: composed
      ).fillingBlankDetails(using: OnDevicePostSuggester(), blog: blog)
      if let problem = composition.validationMessage(limits: app.limits) {
         throw IntentError.message(problem)
      }
      let id = try await app.submit(composition)
      await app.processor.drain()
      let state = try await app.store.snapshot(id)?.state
      return .result(dialog: state == .sent ? "Posted to Field Notes." : "Queued. It will post when you're back online.")
   }
}

/// Errors surfaced to the user by the intents, each carrying a ready-to-show message.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
   /// A failure described by a user-facing message.
   case message(String)

   /// The message as Siri or Shortcuts shows it.
   var localizedStringResource: LocalizedStringResource {
      switch self {
      case .message(let text): "\(text)"
      }
   }
}

/// App Shortcuts registered automatically, so the intents work with Siri and the
/// Action Button without any setup.
struct KoF22Shortcuts: AppShortcutsProvider {
   /// The quick-post and open-composer shortcuts with their Siri phrases.
   static var appShortcuts: [AppShortcut] {
      AppShortcut(
         intent: PostToFieldNotesIntent(),
         phrases: ["Post to Field Notes with \(.applicationName)", "\(.applicationName) quick post"],
         shortTitle: "Post to Field Notes",
         systemImageName: "text.bubble"
      )
      AppShortcut(
         intent: OpenComposeIntent(),
         phrases: ["New post in \(.applicationName)", "Write a field note in \(.applicationName)"],
         shortTitle: "New Field Note",
         systemImageName: "square.and.pencil"
      )
   }
}
