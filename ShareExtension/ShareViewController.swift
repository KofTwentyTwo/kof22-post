import KoF22UI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet entry: turns shared photos, links and text into a composer, queues
/// the post in the shared outbox and tries to send it before closing. Anything not
/// sent here is picked up by the app.
final class ShareViewController: UIViewController {
   private let app = AppModel(context: .shareExtension)

   override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      Task { await load() }
   }

   private func load() async {
      await app.bootstrap()
      let composition = await ShareInput.composition(
         from: extensionContext?.inputItems as? [NSExtensionItem] ?? [],
         blog: app.defaultBlog)
      let root = ShareRootView(model: ComposeModel(app: app, composition: composition)) { [weak self] sent in
         self?.finish(sent: sent)
      }
      .environment(app)
      .modelContainer(app.container)
      let host = UIHostingController(rootView: root)
      addChild(host)
      host.view.frame = view.bounds
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(host.view)
      host.didMove(toParent: self)
   }

   private func finish(sent: Bool) {
      if sent {
         extensionContext?.completeRequest(returningItems: nil)
      }
      else {
         extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
      }
   }
}

struct ShareRootView: View {
   @Environment(AppModel.self) private var app
   @Bindable var model: ComposeModel
   let done: (Bool) -> Void
   @State private var sending = false

   var body: some View {
      NavigationStack {
         Group {
            if app.isSignedIn {
               ComposeView(model: model) {
                  sending = true
                  Task {
                     // Give the upload a short head start; the app finishes the rest.
                     _ = await withTaskGroup(of: Void.self) { group in
                        group.addTask { await app.processor.drain() }
                        group.addTask { try? await Task.sleep(for: .seconds(20)) }
                        await group.next()
                        group.cancelAll()
                     }
                     done(true)
                  }
               }
            }
            else {
               ContentUnavailableView(
                  "Not signed in", systemImage: "person.crop.circle.badge.exclamationmark",
                  description: Text("Open KoF22 Post and sign in, then share again."))
            }
         }
         .overlay { if sending { ProgressView("Posting…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
         .navigationTitle("KoF22 Post")
         .navigationBarTitleDisplayMode(.inline)
         .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } } }
      }
   }
}

enum ShareInput {
   /// Copies shared images into the App Group and collects URLs and text.
   @MainActor
   static func composition(from items: [NSExtensionItem], blog: String) async -> PostComposition {
      var composition = PostComposition(blog: blog)
      var texts: [String] = []
      for item in items {
         for provider in item.attachments ?? [] {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
               if let name = await copyImage(provider) { composition.photos.append(ComposedPhoto(fileName: name)) }
            }
            else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
               if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                  if url.isFileURL { continue }
                  if composition.linkURL.isEmpty {
                     composition.linkURL = url.absoluteString
                  }
                  else {
                     texts.append(url.absoluteString)
                  }
               }
            }
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
               if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                  texts.append(text)
               }
            }
         }
         if texts.isEmpty, let title = item.attributedContentText?.string, !title.isEmpty { texts.append(title) }
      }
      composition.body = texts.filter { $0 != composition.linkURL }.joined(separator: "\n\n")
      return composition
   }

   @MainActor
   private static func copyImage(_ provider: NSItemProvider) async -> String? {
      await withCheckedContinuation { continuation in
         _ = provider.loadFileRepresentation(for: .image) { url, _, _ in
            guard let url else { return continuation.resume(returning: nil) }
            let name = "\(UUID().uuidString).\(url.pathExtension.isEmpty ? "jpg" : url.pathExtension)"
            let target = SharedContainer.photosDirectory.appending(path: name)
            do {
               try FileManager.default.copyItem(at: url, to: target)
               continuation.resume(returning: name)
            }
            catch {
               continuation.resume(returning: nil)
            }
         }
      }
   }
}
