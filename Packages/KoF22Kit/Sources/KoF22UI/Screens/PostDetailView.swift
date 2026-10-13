/*
 * Copyright (c) 2026 James Maes (KofTwentyTwo)
 * SPDX-License-Identifier: MIT
 */

#if os(iOS)
   import SwiftUI
   import Textual

   /// One post as it appears on the site, with open, share, edit and delete.
   struct PostDetailView: View {
      /// Pause before re-reading the post, giving the outbox a moment to send an edit.
      private static let reloadDelayMilliseconds = 500

      /// The app's composition root.
      @Environment(AppModel.self) private var app
      /// Pops back to the list after a delete.
      @Environment(\.dismiss) private var dismiss
      /// The post shown, replaced when a fresh copy loads.
      @State var post: Post
      /// Tells the list that the post was deleted.
      let onDelete: (Int64) -> Void
      /// Composer for the edit sheet, if open.
      @State private var editor: ComposeModel?
      /// Whether the delete confirmation is shown.
      @State private var confirmDelete = false
      /// Why the delete could not be queued.
      @State private var error: String?

      /// The post's content with the toolbar, the delete confirmation and the edit sheet.
      var body: some View {
         ScrollView {
            content.padding()
         }
         .background(Theme.background)
         .navigationBarTitleDisplayMode(.inline)
         .toolbar { toolbarContent }
         .confirmationDialog("Delete this post from kof22.com?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete() }
         }
         .sheet(item: $editor) { composer in
            NavigationStack {
               ComposeView(model: composer) {
                  editor = nil
                  Task { await reload() }
               }
               .navigationTitle("Edit post")
               .navigationBarTitleDisplayMode(.inline)
               .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editor = nil } } }
            }
         }
         .task { await reload() }
      }

      /// Status, title, body, photos, link, location, tags and any delete error.
      private var content: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.xLarge) {
            statusLine
            Text(post.title).font(Theme.mono(.title3, weight: .bold)).foregroundStyle(Theme.heading)
            StructuredText(markdown: post.body)
            ForEach(post.media, id: \.mediaId) { photo in
               photoView(photo)
            }
            if let link = post.link {
               LinkPreviewCard(preview: LinkPreview(url: link.url, title: link.title, description: link.description, imageUrl: link.imageUrl))
            }
            if let location = post.locationLabel {
               Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(Theme.muted)
            }
            if !post.tags.isEmpty {
               FlowLayout(spacing: Theme.Spacing.small) { ForEach(post.tags, id: \.self) { TagChip($0) } }
            }
            PostFieldsCard(post: post, authorName: authorName)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
         }
      }

      /// The author's name, from the picker's list or the account.
      private var authorName: String? {
         let authors = app.authorChoices
         return authors.first { $0.id == post.authorId }?.name ?? (post.authorId == app.me?.author?.id ? app.me?.author?.name : nil)
      }

      /// The status badge, the scheduled time when scheduled, and the blog.
      private var statusLine: some View {
         HStack {
            StatusBadge(post.status)
            if post.status == .scheduled, let publishAt = post.publishAt {
               Text("for \(publishAt, format: .dateTime.month().day().hour().minute())").font(.caption).foregroundStyle(Theme.muted)
            }
            if post.isFeatured {
               Label("Featured", systemImage: "star.fill").font(.caption).foregroundStyle(Theme.accent)
            }
            Spacer()
            Text(post.blog).font(Theme.mono(.caption)).foregroundStyle(Theme.muted)
         }
      }

      /// A photo at full width with its caption.
      private func photoView(_ photo: PostPhoto) -> some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.xSmall) {
            AsyncImage(url: app.photoURL(photo.url)) {
               $0.resizable().scaledToFit()
            } placeholder: {
               Theme.surface.frame(height: Theme.Size.detailImagePlaceholder)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            .accessibilityLabel(photo.altText ?? "Photo")
            if let caption = photo.caption { Text(caption).font(.caption).foregroundStyle(Theme.muted) }
         }
      }

      /// Open on the site and share (when the post has a URL), edit and delete.
      @ToolbarContentBuilder
      private var toolbarContent: some ToolbarContent {
         if let url = post.url.flatMap(URL.init(string:)) {
            ToolbarItem { Link(destination: url) { Image(systemName: "safari") }.accessibilityLabel("Open on kof22.com") }
            ToolbarItem { ShareLink(item: url) }
         }
         ToolbarItem {
            Button("Edit") {
               editor = ComposeModel(
                  app: app, composition: PostComposition(post: post),
                  mode: .edit(postID: post.id, version: post.version))
            }
            .accessibilityIdentifier("post.edit")
         }
         ToolbarItem {
            Button(role: .destructive) {
               confirmDelete = true
            } label: {
               Image(systemName: "trash")
            }
            .accessibilityLabel("Delete post")
         }
      }

      /// Re-reads the post after a short pause. The cached copy stays on screen when the
      /// read fails (for example offline), so the failure is logged, not shown.
      private func reload() async {
         do {
            try await Task.sleep(for: .milliseconds(Self.reloadDelayMilliseconds))
         }
         catch {
            ////////////////////////////////////////////////////////////////
            // Cancelled because the screen went away; nothing to reload. //
            ////////////////////////////////////////////////////////////////
            return
         }
         do {
            post = try await app.service.post(id: post.id)
         }
         catch {
            Log.api.notice("Post could not be refreshed: \(error.localizedDescription, privacy: .public)")
         }
      }

      /// Queues the delete, drops the post from the cache and the list, and pops back.
      private func delete() {
         let id = post.id
         let version = post.version
         Task {
            do {
               try await app.submit(PostComposition(post: post), operation: .delete, serverPostID: id, ifMatch: version)
            }
            catch {
               Log.outbox.warning("Delete could not be queued: \(error.localizedDescription, privacy: .public)")
               self.error = error.localizedDescription
               return
            }
            await removeFromCache(id)
            onDelete(id)
            dismiss()
         }
      }

      /// Removes the post from the local cache. The delete is already queued and the next
      /// list load replaces the cache, so a failure here is logged only.
      private func removeFromCache(_ id: Int64) async {
         do {
            try await app.store.removeCached(id)
         }
         catch {
            Log.storage.notice("Deleted post could not be removed from the cache: \(error.localizedDescription, privacy: .public)")
         }
      }
   }

   /// Every stored field of a post that is not its content: the details, SEO fields,
   /// featured image, author, blog and read time, as the server has them.
   struct PostFieldsCard: View {
      /// The post.
      let post: Post
      /// The author's name, when known.
      let authorName: String?

      /// Label and value rows.
      var body: some View {
         VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text("Details").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.heading)
            row("Name", post.name)
            row("Short name", post.shortName)
            row("Slug", post.slug)
            row("Description", post.description)
            row("SEO title", post.metaTitle)
            row("SEO description", post.metaDescription)
            row("Keywords", post.metaKeywords)
            row("Blog", post.blog)
            row("Author", authorName ?? post.authorId.map { "#\($0)" })
            row("Read time", post.readTime.map { "\($0) min" })
            row("Post image", post.featuredMediaId == nil ? "None" : post.featuredImage ?? "Photo #\(post.featuredMediaId ?? 0)")
            row("Photos", "\(post.media.count)")
            row("Published", post.publishedAt?.formatted(date: .abbreviated, time: .shortened))
         }
         .padding(Theme.Spacing.large)
         .frame(maxWidth: .infinity, alignment: .leading)
         .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
         .accessibilityElement(children: .contain)
         .accessibilityIdentifier("post.fields")
      }

      /// One row; a missing value shows a dash.
      private func row(_ label: String, _ value: String?) -> some View {
         HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(Theme.muted)
            Spacer()
            Text(value?.isEmpty == false ? value ?? "" : "–").font(.caption).foregroundStyle(Theme.body).multilineTextAlignment(.trailing)
         }
      }
   }
#endif
