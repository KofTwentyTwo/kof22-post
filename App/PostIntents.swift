import AppIntents
import KoF22UI
import UniformTypeIdentifiers

/// "Post to Field Notes": publishes without opening the app (Siri, Shortcuts,
/// Action Button). Offline posts are queued and sent later.
struct PostToFieldNotesIntent: AppIntent {
   static let title: LocalizedStringResource = "Post to Field Notes"
   static let description = IntentDescription("Publish a quick post to Field Notes on kof22.com.")

   @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
   var text: String

   @Parameter(title: "Link")
   var link: URL?

   @Parameter(title: "Photos", supportedContentTypes: [.image])
   var photos: [IntentFile]?

   @Parameter(title: "Tags", default: [])
   var tags: [String]

   static var parameterSummary: some ParameterSummary {
      Summary("Post \(\.$text) to Field Notes") {
         \.$link
         \.$photos
         \.$tags
      }
   }

   @MainActor
   func perform() async throws -> some IntentResult & ProvidesDialog {
      let app = AppServices.shared
      if !app.isSignedIn { await app.bootstrap() }
      guard app.isSignedIn else {
         throw IntentError.message("Open KoF22 Post and sign in first.")
      }
      var composed: [ComposedPhoto] = []
      for file in photos ?? [] {
         let ext = file.type?.preferredFilenameExtension ?? "jpg"
         let name = "\(UUID().uuidString).\(ext)"
         try file.data.write(to: SharedContainer.photosDirectory.appending(path: name))
         composed.append(ComposedPhoto(fileName: name))
      }
      let composition = PostComposition(
         blog: "quick-bits", body: text, tags: tags,
         linkURL: link?.absoluteString ?? "", photos: composed)
      if let problem = composition.validationMessage(limits: app.limits) {
         throw IntentError.message(problem)
      }
      let id = try await app.submit(composition)
      await app.processor.drain()
      let state = try await app.store.snapshot(id)?.state
      return .result(dialog: state == .sent ? "Posted to Field Notes." : "Queued. It will post when you're back online.")
   }
}

enum IntentError: Error, CustomLocalizedStringResourceConvertible {
   case message(String)

   var localizedStringResource: LocalizedStringResource {
      switch self {
      case .message(let text): "\(text)"
      }
   }
}

struct KoF22Shortcuts: AppShortcutsProvider {
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
