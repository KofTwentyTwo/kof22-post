/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

import KoF22UI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share sheet entry: turns shared photos, links and text into a composer, queues
/// the post in the shared outbox and tries to send it before closing. Anything not
/// sent here is picked up by the app.
final class ShareViewController: UIViewController {
   /// The extension's own app model, configured for the Share Extension context.
   private let app = AppModel(context: .shareExtension)

   /// Sets the background and starts loading the shared items.
   override func viewDidLoad() {
      super.viewDidLoad()
      view.backgroundColor = .systemBackground
      Task { await load() }
   }

   /// Restores the session, builds a composition from the shared items and embeds the
   /// SwiftUI composer in this controller.
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

   /// Closes the share sheet: completes the request when the post was queued, cancels it
   /// when the user backed out.
   private func finish(sent: Bool) {
      if sent {
         extensionContext?.completeRequest(returningItems: nil)
      }
      else {
         extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
      }
   }
}

/// SwiftUI root of the share sheet: the composer when signed in, otherwise a prompt to
/// sign in from the app first.
struct ShareRootView: View {
   /// Seconds the extension waits for the first send before handing over to the app.
   private static let sendHeadStartSeconds = 20
   /// Corner radius of the "Posting…" overlay card.
   private static let overlayCornerRadius: CGFloat = 12

   /// The shared app model, used for the sign-in state and the outbox processor.
   @Environment(AppModel.self) private var app
   /// The composer state seeded from the shared items.
   @Bindable var model: ComposeModel
   /// Called with `true` once the post is queued, `false` when the user cancels.
   let done: (Bool) -> Void
   /// Whether the post has been submitted and the overlay is showing.
   @State private var sending = false

   /// The composer or the signed-out message, inside a navigation stack with Cancel.
   var body: some View {
      NavigationStack {
         Group {
            if app.isSignedIn {
               ComposeView(model: model) {
                  sending = true
                  Task {
                     await sendWithHeadStart()
                     done(true)
                  }
               }
            }
            else {
               ContentUnavailableView(
                  "Not signed in", systemImage: "person.crop.circle.badge.exclamationmark",
                  description: Text("Open KoF22 Postr and sign in, then share again."))
            }
         }
         .overlay {
            if sending {
               ProgressView("Posting…").padding()
                  .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Self.overlayCornerRadius))
            }
         }
         .navigationTitle("KoF22 Postr")
         .navigationBarTitleDisplayMode(.inline)
         .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done(false) } } }
      }
   }

   /// Drains the outbox, but gives up after a short head start; the app finishes the rest.
   private func sendWithHeadStart() async {
      let headStart = Duration.seconds(Self.sendHeadStartSeconds)
      let processor = app.processor
      _ = await withTaskGroup(of: Void.self) { group in
         group.addTask { await processor.drain() }
         group.addTask {
            ////////////////////////////////////////////////////////////////
            // The timer is cancelled as soon as the drain finishes, so a //
            // CancellationError here is the expected outcome.            //
            ////////////////////////////////////////////////////////////////
            try? await Task.sleep(for: headStart)
         }
         await group.next()
         group.cancelAll()
      }
   }
}

/// Converts the items handed to the Share Extension into a post composition.
enum ShareInput {
   /// File extension used when a shared image arrives without one.
   private static let defaultImageExtension = "jpg"

   /// Copies shared images into the App Group and collects URLs and text.
   @MainActor
   static func composition(from items: [NSExtensionItem], blog: String) async -> PostComposition {
      var composition = PostComposition(blog: blog)
      var texts: [String] = []
      for item in items {
         for provider in item.attachments ?? [] {
            await collect(provider, into: &composition, texts: &texts)
         }
         if texts.isEmpty, let title = item.attributedContentText?.string, !title.isEmpty { texts.append(title) }
      }
      composition.body = texts.filter { $0 != composition.linkURL }.joined(separator: "\n\n")
      return composition
   }

   /// Adds one attachment to the composition: images become photos, the first web URL
   /// becomes the link (later ones go into the text), and plain text is collected.
   @MainActor
   private static func collect(
      _ provider: NSItemProvider, into composition: inout PostComposition, texts: inout [String]
   ) async {
      if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
         if let name = await copyImage(provider) { composition.photos.append(ComposedPhoto(fileName: name)) }
      }
      else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
         guard let url = await loadItem(provider, type: .url, as: URL.self), !url.isFileURL else { return }
         if composition.linkURL.isEmpty {
            composition.linkURL = url.absoluteString
         }
         else {
            texts.append(url.absoluteString)
         }
      }
      else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
         if let text = await loadItem(provider, type: .plainText, as: String.self) {
            texts.append(text)
         }
      }
   }

   /// Loads an attachment as the given type through `Transferable` (the replacement for the
   /// deprecated `loadItem(forTypeIdentifier:)`), logging a failure instead of dropping it
   /// silently.
   @MainActor
   private static func loadItem<Value: Transferable & Sendable>(
      _ provider: NSItemProvider, type: UTType, as valueType: Value.Type
   ) async -> Value? {
      await withCheckedContinuation { continuation in
         _ = provider.loadTransferable(type: valueType) { result in
            switch result {
            case .success(let value):
               continuation.resume(returning: value)
            case .failure(let error):
               Log.ui.warning(
                  "Could not load shared \(type.identifier, privacy: .public): \(error.localizedDescription, privacy: .public)")
               continuation.resume(returning: nil)
            }
         }
      }
   }

   /// Copies a shared image into the App Group photos directory and returns its file name,
   /// or nil when the image could not be read or copied.
   @MainActor
   private static func copyImage(_ provider: NSItemProvider) async -> String? {
      await withCheckedContinuation { continuation in
         _ = provider.loadFileRepresentation(for: .image) { url, _, loadError in
            guard let url else {
               Log.media.warning(
                  "Could not read shared image: \(loadError?.localizedDescription ?? "no file", privacy: .public)")
               return continuation.resume(returning: nil)
            }
            let ext = url.pathExtension.isEmpty ? Self.defaultImageExtension : url.pathExtension
            let name = "\(UUID().uuidString).\(ext)"
            let target = SharedContainer.photosDirectory.appending(path: name)
            do {
               try FileManager.default.copyItem(at: url, to: target)
               continuation.resume(returning: name)
            }
            catch {
               Log.media.warning("Could not copy shared image: \(error.localizedDescription, privacy: .public)")
               continuation.resume(returning: nil)
            }
         }
      }
   }
}
